#!/usr/bin/env python3
"""Find Claude desktop sessions related to a typed sentence.

Reads one JSON request per line from stdin: {"query": "..."}.
Writes one JSON reply per line to stdout: {"matches": [...]}.
Everything runs on this Mac. The session files are an undocumented app format,
so this script reads only the fields it needs and skips what it cannot parse.
"""
import glob
import json
import os
import sys

SESSIONS = os.path.expanduser("~/Library/Application Support/Claude/claude-code-sessions")
MODEL = os.path.expanduser("~/.gtd-island/models/multilingual-e5-small")
CACHE = os.path.expanduser("~/.gtd-island/session-embeddings.json")
SHARED_WORD_BONUS = 0.01


def load_sessions(root=SESSIONS):
    sessions = []
    for path in glob.glob(os.path.join(glob.escape(root), "*", "*", "local_*.json")):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if not data.get("sessionId") or not data.get("title"):
            continue
        if data.get("isArchived") or data.get("scheduledTaskId"):
            continue
        sessions.append({"id": data["sessionId"], "title": data["title"], "cwd": data.get("cwd") or ""})
    return sessions


def word_pairs(text):
    text = text.lower()
    return {text[i:i + 2] for i in range(len(text) - 1) if text[i:i + 2].strip()}


def top_matches(query, sessions, embed, cache, limit=5):
    if not query.strip():
        return []
    wanted = embed("query: " + query)
    pairs = word_pairs(query)
    rows = []
    for session in sessions:
        title = session["title"]
        if title not in cache:
            cache[title] = embed("passage: " + title)
        score = sum(a * b for a, b in zip(wanted, cache[title]))
        # Model scores sit close together, so a shared word such as 登入 decides between them.
        score += SHARED_WORD_BONUS * len(pairs & word_pairs(title))
        rows.append({**session, "score": round(score, 4)})
    rows.sort(key=lambda row: -row["score"])
    return rows[:limit]


def serve(requests, output, find):
    for line in requests:
        try:
            reply = {"matches": find(json.loads(line)["query"])}
        except Exception as error:  # One bad request must not end the helper.
            reply = {"matches": [], "error": str(error)}
        output.write(json.dumps(reply) + "\n")
        output.flush()


def load_model(folder=MODEL):
    import numpy as np
    import onnxruntime as ort
    from tokenizers import Tokenizer

    session = ort.InferenceSession(os.path.join(folder, "model_O4.onnx"), providers=["CPUExecutionProvider"])
    tokenizer = Tokenizer.from_file(os.path.join(folder, "tokenizer.json"))
    names = {item.name for item in session.get_inputs()}

    def embed(text):
        encoded = tokenizer.encode(text)
        ids = np.array([encoded.ids])
        mask = np.array([encoded.attention_mask])
        inputs = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in names:
            inputs["token_type_ids"] = np.zeros_like(ids)
        hidden = session.run(None, inputs)[0]
        vector = (hidden * mask[..., None]).sum(1) / mask.sum()
        return (vector / np.linalg.norm(vector))[0].tolist()

    return embed


def read_cache(path=CACHE):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def write_cache(cache, path=CACHE):
    temporary = path + ".tmp"
    with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
        json.dump(cache, f)
    os.replace(temporary, path)


def main():
    sys.stdin.reconfigure(encoding="utf-8")
    embed = load_model()
    sessions = load_sessions()
    cache = read_cache()

    def find(query):
        size = len(cache)
        rows = top_matches(query, sessions, embed, cache)
        if len(cache) != size:
            write_cache(cache)
        return rows

    serve(sys.stdin, sys.stdout, find)


if __name__ == "__main__":
    main()
