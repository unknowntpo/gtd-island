import AppKit
import Carbon.HIToolbox
import GTDCore
import SwiftUI

let snapshotPath = NSString(string: "~/.gtd-island/snapshot.json").expandingTildeInPath
let tabConfig = TabConfig.load(path: NSString(string: "~/.gtd-island/config.json").expandingTildeInPath)
let refreshScript = NSString(string: "~/.gtd-island/refresh.py").expandingTildeInPath
let routeScript = NSString(string: "~/.gtd-island/route.py").expandingTildeInPath
let routePython = NSString(string: "~/.gtd-island/venv/bin/python").expandingTildeInPath

/// The long-lived `route.py` helper. It holds the model in memory, so it runs only while the tab is in use.
final class RouteProcess {
    private let process = Process()
    private let input = Pipe()

    init(onReply: @escaping (RouteReply?) -> Void, onExit: @escaping () -> Void) throws {
        process.executableURL = URL(fileURLWithPath: routePython)
        process.arguments = ["-I", routeScript]
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let reply = try? RouteReply.decode(Data(buffer[buffer.startIndex..<end]))
                buffer.removeSubrange(buffer.startIndex...end)
                DispatchQueue.main.async { onReply(reply) }
            }
        }
        process.terminationHandler = { _ in DispatchQueue.main.async(execute: onExit) }
        try process.run()
    }

    func send(_ query: String) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else { return }
        try? input.fileHandleForWriting.write(contentsOf: body + Data([10]))
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

extension Color {
    static let islandBackground = Color(red: 0.169, green: 0.161, blue: 0.157)
    static let islandCard = Color(red: 0.208, green: 0.196, blue: 0.192)
    static let islandBorder = Color(red: 0.290, green: 0.275, blue: 0.271)
    static let islandText = Color(red: 0.863, green: 0.867, blue: 0.867)
    static let islandMuted = Color(red: 0.659, green: 0.643, blue: 0.631)
    static let islandAccent = Color(red: 0.773, green: 0.773, blue: 0.416)
}

@MainActor
final class Store: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var tab: GTDTab = .now {
        didSet {
            guard tab != oldValue else { return }
            if tab == .find { startRoute() } else { stopRoute() }
            if tab == .activity { startActivitySync() } else { stopActivitySync() }
        }
    }
    /// Collapsing the panel returns to the first tab, so this also stops the sync on collapse.
    var activitySyncSeconds: UInt64 = 60
    private var activitySync: Task<Void, Never>?
    @Published var hoveredArea: String?
    @Published var thirdSlot: GTDTab? = ThirdSlot.load(config: tabConfig)
    @Published var isExpanded = false
    @Published var isRefreshing = false
    @Published var error: String?
    @Published var query = ""
    @Published var matches: [SessionMatch] = []
    @Published var isRouting = false
    @Published var routeError: String?
    /// Set only by the Option+J path, so the text field never takes focus on hover or click.
    @Published var wantsFieldFocus = false
    var collapse: () -> Void = {}
    private var route: RouteProcess?
    private var routeGeneration = 0
    private var sent = 0
    private var received = 0
    private var debounce: Task<Void, Never>?

    func startRoute() {
        guard route == nil else { return }
        routeError = nil
        routeGeneration += 1
        let generation = routeGeneration
        do {
            route = try RouteProcess(
                onReply: { [weak self] reply in
                    MainActor.assumeIsolated {
                        guard let self, generation == self.routeGeneration else { return }
                        self.receive(reply)
                    }
                },
                onExit: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, generation == self.routeGeneration else { return }
                        self.route = nil
                        self.isRouting = false
                        self.routeError = "模型無法使用。請重新執行 install.sh,其他分頁不受影響。"
                    }
                })
        } catch {
            routeError = "模型無法使用。請重新執行 install.sh,其他分頁不受影響。"
        }
    }

    func stopRoute() {
        routeGeneration += 1
        debounce?.cancel()
        route?.stop()
        route = nil
        query = ""
        matches = []
        isRouting = false
        sent = 0
        received = 0
    }

    func queryChanged() {
        debounce?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            matches = []
            isRouting = false
            return
        }
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, let route = self.route else { return }
            self.sent += 1
            self.isRouting = true
            route.send(text)
        }
    }

    /// Replies arrive in order. Only the newest request's reply reaches the list.
    private func receive(_ reply: RouteReply?) {
        received += 1
        guard received == sent else { return }
        isRouting = false
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        routeError = reply == nil ? "模型回覆無法解析。" : reply?.error
        matches = reply?.matches ?? []
    }

    func open(_ match: SessionMatch) {
        if let target = match.target { NSWorkspace.shared.open(target) }
        collapse()
    }

    func openMatch(number: Int) {
        if number >= 1, number <= matches.count { open(matches[number - 1]) }
    }

    var visible: (actionable: [Project], waiting: [Project]) {
        Ranking.view(tab, rows: snapshot?.rows ?? [], today: Date(), config: tabConfig, thirdSlot: thirdSlot)
    }

    func chooseThirdSlot(_ tab: GTDTab?) {
        thirdSlot = tab
        ThirdSlot.save(tab)
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: snapshotPath) else { return }
        do { snapshot = try Snapshot.decode(data) } catch { self.error = "快照無法解析,請按重新整理。" }
    }

    func refreshIfStale() {
        if snapshot?.isStale(now: Date()) ?? true { refresh() }
    }

    func startActivitySync() {
        activitySync?.cancel()
        activitySync = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.refresh(apiOnly: true)
                try? await Task.sleep(nanoseconds: self.activitySyncSeconds * 1_000_000_000)
            }
        }
    }

    func stopActivitySync() {
        activitySync?.cancel()
        activitySync = nil
    }

    func refresh(apiOnly: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        error = nil
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", refreshScript] + (apiOnly ? ["--api-only"] : [])
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var succeeded = false
            do {
                try process.run()
                process.waitUntilExit()
                succeeded = process.terminationStatus == 0
            } catch {}
            let ok = succeeded
            await MainActor.run {
                self.isRefreshing = false
                if ok { self.load() } else { self.error = "更新失敗,目前顯示舊資料。請確認 Notion token 和連線。" }
            }
        }
    }

    func open(_ project: Project) {
        if let target = project.target { NSWorkspace.shared.open(target) }
        collapse()
    }

    /// Number keys follow what the list shows: 1 is the first actionable row.
    func open(number: Int) {
        let rows = visible.actionable
        if number >= 1, number <= rows.count { open(rows[number - 1]) }
    }
}

