import CoreGraphics
import Foundation

public struct Project: Decodable, Equatable, Identifiable {
    public let title: String
    public let nextAction: String
    public let area: String
    public let url: String
    public let ownerSession: String
    public let priority: String
    public let thisWeek: Bool
    public let deadline: String
    public let lastWorked: String
    public let waitingFor: String
    public let worktree: String
    public let sourceURL: String

    public var id: String { url }

    enum CodingKeys: String, CodingKey {
        case title = "Outcome"
        case nextAction = "Next Action"
        case area = "Area"
        case url
        case ownerSession = "Owner Session"
        case priority = "Priority"
        case thisWeek = "This Week"
        case deadline = "date:Deadline:start"
        case lastWorked = "date:Last Worked:start"
        case waitingFor = "Waiting For"
        case worktree = "Worktree"
        case sourceURL = "Source URL"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        title = Project.plainText(text(.title))
        nextAction = Project.plainText(text(.nextAction))
        area = text(.area)
        url = text(.url)
        ownerSession = text(.ownerSession)
        priority = text(.priority)
        thisWeek = text(.thisWeek) == "__YES__"
        deadline = text(.deadline)
        lastWorked = text(.lastWorked)
        waitingFor = text(.waitingFor)
        worktree = text(.worktree)
        sourceURL = text(.sourceURL)
    }

    /// Notion escapes `_` and turns file names into links; the panel shows plain text.
    static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\\([_~*\[\]])"#, with: "$1", options: .regularExpression)
    }

    public func deadlineLabel(today: Date, calendar: Calendar = .current) -> (text: String, isOverdue: Bool)? {
        guard let due = Ranking.day(deadline, calendar) else { return nil }
        let date = String(deadline.prefix(10).dropFirst(5))
        return due < calendar.startOfDay(for: today) ? ("已過 \(date)", true) : ("截止 \(date)", false)
    }

    public var isWaiting: Bool { nextAction.hasPrefix("等") || !waitingFor.isEmpty }

    /// The page id that `Parent Project` relations point to.
    public var pageID: String { url.split(separator: "/").last.map(String.init) ?? "" }

    /// 延後 unchecks This Week, so only a This Week row has anything to postpone.
    public var canPostpone: Bool { thisWeek }
}

/// An open Action, read so a Project can jump to the session of its next Action.
public struct ActionItem: Decodable, Equatable {
    public let title: String
    public let url: String
    public let ownerSession: String
    public let status: String
    public let parents: [String]

    enum CodingKeys: String, CodingKey {
        case title = "Outcome", url, ownerSession = "Owner Session", status = "GTD Status", parents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        title = Project.plainText(text(.title))
        url = text(.url)
        ownerSession = text(.ownerSession)
        status = text(.status)
        parents = (try? c.decode([String].self, forKey: .parents)) ?? []
    }

    var isOpen: Bool { status != "Done" && status != "Dropped" }
}

/// Where a row's button goes, and what it says.
public struct Jump: Equatable {
    public enum Kind: Equatable { case session, action, notion }
    public let kind: Kind
    public let url: URL?

    public var label: String {
        switch kind {
        case .session: return "打開 session ↗"
        case .action: return "打開 Action ↗"
        case .notion: return "打開 Notion ↗"
        }
    }

    /// The Project's session, then the session or page of the open child Action
    /// whose title is the Project's `Next Action`, then the Project page.
    public static func resolve(_ project: Project, actions: [ActionItem]) -> Jump {
        if !project.ownerSession.isEmpty { return Jump(kind: .session, url: URL(string: project.ownerSession)) }
        let next = actions.first { $0.isOpen && $0.parents.contains(project.pageID) && $0.title == project.nextAction }
        if let next, !next.ownerSession.isEmpty { return Jump(kind: .session, url: URL(string: next.ownerSession)) }
        if let next { return Jump(kind: .action, url: URL(string: next.url)) }
        return Jump(kind: .notion, url: URL(string: project.url))
    }
}

public struct GTDTab: Hashable, Identifiable {
    public let name: String
    public var id: String { name }

    public init(_ name: String) { self.name = name }

    public static let now = GTDTab("先看這 3 件")
    public static let activity = GTDTab("動態")
    public static let other = GTDTab("其他")
    public static let find = GTDTab("找 session")
    public static let waiting = GTDTab("等你")
}

/// One user-defined tab from `config.json`.
public struct TabRule: Decodable, Equatable {
    public let name: String
    public let areas: [String]
    public let titlePrefixes: [String]
    public let linkContains: [String]

