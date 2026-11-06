#!/usr/bin/env python3
"""Fetch the Notion `Projects 下一步` rows and save a snapshot.

Calls the Notion API directly when Keychain has a token, otherwise goes through Claude Code.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone

CONFIG_PATH = os.path.expanduser("~/.gtd-island/config.json")


def load_config(path=CONFIG_PATH):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


CONFIG = load_config()
VIEW = CONFIG.get("view", "")
DATA_SOURCE = CONFIG.get("dataSource", "")
TIME_LOG = CONFIG.get("timeLog", "")
API_URL = "https://api.notion.com/v1/data_sources/{}/query"
API_VERSION = "2025-09-03"
KEYCHAIN_SERVICE = "gtd-island-notion"
OUT = os.path.expanduser("~/.gtd-island/snapshot.json")

def read_token():
    proc = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    return proc.stdout.strip() or None


def flatten(page):
    """Turn an API page into the flat row shape the view query returns."""
    row = {"url": "https://app.notion.com/p/" + page["id"].replace("-", "")}
    for name, prop in page["properties"].items():
        kind = prop["type"]
        if kind in ("title", "rich_text"):
            row[name] = "".join(part["plain_text"] for part in prop[kind])
        elif kind == "select":
            row[name] = prop[kind]["name"] if prop[kind] else ""
        elif kind == "checkbox":
            row[name] = "__YES__" if prop[kind] else "__NO__"
        elif kind == "url":
            row[name] = prop[kind] or ""
        elif kind == "number":
            row[name] = prop[kind]
        elif kind == "date" and prop[kind]:
            row[f"date:{name}:start"] = prop[kind]["start"]
    return row


def query_api(token):
    """Same filter and sort as the `Projects 下一步` view."""
    return query_pages(token, [
        {"property": "Item Type", "select": {"equals": "Project"}},
        {"property": "GTD Status", "select": {"equals": "Active"}},
    ])


def query_time_log(token, today):
    """Time Log rows that start today or in the previous 6 days."""
    return query_pages(token, [
        {"property": "Date", "date": {"on_or_after": (today - timedelta(days=6)).isoformat()}},
    ], data_source=TIME_LOG, sort="Date")


def fetch_time_log():
    """Return None when Time Log cannot be read, so a failure never blocks the Project rows."""
    token = read_token()
    if not token:
        return None
    try:
        return query_time_log(token, date.today())
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        sys.stderr.write(f"Notion Time Log query failed ({error})\n")
        return None


def action_row(page):
    """An open Action, with only what the panel needs to pick a jump target."""
    row = flatten(page)
    parents = page["properties"].get("Parent Project", {}).get("relation", [])
    return {
        "Outcome": row.get("Outcome", ""),
        "url": row["url"],
        "Owner Session": row.get("Owner Session", ""),
        "GTD Status": row.get("GTD Status", ""),
        "parents": [p["id"].replace("-", "") for p in parents],
    }


def query_actions(token):
    """Open Actions, so a Project without `Owner Session` can jump to its next Action's session."""
    return query_pages(token, [
        {"property": "Item Type", "select": {"equals": "Action"}},
        {"property": "GTD Status", "select": {"does_not_equal": "Done"}},
        {"property": "GTD Status", "select": {"does_not_equal": "Dropped"}},
    ], shape=action_row)


def fetch_actions():
    """Return None when Actions cannot be read, so a failure never blocks the Project rows."""
    token = read_token()
    if not token:
        return None
    try:
        return query_actions(token)
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        sys.stderr.write(f"Notion Action query failed ({error})\n")
        return None


def query_pages(token, conditions, data_source=None, sort="Last Worked", shape=flatten):
    body = {
        "filter": {"and": conditions},
        "sorts": [{"property": sort, "direction": "descending"}],
        "page_size": 100,
    }
    rows = []
    while True:
        request = urllib.request.Request(API_URL.format(data_source or DATA_SOURCE), data=json.dumps(body).encode(), method="POST", headers={
            "Authorization": f"Bearer {token}",
            "Notion-Version": API_VERSION,
            "Content-Type": "application/json",
        })
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.loads(response.read())
        rows += [shape(page) for page in data["results"]]
        if not data.get("has_more"):
            return rows
        body["start_cursor"] = data["next_cursor"]


def rows_from_stream(lines):
    """Return rows from the first Notion tool result, without any model transcription."""
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") != "user":
            continue
        for block in event.get("message", {}).get("content", []):
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            content = block.get("content")
            text = content if isinstance(content, str) else "".join(
                part.get("text", "") for part in content or [] if isinstance(part, dict)
            )
            try:
                data = json.loads(text)
            except ValueError:
                continue
            if isinstance(data.get("results"), list):
                if data.get("has_more"):
                    raise SystemExit("view has more than 100 rows")
                return data["results"]
    return None


def query_claude():
    if not VIEW:
        sys.stderr.write("config has no view; skipping claude\n")
        return None
    prompt = (
        "Call the Notion notion-query-data-sources tool once with "
        f'{{"data": {{"mode": "view", "view_url": "{VIEW}", "page_size": 100}}}}. '
        "Do nothing else. Then reply with the single word DONE."
    )
    proc = subprocess.run(
        ["claude", "-p", prompt, "--model", "haiku", "--output-format", "stream-json",
         "--verbose", "--max-turns", "3",
         "--allowedTools", "mcp__*notion-query-data-sources*"],
        capture_output=True, text=True, timeout=180, cwd=tempfile.gettempdir(),
    )
    rows = rows_from_stream(proc.stdout.splitlines())
    if not rows:
        sys.stderr.write(proc.stderr[-300:] + "\n")
    return rows


def fetch_rows(api_only=False):
    """`api_only` is for automatic repeats, which must never start a paid `claude` run."""
    token = read_token()
    if token:
        try:
            rows = query_api(token)
            if rows:
                return rows
            sys.stderr.write("Notion API returned no rows\n")
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            sys.stderr.write(f"Notion API failed ({error})\n")
    return None if api_only else query_claude()


def main():
    if not DATA_SOURCE:
        sys.stderr.write(f"missing dataSource in {CONFIG_PATH}\n")
        return 1
    rows = fetch_rows(api_only="--api-only" in sys.argv[1:])
    if not rows:
        sys.stderr.write("no Notion rows found; snapshot unchanged\n")
        return 1
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"fetchedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"), "rows": rows,
                   "timeLog": fetch_time_log(), "actions": fetch_actions()},
                  f, ensure_ascii=False, indent=1)
    os.replace(tmp, OUT)
    print(f"saved {len(rows)} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
