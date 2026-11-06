import json
import os
import tempfile
import unittest
import urllib.error
from datetime import date
from unittest import mock

import refresh

refresh.DATA_SOURCE = "data-source-id"
refresh.TIME_LOG = "time-log-id"
refresh.VIEW = "view://view-id"

PAGE_ID = "11111111-2222-4333-8444-555555555555"


def page(title="寫完文件", **extra):
    properties = {
        "Outcome": {"type": "title", "title": [{"plain_text": title[:2]}, {"plain_text": title[2:]}]},
        "Next Action": {"type": "rich_text", "rich_text": [{"plain_text": "補測試案例"}]},
        "Waiting For": {"type": "rich_text", "rich_text": []},
        "Area": {"type": "select", "select": {"name": "Side Project"}},
        "Priority": {"type": "select", "select": None},
        "This Week": {"type": "checkbox", "checkbox": True},
        "Owner Session": {"type": "url", "url": "claude://claude.ai/epitaxy/local_1"},
        "Source URL": {"type": "url", "url": None},
        "Deadline": {"type": "date", "date": {"start": "2026-02-01", "end": None}},
        "Last Worked": {"type": "date", "date": None},
        "Parent Project": {"type": "relation", "relation": []},
    }
    return {"id": PAGE_ID, "url": "https://www.notion.so/x", "properties": properties, **extra}


class FakeResponse:
    def __init__(self, body):
        self.body = json.dumps(body).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self.body


class FlattenTests(unittest.TestCase):
    def test_ac9_row_matches_view_shape(self):
        row = refresh.flatten(page())
        self.assertEqual(row["url"], "https://app.notion.com/p/11111111222243338444555555555555")
        self.assertEqual(row["Outcome"], "寫完文件")
        self.assertEqual(row["Next Action"], "補測試案例")
        self.assertEqual(row["Waiting For"], "")
        self.assertEqual(row["Area"], "Side Project")
        self.assertEqual(row["Priority"], "")
        self.assertEqual(row["This Week"], "__YES__")
        self.assertEqual(row["Owner Session"], "claude://claude.ai/epitaxy/local_1")
        self.assertEqual(row["Source URL"], "")
        self.assertEqual(row["date:Deadline:start"], "2026-02-01")
        self.assertNotIn("date:Last Worked:start", row)
        self.assertNotIn("Parent Project", row)


class QueryTests(unittest.TestCase):
    def test_ac9_sends_view_filter_and_reads_every_page(self):
        replies = [
            FakeResponse({"results": [page("第一頁的")], "has_more": True, "next_cursor": "c2"}),
            FakeResponse({"results": [page("第二頁的")], "has_more": False, "next_cursor": None}),
        ]
        with mock.patch("urllib.request.urlopen", side_effect=replies) as urlopen:
            rows = refresh.query_api("secret")
        self.assertEqual([r["Outcome"] for r in rows], ["第一頁的", "第二頁的"])
        first, second = [call.args[0] for call in urlopen.call_args_list]
        body = json.loads(first.data)
        self.assertEqual(body["filter"], {"and": [
            {"property": "Item Type", "select": {"equals": "Project"}},
            {"property": "GTD Status", "select": {"equals": "Active"}},
        ]})
        self.assertEqual(body["sorts"], [{"property": "Last Worked", "direction": "descending"}])
        self.assertNotIn("start_cursor", body)
        self.assertEqual(json.loads(second.data)["start_cursor"], "c2")
        self.assertEqual(first.get_header("Authorization"), "Bearer secret")
        self.assertIn("data-source-id", first.full_url)


