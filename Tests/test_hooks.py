import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cursor_hook.py"
spec = importlib.util.spec_from_file_location("hook", SCRIPT)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class HookTests(unittest.TestCase):
    def test_parallel_sessions_remain_separate_and_latest_replaces(self):
        with tempfile.TemporaryDirectory() as directory:
            for session, event in [("a", "sessionStart"), ("b", "afterFileEdit"), ("a", "stop")]:
                hook.write_event(hook.normalize({"conversation_id": session, "workspace_roots": ["/project"]}, event), directory)
            snapshots = [json.loads(p.read_text()) for p in Path(directory).glob("*.json")]
            self.assertEqual(len(snapshots), 2)
            self.assertEqual(next(e for e in snapshots if e["session"] == "a")["state"], "done")
            self.assertEqual(next(e for e in snapshots if e["session"] == "b")["state"], "working")

    def test_no_prompt_or_output_is_retained(self):
        event = hook.normalize({"conversation_id": "a", "prompt": "SECRET", "output": "SECRET", "workspace_roots": ["/project"]}, "afterShellExecution")
        self.assertNotIn("SECRET", json.dumps(event))

    def test_malformed_input_does_not_break_cursor(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPT), "stop"], input="not json", text=True, capture_output=True, env={**os.environ, "TOUTOU_DATA_DIR": directory})
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), {})
            self.assertEqual(list(Path(directory).glob("*.json")), [])

    def test_session_keeps_started_at_and_recent_steps(self):
        with tempfile.TemporaryDirectory() as directory:
            first = hook.normalize({"conversation_id": "run", "workspace_roots": ["/proj"]}, "sessionStart")
            first["timestamp"] = 1_000
            hook.write_event(first, directory)
            hook.write_event(hook.normalize({"conversation_id": "run", "file_path": "src/a.ts", "workspace_roots": ["/proj"]}, "afterFileEdit"), directory)
            hook.write_event(hook.normalize({"conversation_id": "run", "workspace_roots": ["/proj"]}, "stop"), directory)
            event = json.loads(next(Path(directory).glob("*.json")).read_text())
            self.assertEqual(event["startedAt"], 1_000)
            self.assertEqual(event["state"], "done")
            self.assertEqual([s["detail"] for s in event["steps"]], ["Сессия началась", "Файл обновлён: src/a.ts", "Задача завершена"])
            self.assertLessEqual(len(event["steps"]), 5)

    def test_steps_are_capped_and_skip_duplicates(self):
        event = hook.merge_session(None, {"session": "a", "detail": "Сессия началась", "state": "working", "timestamp": 1})
        for index in range(8):
            event = hook.merge_session(event, {"session": "a", "detail": f"Файл {index}", "state": "working", "timestamp": index + 2})
        self.assertEqual(len(event["steps"]), 5)
        self.assertEqual(event["steps"][0]["detail"], "Файл 3")
        duplicate = hook.merge_session(event, {"session": "a", "detail": "Файл 7", "state": "working", "timestamp": 99})
        self.assertEqual(len(duplicate["steps"]), 5)

    def test_merge_does_not_keep_prompt_fields_from_a_corrupt_previous_file(self):
        previous = {"session": "a", "prompt": "SECRET", "startedAt": 10, "timestamp": 10, "steps": []}
        event = hook.merge_session(previous, {"session": "a", "detail": "Команда выполнена", "state": "working", "timestamp": 20})
        self.assertNotIn("prompt", event)
        self.assertNotIn("SECRET", json.dumps(event))
        self.assertEqual(event["startedAt"], 10)

    def test_real_cli_event_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPT), "afterFileEdit"], input=json.dumps({"conversation_id": "one", "file_path": "src/app.ts", "workspace_roots": ["/project"]}), text=True, capture_output=True, env={**os.environ, "TOUTOU_DATA_DIR": directory})
            self.assertEqual(result.returncode, 0)
            event = json.loads(next(Path(directory).glob("*.json")).read_text())
            self.assertEqual(event["session"], "one")
            self.assertIn("src/app.ts", event["detail"])
            self.assertEqual(event["state"], "working")


if __name__ == "__main__":
    unittest.main()
