"""Live usage from telemt's API: merging, tolerance of odd answers, output format."""

from __future__ import annotations

import io
import json

import pytest

from burrowrs_tools import __main__ as cli
from burrowrs_tools import usage

USERS = [
    {
        "username": "owner",
        "current_connections": 1,
        "active_unique_ips": 1,
        "total_octets": 2048,
    },
    {
        "username": "alice",
        "current_connections": 3,
        "active_unique_ips": 2,
        "total_octets": 53687091200,
        "data_quota_bytes": 107374182400,
    },
    {
        "username": "bob",
        "current_connections": 0,
        "active_unique_ips": 0,
        "total_octets": 0,
    },
]
QUOTA = {
    "users": [{"username": "alice", "data_quota_bytes": 107374182400, "used_bytes": 1234, "quota_period": "monthly"}]
}


def fake_api(answers: dict[str, object]):
    def get(path: str, timeout: float) -> object:
        assert timeout > 0
        return answers[path]

    return get


class TestRows:
    def test_merges_quota_usage_into_user_rows_sorted_by_name(self):
        assert usage.rows(USERS, QUOTA) == [
            ("alice", 3, 2, 53687091200, 1234),
            ("bob", 0, 0, 0, None),
            ("owner", 1, 1, 2048, None),
        ]

    def test_users_without_a_quota_entry_have_none(self):
        assert usage.rows(USERS, {"users": []})[0][4] is None
        assert usage.rows(USERS, None)[0][4] is None

    @pytest.mark.parametrize(
        "name",
        ["Alice", "../etc", "a b", "a\tb", "a\nb", "\x1b[31mred", "", "x" * 33, "-x", 7, None],
    )
    def test_names_outside_burrowrss_alphabet_are_dropped(self, name):
        rows = usage.rows([{"username": name, "current_connections": 1}], {})
        assert rows == []

    @pytest.mark.parametrize("value", [-1, "3", 1.5, None, True, [], {}])
    def test_bad_counters_become_zero(self, value):
        rows = usage.rows(
            [{"username": "carol", "current_connections": value, "active_unique_ips": value, "total_octets": value}],
            {"users": [{"username": "carol", "used_bytes": value}]},
        )
        assert rows == [("carol", 0, 0, 0, 0)]

    @pytest.mark.parametrize("users", [None, {}, "x", 3, [None, "alice", 7]])
    def test_malformed_user_lists_give_no_rows(self, users):
        assert usage.rows(users, QUOTA) == []

    @pytest.mark.parametrize(
        "quota", [None, [], "x", {"users": None}, {"users": "x"}, {"users": [None, 3, {"used_bytes": 5}]}]
    )
    def test_malformed_quota_answers_are_ignored(self, quota):
        assert usage.rows(USERS, quota)[0] == ("alice", 3, 2, 53687091200, None)


class TestReport:
    def test_tab_separated_lines_with_dash_for_no_quota(self, monkeypatch):
        monkeypatch.setattr(usage, "_get", fake_api({"/v1/users": USERS, "/v1/stats/users/quota": QUOTA}))
        assert usage.report(timeout=2) == ("alice\t3\t2\t53687091200\t1234\nbob\t0\t0\t0\t-\nowner\t1\t1\t2048\t-\n")

    def test_no_users_is_empty_output(self, monkeypatch):
        monkeypatch.setattr(usage, "_get", fake_api({"/v1/users": [], "/v1/stats/users/quota": {"users": []}}))
        assert usage.report() == ""


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class TestGet:
    def test_unwraps_the_success_envelope(self, monkeypatch):
        seen = []

        def urlopen(url, timeout):
            seen.append((url, timeout))
            return FakeResponse(json.dumps({"ok": True, "data": [1, 2], "revision": "x"}).encode())

        monkeypatch.setattr(usage.urllib.request, "urlopen", urlopen)
        assert usage._get("/v1/users", 3.0) == [1, 2]
        assert seen == [("http://127.0.0.1:9091/v1/users", 3.0)]

    @pytest.mark.parametrize(
        "body",
        [b'{"ok": false, "error": {"code": "x", "message": "y"}}', b"[]", b"not json", b'"ok"'],
    )
    def test_error_envelopes_and_garbage_raise(self, monkeypatch, body):
        monkeypatch.setattr(usage.urllib.request, "urlopen", lambda url, timeout: FakeResponse(body))
        with pytest.raises(usage.UsageError):
            usage._get("/v1/users", 1.0)

    def test_connection_errors_raise(self, monkeypatch):
        def urlopen(url, timeout):
            raise ConnectionRefusedError("refused")

        monkeypatch.setattr(usage.urllib.request, "urlopen", urlopen)
        with pytest.raises(usage.UsageError, match="refused"):
            usage._get("/v1/users", 1.0)


