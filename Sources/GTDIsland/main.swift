import AppKit
import Carbon.HIToolbox
import GTDCore
import SwiftUI

let snapshotPath = NSString(string: "~/.gtd-island/snapshot.json").expandingTildeInPath
let tabConfig = TabConfig.load(path: NSString(string: "~/.gtd-island/config.json").expandingTildeInPath)
let refreshScript = NSString(string: "~/.gtd-island/refresh.py").expandingTildeInPath
let routeScript = NSString(string: "~/.gtd-island/route.py").expandingTildeInPath
let routePython = NSString(string: "~/.gtd-island/venv/bin/python").expandingTildeInPath
let attentionFolder = NSString(string: "~/.gtd-island/attention").expandingTildeInPath
let requestsFolder = NSString(string: "~/.gtd-island/requests").expandingTildeInPath
let responsesFolder = NSString(string: "~/.gtd-island/responses").expandingTildeInPath
let aliveFile = NSString(string: "~/.gtd-island/island.alive").expandingTildeInPath
let desktopSessionsRoot = NSString(string: "~/Library/Application Support/Claude/claude-code-sessions").expandingTildeInPath

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
    @Published var searchOpen = false
    /// The selected row of the search box (AC56), by id; nil means the first row.
    @Published var selectedID: String?
    var selection: Int { Search.index(of: selectedID, in: searchRows) }
    private var sessions: [DesktopSession] = []
    var closeSearch: () -> Void = {}
    @Published var attention: [AttentionItem] = []
    /// How the collapsed panel is drawn; set by AppDelegate from where the panel sits.
    @Published var notch = NotchLayout(atTop: false, gap: 0, menuBar: 24)
    private var desktopIndex: [String: String] = [:]
    private var unknownIDs: Set<String> = []
    private var indexedAt = Date.distantPast
    private var attentionTimer: Timer?
    /// Choices made so far on each question request, by request id (AC48).
    @Published var choices: [String: [String: Set<String>]] = [:]
    private var seenRequests: Set<String> = []
    /// Called when a request the panel has not shown before appears; returns false when it could not show it (AC49).
    var onNewRequest: () -> Bool = { true }
    var collapse: () -> Void = {}
    private var route: RouteProcess?
    private var routeGeneration = 0
    private var sent = 0
    private var sentText = ""
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
                        self.routeError = "模型無法使用,只比對標題。請重新執行 install.sh。"
                    }
                })
        } catch {
            routeError = "模型無法使用,只比對標題。請重新執行 install.sh。"
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

    var searchRows: [SearchRow] {
        Search.rows(query: query, attention: attention, sessions: sessions, matches: matches)
    }

    /// Reads the session list once per opening and starts the model helper (AC57).
    func openSearch() {
        sessions = DesktopSession.all(root: desktopSessionsRoot)
        selectedID = nil
        searchOpen = true
        startRoute()
    }

    func endSearch() {
        searchOpen = false
        stopRoute()
        selectedID = nil
    }

    func moveSelection(_ step: Int) {
        let rows = searchRows
        let next = Search.move(Search.index(of: selectedID, in: rows), by: step, count: rows.count)
        if rows.indices.contains(next) { selectedID = rows[next].id }
    }

    func open(_ row: SearchRow) {
        guard let target = row.target else { return }
        NSWorkspace.shared.open(target)
        closeSearch()
    }

    func openSelected() {
        let rows = searchRows
        let index = Search.index(of: selectedID, in: rows)
        if rows.indices.contains(index) { open(rows[index]) }
    }

    func queryChanged() {
        debounce?.cancel()
        selectedID = nil
        // Matches belong to the text they were found for.
        matches = []
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            isRouting = false
            return
        }
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, let route = self.route else { return }
            self.sent += 1
            self.sentText = text
            self.isRouting = true
            route.send(text)
        }
    }

    /// Replies arrive in order. Only the newest request's reply reaches the list.
    private func receive(_ reply: RouteReply?) {
        received += 1
        guard received == sent else { return }
        isRouting = false
        // A reply for text the user has since changed is dropped; the new text gets its own reply.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == sentText, !sentText.isEmpty else { return }
        routeError = reply == nil ? "模型回覆無法解析。" : reply?.error
        let before = searchRows
        matches = reply?.matches ?? []
        if searchRows != before { selectedID = nil }
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
        run(apiOnly ? ["--api-only"] : [], failure: "更新失敗,目前顯示舊資料。請確認 Notion token 和連線。")
    }

    /// Unchecks This Week in Notion, then syncs so the list reorders.
    func postpone(_ project: Project) {
        run(["--postpone", project.pageID], failure: "延後失敗,Notion 沒有改動。請確認 Notion token 和連線。")
    }

    func run(_ arguments: [String], failure: String) {
        guard !isRefreshing else { return }
        isRefreshing = true
        error = nil
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", refreshScript] + arguments
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
                if ok { self.load() } else { self.error = failure }
            }
        }
    }

    /// Rereads the attention folder every 3 seconds (AC39).
    func startAttention() {
        reloadAttention()
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadAttention() }
        }
    }

    func reloadAttention() {
        let records = AttentionRecord.load(folder: attentionFolder)
        // Rebuild the id index only when a session it has not seen appears, since it reads every session file.
        let unknown = Set(records.map(\.sessionId)).subtracting(desktopIndex.keys)
        // A new desktop session may get its CLI id after its first record, so also rebuild once a minute.
        if !unknown.isEmpty, unknown != unknownIDs || Date().timeIntervalSince(indexedAt) > 60 {
            indexedAt = Date()
            desktopIndex = DesktopSession.index(root: desktopSessionsRoot)
            unknownIDs = unknown
        }
        var desktop: [String: DesktopSession] = [:]
        for record in records {
            if let path = desktopIndex[record.sessionId],
               let session = FileManager.default.contents(atPath: path).flatMap(DesktopSession.decode) {
                desktop[record.sessionId] = session
            }
        }
        markAlive()
        let requests = PendingRequest.load(folder: requestsFolder, now: Date())
        let items = Attention.items(records, desktop: desktop, now: Date(), requests: requests)
        if items != attention { attention = items }
        let ids = Set(requests.map(\.id))
        let fresh = !ids.subtracting(seenRequests).isEmpty
        // A request the panel could not show stays unseen, so it opens the panel later.
        if !fresh || onNewRequest() { seenRequests = ids }
        choices = choices.filter { ids.contains($0.key) }
        removeOldReplies()
    }

    /// Replies the hook never read (it had already given up) are removed once no hook can wait for them.
    func removeOldReplies() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: responsesFolder)) ?? [] {
            let path = (responsesFolder as NSString).appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
            if Date().timeIntervalSince(modified) > PendingRequest.maxAge { try? fm.removeItem(atPath: path) }
        }
    }

    /// Tells the hook the panel is running (AC43).
    func markAlive() {
        let fm = FileManager.default
        if fm.fileExists(atPath: aliveFile) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: aliveFile)
        } else {
            fm.createFile(atPath: aliveFile, contents: Data())
        }
    }

    func reply(_ request: PendingRequest, _ body: Data) {
        try? FileManager.default.createDirectory(atPath: responsesFolder, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: responsesFolder).appendingPathComponent(request.id + ".json")
        try? body.write(to: url, options: .atomic)
        // The hook removes the request file once it reads the reply; hide it now so it is not answered twice.
        attention = attention.map { item in
            guard item.request?.id == request.id else { return item }
            var copy = item
            copy.request = nil
            return copy
        }
    }

    func decide(_ request: PendingRequest, _ decision: String) { reply(request, PendingRequest.reply(decision: decision)) }

    func toggle(_ request: PendingRequest, _ question: AskQuestion, _ label: String) {
        var picked = choices[request.id]?[question.question] ?? []
        if question.multiSelect == true {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            picked = [label]
        }
        choices[request.id, default: [:]][question.question] = picked
    }

    func submit(_ request: PendingRequest) {
        guard let body = request.reply(choices: choices[request.id] ?? [:]) else { return }
        reply(request, body)
    }

    func open(_ item: AttentionItem) {
        guard let target = item.target else { return }
        NSWorkspace.shared.open(target)
        collapse()
    }

    func jump(for project: Project) -> Jump {
        snapshot?.jump(for: project) ?? Jump.resolve(project, actions: [])
    }

    func open(_ project: Project) {
        if let target = jump(for: project).url { NSWorkspace.shared.open(target) }
        collapse()
    }

    /// Number keys follow what the list shows: 1 is the first actionable row.
    func open(number: Int) {
        if tab == .waiting {
            if number >= 1, number <= attention.count { open(attention[number - 1]) }
            return
        }
        let rows = visible.actionable
        if number >= 1, number <= rows.count { open(rows[number - 1]) }
    }
}

