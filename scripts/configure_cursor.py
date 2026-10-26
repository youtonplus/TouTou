#!/usr/bin/env python3
"""Generate hooks without changing the user's Cursor configuration."""
import json
from pathlib import Path
import shlex
import sys

root = Path(__file__).resolve().parent.parent
events = ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "afterShellExecution", "afterFileEdit", "afterAgentResponse", "stop", "postToolUseFailure"]
command = shlex.quote(sys.executable) + " " + shlex.quote(str(root / "scripts/cursor_hook.py"))
config = {"version": 1, "hooks": {event: [{"command": command + " " + event}] for event in events}}
destination = root / "cursor-hooks.json"
destination.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
print(destination)