class ActionTests(unittest.TestCase):
    def test_ac27_queries_open_actions_and_keeps_parent_ids(self):
        parent = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        action = page("寫說明", **{})
        action["properties"]["Parent Project"]["relation"] = [{"id": parent}]
        action["properties"]["GTD Status"] = {"type": "select", "select": {"name": "Active"}}
        sent = []

        def respond(request, timeout):
            sent.append(json.loads(request.data))
            return FakeResponse({"results": [action], "has_more": False})

        with mock.patch("urllib.request.urlopen", respond):
            rows = refresh.query_actions("secret")
        self.assertEqual(sent[0]["filter"], {"and": [
            {"property": "Item Type", "select": {"equals": "Action"}},
            {"property": "GTD Status", "select": {"does_not_equal": "Done"}},
            {"property": "GTD Status", "select": {"does_not_equal": "Dropped"}},
        ]})
        self.assertEqual(rows, [{
            "Outcome": "寫說明",
            "url": "https://app.notion.com/p/11111111222243338444555555555555",
            "Owner Session": "claude://claude.ai/epitaxy/local_1",
            "GTD Status": "Active",
            "parents": ["aaaaaaaabbbb4ccc8dddeeeeeeeeeeee"],
        }])

    def test_ac27_failure_or_no_token_gives_none(self):
        with mock.patch.object(refresh, "read_token", return_value=None):
            self.assertIsNone(refresh.fetch_actions())
        with mock.patch.object(refresh, "read_token", return_value="secret"), \
                mock.patch.object(refresh, "query_actions", side_effect=urllib.error.URLError("boom")), \
                mock.patch("sys.stderr"):
            self.assertIsNone(refresh.fetch_actions())

    def test_ac27_main_writes_actions_into_the_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(refresh, "OUT", os.path.join(tmp, "snapshot.json")), \
                mock.patch.object(refresh, "fetch_rows", return_value=[{"Outcome": "p"}]), \
                mock.patch.object(refresh, "fetch_time_log", return_value=None), \
                mock.patch.object(refresh, "fetch_actions", return_value=[{"Outcome": "a"}]), \
                mock.patch("builtins.print"):
            self.assertEqual(refresh.main(), 0)
            with open(os.path.join(tmp, "snapshot.json"), encoding="utf-8") as f:
                self.assertEqual(json.load(f)["actions"], [{"Outcome": "a"}])