    enum CodingKeys: String, CodingKey { case name, areas, titlePrefixes, linkContains }

    public init(name: String, areas: [String] = [], titlePrefixes: [String] = [], linkContains: [String] = []) {
        self.name = name
        self.areas = areas
        self.titlePrefixes = titlePrefixes
        self.linkContains = linkContains
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        areas = try c.decodeIfPresent([String].self, forKey: .areas) ?? []
        titlePrefixes = try c.decodeIfPresent([String].self, forKey: .titlePrefixes) ?? []
        linkContains = try c.decodeIfPresent([String].self, forKey: .linkContains) ?? []
    }

    func matchesTitleOrLink(_ p: Project) -> Bool {
        titlePrefixes.contains { p.title.hasPrefix($0) }
            || linkContains.contains { p.worktree.contains($0) || p.sourceURL.contains($0) }
    }
}

/// The user's tabs. They live in a local file, so the program itself names no GTD Area.
public struct TabConfig: Decodable, Equatable {
    public let rules: [TabRule]
    public let thirdSlot: GTDTab?

    enum CodingKeys: String, CodingKey { case tabs, thirdSlot }

    public static let empty = TabConfig(rules: [])

    public init(rules: [TabRule], thirdSlot: String? = nil) {
        var seen: Set<String> = ["", GTDTab.now.name, GTDTab.activity.name, GTDTab.other.name, GTDTab.find.name, GTDTab.waiting.name]
        self.rules = rules.filter { seen.insert($0.name).inserted }
        self.thirdSlot = thirdSlot.map(GTDTab.init)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rules: try c.decodeIfPresent([TabRule].self, forKey: .tabs) ?? [],
                  thirdSlot: try c.decodeIfPresent(String.self, forKey: .thirdSlot))
    }

    public static func load(path: String) -> TabConfig {
        guard let data = FileManager.default.contents(atPath: path) else { return .empty }
        return (try? JSONDecoder().decode(TabConfig.self, from: data)) ?? .empty
    }

    public var tabs: [GTDTab] { [.now, .waiting, .activity] + thirdSlotChoices.dropLast() + [.other, .find] }
    public var thirdSlotChoices: [GTDTab] { rules.map { GTDTab($0.name) } + [.other] }

    public func tab(for project: Project) -> GTDTab {
        let rule = rules.first { $0.matchesTitleOrLink(project) } ?? rules.first { $0.areas.contains(project.area) }
        return rule.map { GTDTab($0.name) } ?? .other
    }
}

/// One session that `route.py` found for a typed sentence.
public struct SessionMatch: Decodable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let cwd: String

    public init(id: String, title: String, cwd: String) {
        self.id = id
        self.title = title
        self.cwd = cwd
    }

    public var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }
    public var target: URL? { URL(string: "claude://claude.ai/epitaxy/\(id)") }
}

/// One line of `route.py` output.
public struct RouteReply: Decodable, Equatable {
    public let matches: [SessionMatch]
    public let error: String?

    public static func decode(_ data: Data) throws -> RouteReply {
        try JSONDecoder().decode(RouteReply.self, from: data)
    }
}

/// One row of the Notion `Time Log`.
public struct TimeEntry: Decodable, Equatable {
    public let title: String
    public let minutes: Int
    public let area: String
    public let date: String

    enum CodingKeys: String, CodingKey {
        case title = "Entry"
        case minutes = "Minutes"
        case area = "Area"
        case date = "date:Date:start"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = Project.plainText((try? c.decode(String.self, forKey: .title)) ?? "")
        minutes = Int((try? c.decode(Double.self, forKey: .minutes)) ?? 0)
        area = (try? c.decode(String.self, forKey: .area)) ?? ""
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
    }
}

/// One Area's time over the last 7 days, ready to draw as a bar.
public struct ActivityBar: Equatable, Identifiable {
    public let label: String
    public let minutes: Int
    public let todayMinutes: Int
    public let titles: [String]
    public var id: String { label }

    public init(label: String, minutes: Int, todayMinutes: Int, titles: [String]) {
        self.label = label
        self.minutes = minutes
        self.todayMinutes = todayMinutes
        self.titles = titles
    }

    public func summary(total: Int) -> String {
        let share = Int((Double(minutes) / Double(max(total, 1)) * 100).rounded())
        return "\(Activity.duration(minutes)) · \(share)% · 今天 \(Activity.duration(todayMinutes))"
    }
}

