#!/usr/bin/env python3
"""Merge TouTou observation hooks, preserving unrelated hooks and a backup."""
import argparse
import datetime
import json
import os
from pathlib import Path
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--user", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = json.loads((root / "cursor-hooks.json").read_text())
destination = (Path.home() if args.user else root) / ".cursor/hooks.json"
existing = json.loads(destination.read_text()) if destination.exists() else {"version": 1, "hooks": {}}
if not isinstance(existing, dict) or existing.get("version", 1) != 1 or not isinstance(existing.get("hooks", {}), dict):
    raise SystemExit("Unsupported Cursor hooks configuration; nothing changed.")
existing.setdefault("version", 1)
hooks = existing.setdefault("hooks", {})
for name, additions in source["hooks"].items():
    previous = hooks.get(name, [])
    if not isinstance(previous, list):
        raise SystemExit("Invalid hooks list; nothing changed.")
    # Exact generated commands only; never discard unrelated entries.
    hooks[name] = previous + [entry for entry in additions if entry not in previous]
destination.parent.mkdir(parents=True, exist_ok=True)
if destination.exists():
    backup = destination.with_name("hooks.json.TouTou-backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.write_bytes(destination.read_bytes())
    print("Backup:", backup)
fd, temporary = tempfile.mkstemp(prefix=".TouTou-hooks-", dir=destination.parent)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(existing, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temporary, destination)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("Installed:", destination)
