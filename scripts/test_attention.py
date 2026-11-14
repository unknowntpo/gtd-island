import json
import os
import tempfile
import unittest

import attention


def event(name, **fields):
    return {"session_id": "s1", "cwd": "/repo/demo", "hook_event_name": name, **fields}


class HandleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = self.tmp.name
        self.path = os.path.join(self.folder, "s1.json")

    def tearDown(self):
        self.tmp.cleanup()

    def handle(self, e, at="2026-11-13T01:00:00Z"):
        return attention.handle(e, self.folder, at=at)

    def saved(self):
        with open(self.path) as f:
            return json.load(f)

    def test_ac33_ac34_ask_user_question_needs_you_with_first_question(self):
        q = {"questions": [{"question": "要用哪個方案?"}, {"question": "第二題"}]}
        self.assertEqual(self.handle(event("PreToolUse", tool_name="AskUserQuestion", tool_input=q)), "needsYou")
        self.assertEqual(self.saved(), {"sessionId": "s1", "cwd": "/repo/demo", "state": "needsYou",
                                        "message": "要用哪個方案?", "at": "2026-11-13T01:00:00Z"})

    def test_ac34_other_pre_tool_use_is_ignored(self):
        self.assertEqual(self.handle(event("PreToolUse", tool_name="Bash")), "ignored")
        self.assertFalse(os.path.exists(self.path))

    def test_ac34_notification_needs_you(self):
        self.handle(event("Notification", message="Claude needs your permission to use Bash"))
        self.assertEqual(self.saved()["state"], "needsYou")
        self.assertEqual(self.saved()["message"], "Claude needs your permission to use Bash")

    def test_ac34_idle_notification_keeps_existing_record(self):
        self.handle(event("Stop"))
        self.assertEqual(self.handle(event("Notification", notification_type="idle_prompt", message="waiting")), "kept")
        self.assertEqual(self.saved()["state"], "done")

    def test_ac34_idle_notification_without_record_needs_you(self):
        self.handle(event("Notification", notification_type="idle_prompt", message="waiting"))
        self.assertEqual(self.saved()["state"], "needsYou")

    def test_ac34_stop_is_done(self):
        self.handle(event("Stop"))
        self.assertEqual(self.saved()["state"], "done")
        self.assertEqual(self.saved()["message"], "")

    def test_ac34_prompt_and_session_end_remove(self):
        for name in ("UserPromptSubmit", "SessionEnd"):
            self.handle(event("Stop"))
            self.assertEqual(self.handle(event(name)), "removed")
            self.assertFalse(os.path.exists(self.path))

    def test_ac34_post_tool_use_clears_only_needs_you(self):
        self.handle(event("Stop"))
        self.assertEqual(self.handle(event("PostToolUse", tool_name="Bash")), "ignored")
        self.assertTrue(os.path.exists(self.path))
        self.handle(event("Notification", message="permission"))
        self.assertEqual(self.handle(event("PostToolUse", tool_name="Bash")), "removed")
        self.assertFalse(os.path.exists(self.path))

    def test_ac35_bad_input_does_nothing(self):
        for bad in (None, [], {"hook_event_name": "Stop"}, event("Stop", session_id="../x"),
                    event("Stop", session_id=7)):
            self.assertEqual(self.handle(bad), "ignored")
        self.assertEqual(os.listdir(self.folder), [])

    def test_ac35_main_is_silent_and_exits_zero_on_garbage(self):
        import subprocess, sys
        here = os.path.dirname(os.path.abspath(__file__))
        out = subprocess.run([sys.executable, "-I", os.path.join(here, "attention.py")], input="not json",
                             capture_output=True, text=True, env={**os.environ, "HOME": self.folder})
        self.assertEqual((out.returncode, out.stdout, out.stderr), (0, "", ""))


class InstallTests(unittest.TestCase):
    def test_ac41_adds_once_keeps_other_hooks_and_backs_up(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "settings.json")
            other = {"hooks": [{"type": "command", "command": "other.sh"}]}
            with open(path, "w") as f:
                json.dump({"model": "x", "hooks": {"Stop": [other]}}, f)
            added = attention.install_hooks(path, "cmd")
            self.assertEqual(added, list(attention.EVENTS))
            self.assertTrue(os.path.exists(path + ".bak-gtd-island"))
            with open(path) as f:
                settings = json.load(f)
            self.assertEqual(settings["model"], "x")
            self.assertEqual(settings["hooks"]["Stop"][0], other)
            self.assertEqual(settings["hooks"]["PreToolUse"][0]["matcher"], "AskUserQuestion")
            self.assertNotIn("matcher", settings["hooks"]["Stop"][1])
            self.assertEqual(attention.install_hooks(path, "cmd"), [])
            with open(path) as f:
                self.assertEqual(json.load(f), settings)


