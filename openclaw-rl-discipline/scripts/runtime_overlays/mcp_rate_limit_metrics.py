#!/usr/bin/env python3
"""Serve MCP runner rate-limit metrics from live UDP events.

File-based metrics are a compatibility/debug fallback only when the tool runner
is launched with MCP_RATE_LIMIT_FILE_METRICS=1.
"""

import argparse
import collections
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


MEMORY_LOCK = threading.Lock()
MEMORY_RATE_EVENTS: collections.deque[dict[str, Any]] = collections.deque(maxlen=20000)
MEMORY_CALL_EVENTS: collections.deque[dict[str, Any]] = collections.deque(maxlen=20000)
MEMORY_WAITERS: dict[str, dict[str, Any]] = {}


def _handle_udp_event(event: dict[str, Any]) -> None:
    event_type = str(event.get("event") or "")
    marker_id = str(event.get("marker_id") or "")
    now = time.time()
    event.setdefault("time", now)
    with MEMORY_LOCK:
        if event_type == "queued" and marker_id:
            MEMORY_WAITERS[marker_id] = event
        elif event_type in {"passed", "removed"} and marker_id:
            MEMORY_WAITERS.pop(marker_id, None)
        if event_type == "passed":
            MEMORY_RATE_EVENTS.append(event)
        elif event_type == "call_finished":
            MEMORY_CALL_EVENTS.append(event)


