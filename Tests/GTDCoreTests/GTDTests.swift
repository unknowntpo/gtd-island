import XCTest
@testable import GTDCore

final class GTDTests: XCTestCase {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    var today: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 3))! }

    func row(_ title: String, next: String = "做事", area: String = "Other", extra: String = "") -> String {
        """
        {"Outcome":"\(title)","Next Action":"\(next)","Area":"\(area)","url":"https://n/\(title)",\
        "Owner Session":"","Waiting For":"","This Week":"__NO__","ExtraA":1,"ExtraB":3\(extra)}
        """
    }

    func decode(_ rows: [String]) throws -> [Project] {
        let json = "{\"fetchedAt\":\"2026-11-03T14:00:00+00:00\",\"rows\":[\(rows.joined(separator: ","))]}"
        return try Snapshot.decode(Data(json.utf8)).rows
    }

    func testAC7DecodesRealRowShapeAndIgnoresExtraFields() throws {
        let rows = try decode([row("A", extra: #","Priority":"P0","date:Deadline:start":"2026-11-12""#)])
        XCTAssertEqual(rows[0].title, "A")
        XCTAssertEqual(rows[0].priority, "P0")
        XCTAssertEqual(rows[0].deadline, "2026-11-12")
        XCTAssertFalse(rows[0].thisWeek)
    }

    func testAC1RanksUpcomingDeadlineThenThisWeekThenPriorityThenRecent() throws {
        let rows = try decode([
            row("old", extra: #","date:Last Worked:start":"2026-10-01""#),
            row("recent", extra: #","date:Last Worked:start":"2026-11-01""#),
            row("p1", extra: #","Priority":"P1""#),
            row("week", extra: #","This Week":"__YES__""#).replacingOccurrences(of: #""This Week":"__NO__","#, with: ""),
            row("far", extra: #","date:Deadline:start":"2026-12-25""#),
            row("overdue", extra: #","date:Deadline:start":"2026-10-13""#),
            row("soon", extra: #","date:Deadline:start":"2026-11-12""#),
            row("sooner", extra: #","date:Deadline:start":"2026-11-05""#),
        ])
        let order = Ranking.actionable(rows, today: today, calendar: calendar).map(\.title)
        XCTAssertEqual(Array(order.prefix(4)), ["sooner", "soon", "week", "p1"])
        XCTAssertLessThan(order.firstIndex(of: "recent")!, order.firstIndex(of: "old")!)
    }

    func testAC2NowTabShowsAtMostThreeAndNoWaiting() throws {
        let rows = try decode(["a", "b", "c", "d"].map { row($0) } + [
            row("wait", next: "等 Sam:結果", extra: #","date:Deadline:start":"2026-11-04""#),
        ])
        let view = Ranking.view(.now, rows: rows, today: today, calendar: calendar)
        XCTAssertEqual(view.actionable.count, 3)
        XCTAssertFalse(view.actionable.map(\.title).contains("wait"))
        XCTAssertTrue(view.waiting.isEmpty)
    }

    func testAC3WaitingFromPrefixOrField() throws {
        let rows = try decode([
            row("prefix", next: "等 Alex review"),
            row("field").replacingOccurrences(of: #""Waiting For":"""#, with: #""Waiting For":"Sam""#),
            row("free"),
        ])
        XCTAssertEqual(rows.map(\.isWaiting), [true, true, false])
    }

    let work = GTDTab("工作"), reading = GTDTab("閱讀"), side = GTDTab("Side")
    var config: TabConfig {
        TabConfig(rules: [
            TabRule(name: "工作", areas: ["Client Work", "Writing"]),
            TabRule(name: "閱讀", areas: ["Reading"], titlePrefixes: ["讀書會"], linkContains: ["reading-notes"]),
            TabRule(name: "Side", areas: ["Side Project"]),
        ])
    }

    func view(_ tab: GTDTab, _ rows: [Project]) -> (actionable: [Project], waiting: [Project]) {
        Ranking.view(tab, rows: rows, today: today, calendar: calendar, config: config)
    }

    func testAC4TabsSplitByAreaAndKeepWaitingSeparate() throws {
        let rows = try decode([
            row("client", area: "Client Work"),
            row("draft", area: "Writing"),
            row("waitClient", next: "等 x", area: "Client Work"),
            row("book", area: "Reading"),
            row("side", area: "Side Project"),
            row("misc", area: "Other"),
        ])
        XCTAssertEqual(Set(view(work, rows).actionable.map(\.title)), ["client", "draft"])
        XCTAssertEqual(view(work, rows).waiting.map(\.title), ["waitClient"])
        XCTAssertEqual(view(reading, rows).actionable.map(\.title), ["book"])
        XCTAssertEqual(view(side, rows).actionable.map(\.title), ["side"])
        XCTAssertEqual(view(.other, rows).actionable.map(\.title), ["misc"])
    }

    func testAC23TabBarKeepsFixedTabsAroundConfiguredOnes() {
        XCTAssertEqual(config.tabs.map(\.name), ["先看這 3 件", "動態", "工作", "閱讀", "Side", "其他", "找 session"])
    }

    func testAC24TitleOrLinkWinsOverAreaAndEarlierTabWins() throws {
        let rows = try decode([
            row("讀書會 範例", area: "Client Work"),
            row("byWorktree", area: "Other", extra: #","Worktree":"/repo/reading-notes/main""#),
            row("bySource", area: "Side Project", extra: #","Source URL":"https://example.com/reading-notes""#),
            row("讀書 elsewhere", area: "Side Project"),
        ])
        XCTAssertEqual(Set(view(reading, rows).actionable.map(\.title)), ["讀書會 範例", "byWorktree", "bySource"])
        XCTAssertEqual(view(side, rows).actionable.map(\.title), ["讀書 elsewhere"])
        let both = TabConfig(rules: [TabRule(name: "A", areas: ["Reading"]), TabRule(name: "B", areas: ["Reading"])])
        XCTAssertEqual(both.tab(for: try decode([row("x", area: "Reading")])[0]), GTDTab("A"))
    }

    func testAC25MissingOrBrokenFileLeavesOnlyFixedTabs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("config.json")
        XCTAssertEqual(TabConfig.load(path: path.path), .empty)
        try Data("not json".utf8).write(to: path)
        XCTAssertEqual(TabConfig.load(path: path.path), .empty)
        try Data(#"{"dataSource":"x"}"#.utf8).write(to: path)
        let noTabs = TabConfig.load(path: path.path)
        XCTAssertEqual(noTabs.tabs, [.now, .activity, .other, .find])
        XCTAssertEqual(noTabs.tab(for: try decode([row("a", area: "Reading")])[0]), .other)
    }

    func testAC25IgnoresEmptyReservedAndRepeatedNames() throws {
        let json = #"{"tabs":[{"name":""},{"name":"其他"},{"name":"動態"},{"name":"A","areas":["x"]},{"name":"A","areas":["y"]}],"thirdSlot":"A","view":"ignored"}"#
        let parsed = try JSONDecoder().decode(TabConfig.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.rules, [TabRule(name: "A", areas: ["x"])])
        XCTAssertEqual(parsed.thirdSlot, GTDTab("A"))
    }

    func testAC12DecodesMatchesAndBuildsSessionLink() throws {
        let json = #"{"matches":[{"id":"local_1","title":"發布說明草稿","cwd":"/repo/app"}]}"#
        let reply = try RouteReply.decode(Data(json.utf8))
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.matches[0].title, "發布說明草稿")
        XCTAssertEqual(reply.matches[0].folder, "app")
        XCTAssertEqual(reply.matches[0].target?.absoluteString, "claude://claude.ai/epitaxy/local_1")
    }

    func testAC11FindTabHoldsNoProjects() throws {
        let rows = try decode([row("a")])
        XCTAssertTrue(TabConfig.empty.tabs.contains(.find))
        XCTAssertTrue(Ranking.view(.find, rows: rows, today: today, calendar: calendar).actionable.isEmpty)
    }

    func entry(_ title: String, area: String, minutes: Int, on date: String) -> String {
        #"{"Entry":"\#(title)","Area":"\#(area)","Minutes":\#(minutes),"date:Date:start":"\#(date)","url":"https://n/\#(title)"}"#
    }

    func decodeEntries(_ entries: [String]) throws -> [TimeEntry] {
        let json = "{\"fetchedAt\":\"2026-11-03T14:00:00+00:00\",\"rows\":[],\"timeLog\":[\(entries.joined(separator: ","))]}"
        return try Snapshot.decode(Data(json.utf8)).timeLog ?? []
    }

    func testAC15KeepsOnlySevenDaysAndPositiveMinutesAndNamesMissingArea() throws {
        let entries = try decodeEntries([
            entry("today", area: "Other", minutes: 30, on: "2026-11-03T22:30:00.000+00:00"),
            entry("firstDay", area: "Other", minutes: 45, on: "2026-10-28"),
            entry("tooOld", area: "Other", minutes: 500, on: "2026-10-27"),
            entry("future", area: "Other", minutes: 500, on: "2026-11-04"),
            entry("retired", area: "Other", minutes: 0, on: "2026-11-03"),
            entry("noArea", area: "", minutes: 10, on: "2026-11-01"),
        ])
        let bars = Activity.bars(entries, today: today, calendar: calendar)
        XCTAssertEqual(bars.map(\.label), ["Other", "未分類"])
        XCTAssertEqual(bars[0].minutes, 75)
        XCTAssertEqual(bars[0].todayMinutes, 30)
    }

    func testAC15RowWithoutDateOrMinutesIsIgnored() throws {
        let entries = try decodeEntries([
            #"{"Entry":"已停用","Area":"Other","Minutes":0}"#,
            #"{"Entry":"noMinutes","Area":"Other","date:Date:start":"2026-11-03"}"#,
        ])
        XCTAssertTrue(Activity.bars(entries, today: today, calendar: calendar).isEmpty)
    }

    func testAC16SortsBarsByMinutesAndListsTodayThenLongerFirstUpToSixTitles() throws {
        let entries = try decodeEntries(
            (1...7).map { entry("work\($0)", area: "Client Work", minutes: $0, on: "2026-11-01") }
                + [entry("workToday", area: "Client Work", minutes: 1, on: "2026-11-03"),
                   entry("book", area: "Reading", minutes: 5, on: "2026-11-02"),
                   entry("many", area: "Other", minutes: 10, on: "2026-11-02"),
                   entry("many", area: "Other", minutes: 1, on: "2026-11-02")])
        let bars = Activity.bars(entries, today: today, calendar: calendar)
        XCTAssertEqual(bars.map(\.label), ["Client Work", "Other", "Reading"])
        XCTAssertEqual(bars[0].minutes, 29)
        XCTAssertEqual(bars[0].titles, ["workToday", "work7", "work6", "work5", "work4", "work3"])
    }

    func testAC16SummaryShowsDurationShareAndToday() {
        let bar = ActivityBar(label: "Side Project", minutes: 150, todayMinutes: 60, titles: [])
        XCTAssertEqual(bar.summary(total: 375), "2 小時 30 分 · 40% · 今天 1 小時")
        let small = ActivityBar(label: "Other", minutes: 45, todayMinutes: 0, titles: [])
        XCTAssertEqual(small.summary(total: 90), "45 分 · 50% · 今天 0 分")
    }

    func testAC17SnapshotDecodesWithAndWithoutTimeLog() throws {
        let without = #"{"fetchedAt":"2026-11-03T14:00:00+00:00","rows":[]}"#
        XCTAssertNil(try Snapshot.decode(Data(without.utf8)).timeLog)
        XCTAssertEqual(try decodeEntries([entry("a", area: "Other", minutes: 5, on: "2026-11-03")]).map(\.title), ["a"])
        XCTAssertTrue(TabConfig.empty.tabs.contains(.activity))
        XCTAssertTrue(Ranking.view(.activity, rows: try decode([row("a")]), today: today, calendar: calendar).actionable.isEmpty)
    }

    func slotRows() throws -> [Project] {
        try decode([
            row("work1", area: "Client Work", extra: #","date:Deadline:start":"2026-11-12""#),
            row("work2", area: "Client Work", extra: #","Priority":"P0""#),
            row("work3", area: "Client Work", extra: #","Priority":"P1""#),
            row("work4", area: "Client Work", extra: #","Priority":"P2""#),
            row("readLow", area: "Reading"),
            row("readHigh", area: "Reading", extra: #","Priority":"P3""#),
            row("readWait", next: "等 x", area: "Reading", extra: #","Priority":"P0""#),
        ])
    }

    func now(_ rows: [Project], _ slot: GTDTab?) -> [String] {
        Ranking.view(.now, rows: rows, today: today, calendar: calendar, config: config, thirdSlot: slot).actionable.map(\.title)
    }

    func testAC18ThirdSlotTakesBestItemOfChosenTabAndKeepsFirstTwo() throws {
        XCTAssertEqual(now(try slotRows(), reading), ["work1", "work2", "readHigh"])
    }

    func testAC19NoChangeWhenUnsetEmptyOrAlreadyInTopThree() throws {
        let rows = try slotRows()
        XCTAssertEqual(now(rows, nil), ["work1", "work2", "work3"])
        XCTAssertEqual(now(rows, side), ["work1", "work2", "work3"])
        XCTAssertEqual(now(rows, work), ["work1", "work2", "work3"])
        let readingSecond = try decode([
            row("a", area: "Client Work", extra: #","Priority":"P0""#),
            row("r", area: "Reading", extra: #","Priority":"P1""#),
            row("b", area: "Client Work", extra: #","Priority":"P2""#),
        ])
        XCTAssertEqual(now(readingSecond, reading), ["a", "r", "b"])
    }

    func testAC20OtherTabsIgnoreThirdSlotAndChoicesMatchSpec() throws {
        let other = Ranking.view(work, rows: try slotRows(), today: today, calendar: calendar, config: config, thirdSlot: reading)
        XCTAssertEqual(other.actionable.count, 4)
        XCTAssertEqual(config.thirdSlotChoices, [work, reading, side, .other])
    }

    func testAC20ChoiceSurvivesReloadAndDefaultComesFromConfig() throws {
        let name = "gtd-island-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(ThirdSlot.load(config: config, defaults))
        let withDefault = TabConfig(rules: config.rules, thirdSlot: "閱讀")
        XCTAssertEqual(ThirdSlot.load(config: withDefault, defaults), reading)
        ThirdSlot.save(side, defaults)
        XCTAssertEqual(ThirdSlot.load(config: withDefault, defaults), side)
        ThirdSlot.save(nil, defaults)
        XCTAssertNil(ThirdSlot.load(config: withDefault, defaults))
        defaults.set(GTDTab.now.name, forKey: ThirdSlot.key)
        XCTAssertNil(ThirdSlot.load(config: withDefault, defaults))
        defaults.set("已刪除的分頁", forKey: ThirdSlot.key)
        XCTAssertNil(ThirdSlot.load(config: withDefault, defaults))
    }

    func testAC5TargetPrefersOwnerSession() throws {
        let withSession = row("s").replacingOccurrences(
            of: #""Owner Session":"""#, with: #""Owner Session":"claude://claude.ai/epitaxy/local_1""#)
        let rows = try decode([withSession, row("n")])
        XCTAssertEqual(rows[0].target?.absoluteString, "claude://claude.ai/epitaxy/local_1")
        XCTAssertTrue(rows[0].opensSession)
        XCTAssertEqual(rows[1].target?.absoluteString, "https://n/n")
        XCTAssertFalse(rows[1].opensSession)
    }

    func testAC6SnapshotStaleAfterFiveMinutes() throws {
        let json = #"{"fetchedAt":"2026-11-03T14:00:00+00:00","rows":[]}"#
        let snapshot = try Snapshot.decode(Data(json.utf8))
        XCTAssertFalse(snapshot.isStale(now: snapshot.fetchedAt.addingTimeInterval(300)))
        XCTAssertTrue(snapshot.isStale(now: snapshot.fetchedAt.addingTimeInterval(301)))
    }

    func testPlainTextRemovesNotionEscapesAndLinks() {
        XCTAssertEqual(Project.plainText(#"合併 claude/[CLAUDE.md](http://CLAUDE.md) 與 Jane\_Doe\_Report"#),
                       "合併 claude/CLAUDE.md 與 Jane_Doe_Report")
    }

    func testDeadlineLabelSeparatesUpcomingFromOverdue() throws {
        let rows = try decode([
            row("soon", extra: #","date:Deadline:start":"2026-11-12""#),
            row("today", extra: #","date:Deadline:start":"2026-11-03""#),
            row("late", extra: #","date:Deadline:start":"2026-10-13""#),
            row("none"),
        ])
        let labels = rows.map { $0.deadlineLabel(today: today, calendar: calendar) }
        XCTAssertEqual(labels[0]?.text, "截止 11-12")
        XCTAssertEqual(labels[0]?.isOverdue, false)
        XCTAssertEqual(labels[1]?.isOverdue, false)
        XCTAssertEqual(labels[2]?.text, "已過 10-13")
        XCTAssertEqual(labels[2]?.isOverdue, true)
        XCTAssertNil(labels[3])
    }
}
