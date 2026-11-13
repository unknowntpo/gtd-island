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


if __name__ == "__main__":
    unittest.main()
