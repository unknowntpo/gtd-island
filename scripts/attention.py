#!/usr/bin/env python3
"""Claude Code hook: record which sessions are waiting for the user (AC33-AC35),
and let GTD Island answer permission requests (AC43-AC47).

Reads one hook event as JSON from stdin and writes or deletes
~/.gtd-island/attention/<session_id>.json. Standard library only, so it runs
wherever Claude Code runs. It always exits 0. It prints only a decision the
user made in GTD Island; in every other case Claude asks as usual.

`attention.py --install-hooks [settings.json]` adds this hook to Claude Code's
settings (AC41).
"""
import datetime
import json
import os
import re
import shutil
import sys
import time

BASE = os.path.expanduser("~/.gtd-island")
FOLDER = os.path.join(BASE, "attention")
SETTINGS = os.path.expanduser("~/.claude/settings.json")
COMMAND = "python3 -I ~/.gtd-island/attention.py"
SESSION_ID = re.compile(r"^[A-Za-z0-9_-]+$")
# Event name -> (matcher, timeout in seconds). "" means every tool or no matcher.
EVENTS = {
    "PreToolUse": ("AskUserQuestion", 5),
    "PermissionRequest": ("", 130),
    "PostToolUse": ("*", 5),
    "Notification": ("", 5),
    "Stop": ("", 5),
    "UserPromptSubmit": ("", 5),
    "SessionEnd": ("", 5),
}
WAIT = 120
POLL = 0.2
ALIVE_SECONDS = 10
DENIED = "使用者在 GTD Island 拒絕"


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def first_question(tool_input):
    questions = (tool_input or {}).get("questions") or []
    if questions and isinstance(questions[0], dict):
        return str(questions[0].get("question") or "")
    return ""


def summary(tool_name, tool_input):
    for key in ("command", "file_path", "url", "pattern"):
        value = (tool_input or {}).get(key)
        if isinstance(value, str) and value:
            return f"{tool_name} · {value[:200]}"
    return str(tool_name or "")


def island_alive(base, clock=time.time):
    try:
        age = clock() - os.path.getmtime(os.path.join(base, "island.alive"))
        return -ALIVE_SECONDS <= age <= ALIVE_SECONDS
    except OSError:
        return False


def clear_requests(base, session):
    folder = os.path.join(base, "requests")
    try:
        names = os.listdir(folder)
    except OSError:
        return
    for name in names:
        if name.startswith(session + "--"):
            remove(os.path.join(folder, name))


def ask_island(base, session, request, wait=WAIT, poll=POLL, sleep=time.sleep, clock=time.time):
    """Writes a request and waits for GTD Island's reply (AC44-AC46). Returns the reply, or None."""
    # "--" separates the session from the rest of the request id, so it may not appear in the session.
    if "--" in session or not island_alive(base, clock):
        return None
    rid = f"{session}--{os.getpid()}-{int(clock() * 1000)}"
    req_path = os.path.join(base, "requests", rid + ".json")
    res_path = os.path.join(base, "responses", rid + ".json")
    write(req_path, {"id": rid, **request})
    try:
        deadline = clock() + wait
        while clock() < deadline:
            if os.path.exists(res_path):
                reply = read(res_path)
                return reply if isinstance(reply, dict) else None
            if not os.path.exists(req_path) or not island_alive(base, clock):
                return None
            sleep(poll)
        return None
    finally:
        remove(req_path)
        remove(res_path)


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


def is_question_permission(event):
    """AC51: after "到 app 處理", Claude Code asks permission for AskUserQuestion itself; leave it to Claude."""
    return event.get("hook_event_name") == "PermissionRequest" and event.get("tool_name") == "AskUserQuestion"


def handle(event, folder=FOLDER, at=None):
    """Records one hook event (AC33-AC34, AC47). Returns what it did, for tests."""
    if not isinstance(event, dict):
        return "ignored"
    session = event.get("session_id")
    if not isinstance(session, str) or not SESSION_ID.match(session):
        return "ignored"
    path = os.path.join(folder, session + ".json")
    name = event.get("hook_event_name")
    if is_question_permission(event):
        return "ignored"
    if name in ("UserPromptSubmit", "SessionEnd", "Stop", "PostToolUse"):
        clear_requests(os.path.dirname(folder), session)

    def record(state, message=""):
        write(path, {"sessionId": session, "cwd": event.get("cwd") or "", "state": state,
                     "message": message, "at": at or now()})
        return state

    if name == "PreToolUse" and event.get("tool_name") == "AskUserQuestion":
        return record("needsYou", first_question(event.get("tool_input")))
    if name == "PermissionRequest":
        return record("needsYou", summary(event.get("tool_name"), event.get("tool_input")))
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


def decide(event, base=BASE, **wait):
    """Asks GTD Island and returns the hook output to print, or None to let Claude ask (AC44-AC46)."""
    if not isinstance(event, dict):
        return None
    session = event.get("session_id")
    if not isinstance(session, str) or not SESSION_ID.match(session):
        return None
    name, tool, tool_input = event.get("hook_event_name"), event.get("tool_name"), event.get("tool_input") or {}
    common = {"sessionId": session, "cwd": event.get("cwd") or "", "at": now()}
    if name == "PermissionRequest" and not is_question_permission(event):
        reply = ask_island(base, session, {**common, "kind": "permission", "toolName": tool or "",
                                           "detail": summary(tool, tool_input)}, **wait)
        decision = (reply or {}).get("decision")
        if decision == "allow":
            return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
        if decision == "deny":
            return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                           "decision": {"behavior": "deny", "message": DENIED}}}
        return None
    # AC45: AskUserQuestion is only recorded; waiting here would hide the question in Claude Code.
    return None


def install_hooks(settings_path=SETTINGS, command=COMMAND):
    """Adds the hook for each event in EVENTS, once. Returns the events it added."""
    settings = read(settings_path) if os.path.exists(settings_path) else {}
    if not isinstance(settings, dict):
        raise SystemExit(f"{settings_path} is not a JSON object; nothing changed")
    hooks = settings.setdefault("hooks", {})
    added = []
    changed = False
    for name, (matcher, timeout) in EVENTS.items():
        groups = hooks.setdefault(name, [])
        mine = [h for g in groups for h in g.get("hooks", []) if h.get("command") == command]
        if mine:
            for h in mine:
                if h.get("timeout") != timeout:
                    h["timeout"] = timeout
                    changed = True
            continue
        group = {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}
        if matcher:
            group["matcher"] = matcher
        groups.append(group)
        added.append(name)
    if added or changed:
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
        event = json.loads(sys.stdin.read() or "null")
        handle(event)
        output = decide(event)
        if output is not None:
            sys.stdout.write(json.dumps(output, ensure_ascii=False))
    except Exception:
        pass


if __name__ == "__main__":
    main()