/// Where the collapsed panel sits: against the screen's top edge, and how wide the camera notch is there.
struct NotchLayout: Equatable {
    var atTop: Bool
    var gap: CGFloat
    var menuBar: CGFloat = 24
}

/// Flat top and round bottom corners when the panel hangs from the top edge; a capsule elsewhere (AC39).
struct IslandShape: Shape {
    let atTop: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        if atTop {
            return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius).path(in: rect)
        }
        return RoundedRectangle(cornerRadius: min(radius, rect.height / 2)).path(in: rect)
    }
}

struct PillView: View {
    @ObservedObject var store: Store

    var waiting: some View {
        HStack(spacing: 5) {
            Circle().fill(store.attention.isEmpty ? Color.islandAccent : Color.orange).frame(width: 7, height: 7)
            if !store.attention.isEmpty {
                Text("\(store.attention.count) 等你").font(.system(size: 12, weight: .semibold)).foregroundColor(.islandText)
            }
        }
    }

    var next: some View {
        Text(store.visibleTop).lineLimit(1).font(.system(size: 12, weight: .medium)).foregroundColor(.islandText)
    }

    var body: some View {
        HStack(spacing: 8) {
            if store.notch.gap > 0 {
                // Nothing goes under the camera: the count sits left of it, the next step right of it.
                waiting.frame(maxWidth: .infinity, alignment: .trailing)
                Spacer().frame(width: store.notch.gap)
                next.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                waiting
                next
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(IslandShape(atTop: store.notch.atTop, radius: store.notch.atTop ? 10 : 15))
        .contentShape(Rectangle())
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
    let jump: Jump
    var postpone: (() -> Void)? = nil
    let action: () -> Void
    @State private var isHovering = false

    /// A session is the main way back into work, so it reads as a filled button.
    var openLabel: some View {
        Text(jump.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(jump.kind == .session ? .islandBackground : .islandAccent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(jump.kind == .session ? Color.islandAccent : Color.clear)
            .overlay(Capsule().stroke(Color.islandAccent))
            .clipShape(Capsule())
    }

    var body: some View {
        // A tap gesture, not a Button, so the 延後 button inside wins its own clicks.
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
                    if let postpone, project.canPostpone {
                        Button("延後", action: postpone).buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundColor(.islandMuted)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(Capsule().stroke(Color.islandBorder))
                            .help("取消本週,讓它排到後面")
                    }
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
        .onTapGesture(perform: action)
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

struct SearchRowView: View {
    let row: SearchRow
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Circle().fill(row.waiting ? Color.islandAccent : Color.clear).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.islandText).lineLimit(1)
                    if !row.note.isEmpty {
                        Text(row.note).font(.system(size: 11)).foregroundColor(row.waiting ? .islandAccent : .islandMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(row.target == nil ? "在終端機" : (selected ? "打開 ↩" : "")).font(.system(size: 11)).foregroundColor(.islandMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.islandBorder : (isHovering ? Color.islandCard : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The Raycast-like search box (AC52-AC56). It sits in its own window, apart from the notch panel.
struct SearchView: View {
    @ObservedObject var store: Store
    @FocusState private var isFieldFocused: Bool

    var hint: String? {
        if store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.searchRows.isEmpty ? "沒有等你的 session。輸入文字找其他 session。" : nil
        }
        if store.isRouting { return "模型比對中…" }
        return store.searchRows.isEmpty ? "找不到符合的 session。" : nil
    }

    var body: some View {
        let rows = store.searchRows
        let selection = Search.index(of: store.selectedID, in: rows)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundColor(.islandMuted)
                TextField("找 session…", text: $store.query)
                    .textFieldStyle(.plain).font(.system(size: 20)).foregroundColor(.islandText)
                    .focused($isFieldFocused)
                    .onChange(of: store.query) { _ in store.queryChanged() }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            Rectangle().fill(Color.islandBorder).frame(height: 1)
            if store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !rows.isEmpty {
                Text("等你").font(.system(size: 11, weight: .semibold)).foregroundColor(.islandMuted).padding(.horizontal, 14).padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    SearchRowView(row: row, selected: i == selection) { store.open(row) }
                }
            }
            .padding(.horizontal, 6)
            if let error = store.routeError {
                Text("× \(error)").font(.system(size: 11)).foregroundColor(Color(red: 0.96, green: 0.69, blue: 0.67)).padding(.horizontal, 14)
            }
            if let hint { Text(hint).font(.system(size: 12)).foregroundColor(.islandMuted).padding(.horizontal, 14) }
            HStack(spacing: 12) {
                Spacer()
                Text("↑↓ 選擇").font(.system(size: 11)).foregroundColor(.islandMuted)
                Text("↩ 打開").font(.system(size: 11)).foregroundColor(.islandMuted)
                Text("esc 關閉").font(.system(size: 11)).foregroundColor(.islandMuted)
            }
            .padding(.horizontal, 14).padding(.bottom, 10).padding(.top, 2)
        }
        .background(Color.islandBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.islandBorder))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.searchOpen) { open in if open { DispatchQueue.main.async { isFieldFocused = true } } }
        .onAppear { isFieldFocused = true }
    }
}

/// A small capsule button for answering in the panel.
struct ChoiceButton: View {
    let label: String
    var selected = false
    var primary = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: primary || selected ? .semibold : .regular))
                .foregroundColor(primary || selected ? .islandBackground : .islandText)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(primary || selected ? Color.islandAccent : Color.clear)
                .overlay(Capsule().stroke(selected || primary ? Color.islandAccent : Color.islandBorder))
                .clipShape(Capsule())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The permission or question a hook is waiting on, with the buttons that answer it (AC48).
struct RequestView: View {
    @ObservedObject var store: Store
    let request: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if request.isQuestion {
                ForEach(request.questions ?? [], id: \.question) { q in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(q.question + (q.multiSelect == true ? "(可複選)" : ""))
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.islandText)
                            .fixedSize(horizontal: false, vertical: true)
                        FlowRow(spacing: 6) {
                            ForEach(q.options, id: \.label) { option in
                                ChoiceButton(label: option.label,
                                             selected: store.choices[request.id]?[q.question]?.contains(option.label) ?? false) {
                                    store.toggle(request, q, option.label)
                                }
                                .help(option.description ?? "")
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    ChoiceButton(label: "送出", primary: true,
                                 enabled: request.reply(choices: store.choices[request.id] ?? [:]) != nil) { store.submit(request) }
                    ChoiceButton(label: "到 app 處理") { store.decide(request, "skip") }
                }
            } else {
                HStack(spacing: 6) {
                    ChoiceButton(label: "允許", primary: true) { store.decide(request, "allow") }
                    ChoiceButton(label: "拒絕") { store.decide(request, "deny") }
                    ChoiceButton(label: "到 app 處理") { store.decide(request, "skip") }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Lays children left to right and wraps to a new line when the row is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

struct AttentionRow: View {
    @ObservedObject var store: Store
    let index: Int
    let item: AttentionItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index <= 9 ? String(index) : "·").font(.system(size: 12, design: .monospaced))
                .foregroundColor(.islandMuted).frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.islandText)
                    .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                // A permission request shows the full command it asks about.
                let reason = item.request.flatMap { $0.isQuestion ? nil : $0.detail } ?? item.reason
                Text(reason).font(.system(size: 12, design: item.request?.isQuestion == false ? .monospaced : .default))
                    .foregroundColor(item.needsYou ? .orange : .islandMuted).lineLimit(item.request == nil ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(Attention.age(item.at, now: Date()))
                    if !item.folder.isEmpty { Text(item.folder).lineLimit(1) }
                    Spacer(minLength: 0)
                    if item.target == nil {
                        Text("在終端機")
                    } else {
                        Text("打開 session ↗").font(.system(size: 11, weight: .semibold)).foregroundColor(.islandAccent)
                    }
                }.font(.system(size: 11)).foregroundColor(.islandMuted)
                if let request = item.request { RequestView(store: store, request: request) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering && item.target != nil ? Color.islandBorder : Color.islandCard)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isHovering && item.target != nil ? Color.islandAccent : Color.islandBorder))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
    }
}

struct AttentionView: View {
    @ObservedObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if store.attention.isEmpty {
                    Text("目前沒有 session 在等你。").foregroundColor(.islandMuted).font(.system(size: 13))
                }
                ForEach(Array(store.attention.enumerated()), id: \.element.id) { i, item in
                    AttentionRow(store: store, index: i + 1, item: item) { store.open(item) }
                }
            }
        }
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
                    Button(tab == .waiting && !store.attention.isEmpty ? "等你 \(store.attention.count)" : tab.name) { store.tab = tab }
                        .buttonStyle(.plain).font(.system(size: 12, weight: store.tab == tab ? .semibold : .regular))
                        .foregroundColor(store.tab == tab ? .islandAccent : .islandMuted)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 4)
                }
                Spacer()
                Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundColor(.islandMuted)
                    .help("拖曳移動面板")
            }
            .contentShape(Rectangle())
            .modifier(PanelDrag())
            if let error = store.error {
                Text("× \(error)").font(.system(size: 12)).foregroundColor(Color(red: 0.96, green: 0.69, blue: 0.67))
            }
            if store.tab == .waiting {
                AttentionView(store: store)
            } else if store.tab == .activity {
                ActivityChart(store: store)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if view.actionable.isEmpty { Text("這裡目前沒有可動手的下一步。").foregroundColor(.islandMuted).font(.system(size: 13)) }
                        ForEach(Array(view.actionable.enumerated()), id: \.element.id) { i, project in
                            RowView(index: i < 9 ? i + 1 : nil, project: project, jump: store.jump(for: project),
                                    postpone: { store.postpone(project) }) { store.open(project) }
                        }
                        if !view.waiting.isEmpty {
                            Text("等別人").font(.system(size: 11, weight: .semibold)).foregroundColor(.islandMuted).padding(.top, 6)
                            ForEach(view.waiting) { project in
                                RowView(index: nil, project: project, jump: store.jump(for: project)) { store.open(project) }.opacity(0.7)
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
        .padding(.top, store.notch.atTop ? store.notch.menuBar : 0)
        .background(store.notch.atTop ? Color.black : Color.islandBackground)
        .clipShape(IslandShape(atTop: store.notch.atTop, radius: 14))
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
            PillView(store: store).onTapGesture(perform: tap).onHover(perform: hover).modifier(PanelDrag())
        }
    }
}