class IslandTests(unittest.TestCase):
    """AC43-AC47: the hook asks GTD Island and waits for its reply."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = self.tmp.name
        self.alive()

    def tearDown(self):
        self.tmp.cleanup()

    def alive(self, age=0):
        path = os.path.join(self.base, "island.alive")
        open(path, "w").close()
        t = __import__("time").time() - age
        os.utime(path, (t, t))

    def requests(self):
        folder = os.path.join(self.base, "requests")
        return sorted(os.listdir(folder)) if os.path.isdir(folder) else []

    def reply_with(self, reply):
        """A fake sleep that answers the first request the hook wrote."""
        def sleep(_):
            names = self.requests()
            if names and reply is not None:
                attention.write(os.path.join(self.base, "responses", names[0]), reply)
            self.seen = [attention.read(os.path.join(self.base, "requests", n)) for n in names]
        return sleep

    def decide(self, event, reply, wait=1):
        self.seen = []
        return attention.decide(event, self.base, wait=wait, poll=0, sleep=self.reply_with(reply))

    def permission(self, **fields):
        return event("PermissionRequest", tool_name="Bash", tool_input={"command": "npm publish"}, **fields)

    def test_ac44_allow_and_deny(self):
        out = self.decide(self.permission(), {"decision": "allow"})
        self.assertEqual(out, {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                                      "decision": {"behavior": "allow"}}})
        self.assertEqual(self.seen[0]["kind"], "permission")
        self.assertEqual(self.seen[0]["detail"], "Bash · npm publish")
        self.assertEqual(self.seen[0]["sessionId"], "s1")
        out = self.decide(self.permission(), {"decision": "deny"})
        self.assertEqual(out["hookSpecificOutput"]["decision"],
                         {"behavior": "deny", "message": "使用者在 GTD Island 拒絕"})
        self.assertEqual(self.requests(), [])
        self.assertEqual(os.listdir(os.path.join(self.base, "responses")), [])

    def test_ac44_permission_records_needs_you(self):
        attention.handle(self.permission(), os.path.join(self.base, "attention"), at="t")
        with open(os.path.join(self.base, "attention", "s1.json")) as f:
            self.assertEqual(json.load(f)["message"], "Bash · npm publish")

    def test_ac45_question_is_only_recorded_never_asked(self):
        q = {"questions": [{"question": "方案?", "header": "方案", "multiSelect": False,
                            "options": [{"label": "A", "description": ""}, {"label": "B", "description": ""}]},
                           {"question": "環境?", "header": "環境", "multiSelect": True,
                            "options": [{"label": "dev", "description": ""}, {"label": "prod", "description": ""}]}]}
        e = event("PreToolUse", tool_name="AskUserQuestion", tool_input=q)
        self.assertIsNone(self.decide(e, {"answers": {"方案?": "B", "環境?": ["dev", "prod"]}}))
        self.assertEqual(self.seen, [])
        self.assertEqual(self.requests(), [])

    def test_ac51_permission_for_ask_user_question_is_ignored(self):
        e = event("PermissionRequest", tool_name="AskUserQuestion", tool_input={"questions": [{"question": "q?"}]})
        folder = os.path.join(self.base, "attention")
        attention.write(os.path.join(folder, "s1.json"), {"state": "needsYou", "message": "q?"})
        self.assertEqual(attention.handle(e, folder, at="t"), "ignored")
        self.assertEqual(attention.read(os.path.join(folder, "s1.json"))["message"], "q?")
        self.assertIsNone(self.decide(e, {"decision": "allow"}))
        self.assertEqual(self.seen, [])

    def test_ac46_skip_timeout_bad_reply_and_removed_request_fall_back(self):
        self.assertIsNone(self.decide(self.permission(), {"skip": True}))
        self.assertIsNone(self.decide(self.permission(), None, wait=0.05))
        self.assertIsNone(self.decide(self.permission(), {"decision": "maybe"}))
        e = event("PreToolUse", tool_name="AskUserQuestion", tool_input={"questions": [{"question": "q"}]})
        self.assertIsNone(self.decide(e, {"answers": {}}))
        self.assertEqual(self.requests(), [])

        def remove_request(_):
            for n in self.requests():
                os.remove(os.path.join(self.base, "requests", n))
        self.assertIsNone(attention.decide(self.permission(), self.base, wait=5, poll=0, sleep=remove_request))

    def test_ac44_summary_uses_first_known_field(self):
        self.assertEqual(attention.summary("Edit", {"file_path": "/a.py"}), "Edit · /a.py")
        self.assertEqual(attention.summary("WebFetch", {"url": "https://x"}), "WebFetch · https://x")
        self.assertEqual(attention.summary("Grep", {"pattern": "TODO"}), "Grep · TODO")
        self.assertEqual(attention.summary("Task", {"prompt": "p"}), "Task")

    def test_ac46_removed_request_stops_waiting_at_once(self):
        calls = []

        def remove_request(_):
            calls.append(1)
            for n in self.requests():
                os.remove(os.path.join(self.base, "requests", n))
        t = [0.0]
        self.assertIsNone(attention.decide(self.permission(), self.base, wait=100, poll=0, sleep=remove_request,
                                           clock=lambda: t[0] + __import__("time").time()))
        self.assertEqual(len(calls), 1)

    def test_ac43_future_heartbeat_and_dashed_session_do_not_ask(self):
        self.alive(age=-60)
        calls = []
        self.assertIsNone(attention.decide(self.permission(), self.base, wait=5, poll=0, sleep=calls.append))
        self.alive()
        self.assertIsNone(attention.decide(self.permission(session_id="a--b"), self.base, wait=5, poll=0,
                                           sleep=calls.append))
        self.assertEqual((calls, self.requests()), ([], []))

    def test_ac47_stop_and_session_end_clear_requests_too(self):
        folder = os.path.join(self.base, "requests")
        for name in ("Stop", "SessionEnd", "UserPromptSubmit"):
            attention.write(os.path.join(folder, "s1--1.json"), {})
            attention.handle(event(name), os.path.join(self.base, "attention"))
            self.assertEqual(self.requests(), [], name)

    def test_ac43_no_island_means_no_wait(self):
        self.alive(age=30)
        calls = []
        self.assertIsNone(attention.decide(self.permission(), self.base, wait=5, poll=0, sleep=calls.append))
        self.assertEqual((calls, self.requests()), ([], []))

    def test_ac46_other_events_never_ask(self):
        calls = []
        for e in (event("Stop"), event("PreToolUse", tool_name="Bash"), event("PermissionRequest", session_id="../x")):
            self.assertIsNone(attention.decide(e, self.base, wait=5, poll=0, sleep=calls.append))
        self.assertEqual(calls, [])

    def test_ac47_session_events_clear_its_requests(self):
        folder = os.path.join(self.base, "requests")
        for name in ("s1--1.json", "s1--2.json", "s2--1.json"):
            attention.write(os.path.join(folder, name), {})
        attention.handle(event("PostToolUse", tool_name="Bash"), os.path.join(self.base, "attention"))
        self.assertEqual(self.requests(), ["s2--1.json"])

    def test_ac44_main_prints_the_decision_end_to_end(self):
        import subprocess, sys, threading, time
        home = self.base
        base = os.path.join(home, ".gtd-island")
        os.makedirs(base)
        open(os.path.join(base, "island.alive"), "w").close()

        def answer():
            folder = os.path.join(base, "requests")
            for _ in range(100):
                names = os.listdir(folder) if os.path.isdir(folder) else []
                if names:
                    attention.write(os.path.join(base, "responses", names[0]), {"decision": "allow"})
                    return
                time.sleep(0.05)
        threading.Thread(target=answer).start()
        here = os.path.dirname(os.path.abspath(__file__))
        out = subprocess.run([sys.executable, "-I", os.path.join(here, "attention.py")],
                             input=json.dumps(self.permission()), capture_output=True, text=True,
                             env={**os.environ, "HOME": home}, timeout=20)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(json.loads(out.stdout)["hookSpecificOutput"]["decision"], {"behavior": "allow"})

    def test_ac50_install_updates_timeouts_of_existing_entries(self):
        path = os.path.join(self.base, "settings.json")
        old = {"hooks": {"PreToolUse": [{"matcher": "AskUserQuestion",
                                         "hooks": [{"type": "command", "command": "cmd", "timeout": 130}]}]}}
        attention.write(path, old)
        added = attention.install_hooks(path, "cmd")
        self.assertNotIn("PreToolUse", added)
        self.assertIn("PermissionRequest", added)
        settings = attention.read(path)
        self.assertEqual(settings["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"], 5)
        self.assertEqual(settings["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 130)
        self.assertEqual(len(settings["hooks"]["PreToolUse"]), 1)


if __name__ == "__main__":
    unittest.main()
