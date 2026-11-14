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
        XCTAssertEqual(config.tabs.map(\.name), ["先看這 3 件", "等你", "動態", "工作", "閱讀", "Side", "其他"])
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
        XCTAssertEqual(noTabs.tabs, [.now, .waiting, .activity, .other])
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

    func testAC58NotchHasNoFindTab() {
        XCTAssertEqual(TabConfig.empty.tabs, [.now, .waiting, .activity, .other])
    }

    private func waitingItem(_ id: String, _ title: String, needsYou: Bool = true, local: String? = nil) -> AttentionItem {
        AttentionItem(id: id, title: title, reason: needsYou ? "等你回覆" : "做完了", folder: "repo", at: Date(timeIntervalSince1970: 0),
                      needsYou: needsYou, target: local.flatMap { URL(string: "claude://claude.ai/epitaxy/\($0)") })
    }

    func testAC53EmptyQueryListsWaitingSessionsInOrder() {
        let waiting = (1...10).map { waitingItem("s\($0)", "等你 \($0)", local: "local_\($0)") }
        let sessions = [DesktopSession(sessionId: "local_99", cliSessionId: nil, title: "別的", lastFocusedAt: 9)]
        let rows = Search.rows(query: "  ", attention: waiting, sessions: sessions, matches: [])
        XCTAssertEqual(rows.map(\.title), (1...8).map { "等你 \($0)" })
        XCTAssertEqual(rows[0].note, "等你回覆")
        XCTAssertTrue(rows[0].waiting)
    }

    func testAC54FiltersByEveryWordWaitingFirstThenNewest() {
        let waiting = [waitingItem("t1", "kafka-pm", needsYou: false), waitingItem("s2", "Kafka PM 週報", local: "local_2")]
        let sessions = [
            DesktopSession(sessionId: "local_2", cliSessionId: "s2", title: "Kafka PM 週報", lastFocusedAt: 1),
            DesktopSession(sessionId: "local_3", cliSessionId: nil, title: "kafka 舊的 pm 筆記", lastFocusedAt: 5, cwd: "/r/notes"),
            DesktopSession(sessionId: "local_4", cliSessionId: nil, title: "PM kafka 新的", lastFocusedAt: 8),
            DesktopSession(sessionId: "local_5", cliSessionId: nil, title: "只有 kafka", lastFocusedAt: 9),
            DesktopSession(sessionId: "local_6", cliSessionId: nil, title: "kafka pm 封存", isArchived: true, lastFocusedAt: 9),
            DesktopSession(sessionId: "local_7", cliSessionId: nil, title: "kafka pm 排程", lastFocusedAt: 9, scheduledTaskId: "x"),
            DesktopSession(sessionId: "local_8", cliSessionId: nil, title: nil, lastFocusedAt: 9),
            DesktopSession(sessionId: "local_9", cliSessionId: nil, title: "週報", lastFocusedAt: 2, cwd: "/r/kafka-pm"),
        ]
        let rows = Search.rows(query: "kafka PM", attention: waiting, sessions: sessions, matches: [])
        XCTAssertEqual(rows.map(\.title), ["kafka-pm", "Kafka PM 週報", "PM kafka 新的", "kafka 舊的 pm 筆記", "週報"])
        XCTAssertNil(rows[0].target)
        XCTAssertEqual(rows[1].target?.absoluteString, "claude://claude.ai/epitaxy/local_2")
        XCTAssertEqual(rows.map(\.waiting), [true, true, false, false, false])
        XCTAssertEqual(rows[3].note, "notes")
    }

    func testAC55ModelMatchesFollowWithoutRepeatsUpToEight() {
        let sessions = (1...6).map { DesktopSession(sessionId: "local_\($0)", cliSessionId: nil, title: "登入 \($0)", lastFocusedAt: Double($0)) }
        let matches = [SessionMatch(id: "local_3", title: "登入 3", cwd: "/r/a"), SessionMatch(id: "local_20", title: "修 auth", cwd: "/r/a"),
                       SessionMatch(id: "local_21", title: "sign-in", cwd: "/r/b"), SessionMatch(id: "local_22", title: "第九個", cwd: "/r/b")]
        let rows = Search.rows(query: "登入", attention: [], sessions: sessions, matches: matches)
        XCTAssertEqual(rows.map(\.title), ["登入 6", "登入 5", "登入 4", "登入 3", "登入 2", "登入 1", "修 auth", "sign-in"])
        XCTAssertEqual(rows[6].note, "a")
        XCTAssertEqual(Search.rows(query: "", attention: [], sessions: sessions, matches: matches), [])
    }

    func testAC56SelectionFollowsTheRowNotItsPosition() {
        let rows = Search.rows(query: "", attention: [waitingItem("a", "A"), waitingItem("b", "B")], sessions: [], matches: [])
        XCTAssertEqual(Search.index(of: rows[1].id, in: rows), 1)
        let reordered = Search.rows(query: "", attention: [waitingItem("c", "C"), waitingItem("b", "B"), waitingItem("a", "A")], sessions: [], matches: [])
        XCTAssertEqual(Search.index(of: rows[1].id, in: reordered), 1)
        XCTAssertEqual(Search.index(of: rows[0].id, in: reordered), 2)
        XCTAssertEqual(Search.index(of: "gone", in: reordered), 0)
        XCTAssertEqual(Search.index(of: nil, in: reordered), 0)
    }

    func testAC54WaitingSessionWithoutLinkBorrowsItFromTheDesktopSession() {
        let waiting = [waitingItem("cli-1", "部署")]
        let sessions = [DesktopSession(sessionId: "local_1", cliSessionId: "cli-1", title: "部署", lastFocusedAt: 1)]
        for query in ["", "部署"] {
            let rows = Search.rows(query: query, attention: waiting, sessions: sessions, matches: [])
            XCTAssertEqual(rows.count, 1, query)
            XCTAssertTrue(rows[0].waiting)
            XCTAssertEqual(rows[0].target?.absoluteString, "claude://claude.ai/epitaxy/local_1")
        }
    }

    func testAC56SelectionStaysInsideTheList() {
        XCTAssertEqual(Search.move(0, by: -1, count: 3), 0)
        XCTAssertEqual(Search.move(0, by: 1, count: 3), 1)
        XCTAssertEqual(Search.move(2, by: 1, count: 3), 2)
        XCTAssertEqual(Search.move(5, by: 0, count: 3), 2)
        XCTAssertEqual(Search.move(0, by: 1, count: 0), 0)
    }

    func testAC54DecodesTheFieldsSearchNeeds() {
        let json = #"{"sessionId":"local_1","title":"t","cwd":"/r/app","scheduledTaskId":"job","lastFocusedAt":5}"#
        let session = DesktopSession.decode(Data(json.utf8))
        XCTAssertEqual(session?.cwd, "/r/app")
        XCTAssertEqual(session?.scheduledTaskId, "job")
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

    func action(_ title: String, parent: String, session: String = "", status: String = "Active") -> String {
        """
        {"Outcome":"\(title)","url":"https://n/act-\(title)","Owner Session":"\(session)",\
        "GTD Status":"\(status)","parents":["\(parent)"]}
        """
    }

    func snapshot(_ rows: [String], actions: [String]?) throws -> Snapshot {
        let list = actions.map { "[\($0.joined(separator: ","))]" } ?? "null"
        let json = "{\"fetchedAt\":\"2026-11-03T14:00:00+00:00\",\"rows\":[\(rows.joined(separator: ","))],\"actions\":\(list)}"
        return try Snapshot.decode(Data(json.utf8))
    }

    func jump(_ snap: Snapshot, _ index: Int = 0) -> (Jump.Kind, String?) {
        let j = snap.jump(for: snap.rows[index])
        return (j.kind, j.url?.absoluteString.removingPercentEncoding)
    }

    func testAC5ProjectOwnerSessionComesFirst() throws {
        let withSession = row("p", next: "寫說明").replacingOccurrences(
            of: #""Owner Session":"""#, with: #""Owner Session":"claude://claude.ai/epitaxy/local_1""#)
        let snap = try snapshot([withSession], actions: [action("寫說明", parent: "p", session: "claude://claude.ai/epitaxy/local_2")])
        XCTAssertTrue(jump(snap) == (.session, "claude://claude.ai/epitaxy/local_1"))
    }

    func testAC5UsesSessionOfOpenChildActionNamedByNextAction() throws {
        let snap = try snapshot([row("p", next: "寫說明")], actions: [
            action("別的事", parent: "p", session: "claude://claude.ai/epitaxy/local_9"),
            action("寫說明", parent: "other", session: "claude://claude.ai/epitaxy/local_8"),
            action("寫說明", parent: "p", session: "claude://claude.ai/epitaxy/local_2"),
        ])
        XCTAssertTrue(jump(snap) == (.session, "claude://claude.ai/epitaxy/local_2"))
    }

    func testAC5MatchedActionWithoutSessionOpensActionPage() throws {
        let snap = try snapshot([row("p", next: "寫\\\\_說明")], actions: [action("寫_說明", parent: "p")])
        XCTAssertTrue(jump(snap) == (.action, "https://n/act-寫_說明"))
    }

    func testAC5TitleMismatchFallsBackToProjectPage() throws {
        let snap = try snapshot([row("p", next: "寫說明")], actions: [
            action("寫 changelog", parent: "p", session: "claude://claude.ai/epitaxy/local_2"),
        ])
        XCTAssertTrue(jump(snap) == (.notion, "https://n/p"))
    }

    func testAC5DoneOrDroppedActionIsIgnored() throws {
        let snap = try snapshot([row("p", next: "寫說明")], actions: [
            action("寫說明", parent: "p", session: "claude://claude.ai/epitaxy/local_2", status: "Done"),
            action("寫說明", parent: "p", session: "claude://claude.ai/epitaxy/local_3", status: "Dropped"),
        ])
        XCTAssertTrue(jump(snap) == (.notion, "https://n/p"))
    }

    func testAC27SnapshotWithoutActionsUsesOnlyProjectFields() throws {
        let old = #"{"fetchedAt":"2026-11-03T14:00:00+00:00","rows":[\#(row("p"))]}"#
        let snap = try Snapshot.decode(Data(old.utf8))
        XCTAssertNil(snap.actions)
        XCTAssertTrue(jump(snap) == (.notion, "https://n/p"))
        XCTAssertTrue(jump(try snapshot([row("p")], actions: nil)) == (.notion, "https://n/p"))
    }

    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let pillSize = CGSize(width: 340, height: 30)
    let panelSize = CGSize(width: 480, height: 560)

    func testAC40DefaultIsTheScreenTopCenterOverTheMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let area = Placement.area(visible: visible, screen: screen)
        XCTAssertEqual(area, CGRect(x: 0, y: 0, width: 1440, height: 900))
        let anchor = Placement.defaultAnchor(area)
        XCTAssertEqual(Placement.frame(size: pillSize, anchor: anchor, visible: area),
                       CGRect(x: 550, y: 900 - 30, width: 340, height: 30))
    }

    func testAC29PanelGrowsDownFromTheSameTopCenter() {
        let anchor = CGPoint(x: 700, y: 600)
        let pill = Placement.frame(size: pillSize, anchor: anchor, visible: visible)
        let panel = Placement.frame(size: panelSize, anchor: anchor, visible: visible)
        XCTAssertEqual(pill.midX, panel.midX)
        XCTAssertEqual(pill.maxY, panel.maxY)
        XCTAssertEqual(Placement.anchor(for: pill), anchor)
    }

    func testAC29FrameUsesWholePointsSoTheWindowServerKeepsIt() {
        let frame = Placement.frame(size: panelSize, anchor: CGPoint(x: 700.4, y: 600.6), visible: visible)
        XCTAssertEqual(frame.origin, CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()))
    }

    func testAC29PanelIsPushedBackInsideTheVisibleArea() {
        let corner = CGPoint(x: 1430, y: 875)
        XCTAssertEqual(Placement.frame(size: panelSize, anchor: corner, visible: visible),
                       CGRect(x: 960, y: 315, width: 480, height: 560))
        let low = CGPoint(x: 10, y: 100)
        XCTAssertEqual(Placement.frame(size: panelSize, anchor: low, visible: visible),
                       CGRect(x: 0, y: 0, width: 480, height: 560))
    }

    func testAC28SavedPositionSurvivesReload() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "gtd-island-test-\(UUID())"))
        XCTAssertNil(Placement.load(defaults, screens: [visible]))
        Placement.save(CGPoint(x: 1200, y: 870), defaults)
        XCTAssertEqual(Placement.load(defaults, screens: [visible]), CGPoint(x: 1200, y: 870))
    }

    func testAC30SavedPointOffEveryScreenIsIgnored() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "gtd-island-test-\(UUID())"))
        Placement.save(CGPoint(x: 2000, y: 500), defaults)
        XCTAssertNil(Placement.load(defaults, screens: [visible]))
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(Placement.load(defaults, screens: [visible, external]), CGPoint(x: 2000, y: 500))
    }

    func testAC31OnlyThisWeekRowsCanBePostponed() throws {
        let week = row("w", extra: #","This Week":"__YES__""#).replacingOccurrences(of: #""This Week":"__NO__","#, with: "")
        let rows = try decode([week, row("n")])
        XCTAssertTrue(rows[0].canPostpone)
        XCTAssertFalse(rows[1].canPostpone)
        XCTAssertEqual(rows[0].pageID, "w")
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

    // MARK: 等你 (AC36-AC38)

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ id: String, _ state: String, minutesAgo: Double, message: String = "", cwd: String = "/repo/demo") -> AttentionRecord {
        AttentionRecord(sessionId: id, cwd: cwd, state: state, message: message, at: now.addingTimeInterval(-minutesAgo * 60))
    }

    func testAC33RecordDecodesHookOutput() throws {
        let json = #"{"sessionId":"s1","cwd":"/repo/demo","state":"needsYou","message":"要用哪個方案?","at":"2026-11-13T01:00:00Z"}"#
        let r = try XCTUnwrap(AttentionRecord.decode(Data(json.utf8)))
        XCTAssertEqual(r.sessionId, "s1")
        XCTAssertTrue(r.needsYou)
        XCTAssertEqual(r.at, ISO8601DateFormatter().date(from: "2026-11-13T01:00:00Z"))
        XCTAssertNil(AttentionRecord.decode(Data("{}".utf8)))
        let ms = #"{"sessionId":"s1","cwd":"","state":"done","message":"","at":"2026-11-13T01:00:00.250Z"}"#
        XCTAssertEqual(AttentionRecord.decode(Data(ms.utf8))?.at.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-11-13T01:00:00Z")!.timeIntervalSince1970 + 0.25)
    }

    func testAC36NeedsYouFirstThenNewestFirst() {
        let items = Attention.items([
            record("done-old", "done", minutesAgo: 30),
            record("ask", "needsYou", minutesAgo: 20, message: "要用哪個方案?"),
            record("done-new", "done", minutesAgo: 1),
            record("perm", "needsYou", minutesAgo: 5),
        ], desktop: [:], now: now)
        XCTAssertEqual(items.map(\.id), ["perm", "ask", "done-new", "done-old"])
        XCTAssertEqual(items.map(\.reason), ["等你回覆", "要用哪個方案?", "做完了", "做完了"])
        XCTAssertEqual(items[0].folder, "demo")
    }

    func testAC37DesktopSessionGivesTitleAndJumpTerminalHasNone() {
        let desktop = ["cli-1": DesktopSession(sessionId: "local_7", cliSessionId: "cli-1", title: "發布 1.0")]
        let items = Attention.items([record("cli-1", "needsYou", minutesAgo: 2), record("cli-2", "done", minutesAgo: 1)],
                                   desktop: desktop, now: now)
        XCTAssertEqual(items[0].title, "發布 1.0")
        XCTAssertEqual(items[0].target, URL(string: "claude://claude.ai/epitaxy/local_7"))
        XCTAssertEqual(items[1].title, "demo")
        XCTAssertNil(items[1].target)
    }

    func testAC38HidesOldArchivedAndAlreadySeen() {
        let seenAt = now.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        let desktop = [
            "archived": DesktopSession(sessionId: "local_a", cliSessionId: "archived", title: "a", isArchived: true),
            "seen": DesktopSession(sessionId: "local_s", cliSessionId: "seen", title: "s", lastFocusedAt: seenAt),
            "unseen": DesktopSession(sessionId: "local_u", cliSessionId: "unseen", title: "u", lastFocusedAt: seenAt),
        ]
        let items = Attention.items([
            record("old", "done", minutesAgo: 8 * 24 * 60),
            record("week", "done", minutesAgo: 7 * 24 * 60 - 1),
            record("archived", "done", minutesAgo: 1),
            record("seen", "done", minutesAgo: 5),
            record("unseen", "done", minutesAgo: 0.5),
        ], desktop: desktop, now: now)
        XCTAssertEqual(items.map(\.id), ["unseen", "week"])
    }

    func testAC37DesktopIndexReadsCliSessionIds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gtd-desktop-\(UUID())")
        let folder = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_7","cliSessionId":"cli-1","title":"t","extra":{"x":1}}"#.utf8)
            .write(to: folder.appendingPathComponent("local_7.json"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("local_8.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let index = DesktopSession.index(root: root.path)
        XCTAssertEqual(Array(index.keys), ["cli-1"])
        let path = try XCTUnwrap(index["cli-1"])
        XCTAssertEqual(FileManager.default.contents(atPath: path).flatMap(DesktopSession.decode)?.sessionId, "local_7")
    }

    func testAgeText() {
        XCTAssertEqual(Attention.age(now.addingTimeInterval(-30), now: now), "剛剛")
        XCTAssertEqual(Attention.age(now.addingTimeInterval(-5 * 60), now: now), "5 分鐘前")
        XCTAssertEqual(Attention.age(now.addingTimeInterval(-3 * 3600), now: now), "3 小時前")
        XCTAssertEqual(Attention.age(now.addingTimeInterval(-2 * 86400), now: now), "2 天前")
    }

    // MARK: 在瀏海裡回答 (AC44-AC48)

    let questionJSON = #"{"id":"s1--1","sessionId":"s1","cwd":"/r","kind":"question","at":"2026-11-13T01:00:00.000Z","questions":[{"question":"方案?","header":"方案","multiSelect":false,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]},{"question":"環境?","multiSelect":true,"options":[{"label":"dev"},{"label":"prod"}]}]}"#

    func testAC45RequestDecodesQuestions() throws {
        let r = try XCTUnwrap(PendingRequest.decode(Data(questionJSON.utf8)))
        XCTAssertTrue(r.isQuestion)
        XCTAssertEqual(r.questions?.map(\.question), ["方案?", "環境?"])
        XCTAssertEqual(r.questions?[1].options.map(\.label), ["dev", "prod"])
        let empty = #"{"id":"x","sessionId":"s1","kind":"question","at":"2026-11-13T01:00:00Z","questions":[]}"#
        XCTAssertNil(PendingRequest.decode(Data(empty.utf8)))
    }

    func testAC48QuestionReplyNeedsEveryAnswer() throws {
        let r = try XCTUnwrap(PendingRequest.decode(Data(questionJSON.utf8)))
        XCTAssertNil(r.reply(choices: ["方案?": ["B"]]))
        XCTAssertNil(r.reply(choices: ["方案?": ["B"], "環境?": []]))
        let data = try XCTUnwrap(r.reply(choices: ["方案?": ["B"], "環境?": ["prod", "dev", "ghost"]]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        XCTAssertEqual(json["answers"]?["方案?"] as? String, "B")
        XCTAssertEqual(json["answers"]?["環境?"] as? [String], ["dev", "prod"])
    }

    func testAC44PermissionReplies() {
        XCTAssertEqual(String(data: PendingRequest.reply(decision: "allow"), encoding: .utf8), #"{"decision":"allow"}"#)
        XCTAssertEqual(String(data: PendingRequest.reply(decision: "deny"), encoding: .utf8), #"{"decision":"deny"}"#)
        XCTAssertEqual(String(data: PendingRequest.reply(decision: "skip"), encoding: .utf8), #"{"skip":true}"#)
    }

    func testAC48OldRequestFilesAreIgnored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gtd-req-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fresh = #"{"id":"a","sessionId":"s1","kind":"permission","toolName":"Bash","detail":"Bash · ls","at":"2026-11-13T01:00:00Z"}"#
        try Data(fresh.utf8).write(to: folder.appendingPathComponent("a.json"))
        let at = ISO8601DateFormatter().date(from: "2026-11-13T01:00:00Z")!
        XCTAssertEqual(PendingRequest.load(folder: folder.path, now: at.addingTimeInterval(129)).map(\.id), ["a"])
        XCTAssertEqual(PendingRequest.load(folder: folder.path, now: at.addingTimeInterval(131)).map(\.id), [])
    }

    func testAC48RequestStaysVisibleAndAttachesToItsSession() throws {
        let r = try XCTUnwrap(PendingRequest.decode(Data(questionJSON.utf8)))
        let seen = r.at.addingTimeInterval(10).timeIntervalSince1970 * 1000
        let desktop = ["s1": DesktopSession(sessionId: "local_1", cliSessionId: "s1", title: "發布 1.0", lastFocusedAt: seen)]
        let rec = AttentionRecord(sessionId: "s1", cwd: "/r", state: "needsYou", message: "方案?", at: r.at)
        let items = Attention.items([rec], desktop: desktop, now: r.at.addingTimeInterval(20), requests: [r])
        XCTAssertEqual(items.map(\.id), ["s1"])
        XCTAssertEqual(items[0].request?.id, "s1--1")
        XCTAssertTrue(Attention.items([rec], desktop: desktop, now: r.at.addingTimeInterval(20)).isEmpty)
        let alone = Attention.items([], desktop: [:], now: r.at, requests: [r])
        XCTAssertEqual(alone.map(\.id), ["s1"])
        XCTAssertTrue(alone[0].needsYou)
    }
}
