#!/usr/bin/env python3
"""Serialized inbox receipt projection, imported once and refreshed on owner writes.

The inbox files remain authoritative; the SQLite projection is disposable.
Directory generation changes recover interrupted writes or imports of old records.
Public commands and receipt bounds are owned by fm-inbox.sh.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


def generations(inbox):
    result = []
    for path in (inbox, inbox / "handled", inbox / ".announced", inbox / ".replies"):
        try:
            stat = path.stat()
            result.append((stat.st_ino, stat.st_mtime_ns, stat.st_ctime_ns))
        except FileNotFoundError:
            result.append(None)
    return json.dumps(result)


def rebuild(db, command, env, inbox):
    raw = subprocess.run(command + ["receipts", "--all-pending", "--all-handled", "--all-replies"],
                         env=env, capture_output=True, text=True, check=True)
    view = json.loads(raw.stdout)
    with db:
        db.execute("DELETE FROM notes")
        db.execute("DELETE FROM replies")
        for kind in ("pending", "handled"):
            db.executemany("INSERT INTO notes VALUES (?, ?, ?)",
                           ((kind, i, json.dumps(row)) for i, row in enumerate(view[kind])))
        db.executemany("INSERT INTO replies VALUES (?, ?, ?)",
                       ((row["cursor"], i, json.dumps(row)) for i, row in enumerate(view["replies"])))
        meta = {"home": view["home"], "omitted": view["omitted"],
                "counts": {kind: len(view[kind]) for kind in ("pending", "handled", "replies")},
                "generation": generations(inbox)}
        db.execute("INSERT OR REPLACE INTO metadata VALUES (1, ?)", (json.dumps(meta),))
    return meta


def receipt_page(db, meta, args):
    parser = argparse.ArgumentParser(prog="fm-inbox.sh receipts")
    parser.add_argument("--after", default="")
    for kind in ("pending", "handled", "replies"):
        parser.add_argument("--all-" + kind, action="store_true")
    options = parser.parse_args(args)
    if options.after and (len(options.after) != 12 or not options.after.isascii() or not options.after.isdigit()):
        parser.error("--after must be a 12-digit reply cursor")
    result = {"schema": "fm-inbox-receipts.v1", "home": meta["home"],
              "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "omitted": list(meta["omitted"])}
    for kind in ("pending", "handled", "replies"):
        limit = -1 if getattr(options, "all_" + kind) else 20
        if kind == "replies":
            rows = db.execute("SELECT position, payload FROM replies WHERE cursor > ? ORDER BY cursor LIMIT ?",
                              (options.after, limit)).fetchall()
        else:
            rows = db.execute("SELECT position, payload FROM notes WHERE kind = ? ORDER BY position LIMIT ?",
                              (kind, limit)).fetchall()
        result[kind] = [json.loads(payload) for _, payload in rows]
        omitted = meta["counts"][kind] - rows[-1][0] - 1 if rows else 0
        if omitted:
            surface = kind if kind == "replies" else kind + " notes"
            result["omitted"].append({"surface": f"{surface} omitted by bound: {omitted}",
                                      "reveal": "pass --all-" + kind})
    result["reply_cursor"] = result["replies"][-1]["cursor"] if result["replies"] else options.after
    return result


def main():
    state, home = map(Path, sys.argv[1:3])
    args = sys.argv[3:]
    state.mkdir(parents=True, exist_ok=True)
    inbox = state / "inbox"
    env = dict(os.environ, FM_INBOX_RECEIPT_OWNER="1", FM_HOME=str(home))
    command = [str(Path(__file__).with_name("fm-inbox.sh"))]
    with (state / ".inbox-receipts.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with sqlite3.connect(state / ".inbox-receipts.sqlite3") as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS notes (
                    kind TEXT, position INTEGER, payload TEXT, PRIMARY KEY(kind, position));
                CREATE TABLE IF NOT EXISTS replies (
                    cursor TEXT PRIMARY KEY, position INTEGER, payload TEXT);
                CREATE TABLE IF NOT EXISTS metadata (id INTEGER PRIMARY KEY, payload TEXT);
            """)
            if args[0] != "receipts":
                result = subprocess.run(command + args, env=env, pass_fds=(lock.fileno(),))
                rebuild(db, command, env, inbox)
                return result.returncode
            row = db.execute("SELECT payload FROM metadata WHERE id = 1").fetchone()
            meta = json.loads(row[0]) if row else None
            if meta is None or meta["generation"] != generations(inbox):
                meta = rebuild(db, command, env, inbox)
            print(json.dumps(receipt_page(db, meta, args[1:]), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