public enum Activity {
    public static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) 分" }
        return rest == 0 ? "\(hours) 小時" : "\(hours) 小時 \(rest) 分"
    }

    public static func bars(_ entries: [TimeEntry], today: Date, calendar: Calendar = .current) -> [ActivityBar] {
        let end = calendar.startOfDay(for: today)
        let start = calendar.date(byAdding: .day, value: -6, to: end)!
        let kept = entries.compactMap { entry -> (entry: TimeEntry, day: Date)? in
            guard entry.minutes > 0, let day = Ranking.day(entry.date, calendar), day >= start, day <= end else { return nil }
            return (entry, day)
        }
        return Dictionary(grouping: kept) { $0.entry.area.isEmpty ? "未分類" : $0.entry.area }
            .map { label, group in
                let ordered = group.sorted { ($1.day, $1.entry.minutes) < ($0.day, $0.entry.minutes) }
                return ActivityBar(label: label, minutes: group.reduce(0) { $0 + $1.entry.minutes },
                                   todayMinutes: group.filter { $0.day == end }.reduce(0) { $0 + $1.entry.minutes },
                                   titles: ordered.prefix(6).map(\.entry.title))
            }
            .sorted { ($1.minutes, $0.label) < ($0.minutes, $1.label) }
    }
}

public struct Snapshot: Decodable, Equatable {
    public let fetchedAt: Date
    public let rows: [Project]
    /// Nil when the snapshot came from a path that cannot read Time Log.
    public let timeLog: [TimeEntry]?
    /// Nil when the snapshot came from a path that cannot read Actions.
    public let actions: [ActionItem]?

    public func jump(for project: Project) -> Jump { Jump.resolve(project, actions: actions ?? []) }

    public static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: data)
    }

    public func isStale(now: Date, maxAge: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(fetchedAt) > maxAge
    }
}

public enum Ranking {
    static func day(_ text: String, _ calendar: Calendar) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Lower sorts first: upcoming deadline, then This Week, then everything else.
    static func sortKey(_ p: Project, today: Date, calendar: Calendar) -> (Int, Double, Int, Double) {
        let start = calendar.startOfDay(for: today)
        let priority = ["P0": 0, "P1": 1, "P2": 2, "P3": 3][p.priority] ?? 4
        let worked = day(p.lastWorked, calendar)?.timeIntervalSince1970 ?? 0
        if let due = day(p.deadline, calendar), due >= start,
           due <= calendar.date(byAdding: .day, value: 14, to: start)! {
            return (0, due.timeIntervalSince1970, priority, -worked)
        }
        return (p.thisWeek ? 1 : 2, 0, priority, -worked)
    }

    public static func actionable(_ rows: [Project], today: Date, calendar: Calendar = .current) -> [Project] {
        rows.filter { !$0.isWaiting }.sorted {
            sortKey($0, today: today, calendar: calendar) < sortKey($1, today: today, calendar: calendar)
        }
    }

    public static func view(_ tab: GTDTab, rows: [Project], today: Date, calendar: Calendar = .current,
                            config: TabConfig = .empty, thirdSlot: GTDTab? = nil)
        -> (actionable: [Project], waiting: [Project]) {
        if tab == .find || tab == .activity { return ([], []) }
        let ranked = actionable(rows, today: today, calendar: calendar)
        if tab == .now { return (topThree(ranked, config: config, thirdSlot: thirdSlot), []) }
        return (ranked.filter { config.tab(for: $0) == tab }, rows.filter { $0.isWaiting && config.tab(for: $0) == tab })
    }

    /// The third place goes to the chosen tab's best item, unless that tab is already in the top three.
    static func topThree(_ ranked: [Project], config: TabConfig, thirdSlot: GTDTab?) -> [Project] {
        let top = Array(ranked.prefix(3))
        guard let thirdSlot, !top.contains(where: { config.tab(for: $0) == thirdSlot }),
              let pick = ranked.first(where: { config.tab(for: $0) == thirdSlot }) else { return top }
        return top.prefix(2) + [pick]
    }
}

/// Which tab keeps the third place of `先看這 3 件`. Nil means no tab keeps it.
public enum ThirdSlot {
    public static let key = "thirdSlotTab"

    public static func load(config: TabConfig, _ defaults: UserDefaults = .standard) -> GTDTab? {
        let saved = defaults.string(forKey: key).map(GTDTab.init) ?? config.thirdSlot
        return config.thirdSlotChoices.first { $0 == saved }
    }