def _start_udp_listener(host: str, port: int) -> None:
    if port <= 0:
        return

    def run() -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        while True:
            data, _addr = sock.recvfrom(16384)
            try:
                event = json.loads(data.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                _handle_udp_event(event)

    thread = threading.Thread(target=run, name="mcp-rate-limit-udp", daemon=True)
    thread.start()


def _read_recent_events(path: Path, max_bytes: int = 4 * 1024 * 1024) -> list[dict[str, Any]]:
    try:
        size = path.stat().st_size
        with path.open("rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()
            raw = f.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return []
    except OSError:
        return []

    events: list[dict[str, Any]] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _read_waiters(waiter_dir: Path, stale_seconds: float) -> dict[str, Any]:
    now = time.time()
    live: list[dict[str, Any]] = []
    stale = 0
    for marker in waiter_dir.glob("*.json"):
        try:
            data = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        try:
            pid = int(data.get("pid") or 0)
            created_at = float(data.get("created_at") or 0.0)
        except (TypeError, ValueError):
            stale += 1
            continue
        age_s = max(0.0, now - created_at) if created_at else None
        if age_s is None or age_s > stale_seconds or not _pid_alive(pid):
            stale += 1
            continue
        live.append(
                {
                    "pid": pid,
                    "age_s": age_s,
                    "psm": data.get("psm") or "",
                    "tool_name": data.get("tool_name") or "",
                    "scope": data.get("scope") or "",
                    "limit_key": data.get("limit_key") or "",
                    "qps": data.get("qps"),
                }
            )
    live.sort(key=lambda item: item["age_s"], reverse=True)
    return {
        "pending_count": len(live),
        "stale_marker_count": stale,
        "oldest_pending_s": live[0]["age_s"] if live else 0.0,
        "pending": live[:50],
    }


def _memory_waiters_snapshot(stale_seconds: float) -> dict[str, Any]:
    now = time.time()
    live: list[dict[str, Any]] = []
    stale = 0
    with MEMORY_LOCK:
        for marker_id, data in list(MEMORY_WAITERS.items()):
            try:
                created_at = float(data.get("created_at") or data.get("time") or 0.0)
            except (TypeError, ValueError):
                created_at = 0.0
            age_s = max(0.0, now - created_at) if created_at else stale_seconds + 1
            if age_s > stale_seconds:
                stale += 1
                MEMORY_WAITERS.pop(marker_id, None)
                continue
            live.append(
                {
                    "pid": data.get("pid"),
                    "age_s": age_s,
                    "psm": data.get("psm") or "",
                    "tool_name": data.get("tool_name") or "",
                    "scope": data.get("scope") or "",
                    "limit_key": data.get("limit_key") or "",
                    "qps": data.get("qps"),
                    "marker_id": marker_id,
                }
            )
    live.sort(key=lambda item: item["age_s"], reverse=True)
    return {
        "pending_count": len(live),
        "stale_marker_count": stale,
        "oldest_pending_s": live[0]["age_s"] if live else 0.0,
        "pending": live[:50],
    }


def _memory_events_snapshot() -> list[dict[str, Any]]:
    with MEMORY_LOCK:
        return list(MEMORY_RATE_EVENTS)


def _memory_call_events_snapshot() -> list[dict[str, Any]]:
    with MEMORY_LOCK:
        return list(MEMORY_CALL_EVENTS)


def _window_stats(events: list[dict[str, Any]], now: float, seconds: float) -> dict[str, Any]:
    selected = []
    for event in events:
        try:
            event_time = float(event.get("time") or 0.0)
        except (TypeError, ValueError):
            continue
        if event_time >= now - seconds:
            selected.append(event)

    waits = []
    by_psm: dict[str, int] = {}
    by_tool: dict[str, int] = {}
    by_scope: dict[str, int] = {}
    by_limit_key: dict[str, int] = {}
    for event in selected:
        try:
            waits.append(float(event.get("wait_s") or 0.0))
        except (TypeError, ValueError):
            pass
        psm = str(event.get("psm") or "")
        tool = str(event.get("tool_name") or "")
        if psm:
            by_psm[psm] = by_psm.get(psm, 0) + 1
        if tool:
            by_tool[tool] = by_tool.get(tool, 0) + 1
        scope = str(event.get("scope") or "")
        limit_key = str(event.get("limit_key") or "")
        if scope:
            by_scope[scope] = by_scope.get(scope, 0) + 1
        if limit_key:
            by_limit_key[limit_key] = by_limit_key.get(limit_key, 0) + 1

    waits_sorted = sorted(waits)
    p95 = 0.0
    if waits_sorted:
        p95 = waits_sorted[min(len(waits_sorted) - 1, int(0.95 * (len(waits_sorted) - 1)))]
    return {
        "seconds": seconds,
        "events": len(selected),
        "effective_qps": len(selected) / seconds if seconds > 0 else 0.0,
        "avg_wait_s": sum(waits) / len(waits) if waits else 0.0,
        "max_wait_s": max(waits) if waits else 0.0,
        "p95_wait_s": p95,
        "by_scope": dict(sorted(by_scope.items(), key=lambda item: item[1], reverse=True)[:20]),
        "by_limit_key": dict(sorted(by_limit_key.items(), key=lambda item: item[1], reverse=True)[:20]),
        "by_psm": dict(sorted(by_psm.items(), key=lambda item: item[1], reverse=True)[:20]),
        "by_tool": dict(sorted(by_tool.items(), key=lambda item: item[1], reverse=True)[:20]),
    }


def _call_window_stats(events: list[dict[str, Any]], now: float, seconds: float) -> dict[str, Any]:
    selected = []
    for event in events:
        try:
            event_time = float(event.get("time") or 0.0)
        except (TypeError, ValueError):
            continue
        if event_time >= now - seconds:
            selected.append(event)

    durations = []
    by_psm: dict[str, int] = {}
    by_tool: dict[str, int] = {}
    by_transport: dict[str, int] = {}
    errors = 0
    error_types: dict[str, int] = {}
    for event in selected:
        try:
            durations.append(float(event.get("duration_s") or 0.0))
        except (TypeError, ValueError):
            pass
        psm = str(event.get("psm") or "")
        tool = str(event.get("tool_name") or "")
        transport = str(event.get("transport") or "")
        if psm:
            by_psm[psm] = by_psm.get(psm, 0) + 1
        if tool:
            by_tool[tool] = by_tool.get(tool, 0) + 1
        if transport:
            by_transport[transport] = by_transport.get(transport, 0) + 1
        if event.get("ok") is False:
            errors += 1
            err = str(event.get("error_type") or "unknown")
            error_types[err] = error_types.get(err, 0) + 1

    durations_sorted = sorted(durations)
    p95 = 0.0
    if durations_sorted:
        p95 = durations_sorted[min(len(durations_sorted) - 1, int(0.95 * (len(durations_sorted) - 1)))]
    return {
        "seconds": seconds,
        "events": len(selected),
        "effective_qps": len(selected) / seconds if seconds > 0 else 0.0,
        "avg_duration_s": sum(durations) / len(durations) if durations else 0.0,
        "max_duration_s": max(durations) if durations else 0.0,
        "p95_duration_s": p95,
        "errors": errors,
        "error_types": dict(sorted(error_types.items(), key=lambda item: item[1], reverse=True)[:20]),
        "by_psm": dict(sorted(by_psm.items(), key=lambda item: item[1], reverse=True)[:20]),
        "by_tool": dict(sorted(by_tool.items(), key=lambda item: item[1], reverse=True)[:20]),
        "by_transport": dict(sorted(by_transport.items(), key=lambda item: item[1], reverse=True)[:20]),
    }


def build_snapshot(rate_limit_dir: Path, stale_seconds: float) -> dict[str, Any]:
    now = time.time()
    memory_events = _memory_events_snapshot()
    memory_call_events = _memory_call_events_snapshot()
    events = memory_events or _read_recent_events(rate_limit_dir / "events.jsonl")
    latest = None
    if memory_events:
        latest = memory_events[-1]
    else:
        try:
            latest = json.loads((rate_limit_dir / "latest.json").read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            latest = None

    memory_queue = _memory_waiters_snapshot(stale_seconds)
    queue = memory_queue
    if not memory_events and memory_queue["pending_count"] == 0:
        queue = _read_waiters(rate_limit_dir / "waiters", stale_seconds)

    return {
        "time": now,
        "time_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "rate_limit_dir": str(rate_limit_dir),
        "source": (
            "udp-memory"
            if memory_events or memory_call_events or memory_queue["pending_count"]
            else "file-fallback"
        ),
        "latest": latest,
        "queue": queue,
        "windows": {
            "1s": _window_stats(events, now, 1.0),
            "10s": _window_stats(events, now, 10.0),
            "60s": _window_stats(events, now, 60.0),
        },
        "call_windows": {
            "1s": _call_window_stats(memory_call_events, now, 1.0),
            "10s": _call_window_stats(memory_call_events, now, 10.0),
            "60s": _call_window_stats(memory_call_events, now, 60.0),
        },
    }


class MetricsHandler(BaseHTTPRequestHandler):
    rate_limit_dir: Path
    stale_seconds: float

    def do_GET(self) -> None:
        if self.path not in ("/", "/health", "/metrics"):
            self.send_error(404)
            return
        payload = {"ok": True} if self.path == "/health" else build_snapshot(self.rate_limit_dir, self.stale_seconds)
        body = (json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: Any) -> None:
        if os.environ.get("MCP_METRICS_ACCESS_LOG") == "1":
            super().log_message(fmt, *args)


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve MCP rate-limit metrics")
    parser.add_argument("--host", default=os.environ.get("MCP_METRICS_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MCP_METRICS_PORT", "18090")))
    parser.add_argument("--udp-host", default=os.environ.get("MCP_METRICS_UDP_HOST", "127.0.0.1"))
    parser.add_argument("--udp-port", type=int, default=int(os.environ.get("MCP_METRICS_UDP_PORT", "18091")))
    parser.add_argument(
        "--rate-limit-dir",
        default=os.environ.get("MCP_RATE_LIMIT_DIR", "/tmp/server-ops-runtime/mcp/rate_limit"),
    )
    parser.add_argument("--stale-seconds", type=float, default=3600.0)
    args = parser.parse_args()
    _start_udp_listener(args.udp_host, args.udp_port)

    handler = type(
        "ConfiguredMetricsHandler",
        (MetricsHandler,),
        {
            "rate_limit_dir": Path(args.rate_limit_dir),
            "stale_seconds": args.stale_seconds,
        },
    )
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(
        f"serving MCP rate-limit metrics on http://{args.host}:{args.port}/metrics "
        f"(udp {args.udp_host}:{args.udp_port})"
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
