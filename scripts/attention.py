#!/usr/bin/env python3
"""Claude Code hook: record which sessions are waiting for the user (AC33-AC35).

Reads one hook event as JSON from stdin and writes or deletes
~/.gtd-island/attention/<session_id>.json. Standard library only, so it runs
wherever Claude Code runs. It never prints and always exits 0, so it cannot
block or change a session.

`attention.py --install-hooks [settings.json]` adds this hook to Claude Code's
settings (AC41).
"""
import datetime
import json
import os
import re
import shutil
import sys

FOLDER = os.path.expanduser("~/.gtd-island/attention")
SETTINGS = os.path.expanduser("~/.claude/settings.json")
COMMAND = "python3 -I ~/.gtd-island/attention.py"
SESSION_ID = re.compile(r"^[A-Za-z0-9_-]+$")
# Event name -> matcher ("" means every tool or no matcher).
EVENTS = {
    "PreToolUse": "AskUserQuestion",
    "PostToolUse": "*",
    "Notification": "",
    "Stop": "",
    "UserPromptSubmit": "",
    "SessionEnd": "",
}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def first_question(tool_input):
    questions = (tool_input or {}).get("questions") or []
    if questions and isinstance(questions[0], dict):
        return str(questions[0].get("question") or "")
    return ""


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write(path, record, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(record, f, ensure_ascii=False, indent=indent)
    os.replace(tmp, path)


def remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def handle(event, folder=FOLDER, at=None):
    """Applies one hook event. Returns what it did, for tests."""
    if not isinstance(event, dict):
        return "ignored"
    session = event.get("session_id")
    if not isinstance(session, str) or not SESSION_ID.match(session):
        return "ignored"
    path = os.path.join(folder, session + ".json")
    name = event.get("hook_event_name")

    def record(state, message=""):
        write(path, {"sessionId": session, "cwd": event.get("cwd") or "", "state": state,
                     "message": message, "at": at or now()})
        return state

    if name == "PreToolUse" and event.get("tool_name") == "AskUserQuestion":
        return record("needsYou", first_question(event.get("tool_input")))
    if name == "Notification":
        if event.get("notification_type") == "idle_prompt" and os.path.exists(path):
            return "kept"
        return record("needsYou", str(event.get("message") or ""))
    if name == "Stop":
        return record("done")
    if name in ("UserPromptSubmit", "SessionEnd"):
        remove(path)
        return "removed"
    if name == "PostToolUse":
        current = read(path)
        if current and current.get("state") == "needsYou":
            remove(path)
            return "removed"
    return "ignored"


def install_hooks(settings_path=SETTINGS, command=COMMAND):
    """Adds the hook for each event in EVENTS, once. Returns the events it added."""
    settings = read(settings_path) if os.path.exists(settings_path) else {}
    if not isinstance(settings, dict):
        raise SystemExit(f"{settings_path} is not a JSON object; nothing changed")
    hooks = settings.setdefault("hooks", {})
    added = []
    for name, matcher in EVENTS.items():
        groups = hooks.setdefault(name, [])
        present = any(h.get("command") == command for g in groups for h in g.get("hooks", []))
        if present:
            continue
        group = {"hooks": [{"type": "command", "command": command, "timeout": 5}]}
        if matcher:
            group["matcher"] = matcher
        groups.append(group)
        added.append(name)
    if added:
        if os.path.exists(settings_path):
            shutil.copy2(settings_path, settings_path + ".bak-gtd-island")
        write(settings_path, settings, indent=2)
    return added


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--install-hooks":
        added = install_hooks(*(sys.argv[2:3] or [SETTINGS]))
        print("added hooks:", ", ".join(added) if added else "none (already installed)")
        return
    try:
        handle(json.loads(sys.stdin.read() or "null"))
    except Exception:
        pass


if __name__ == "__main__":
    main()