    public static func save(_ tab: GTDTab?, _ defaults: UserDefaults = .standard) {
        defaults.set(tab?.name ?? "", forKey: key)
    }
}

/// Where the panel sits. The point is the top center of the pill; the expanded
/// panel hangs down from the same point and is kept inside the visible area.
public enum Placement {
    static let key = "panelAnchor"
    public static let gap: CGFloat = 0

    /// The visible area stretched up to the screen's top edge, so the panel may sit over the menu bar (AC40).
    public static func area(visible: CGRect, screen: CGRect) -> CGRect {
        CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: screen.maxY - visible.minY)
    }

    public static func defaultAnchor(_ area: CGRect) -> CGPoint {
        CGPoint(x: area.midX, y: area.maxY - gap)
    }

    public static func frame(size: CGSize, anchor: CGPoint, visible: CGRect) -> CGRect {
        let x = min(max((anchor.x - size.width / 2).rounded(), visible.minX), visible.maxX - size.width)
        let y = min(max((anchor.y - size.height).rounded(), visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    public static func anchor(for frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.maxY) }

    static func isOn(_ point: CGPoint, _ screen: CGRect) -> Bool {
        (screen.minX...screen.maxX).contains(point.x) && (screen.minY...screen.maxY).contains(point.y)
    }

    /// The saved point, or nil when there is none or no screen holds it any more.
    public static func load(_ defaults: UserDefaults, screens: [CGRect]) -> CGPoint? {
        guard let pair = defaults.array(forKey: key) as? [Double], pair.count == 2 else { return nil }
        let point = CGPoint(x: pair[0], y: pair[1])
        return screens.contains { isOn(point, $0) } ? point : nil
    }

    public static func save(_ point: CGPoint, _ defaults: UserDefaults) {
        defaults.set([Double(point.x), Double(point.y)], forKey: key)
    }
}

/// One file in `~/.gtd-island/attention`, written by `attention.py` (AC33).
public struct AttentionRecord: Decodable, Equatable {
    public let sessionId: String
    public let cwd: String
    public let state: String
    public let message: String
    public let at: Date

    public init(sessionId: String, cwd: String, state: String, message: String, at: Date) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.state = state
        self.message = message
        self.at = at
    }

    public var needsYou: Bool { state == "needsYou" }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // `attention.py` writes milliseconds, so a focus earlier in the same second still counts as earlier (AC38).
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = fractional.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
            }
            return date
        }
        return decoder
    }()

    public static func decode(_ data: Data) -> AttentionRecord? { try? decoder.decode(AttentionRecord.self, from: data) }

    /// Every record in the folder; files that do not parse are skipped.
    public static func load(folder: String) -> [AttentionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(name)).flatMap(decode)
        }
    }
}

/// The few fields GTD Island reads from a Claude desktop app session file. The format is
/// undocumented, so every field is optional and a file that does not parse is skipped.
public struct DesktopSession: Decodable, Equatable {
    public let sessionId: String
    public let cliSessionId: String?
    public let title: String?
    public let isArchived: Bool?
    /// Milliseconds since 1970.
    public let lastFocusedAt: Double?

    public init(sessionId: String, cliSessionId: String?, title: String?, isArchived: Bool? = nil, lastFocusedAt: Double? = nil) {
        self.sessionId = sessionId
        self.cliSessionId = cliSessionId
        self.title = title
        self.isArchived = isArchived
        self.lastFocusedAt = lastFocusedAt
    }

    public static func decode(_ data: Data) -> DesktopSession? { try? JSONDecoder().decode(DesktopSession.self, from: data) }

    /// Maps each CLI session id to the desktop session file that holds it.
    public static func index(root: String) -> [String: String] {
        var index: [String: String] = [:]
        let fm = FileManager.default
        for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let first = (root as NSString).appendingPathComponent(a)
            for b in (try? fm.contentsOfDirectory(atPath: first)) ?? [] {
                let second = (first as NSString).appendingPathComponent(b)
                for name in (try? fm.contentsOfDirectory(atPath: second)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    let path = (second as NSString).appendingPathComponent(name)
                    if let cli = fm.contents(atPath: path).flatMap(decode)?.cliSessionId { index[cli] = path }
                }
            }
        }
        return index
    }
}