class FallbackTests(unittest.TestCase):
    def test_ac9_uses_api_when_token_exists(self):
        with mock.patch.object(refresh, "read_token", return_value="secret"), \
                mock.patch.object(refresh, "query_api", return_value=[{"Outcome": "a"}]), \
                mock.patch.object(refresh, "query_claude") as claude:
            self.assertEqual(refresh.fetch_rows(), [{"Outcome": "a"}])
        claude.assert_not_called()

    def test_ac10_uses_claude_without_token(self):
        with mock.patch.object(refresh, "read_token", return_value=None), \
                mock.patch.object(refresh, "query_api") as api, \
                mock.patch.object(refresh, "query_claude", return_value=[{"Outcome": "b"}]):
            self.assertEqual(refresh.fetch_rows(), [{"Outcome": "b"}])
        api.assert_not_called()

    def test_ac10_uses_claude_when_api_fails_and_hides_token(self):
        error = urllib.error.URLError("boom")
        with mock.patch.object(refresh, "read_token", return_value="secret"), \
                mock.patch.object(refresh, "query_api", side_effect=error), \
                mock.patch.object(refresh, "query_claude", return_value=[{"Outcome": "c"}]), \
                mock.patch("sys.stderr") as stderr:
            self.assertEqual(refresh.fetch_rows(), [{"Outcome": "c"}])
        written = "".join(str(call.args[0]) for call in stderr.write.call_args_list)
        self.assertIn("boom", written)
        self.assertNotIn("secret", written)

    def test_ac10_uses_claude_when_api_returns_no_rows(self):
        with mock.patch.object(refresh, "read_token", return_value="secret"), \
                mock.patch.object(refresh, "query_api", return_value=[]), \
                mock.patch.object(refresh, "query_claude", return_value=[{"Outcome": "d"}]):
            self.assertEqual(refresh.fetch_rows(), [{"Outcome": "d"}])

    def test_config_is_read_from_a_file_and_missing_file_is_empty(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "config.json")
            self.assertEqual(refresh.load_config(path), {})
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"dataSource": "abc"}, f)
            self.assertEqual(refresh.load_config(path), {"dataSource": "abc"})

    def test_main_stops_without_a_data_source(self):
        with mock.patch.object(refresh, "DATA_SOURCE", ""), mock.patch.object(refresh, "fetch_rows") as fetch, \
                mock.patch("sys.stderr"):
            self.assertEqual(refresh.main(), 1)
        fetch.assert_not_called()

    def test_ac22_api_only_never_uses_claude(self):
        with mock.patch.object(refresh, "query_claude") as claude, mock.patch("sys.stderr"):
            with mock.patch.object(refresh, "read_token", return_value=None):
                self.assertIsNone(refresh.fetch_rows(api_only=True))
            with mock.patch.object(refresh, "read_token", return_value="secret"), \
                    mock.patch.object(refresh, "query_api", side_effect=urllib.error.URLError("boom")):
                self.assertIsNone(refresh.fetch_rows(api_only=True))
            with mock.patch.object(refresh, "read_token", return_value="secret"), \
                    mock.patch.object(refresh, "query_api", return_value=[]):
                self.assertIsNone(refresh.fetch_rows(api_only=True))
        claude.assert_not_called()

    def test_ac22_main_reads_the_flag_and_keeps_the_snapshot_on_failure(self):
        with mock.patch.object(refresh, "fetch_rows", return_value=None) as fetch, \
                mock.patch.object(refresh.os, "replace") as replace, \
                mock.patch.object(refresh.sys, "argv", ["refresh.py", "--api-only"]), \
                mock.patch("sys.stderr"):
            self.assertEqual(refresh.main(), 1)
        fetch.assert_called_once_with(api_only=True)
        replace.assert_not_called()

    def test_ac15_time_log_query_covers_seven_days_and_keeps_minutes(self):
        sent = []
        time_page = {"id": PAGE_ID, "properties": {
            "Entry": {"type": "title", "title": [{"plain_text": "範例工作 30 分鐘"}]},
            "Minutes": {"type": "number", "number": 30},
            "Area": {"type": "select", "select": {"name": "Side Project"}},
            "Date": {"type": "date", "date": {"start": "2026-02-04T09:00:00.000+00:00", "end": None}},
        }}

        def respond(request, timeout):
            sent.append((request.full_url, json.loads(request.data)))
            return FakeResponse({"results": [time_page], "has_more": False})

        with mock.patch("urllib.request.urlopen", respond):
            rows = refresh.query_time_log("secret", date(2026, 2, 4))
        self.assertEqual(rows[0]["Entry"], "範例工作 30 分鐘")
        self.assertEqual(rows[0]["Minutes"], 30)
        self.assertEqual(rows[0]["date:Date:start"], "2026-02-04T09:00:00.000+00:00")
        url, body = sent[0]
        self.assertIn("time-log-id", url)
        self.assertEqual(body["filter"], {"and": [{"property": "Date", "date": {"on_or_after": "2026-01-29"}}]})
        self.assertEqual(body["sorts"], [{"property": "Date", "direction": "descending"}])

    def test_ac17_time_log_is_none_without_token_or_when_the_query_fails(self):
        with mock.patch.object(refresh, "read_token", return_value=None):
            self.assertIsNone(refresh.fetch_time_log())
        error = urllib.error.URLError("boom")
        with mock.patch.object(refresh, "read_token", return_value="secret"), \
                mock.patch.object(refresh, "query_time_log", side_effect=error), \
                mock.patch("sys.stderr"):
            self.assertIsNone(refresh.fetch_time_log())


if __name__ == "__main__":
    unittest.main()
