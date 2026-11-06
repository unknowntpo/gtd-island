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
    var pageID: String { url.split(separator: "/").last.map(String.init) ?? "" }
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
        var seen: Set<String> = ["", GTDTab.now.name, GTDTab.activity.name, GTDTab.other.name, GTDTab.find.name]
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

    public var tabs: [GTDTab] { [.now, .activity] + thirdSlotChoices.dropLast() + [.other, .find] }
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