/// One row of the 等你 tab (AC36-AC38).
public struct AttentionItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let reason: String
    public let folder: String
    public let at: Date
    public let needsYou: Bool
    /// The desktop app link; nil for a terminal session.
    public let target: URL?
    /// A question or permission the hook is waiting on (AC48).
    public var request: PendingRequest? = nil
}

public struct AskOption: Codable, Equatable, Hashable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct AskQuestion: Codable, Equatable {
    public let question: String
    public let header: String?
    public let options: [AskOption]
    public let multiSelect: Bool?

    public init(question: String, header: String? = nil, options: [AskOption], multiSelect: Bool? = nil) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// One file in `~/.gtd-island/requests`, written by `attention.py` while it waits (AC44, AC45).
public struct PendingRequest: Decodable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let kind: String
    public let toolName: String?
    public let detail: String?
    public let questions: [AskQuestion]?
    public let at: Date

    public static let maxAge: TimeInterval = 130

    public var isQuestion: Bool { kind == "question" }

    public static func decode(_ data: Data) -> PendingRequest? {
        guard let request = try? AttentionRecord.decoder.decode(PendingRequest.self, from: data) else { return nil }
        if request.isQuestion, request.questions?.isEmpty ?? true { return nil }
        return request
    }

    /// Requests that are still waiting; older files belong to a hook that already gave up (AC48).
    public static func load(folder: String, now: Date) -> [PendingRequest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(name)).flatMap(decode)
        }.filter { now.timeIntervalSince($0.at) <= maxAge }
    }

    /// The reply file body for a permission decision: "allow", "deny" or "skip".
    public static func reply(decision: String) -> Data {
        decision == "skip" ? Data(#"{"skip":true}"#.utf8) : Data(#"{"decision":"\#(decision)"}"#.utf8)
    }

    /// The reply for a question, or nil until every question has a choice (AC48).
    public func reply(choices: [String: Set<String>]) -> Data? {
        guard let questions else { return nil }
        var answers: [String: Any] = [:]
        for q in questions {
            let picked = q.options.map(\.label).filter { choices[q.question]?.contains($0) ?? false }
            if picked.isEmpty { return nil }
            answers[q.question] = q.multiSelect == true ? picked : picked[0]
        }
        return try? JSONSerialization.data(withJSONObject: ["answers": answers], options: [.sortedKeys])
    }
}

public enum Attention {
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    /// `desktop` maps a CLI session id to its desktop session, when one exists.
    public static func items(_ records: [AttentionRecord], desktop: [String: DesktopSession], now: Date,
                             requests: [PendingRequest] = []) -> [AttentionItem] {
        let waiting = Dictionary(requests.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, b in a.at <= b.at ? a : b })
        var all = records
        for request in requests where !records.contains(where: { $0.sessionId == request.sessionId }) {
            all.append(AttentionRecord(sessionId: request.sessionId, cwd: "", state: "needsYou",
                                       message: request.detail ?? "", at: request.at))
        }
        return all.compactMap { record -> AttentionItem? in
            let request = waiting[record.sessionId]
            guard now.timeIntervalSince(record.at) <= maxAge else { return nil }
            let session = desktop[record.sessionId]
            if session?.isArchived == true { return nil }
            // A waiting request stays visible even when the user looked at the session (AC48).
            if request == nil, let focused = session?.lastFocusedAt, focused / 1000 > record.at.timeIntervalSince1970 { return nil }
            let folder = record.cwd.isEmpty ? "" : URL(fileURLWithPath: record.cwd).lastPathComponent
            let title = session?.title.flatMap { $0.isEmpty ? nil : $0 } ?? (folder.isEmpty ? record.sessionId : folder)
            return AttentionItem(id: record.sessionId, title: title,
                                 reason: record.message.isEmpty ? (record.needsYou ? "等你回覆" : "做完了") : record.message,
                                 folder: folder, at: record.at, needsYou: record.needsYou,
                                 target: session.flatMap { URL(string: "claude://claude.ai/epitaxy/\($0.sessionId)") },
                                 request: request)
        }
        .sorted { ($0.needsYou ? 0 : 1, -$0.at.timeIntervalSince1970) < ($1.needsYou ? 0 : 1, -$1.at.timeIntervalSince1970) }
    }

    public static func age(_ at: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(at) / 60)
        if minutes < 1 { return "剛剛" }
        if minutes < 60 { return "\(minutes) 分鐘前" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小時前" }
        return "\(minutes / (24 * 60)) 天前"
    }
}