struct PillView: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.islandAccent).frame(width: 7, height: 7)
            Text(store.visibleTop).lineLimit(1).font(.system(size: 12, weight: .medium))
                .foregroundColor(.islandText)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
}

extension Store {
    var visibleTop: String {
        guard let first = Ranking.actionable(snapshot?.rows ?? [], today: Date()).first else { return "GTD · 尚無資料" }
        return first.nextAction
    }
}

struct RowView: View {
    let index: Int?
    let project: Project
    let action: () -> Void
    @State private var isHovering = false

    /// A session is the main way back into work, so it reads as a filled button.
    var openLabel: some View {
        Text(project.opensSession ? "打開 session ↗" : "打開 Notion ↗")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(project.opensSession ? .islandBackground : .islandAccent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(project.opensSession ? Color.islandAccent : Color.clear)
            .overlay(Capsule().stroke(Color.islandAccent))
            .clipShape(Capsule())
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(index.map(String.init) ?? "·").font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.islandMuted).frame(width: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title).font(.system(size: 11)).foregroundColor(.islandMuted).lineLimit(1)
                    Text(project.nextAction).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.islandText).lineLimit(3).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if let label = project.deadlineLabel(today: Date()) {
                            Text(label.text).foregroundColor(label.isOverdue ? .islandMuted : .islandAccent)
                        }
                        if project.thisWeek { Text("本週").foregroundColor(.islandMuted) }
                        Spacer(minLength: 0)
                        openLabel
                    }.font(.system(size: 11))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.islandBorder : Color.islandCard)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isHovering ? Color.islandAccent : Color.islandBorder))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct ActivityChart: View {
    @ObservedObject var store: Store

    func row(_ bar: ActivityBar, largest: Int) -> some View {
        let isHovered = store.hoveredArea == bar.label
        return HStack(spacing: 8) {
            Text(bar.label).font(.system(size: 12)).lineLimit(1)
                .foregroundColor(isHovered ? .islandText : .islandMuted)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geometry in
                let unit = geometry.size.width / CGFloat(max(largest, 1))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.islandAccent.opacity(isHovered ? 0.6 : 0.35))
                        .frame(width: max(2, unit * CGFloat(bar.minutes)), height: 10)
                    if bar.todayMinutes > 0 {
                        RoundedRectangle(cornerRadius: 2).fill(Color.islandAccent)
                            .frame(width: max(2, unit * CGFloat(bar.todayMinutes)), height: 10)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { store.hoveredArea = bar.label } else if isHovered { store.hoveredArea = nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let entries = store.snapshot?.timeLog {
                let bars = Activity.bars(entries, today: Date())
                let total = bars.reduce(0) { $0 + $1.minutes }
                Text("最近 7 天的時間分配 · 亮色是今天")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.islandMuted).padding(.bottom, 4)
                if bars.isEmpty {
                    Text("最近 7 天的 Time Log 沒有紀錄。").font(.system(size: 12)).foregroundColor(.islandMuted)
                }
                ForEach(bars) { row($0, largest: bars.first?.minutes ?? 1) }
                if let bar = bars.first(where: { $0.label == store.hoveredArea }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(bar.label) · \(bar.summary(total: total))")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.islandText)
                        ForEach(Array(bar.titles.enumerated()), id: \.offset) { _, title in
                            Text(title).font(.system(size: 12)).foregroundColor(.islandMuted).lineLimit(1)
                        }
                    }
                    .padding(.top, 10)
                }
            } else {
                Text("還沒有時間資料。Time Log 要用 Notion token 讀取,請確認 token 後按重新整理。")
                    .font(.system(size: 12)).foregroundColor(.islandMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MatchRow: View {
    let index: Int
    let match: SessionMatch
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Text("⌘\(index)").font(.system(size: 11, design: .monospaced)).foregroundColor(.islandMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(match.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.islandText)
                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !match.folder.isEmpty {
                        Text(match.folder).font(.system(size: 11)).foregroundColor(.islandMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text("打開 ↗").font(.system(size: 11, weight: .semibold)).foregroundColor(.islandAccent)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.islandBorder : Color.islandCard)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isHovering ? Color.islandAccent : Color.islandBorder))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct FindView: View {
    @ObservedObject var store: Store
    @FocusState private var isFieldFocused: Bool

    func takeFocusIfAsked() {
        guard store.wantsFieldFocus else { return }
        store.wantsFieldFocus = false
        DispatchQueue.main.async { isFieldFocused = true }
    }

    var hint: String {
        if store.isRouting { return store.matches.isEmpty ? "比對中…第一次要載入模型,大約幾秒。" : "比對中…" }
        return "輸入一句話,相關的 session 會列在這裡。Enter 打開第 1 列。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("例如:上週修到一半的登入錯誤", text: $store.query)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.islandText)
                .padding(8)
                .background(Color.islandCard)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isFieldFocused ? Color.islandAccent : Color.islandBorder))
                .focused($isFieldFocused)
                .onSubmit { store.openMatch(number: 1) }
                .onChange(of: store.query) { _ in store.queryChanged() }
                .onChange(of: store.wantsFieldFocus) { _ in takeFocusIfAsked() }
                .onAppear(perform: takeFocusIfAsked)
            if let error = store.routeError {
                Text("× \(error)").font(.system(size: 12)).foregroundColor(Color(red: 0.96, green: 0.69, blue: 0.67))
            }
            if store.isRouting || store.matches.isEmpty {
                Text(hint).font(.system(size: 12)).foregroundColor(.islandMuted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(store.matches.enumerated()), id: \.element.id) { i, match in
                        MatchRow(index: i + 1, match: match) { store.open(match) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ExpandedView: View {
    @ObservedObject var store: Store

    var ageText: String {
        guard let at = store.snapshot?.fetchedAt else { return "尚未同步" }
        let minutes = Int(Date().timeIntervalSince(at) / 60)
        return minutes < 1 ? "剛同步" : minutes < 60 ? "\(minutes) 分鐘前同步" : "\(minutes / 60) 小時前同步"
    }

    func thirdSlotButton(_ label: String, _ tab: GTDTab?) -> some View {
        Button(label) { store.chooseThirdSlot(tab) }
            .buttonStyle(.plain).font(.system(size: 11, weight: store.thirdSlot == tab ? .semibold : .regular))
            .foregroundColor(store.thirdSlot == tab ? .islandAccent : .islandMuted)
            .padding(.horizontal, 5).padding(.vertical, 2)
    }

    var body: some View {
        let view = store.visible
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(tabConfig.tabs) { tab in
                    Button(tab.name) { store.tab = tab }
                        .buttonStyle(.plain).font(.system(size: 12, weight: store.tab == tab ? .semibold : .regular))
                        .foregroundColor(store.tab == tab ? .islandAccent : .islandMuted)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                Spacer()
            }
            if let error = store.error {
                Text("× \(error)").font(.system(size: 12)).foregroundColor(Color(red: 0.96, green: 0.69, blue: 0.67))
            }
            if store.tab == .find {
                FindView(store: store)
            } else if store.tab == .activity {
                ActivityChart(store: store)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if view.actionable.isEmpty { Text("這裡目前沒有可動手的下一步。").foregroundColor(.islandMuted).font(.system(size: 13)) }
                        ForEach(Array(view.actionable.enumerated()), id: \.element.id) { i, project in
                            RowView(index: i < 9 ? i + 1 : nil, project: project) { store.open(project) }
                        }
                        if !view.waiting.isEmpty {
                            Text("等別人").font(.system(size: 11, weight: .semibold)).foregroundColor(.islandMuted).padding(.top, 6)
                            ForEach(view.waiting) { project in
                                RowView(index: nil, project: project) { store.open(project) }.opacity(0.7)
                            }
                        }
                    }
                }
            }
            if store.tab == .now {
                HStack(spacing: 2) {
                    Text("第 3 格").font(.system(size: 11)).foregroundColor(.islandMuted).padding(.trailing, 4)
                    ForEach(tabConfig.thirdSlotChoices) { tab in thirdSlotButton(tab.name, tab) }
                    thirdSlotButton("不固定", nil)
                    Spacer()
                }
            }
            HStack {
                Text(store.isRefreshing ? "同步中…" : ageText).font(.system(size: 11)).foregroundColor(.islandMuted)
                Spacer()
                Button("重新整理") { store.refresh() }.buttonStyle(.plain).font(.system(size: 12))
                    .foregroundColor(.islandAccent).disabled(store.isRefreshing)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.islandBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct RootView: View {
    @ObservedObject var store: Store
    let tap: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        if store.isExpanded {
            ExpandedView(store: store)
        } else {
            PillView(store: store).onTapGesture(perform: tap).onHover(perform: hover)
        }
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var panel: IslandPanel!
    var hotKey: EventHotKeyRef?
    var findHotKey: EventHotKeyRef?
    var hoverOpen: DispatchWorkItem?
    static var shared: AppDelegate!
    let pillSize = NSSize(width: 340, height: 30)
    let expandedSize = NSSize(width: 480, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // A helper that died must not end the app when the panel writes to its pipe.
        signal(SIGPIPE, SIG_IGN)
        store.collapse = { [weak self] in self?.setExpanded(false) }
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let host = NSHostingView(rootView: RootView(store: store,
                                                    tap: { [weak self] in self?.setExpanded(true) },
                                                    hover: { [weak self] inside in self?.pillHover(inside) }))
        // The panel's frame comes only from `frame(for:)`; SwiftUI must not resize the window.
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame(for: pillSize), display: true)
        panel.orderFrontRegardless()
        store.load()
        store.refreshIfStale()
        registerHotKey()

        if CommandLine.arguments.contains("--selftest") { runSelfTest(); return }
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-find"), flag + 1 < CommandLine.arguments.count {
            runFindSelfTest(query: CommandLine.arguments[flag + 1]); return
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.store.isExpanded else { return event }
            // Esc and Enter belong to the input method while it is composing text.
            if (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.setExpanded(false); return nil }
            guard let digit = Int(event.charactersIgnoringModifiers ?? "") else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if self.store.tab == .find {
                if modifiers == .command { self.store.openMatch(number: digit); return nil }
                return event
            }
            if modifiers.isEmpty { self.store.open(number: digit); return nil }
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.setExpanded(false) }
        }
    }

    /// Opens and closes quickly, forces the frame the bug produced, and checks the panel recovers.
    func runSelfTest() {
        for (i, expanded) in [true, false, true, true, false, true].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) { self.setExpanded(expanded) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let pill = self.frame(for: self.pillSize)
            self.panel.setFrame(NSRect(origin: pill.origin, size: self.expandedSize), display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let want = self.frame(for: self.expandedSize)
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let ok = self.store.isExpanded && self.panel.frame == want && screen.contains(want)
            print(ok ? "PASS" : "FAIL", "frame", self.panel.frame, "want", want)
            exit(ok ? 0 : 1)
        }
    }

    /// Checks focus on both paths, then runs one real query through `route.py`.
    func runFindSelfTest(query: String) {
        setExpanded(true)
        store.tab = .find
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let plainOpen = self.panel.firstResponder is NSTextView
            self.setExpanded(false)
            let helperStopped = self.store.tab == .now
            self.showFind()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let hotKeyOpen = self.panel.firstResponder is NSTextView
                print("focus after plain open:", plainOpen, "after Option+J path:", hotKeyOpen, "collapse leaves tab:", helperStopped)
                self.store.query = query
                self.waitForMatches(deadline: Date().addingTimeInterval(60), started: Date(), ok: !plainOpen && hotKeyOpen)
            }
        }
    }

    func waitForMatches(deadline: Date, started: Date, ok: Bool) {
        if !store.matches.isEmpty || Date() > deadline || store.routeError != nil {
            print(String(format: "first reply: %.1f s", Date().timeIntervalSince(started)), "error:", store.routeError ?? "none")
            store.matches.forEach { print(" -", $0.title, "|", $0.folder) }
            exit(ok && !store.matches.isEmpty ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForMatches(deadline: deadline, started: started, ok: ok) }
    }

    func frame(for size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.maxY - size.height - 4, width: size.width, height: size.height)
    }

    var targetFrame: NSRect { frame(for: store.isExpanded ? expandedSize : pillSize) }

    func windowDidResize(_ notification: Notification) { keepFrame() }
    func windowDidMove(_ notification: Notification) { keepFrame() }

    func keepFrame() {
        if panel.frame != targetFrame { panel.setFrame(targetFrame, display: true) }
    }

    /// A short delay keeps a mouse passing over the pill from opening the panel.
    func pillHover(_ inside: Bool) {
        hoverOpen?.cancel()
        hoverOpen = nil
        guard inside, !store.isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(true) }
        hoverOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != store.isExpanded else { return }
        hoverOpen?.cancel()
        hoverOpen = nil
        store.isExpanded = expanded
        panel.setFrame(targetFrame, display: true)
        if expanded {
            store.load()
            store.refreshIfStale()
            panel.makeKeyAndOrderFront(nil)
        } else {
            store.tab = .now
            // Leaving the screen gives up key status, so typing returns to the previous app.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func showFind() {
        store.wantsFieldFocus = true
        setExpanded(true)
        store.tab = .find
        panel.makeKeyAndOrderFront(nil)
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let isFind = pressed.id == 2
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let app = AppDelegate.shared!
                    if isFind { app.showFind() } else { app.setExpanded(!app.store.isExpanded) }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let signature = OSType(0x4754_4449)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(optionKey), EventHotKeyID(signature: signature, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { store.error = "Option+G 已被其他 app 佔用,請把滑鼠移到膠囊上打開面板。" }
        let findStatus = RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(optionKey), EventHotKeyID(signature: signature, id: 2),
                                             GetApplicationEventTarget(), 0, &findHotKey)
        if findStatus != noErr { store.error = "Option+J 已被其他 app 佔用,請點「找 session」分頁後再點文字框。" }
    }
}

// `--selftest-sync` runs the activity sync against real Notion data and counts the snapshot rewrites.
if CommandLine.arguments.contains("--selftest-sync") {
    MainActor.assumeIsolated {
        let store = Store()
        store.activitySyncSeconds = 3
        func modified() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: snapshotPath))?[.modificationDate] as? Date
        }
        func writes(during seconds: Int) -> Int {
            var seen = modified(), count = 0
            for _ in 0..<(seconds * 5) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                if modified() != seen { seen = modified(); count += 1 }
            }
            return count
        }
        store.tab = .activity
        let open = writes(during: 11)
        store.tab = .now
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let closed = writes(during: 8)
        print("writes while open: \(open), after leaving: \(closed), error: \(store.error ?? "none")")
        exit(open >= 2 && closed == 0 && store.error == nil ? 0 : 1)
    }
}

