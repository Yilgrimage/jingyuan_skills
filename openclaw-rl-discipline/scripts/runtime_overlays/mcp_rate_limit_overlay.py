"""Training-only MCP global QPS limiter and lightweight metrics.

This module is copied into the derived training skills workspace. It is not
part of the online Codex runtime. Keep it independent from business routing so
online mcp_tool_call.py semantics stay intact.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import socket
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


RATE_LIMIT_DIR = Path(os.environ.get("MCP_RATE_LIMIT_DIR", "/tmp/server-ops-runtime/mcp/rate_limit"))
RATE_LIMIT_WAITER_DIR = RATE_LIMIT_DIR / "waiters"
RATE_LIMIT_EVENT_PATH = RATE_LIMIT_DIR / "events.jsonl"
RATE_LIMIT_LATEST_PATH = RATE_LIMIT_DIR / "latest.json"


def _resolve_global_qps() -> float:
    raw = os.environ.get("MCP_GLOBAL_QPS") or os.environ.get("MCP_RATE_LIMIT_QPS") or "0"
    try:
        return max(0.0, float(raw))
    except ValueError:
        return 0.0


def _parse_qps(raw: Any) -> float:
    try:
        return max(0.0, float(raw))
    except (TypeError, ValueError):
        return 0.0


def _parse_tool_qps_inline(raw: str) -> dict[str, float]:
    raw = raw.strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = None
    if isinstance(data, dict):
        return {str(k): _parse_qps(v) for k, v in data.items() if _parse_qps(v) > 0}

    config: dict[str, float] = {}
    for item in raw.split(","):
        if not item.strip() or "=" not in item:
            continue
        key, value = item.split("=", 1)
        qps = _parse_qps(value.strip())
        if key.strip() and qps > 0:
            config[key.strip()] = qps
    return config


def _load_tool_qps_config() -> dict[str, float]:
    config: dict[str, float] = {}
    config_path = os.environ.get("MCP_TOOL_QPS_CONFIG", "").strip()
    if config_path:
        try:
            data = json.loads(Path(config_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = None
        if isinstance(data, dict):
            config.update({str(k): _parse_qps(v) for k, v in data.items() if _parse_qps(v) > 0})
    config.update(_parse_tool_qps_inline(os.environ.get("MCP_TOOL_QPS", "")))
    return config


def _tool_limit_key(psm: str, tool_name: str | None) -> str:
    return f"{psm}/{tool_name}" if tool_name else f"{psm}/__unknown__"


def _resolve_tool_qps(psm: str, tool_name: str | None) -> tuple[float, str]:
    config = _load_tool_qps_config()
    candidates = []
    if tool_name:
        candidates.append(f"{psm}/{tool_name}")
    candidates.append(f"{psm}/*")
    for key in candidates:
        qps = config.get(key)
        if qps and qps > 0:
            return qps, key
    default_qps = _parse_qps(os.environ.get("MCP_TOOL_QPS_DEFAULT"))
    if default_qps > 0:
        return default_qps, _tool_limit_key(psm, tool_name)
    return 0.0, ""


def _file_metrics_enabled() -> bool:
    value = os.environ.get("MCP_RATE_LIMIT_FILE_METRICS", "0").lower()
    return value in {"1", "true", "yes", "on"} or value.endswith(".jsonl")


def _events_path() -> Path:
    value = os.environ.get("MCP_RATE_LIMIT_FILE_METRICS", "0")
    if value and value.lower() not in {"1", "true", "yes", "on", "0", "false", "no", "off"}:
        return Path(value)
    return RATE_LIMIT_EVENT_PATH


def _safe_tool_name(tool_name: str | None) -> str:
    if not tool_name:
        return ""
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in tool_name)[:96]


def _safe_limit_key(value: str) -> str:
    value = value or "unknown"
    value = re.sub(r"[^0-9A-Za-z._/-]+", "_", value).strip("._-/")
    value = value.replace("/", "__")
    return value[:180] or "unknown"


def _send_udp(payload: dict[str, Any]) -> None:
    if os.environ.get("MCP_METRICS_UDP_DISABLE", "0").lower() in {"1", "true", "yes", "on"}:
        return
    try:
        port = int(os.environ.get("MCP_METRICS_UDP_PORT", "18091"))
    except ValueError:
        return
    if port <= 0:
        return
    payload = dict(payload)
    payload.setdefault("schema", "mcp_rate_limit_event_v1")
    payload.setdefault("time", time.time())
    try:
        data = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")[:8192]
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setblocking(False)
            sock.sendto(data, (os.environ.get("MCP_METRICS_UDP_HOST", "127.0.0.1"), port))
        finally:
            sock.close()
    except OSError:
        pass


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _append_event(payload: dict[str, Any]) -> None:
    _send_udp(payload)
    if not _file_metrics_enabled():
        return
    path = _events_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
    _write_json_atomic(RATE_LIMIT_LATEST_PATH, payload)


def _count_live_waiters(now: float | None = None, scope: str | None = None, limit_key: str | None = None) -> int:
    if now is None:
        now = time.time()
    if not RATE_LIMIT_WAITER_DIR.exists():
        return 0
    count = 0
    for marker in RATE_LIMIT_WAITER_DIR.glob("*.json"):
        try:
            data = json.loads(marker.read_text(encoding="utf-8"))
            pid = int(data.get("pid") or 0)
            created_at = float(data.get("created_at") or 0.0)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        if scope is not None and data.get("scope") != scope:
            continue
        if limit_key is not None and data.get("limit_key") != limit_key:
            continue
        if created_at and now - created_at > 3600:
            continue
        if pid <= 0:
            continue
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        count += 1
    return count


def _apply_one_limit(psm: str, tool_name: str | None, qps: float, scope: str, limit_key: str) -> None:
    if qps <= 0:
        return

    RATE_LIMIT_DIR.mkdir(parents=True, exist_ok=True)
    RATE_LIMIT_WAITER_DIR.mkdir(parents=True, exist_ok=True)
    wait_start = time.monotonic()
    safe_key = _safe_limit_key(limit_key)
    marker = RATE_LIMIT_WAITER_DIR / f"{os.getpid()}-{time.time_ns()}-{scope}-{safe_key}-{_safe_tool_name(tool_name)}.json"
    queued = {
        "event": "queued",
        "marker_id": marker.name,
        "pid": os.getpid(),
        "created_at": time.time(),
        "psm": psm,
        "tool_name": tool_name or "",
        "scope": scope,
        "limit_key": limit_key,
        "qps": qps,
    }
    if _file_metrics_enabled():
        _write_json_atomic(marker, queued)
    _send_udp(queued)

    scope_dir = RATE_LIMIT_DIR / scope
    scope_dir.mkdir(parents=True, exist_ok=True)
    lock_path = scope_dir / f"{safe_key}.lock"
    state_path = scope_dir / f"{safe_key}.next_time.txt"
    min_interval = 1.0 / qps
    try:
        with lock_path.open("a+") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            now = time.monotonic()
            next_time = now
            try:
                state_text = state_path.read_text(encoding="utf-8").strip()
                if state_text:
                    next_time = float(state_text)
            except (FileNotFoundError, ValueError):
                next_time = now
            sleep_s = max(0.0, next_time - now)
            if sleep_s > 0:
                time.sleep(sleep_s)
            state_path.write_text(f"{time.monotonic() + min_interval:.9f}\n", encoding="utf-8")
            passed = {
                "event": "passed",
                "marker_id": marker.name,
                "time": time.time(),
                "time_iso": datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds"),
                "pid": os.getpid(),
                "psm": psm,
                "tool_name": tool_name or "",
                "scope": scope,
                "limit_key": limit_key,
                "qps": qps,
                "wait_s": max(0.0, time.monotonic() - wait_start),
                "pending_count": _count_live_waiters(scope=scope, limit_key=limit_key),
            }
            _append_event(passed)
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    finally:
        if _file_metrics_enabled():
            try:
                marker.unlink()
            except FileNotFoundError:
                pass
        _send_udp({"event": "removed", "marker_id": marker.name, "pid": os.getpid()})


def apply_rate_limit(psm: str, tool_name: str | None = None) -> None:
    global_qps = _resolve_global_qps()
    if global_qps > 0:
        _apply_one_limit(psm, tool_name, global_qps, scope="global", limit_key="global")

    tool_qps, limit_key = _resolve_tool_qps(psm, tool_name)
    if tool_qps > 0:
        _apply_one_limit(psm, tool_name, tool_qps, scope="tool", limit_key=limit_key)


def apply_global_rate_limit(psm: str, tool_name: str | None = None) -> None:
    """Backward-compatible name used by older derived workspaces."""
    apply_rate_limit(psm, tool_name)


def emit_call_finished(
    psm: str,
    tool_name: str | None = None,
    *,
    transport: str | None = None,
    duration_s: float = 0.0,
    ok: bool = True,
    error_type: str | None = None,
) -> None:
    _send_udp(
        {
            "event": "call_finished",
            "time": time.time(),
            "time_iso": datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds"),
            "pid": os.getpid(),
            "psm": psm,
            "tool_name": tool_name or "",
            "transport": transport or "",
            "duration_s": max(0.0, duration_s),
            "ok": bool(ok),
            "error_type": error_type or "",
        }
    )


@contextlib.contextmanager
def mcp_call_scope(psm: str, tool_name: str | None = None, *, transport: str | None = None):
    started = time.monotonic()
    apply_rate_limit(psm, tool_name)
    try:
        yield
    except BaseException as exc:
        emit_call_finished(
            psm,
            tool_name,
            transport=transport,
            duration_s=time.monotonic() - started,
            ok=False,
            error_type=type(exc).__name__,
        )
        raise
    else:
        emit_call_finished(
            psm,
            tool_name,
            transport=transport,
            duration_s=time.monotonic() - started,
            ok=True,
        )
