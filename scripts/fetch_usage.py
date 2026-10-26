#!/usr/bin/env python3
"""Read provider quotas. stdout contains only percentages, windows and reset dates."""
import base64
import concurrent.futures
import json
import math
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return float(value)


def remaining(used):
    value = number(used)
    return None if value is None else max(0, min(100, 100 - value))


def plan_title(value):
    if not isinstance(value, str) or not value.strip():
        return None
    names = {"pro": "Pro", "plus": "Plus", "team": "Team", "business": "Business", "enterprise": "Enterprise",
             "free": "Free", "pro_plus": "Pro+", "ultra": "Ultra", "edu": "Edu", "go": "Go"}
    key = value.strip().lower()
    return names.get(key, value.strip()[:24].title())


def money(cents):
    value = number(cents)
    if value is None:
        return None
    dollars = value / 100
    return "$%d" % dollars if dollars == int(dollars) else "$%.2f" % dollars


def codex_snapshot(result):
    buckets = result.get("rateLimitsByLimitId")
    bucket = buckets.get("codex") if isinstance(buckets, dict) else result.get("rateLimits")
    if not isinstance(bucket, dict):
        raise ValueError("No quota bucket")
    windows = []
    for key in ("primary", "secondary"):
        window = bucket.get(key)
        if not isinstance(window, dict):
            continue
        percent = remaining(window.get("usedPercent"))
        if percent is not None:
            minutes = number(window.get("windowDurationMins"))
            label = "Неделя" if minutes == 10080 else "5 часов" if minutes == 300 else (str(int(minutes)) + " мин" if minutes else "Лимит")
            used_percent = number(window.get("usedPercent"))
            windows.append({"label": label, "remainingPercent": percent, "usedPercent": None if used_percent is None else max(0, min(100, used_percent)), "resetsAt": number(window.get("resetsAt")), "detail": None})
    if not windows:
        raise ValueError("No quota windows")
    notes = []
    credits = bucket.get("credits")
    if isinstance(credits, dict) and credits.get("hasCredits"):
        balance = credits.get("balance")
        notes.append("Кредиты: без лимита" if credits.get("unlimited") else "Кредиты: " + str(balance)[:16] if balance is not None else "Есть кредиты")
    if bucket.get("rateLimitReachedType"):
        notes.append("Лимит исчерпан")
    if bucket.get("spendControlReached"):
        notes.append("Достигнут лимит расходов")
    return {"provider": "chatgpt", "windows": windows, "source": "ChatGPT Work / Codex", "error": None,
            "plan": plan_title(bucket.get("planType")), "notes": notes}


def chatgpt_usage():
    binary = shutil.which("codex") or "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    if not Path(binary).is_file():
        raise FileNotFoundError("CLI missing")
    proc = subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    buffer = b""
    deadline = time.monotonic() + 25
    def send(message):
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()
    def response(identifier):
        nonlocal buffer
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                item = json.loads(line)
                if item.get("id") == identifier:
                    if "error" in item:
                        raise ValueError("Provider rejected request")
                    return item.get("result", {})
            readable, _, _ = select.select([proc.stdout], [], [], max(0, deadline - time.monotonic()))
            if not readable:
                break
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            if len(buffer) > 1048576:
                raise ValueError("Response too large")
        raise TimeoutError("Provider timeout")
    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "TouTou", "title": "TouTou", "version": "0.4.0"}}})
        response(1)
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "account/rateLimits/read"})
        return codex_snapshot(response(2))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        proc.stdin.close()
        proc.stdout.close()


def cursor_snapshot(data):
    usage = data.get("individualUsage") or {}
    plan = usage.get("plan") or usage.get("overall") or {}
    used, limit = number(plan.get("used")), number(plan.get("limit"))
    windows = []
    if data.get("isUnlimited") is True:
        windows.append({"label": "План", "remainingPercent": 100.0, "usedPercent": 0.0, "resetsAt": None, "detail": "Без лимита"})
    else:
        # Cursor dashboard: "Cursor Models" (Composer / Grok / Auto) and "Other Models" (third-party API).
        # Those two percentages are what the IDE shows; totalPercentUsed is a different internal metric.
        for field, label in [("autoPercentUsed", "Cursor"), ("apiPercentUsed", "Другие")]:
            used_percent = number(plan.get(field))
            if used_percent is None:
                continue
            used_percent = max(0, min(100, used_percent))
            windows.append({"label": label, "remainingPercent": remaining(used_percent), "usedPercent": used_percent, "resetsAt": None, "detail": None})
        if not windows and used is not None and limit is not None and limit > 0:
            used_percent = used / limit * 100
            windows.append({"label": "План", "remainingPercent": remaining(used_percent), "usedPercent": max(0, min(100, used_percent)), "resetsAt": None, "detail": None})
    if not windows:
        raise ValueError("No included quota")
    notes = []
    on_demand = usage.get("onDemand") or {}
    if isinstance(on_demand, dict) and on_demand.get("enabled"):
        spent = money(on_demand.get("used"))
        cap = money(on_demand.get("limit"))
        if spent is not None:
            notes.append("Сверх плана: " + spent + (" / " + cap if cap else ""))
    reset = data.get("billingCycleEnd")
    if isinstance(reset, str):
        import datetime
        try:
            timestamp = datetime.datetime.fromisoformat(reset.replace("Z", "+00:00")).timestamp()
            for window in windows:
                window["resetsAt"] = timestamp
        except ValueError:
            pass
    return {"provider": "cursor", "windows": windows, "source": "Cursor plan", "error": None,
            "plan": plan_title(data.get("membershipType")), "notes": notes}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def cursor_token():
    database = Path.home() / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    last_error = None
    for extra in ("?mode=ro", "?mode=ro&immutable=1"):
        try:
            connection = sqlite3.connect(database.as_uri() + extra, uri=True, timeout=5)
            try:
                row = connection.execute("SELECT value FROM ItemTable WHERE key = ?", ("cursorAuth/accessToken",)).fetchone()
            finally:
                connection.close()
            if row and isinstance(row[0], str) and row[0]:
                return row[0]
        except sqlite3.Error as error:
            last_error = error
            time.sleep(0.25)
    raise ValueError("Sign in to Cursor" if last_error is None else "Cursor database busy")


def cursor_usage():
    token = cursor_token()
    part = token.split(".")[1]
    payload = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    subject = str(payload.get("sub", "")).split("|")[-1]
    if not subject or any(not (c.isalnum() or c in "._-") for c in subject):
        raise ValueError("Invalid identity")
    if payload.get("exp", 0) <= time.time():
        raise ValueError("Cursor login expired")
    request = urllib.request.Request("https://cursor.com/api/usage-summary", headers={
        "Cookie": "WorkosCursorSessionToken=" + subject + "%3A%3A" + token,
        "Accept": "application/json", "User-Agent": "TouTou/0.4.0",
    })
    # Never forward an authenticated request to a redirect destination.
    with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
        data = json.loads(response.read(1048576))
    return cursor_snapshot(data)


def fetch(provider, function):
    try:
        return function()
    except Exception:
        # Never expose tokens, account identity, raw responses or network exceptions.
        return {"provider": provider, "windows": [], "source": None, "error": "Нет данных — проверь вход и сеть", "plan": None, "notes": []}


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(fetch, "chatgpt", chatgpt_usage), pool.submit(fetch, "cursor", cursor_usage)]
        print(json.dumps({"updatedAt": time.time(), "providers": [future.result() for future in futures]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