/// Moving more than 3 points drags the panel; a shorter press stays a click.
struct PanelDrag: ViewModifier {
    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in AppDelegate.shared?.dragMoved() }
            .onEnded { _ in AppDelegate.shared?.dragEnded() })
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
    var searchHotKey: EventHotKeyRef?
    var searchPanel: IslandPanel!
    let searchSize = NSSize(width: 640, height: 520)
    var hoverOpen: DispatchWorkItem?
    /// Watches the mouse while the panel is open, to close it after the mouse leaves (AC42).
    var leaveWatch: Timer?
    var mouseWasInside = false
    /// The panel opened by itself for a request; it closes again when no request is left and the mouse never came.
    var openedForRequest = false
    var mouseLeftAt: Date?
    /// The top center of the pill, chosen by dragging; nil means the default place.
    var anchor: CGPoint?
    var dragOffset: CGPoint?
    static var shared: AppDelegate!
    var pillSize: NSSize {
        guard store.notch.atTop else { return NSSize(width: 340, height: 30) }
        return NSSize(width: store.notch.gap > 0 ? store.notch.gap + 300 : 340, height: store.notch.menuBar)
    }
    let expandedSize = NSSize(width: 560, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // A helper that died must not end the app when the panel writes to its pipe.
        signal(SIGPIPE, SIG_IGN)
        store.collapse = { [weak self] in self?.setExpanded(false) }
        store.onNewRequest = { [weak self] in self?.showRequests() ?? true }
        store.closeSearch = { [weak self] in self?.hideSearch() }
        searchPanel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        searchPanel.level = .statusBar
        searchPanel.isOpaque = false
        searchPanel.backgroundColor = .clear
        searchPanel.hasShadow = false
        searchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        searchPanel.hidesOnDeactivate = false
        let searchHost = NSHostingView(rootView: SearchView(store: store).environment(\.colorScheme, .dark))
        searchHost.sizingOptions = []
        searchPanel.contentView = searchHost
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: searchPanel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideSearch() }
        }
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
        anchor = Placement.load(.standard, screens: NSScreen.screens.map(\.frame))
        panel.setFrame(targetFrame, display: true)
        panel.orderFrontRegardless()
        store.startAttention()
        store.load()
        store.refreshIfStale()
        registerHotKey()

        if CommandLine.arguments.contains("--selftest") { runSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-drag") { runDragSelfTest(); return }
        if CommandLine.arguments.contains("--selftest-leave") { runLeaveSelfTest(); return }
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-search"), flag + 1 < CommandLine.arguments.count {
            runSearchSelfTest(query: CommandLine.arguments[flag + 1]); return
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.store.searchOpen, event.window === self.searchPanel { return self.searchKey(event) }
            guard self.store.isExpanded else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.setExpanded(false); return nil }
            guard let digit = Int(event.charactersIgnoringModifiers ?? "") else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if modifiers.isEmpty { self.store.open(number: digit); return nil }
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setExpanded(false)
                self?.hideSearch()
            }
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
            let screen = self.placement().area
            let ok = self.store.isExpanded && self.panel.frame == want && screen.contains(want)
            print(ok ? "PASS" : "FAIL", "frame", self.panel.frame, "want", want)
            exit(ok ? 0 : 1)
        }
    }

    /// Drags the pill to the top-right corner with simulated mouse points, then checks
    /// the expanded panel stays on screen and the point is saved. Leaves no saved point behind.
    func runDragSelfTest() {
        let main = NSScreen.screens[0]
        let visible = Placement.area(visible: main.visibleFrame, screen: main.frame)
        let start = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        dragMoved(to: start)
        dragMoved(to: CGPoint(x: start.x + 2000, y: start.y + 500))
        dragEnded()
        let pill = panel.frame
        let saved = Placement.load(.standard, screens: NSScreen.screens.map(\.frame))
        setExpanded(true)
        let expanded = panel.frame
        setExpanded(false)
        let ok = pill.maxX == visible.maxX && pill.maxY == visible.maxY && saved == Placement.anchor(for: pill)
            && visible.contains(expanded) && expanded.maxY == pill.maxY && expanded.maxX == visible.maxX
        print(ok ? "PASS" : "FAIL", "notch", store.notch, "pill", pill, "expanded", expanded, "saved", saved as Any, "visible", visible)
        UserDefaults.standard.removeObject(forKey: "panelAnchor")
        exit(ok ? 0 : 1)
    }

    /// Feeds simulated mouse points to the AC42 check.
    func runLeaveSelfTest() {
        setExpanded(true)
        leaveWatch?.invalidate()
        let t = Date()
        let inside = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let outside = CGPoint(x: panel.frame.maxX + 100, y: panel.frame.midY)
        mouseWasInside = false
        checkMouseLeft(mouse: outside, pressed: false, now: t.addingTimeInterval(5))
        let keyboardOpenStays = store.isExpanded
        checkMouseLeft(mouse: inside, pressed: false, now: t)
        checkMouseLeft(mouse: outside, pressed: false, now: t.addingTimeInterval(0.1))
        checkMouseLeft(mouse: outside, pressed: false, now: t.addingTimeInterval(0.3))
        checkMouseLeft(mouse: inside, pressed: false, now: t.addingTimeInterval(0.35))
        checkMouseLeft(mouse: outside, pressed: false, now: t.addingTimeInterval(0.4))
        let backInTimeStays = store.isExpanded
        checkMouseLeft(mouse: outside, pressed: true, now: t.addingTimeInterval(2))
        let dragStays = store.isExpanded
        checkMouseLeft(mouse: outside, pressed: false, now: t.addingTimeInterval(2.1))
        checkMouseLeft(mouse: outside, pressed: false, now: t.addingTimeInterval(2.6))
        let closed = !store.isExpanded
        let ok = keyboardOpenStays && backInTimeStays && dragStays && closed
        print(ok ? "PASS" : "FAIL", "keyboard", keyboardOpenStays, "back in time", backInTimeStays, "drag", dragStays, "closed", closed)
        exit(ok ? 0 : 1)
    }

    /// Keys of the search box (AC56). The input method keeps them while it is composing text.
    func searchKey(_ event: NSEvent) -> NSEvent? {
        if (searchPanel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
        switch Int(event.keyCode) {
        case kVK_Escape: hideSearch()
        case kVK_DownArrow: store.moveSelection(1)
        case kVK_UpArrow: store.moveSelection(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter: store.openSelected()
        default: return event
        }
        return nil
    }

    /// Opens the search box, checks focus and the arrow keys, runs one real query, then checks closing clears it.
    func runSearchSelfTest(query: String) {
        showSearch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let focused = self.searchPanel.isKeyWindow && self.searchPanel.firstResponder is NSTextView
            let notchClosed = !self.store.isExpanded
            print("search focused:", focused, "notch stays closed:", notchClosed, "waiting rows:", self.store.searchRows.count)
            self.store.query = query
            self.waitForMatches(deadline: Date().addingTimeInterval(60), started: Date(), ok: focused && notchClosed)
        }
    }

    func waitForMatches(deadline: Date, started: Date, ok: Bool) {
        if !store.matches.isEmpty || Date() > deadline || store.routeError != nil {
            print(String(format: "first reply: %.1f s", Date().timeIntervalSince(started)), "error:", store.routeError ?? "none")
            let rows = store.searchRows
            rows.forEach { print(" -", $0.waiting ? "[等你]" : "", $0.title, "|", $0.note) }
            store.moveSelection(1); store.moveSelection(1); store.moveSelection(-1)
            let moved = store.selection == min(1, rows.count - 1)
            hideSearch()
            let cleared = store.query.isEmpty && !store.searchOpen && !searchPanel.isVisible
            print("selection moved:", moved, "closing clears:", cleared)
            exit(ok && !store.matches.isEmpty && !rows.isEmpty && moved && cleared ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForMatches(deadline: deadline, started: started, ok: ok) }
    }

    /// The screen that holds the anchor, the area the panel may use there (AC40), and the point itself.
    /// On the top edge near a camera notch, the point snaps to the notch's center (AC39).
    func placement() -> (screen: NSScreen, area: CGRect, point: CGPoint, notch: NotchLayout) {
        let held = anchor.flatMap { point in NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) } }
        let screen = held ?? NSScreen.screens[0]
        let area = Placement.area(visible: screen.visibleFrame, screen: screen.frame)
        var point = held == nil ? Placement.defaultAnchor(area) : anchor!
        let atTop = point.y >= area.maxY - 0.5
        var gap: CGFloat = 0
        if atTop, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 0, abs(point.x - screen.frame.midX) < width / 2 + 150 {
                gap = width
                point.x = screen.frame.midX
            }
        }
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return (screen, area, point, NotchLayout(atTop: atTop, gap: gap, menuBar: menuBar))
    }

    func frame(for size: NSSize) -> NSRect {
        let place = placement()
        return Placement.frame(size: size, anchor: place.point, visible: place.area)
    }

    func dragMoved(to mouse: CGPoint = NSEvent.mouseLocation) {
        if dragOffset == nil {
            hoverOpen?.cancel()
            hoverOpen = nil
            dragOffset = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        }
        guard let offset = dragOffset else { return }
        let origin = CGPoint(x: mouse.x - offset.x, y: mouse.y - offset.y)
        // Keep the point on the screen under the mouse; a point off every screen means "default".
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = Placement.area(visible: screen.visibleFrame, screen: screen.frame)
        let raw = Placement.anchor(for: CGRect(origin: origin, size: panel.frame.size))
        anchor = Placement.anchor(for: Placement.frame(size: panel.frame.size, anchor: raw, visible: area))
        panel.setFrame(targetFrame, display: true)
    }

    func dragEnded() {
        dragOffset = nil
        let point = Placement.anchor(for: targetFrame)
        anchor = point
        Placement.save(point, .standard)
    }

    var targetFrame: NSRect {
        let notch = placement().notch
        if store.notch != notch { store.notch = notch }
        return frame(for: store.isExpanded ? expandedSize : pillSize)
    }

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
        // A press on the pill may be the start of a drag, so it does not open the panel.
        let work = DispatchWorkItem { [weak self] in
            // Passing over the pill must not take the keyboard from the search box (AC58).
            if NSEvent.pressedMouseButtons == 0, let self { self.setExpanded(true, takeFocus: !self.store.searchOpen) }
        }
        hoverOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Opens the 等你 tab for a new request without taking the keyboard from the current app (AC49).
    @discardableResult
    func showRequests() -> Bool {
        if !store.isExpanded {
            setExpanded(true, takeFocus: false)
            openedForRequest = true
        }
        store.tab = .waiting
        return true
    }

    func setExpanded(_ expanded: Bool, takeFocus: Bool = true) {
        guard expanded != store.isExpanded else { return }
        openedForRequest = false
        hoverOpen?.cancel()
        hoverOpen = nil
        store.isExpanded = expanded
        panel.setFrame(targetFrame, display: true)
        if expanded {
            store.load()
            store.refreshIfStale()
            if takeFocus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
            startLeaveWatch()
        } else {
            leaveWatch?.invalidate()
            leaveWatch = nil
            store.tab = .now
            // Leaving the screen gives up key status, so typing returns to the previous app.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// Closes the panel 0.4 s after the mouse leaves it. A panel opened by keyboard waits until the
    /// mouse has been inside once; a pressed button (a drag) never closes it.
    func startLeaveWatch() {
        leaveWatch?.invalidate()
        mouseWasInside = panel.frame.contains(NSEvent.mouseLocation)
        mouseLeftAt = nil
        leaveWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouseLeft() }
        }
    }

    func checkMouseLeft(mouse: CGPoint = NSEvent.mouseLocation, pressed: Bool = NSEvent.pressedMouseButtons != 0, now: Date = Date()) {
        let inside = panel.frame.insetBy(dx: -8, dy: -8).contains(mouse)
        // A panel opened without focus takes it once the mouse is over it, so the first click counts (AC49).
        if inside, !panel.isKeyWindow, !store.searchOpen, mouse == NSEvent.mouseLocation { panel.makeKey() }
        if inside || pressed {
            mouseWasInside = mouseWasInside || inside
            mouseLeftAt = nil
            return
        }
        guard mouseWasInside else {
            if openedForRequest, !store.attention.contains(where: { $0.request != nil }) { setExpanded(false) }
            return
        }
        let left = mouseLeftAt ?? now
        mouseLeftAt = left
        if now.timeIntervalSince(left) >= 0.4 { setExpanded(false) }
    }

    /// Opens the search box on the screen under the mouse, in the upper middle (AC52).
    func showSearch() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let origin = CGPoint(x: area.midX - searchSize.width / 2, y: area.maxY - area.height * 0.2 - searchSize.height)
        searchPanel.setFrame(NSRect(origin: origin, size: searchSize), display: true)
        store.openSearch()
        searchPanel.makeKeyAndOrderFront(nil)
    }

    func hideSearch() {
        guard store.searchOpen else { return }
        store.endSearch()
        searchPanel.orderOut(nil)
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let isSearch = pressed.id == 2
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let app = AppDelegate.shared!
                    if isSearch {
                        if app.store.searchOpen { app.hideSearch() } else { app.showSearch() }
                    } else {
                        app.setExpanded(!app.store.isExpanded)
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let signature = OSType(0x4754_4449)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(optionKey), EventHotKeyID(signature: signature, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { store.error = "Option+G 已被其他 app 佔用,請把滑鼠移到膠囊上打開面板。" }
        let searchStatus = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: signature, id: 2),
                                               GetApplicationEventTarget(), 0, &searchHotKey)
        if searchStatus != noErr { store.error = "Option+Space 已被其他 app 佔用,搜尋框無法用快捷鍵打開。" }
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
        store.reloadAttention()
        save("pill-waiting", PillView(store: store), NSSize(width: 340, height: 30))
        store.notch = NotchLayout(atTop: true, gap: 185, menuBar: 37)
        save("pill-notch", PillView(store: store), NSSize(width: 485, height: 37))
        store.tab = .waiting
        let now = ISO8601DateFormatter().string(from: Date())
        let ask = #"{"id":"demo--1","sessionId":"demo-a","kind":"question","at":"\#(now)","questions":[{"question":"要用哪個方案?","multiSelect":false,"options":[{"label":"A 先做 hook","description":""},{"label":"B 先做介面","description":""}]},{"question":"要測哪些環境?","multiSelect":true,"options":[{"label":"dev"},{"label":"staging"},{"label":"prod"}]}]}"#
        let perm = #"{"id":"demo--2","sessionId":"demo-b","kind":"permission","toolName":"Bash","detail":"Bash · npm publish --access public","at":"\#(now)"}"#
        let demo = [ask, perm].compactMap { PendingRequest.decode(Data($0.utf8)) }
        store.attention = Attention.items([], desktop: [:], now: Date(), requests: demo) + store.attention
        store.choices = ["demo--1": ["要測哪些環境?": ["dev", "prod"]]]
        save("waiting-requests", ExpandedView(store: store), NSSize(width: 560, height: 560))
        store.reloadAttention()
        save("waiting-notch", ExpandedView(store: store), NSSize(width: 560, height: 560))
        store.notch = NotchLayout(atTop: false, gap: 0, menuBar: 24)
        save("waiting", ExpandedView(store: store), NSSize(width: 560, height: 560))
        store.tab = .now
        save("now", ExpandedView(store: store), NSSize(width: 560, height: 560))
        store.tab = tabConfig.thirdSlotChoices[0]
        save("first-tab", ExpandedView(store: store), NSSize(width: 560, height: 560))
        store.tab = .activity
        save("activity", ExpandedView(store: store), NSSize(width: 560, height: 560))
        store.hoveredArea = Activity.bars(store.snapshot?.timeLog ?? [], today: Date()).first?.label
        save("activity-hover", ExpandedView(store: store), NSSize(width: 560, height: 560))
        store.tab = .now
        store.reloadAttention()
        store.searchOpen = true
        save("search-empty", SearchView(store: store), NSSize(width: 640, height: 520))
        store.query = "登入"
        store.matches = [
            SessionMatch(id: "1", title: "修登入錯誤(接手)", cwd: "/repo/app"),
            SessionMatch(id: "2", title: "登入流程重構", cwd: "/repo/app"),
        ]
        store.selectedID = "2"
        save("search-matches", SearchView(store: store), NSSize(width: 640, height: 520))
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
