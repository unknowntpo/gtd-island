import io
import json
import os
import tempfile
import unittest

import route


def write_session(root, name, **fields):
    folder = os.path.join(root, "a", "b")
    os.makedirs(folder, exist_ok=True)
    body = {"sessionId": name, "title": name, "cwd": "/repo/" + name, "lastActivityAt": 1, **fields}
    with open(os.path.join(folder, name + ".json"), "w") as f:
        json.dump(body, f)


class LoadTests(unittest.TestCase):
    def test_ac12_excludes_archived_and_scheduled_sessions(self):
        with tempfile.TemporaryDirectory() as root:
            write_session(root, "local_keep", title="發布說明草稿")
            write_session(root, "local_old", isArchived=True)
            write_session(root, "local_cron", scheduledTaskId="t1")
            sessions = route.load_sessions(root)
        self.assertEqual([s["id"] for s in sessions], ["local_keep"])
        self.assertEqual(sessions[0]["title"], "發布說明草稿")
        self.assertEqual(sessions[0]["cwd"], "/repo/local_keep")

    def test_ac12_ignores_files_without_a_session(self):
        with tempfile.TemporaryDirectory() as root:
            write_session(root, "local_keep")
            with open(os.path.join(root, "a", "b", "local_bad.json"), "w") as f:
                f.write("{not json")
            self.assertEqual(len(route.load_sessions(root)), 1)


class MatchTests(unittest.TestCase):
    VECTORS = {"query: 報告": [1.0, 0.0], "passage: 報告準備": [0.9, 0.1], "passage: 部署": [0.0, 1.0]}

    def sessions(self):
        return [{"id": "a", "title": "部署", "cwd": ""}, {"id": "b", "title": "報告準備", "cwd": ""}]

    def test_ac12_puts_related_session_first_and_limits_results(self):
        rows = route.top_matches("報告", self.sessions(), self.VECTORS.__getitem__, {}, limit=1)
        self.assertEqual([r["id"] for r in rows], ["b"])

    def test_ac12_reuses_cached_title_vectors(self):
        calls = []

        def embed(text):
            calls.append(text)
            return self.VECTORS[text]

        cache = {}
        route.top_matches("報告", self.sessions(), embed, cache)
        route.top_matches("報告", self.sessions(), embed, cache)
        self.assertEqual(calls.count("passage: 部署"), 1)

    def test_ac12_shared_words_lift_a_title_above_a_close_semantic_score(self):
        vectors = {"query: 想寫發布說明": [1.0, 0.0], "passage: 烹飪筆記": [0.86, 0.0], "passage: 發布說明草稿": [0.855, 0.0]}
        sessions = [{"id": "other", "title": "烹飪筆記", "cwd": ""}, {"id": "docs", "title": "發布說明草稿", "cwd": ""}]
        rows = route.top_matches("想寫發布說明", sessions, vectors.__getitem__, {})
        self.assertEqual([r["id"] for r in rows], ["docs", "other"])

    def test_ac12_empty_query_returns_nothing(self):
        self.assertEqual(route.top_matches("  ", self.sessions(), self.VECTORS.__getitem__, {}), [])


class ServeTests(unittest.TestCase):
    def test_ac12_answers_one_json_line_per_request_and_survives_a_bad_line(self):
        requests = io.StringIO('not json\n{"query":"報告"}\n')
        output = io.StringIO()
        route.serve(requests, output, lambda query: [{"id": "b", "query": query}])
        lines = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(lines[0]["matches"], [])
        self.assertIn("error", lines[0])
        self.assertEqual(lines[1], {"matches": [{"id": "b", "query": "報告"}]})


if __name__ == "__main__":
    unittest.main()