// `--render <dir>` writes the views to PNG files so they can be checked without a screen.
if let flag = CommandLine.arguments.firstIndex(of: "--render"), flag + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[flag + 1]
    MainActor.assumeIsolated {
        let store = Store()
        store.load()
        @MainActor func save(_ name: String, _ view: some View, _ size: NSSize) {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            FileManager.default.createFile(atPath: "\(dir)/\(name).png", contents: rep.representation(using: .png, properties: [:]))
        }
        save("pill", PillView(store: store), NSSize(width: 340, height: 30))
        save("now", ExpandedView(store: store), NSSize(width: 480, height: 560))
        store.tab = tabConfig.thirdSlotChoices[0]
        save("first-tab", ExpandedView(store: store), NSSize(width: 480, height: 560))
        store.tab = .activity
        save("activity", ExpandedView(store: store), NSSize(width: 480, height: 560))
        store.hoveredArea = Activity.bars(store.snapshot?.timeLog ?? [], today: Date()).first?.label
        save("activity-hover", ExpandedView(store: store), NSSize(width: 480, height: 560))
        store.tab = .find
        save("find-empty", ExpandedView(store: store), NSSize(width: 480, height: 560))
        store.query = "上週修到一半的登入錯誤"
        store.matches = [
            SessionMatch(id: "1", title: "修登入錯誤(接手)", cwd: "/repo/app"),
            SessionMatch(id: "2", title: "登入流程重構", cwd: "/repo/app"),
        ]
        save("find-matches", ExpandedView(store: store), NSSize(width: 480, height: 560))
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
