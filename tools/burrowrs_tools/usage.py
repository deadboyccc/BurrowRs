"""Live per-user usage from telemt's read-only control API.

The API listens on 127.0.0.1 inside telemt's network namespace only, so this
runs in a container that shares it (the ``tools-api`` compose service).
Output is one tab-separated line per user, for ``./burrowrs user list``:

    name  connections  active_ips  total_bytes  quota_used_bytes

``quota_used_bytes`` is ``-`` for users without a quota. Usernames come from
telemt and are checked against burrowrs's alphabet before they are printed.
"""

from __future__ import annotations

import json
import re
import time
import urllib.request
from typing import Any

API = "http://127.0.0.1:9091"
USERNAME = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,31}$")


class UsageError(RuntimeError):
    pass


def _get(path: str, timeout: float) -> Any:
    try:
        with urllib.request.urlopen(API + path, timeout=timeout) as response:  # noqa: S310 (fixed http://127.0.0.1)
            body = json.load(response)
    except (OSError, ValueError) as exc:
        raise UsageError(f"telemt API {path}: {exc}") from exc
    if not isinstance(body, dict) or not body.get("ok"):
        raise UsageError(f"telemt API {path}: unexpected answer")
    return body.get("data")


def _count(value: Any) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def rows(users: Any, quota: Any) -> list[tuple[str, int, int, int, int | None]]:
    """Merge /v1/users and /v1/stats/users/quota into report rows."""
    used: dict[str, int] = {}
    entries = quota.get("users", []) if isinstance(quota, dict) else []
    for entry in entries if isinstance(entries, list) else []:
        if isinstance(entry, dict) and isinstance(entry.get("username"), str):
            used[entry["username"]] = _count(entry.get("used_bytes"))
    out = []
    for user in users if isinstance(users, list) else []:
        if not isinstance(user, dict):
            continue
        name = user.get("username")
        if not isinstance(name, str) or not USERNAME.match(name):
            continue
        out.append(
            (
                name,
                _count(user.get("current_connections")),
                _count(user.get("active_unique_ips")),
                _count(user.get("total_octets")),
                used.get(name),
            )
        )
    return sorted(out)


def report(timeout: float = 5.0) -> str:
    lines = []
    for name, conns, ips, total, quota_used in rows(_get("/v1/users", timeout), _get("/v1/stats/users/quota", timeout)):
        lines.append(f"{name}\t{conns}\t{ips}\t{total}\t{'-' if quota_used is None else quota_used}\n")
    return "".join(lines)


def applied(state: Any) -> bool:
    """True when the access section telemt runs matches the files on disk."""
    if not isinstance(state, dict) or state.get("desired_status") != "valid":
        return False
    comparison = state.get("comparison")
    return isinstance(comparison, dict) and comparison.get("status") == "published_match"


def wait_applied(timeout: float = 15.0, interval: float = 0.25) -> bool:
    """Wait until telemt's file watcher has published users.toml.

    telemt watches its config files itself (inotify plus a 3-second poll), so
    burrowrs never signals the container: ``docker kill -s HUP`` would also
    switch off Docker's restart policy for it.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            if applied(_get("/v1/config/state?sections=access", timeout=5.0)):
                return True
        except UsageError:
            pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)