class TestCommand:
    def test_prints_the_report(self, monkeypatch, capsys):
        monkeypatch.setattr(usage, "_get", fake_api({"/v1/users": USERS, "/v1/stats/users/quota": QUOTA}))
        assert cli.main(["usage", "--timeout", "2"]) == 0
        assert capsys.readouterr().out.startswith("alice\t3\t2\t")

    def test_api_failure_is_a_clean_error(self, monkeypatch, capsys):
        def broken(path, timeout):
            raise usage.UsageError("telemt API /v1/users: \x1b[2Jrefused")

        monkeypatch.setattr(usage, "_get", broken)
        assert cli.main(["usage"]) == 1
        err = capsys.readouterr().err
        assert "refused" in err
        assert "\x1b" not in err


MATCH = {"desired_status": "valid", "comparison": {"status": "published_match"}}


class TestApplied:
    def test_only_a_valid_published_match_counts(self):
        assert usage.applied(MATCH)

    @pytest.mark.parametrize(
        "state",
        [
            None,
            [],
            "valid",
            {},
            {"desired_status": "invalid", "comparison": {"status": "published_match"}},
            {"desired_status": "valid", "comparison": {"status": "pending"}},
            {"desired_status": "valid", "comparison": "published_match"},
            {"desired_status": "valid"},
        ],
    )
    def test_anything_else_is_not_applied(self, state):
        assert not usage.applied(state)


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class TestWaitApplied:
    def answers(self, monkeypatch, sequence):
        clock = FakeClock()
        monkeypatch.setattr(usage.time, "monotonic", clock.monotonic)
        monkeypatch.setattr(usage.time, "sleep", clock.sleep)
        paths = []

        def get(path, timeout):
            paths.append(path)
            item = sequence[min(len(paths), len(sequence)) - 1]
            if isinstance(item, Exception):
                raise item
            return item

        monkeypatch.setattr(usage, "_get", get)
        return paths

    def test_returns_once_telemt_publishes_the_files(self, monkeypatch):
        pending = {"desired_status": "valid", "comparison": {"status": "pending"}}
        paths = self.answers(monkeypatch, [usage.UsageError("not yet"), pending, MATCH])
        assert usage.wait_applied(timeout=10, interval=0.5)
        assert paths == ["/v1/config/state?sections=access"] * 3

    def test_gives_up_at_the_deadline(self, monkeypatch):
        paths = self.answers(monkeypatch, [{"desired_status": "valid", "comparison": {"status": "pending"}}])
        assert not usage.wait_applied(timeout=2, interval=0.5)
        assert len(paths) == 5  # t = 0, 0.5, 1.0, 1.5, 2.0

    def test_command_exit_status(self, monkeypatch, capsys):
        monkeypatch.setattr(usage, "wait_applied", lambda timeout: False)
        assert cli.main(["wait-applied", "--timeout", "3"]) != 0
        assert "not applied" in capsys.readouterr().err
        monkeypatch.setattr(usage, "wait_applied", lambda timeout: True)
        assert cli.main(["wait-applied"]) == 0
