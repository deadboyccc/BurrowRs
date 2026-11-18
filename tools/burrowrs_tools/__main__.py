"""Command line for burrowrs-tools.

Secrets are read from the ``BURROWRS_SECRET`` environment variable by default,
so they never appear in ``ps`` output on the host.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections.abc import Callable

from . import __version__, probe
from .secret import Secret, SecretError

VERDICTS = (probe.PROXY, probe.FRONTED, probe.CLOSED, probe.ERROR)


def _secret(args: argparse.Namespace) -> Secret:
    text = args.secret or os.environ.get("BURROWRS_SECRET", "")
    if not text:
        raise SecretError("no secret: pass --secret or set BURROWRS_SECRET")
    return Secret.parse(text)


def printable(text: str, limit: int = 200) -> str:
    """Server-controlled text, made safe for a terminal: no escape sequences,
    no carriage returns that could overwrite a FAIL line, bounded length."""
    safe = "".join(c if c.isprintable() else f"\\x{ord(c):02x}" for c in text)
    return safe if len(safe) <= limit else safe[:limit] + "…"


def _report(result: probe.Result, args: argparse.Namespace, ok: bool) -> int:
    if args.json:  # json.dumps escapes control characters
        print(json.dumps({"ok": ok, **result.as_dict()}, sort_keys=True))
    else:
        mark = "PASS" if ok else "FAIL"
        print(f"{mark} {result.check}: {result.verdict} - {printable(result.detail)} ({result.elapsed_ms:.0f} ms)")
    return 0 if ok else 1


def _float_range(low: float, high: float) -> Callable[[str], float]:
    def parse(text: str) -> float:
        try:
            value = float(text)
        except ValueError:
            raise argparse.ArgumentTypeError(f"not a number: {text!r}") from None
        if not low <= value <= high:  # also rejects nan and inf
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return value

    return parse


def _int_range(low: int, high: int) -> Callable[[str], int]:
    def parse(text: str) -> int:
        try:
            value = int(text)
        except ValueError:
            raise argparse.ArgumentTypeError(f"not an integer: {text!r}") from None
        if not low <= value <= high:
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return value

    return parse


def _with_retries(
    args: argparse.Namespace, run: Callable[[], probe.Result], accept: Callable[[probe.Result], bool]
) -> int:
    attempts = max(1, args.retries + 1)
    result = run()
    for _ in range(attempts - 1):
        if accept(result):
            break
        time.sleep(args.retry_delay)
        result = run()
    return _report(result, args, accept(result))


def cmd_probe(args: argparse.Namespace) -> int:
    if args.telegram and args.time_offset:
        raise ValueError("--time-offset cannot be combined with --telegram")
    secret = _secret(args)
    if args.telegram:

        def run() -> probe.Result:
            return probe.telegram_probe(args.host, args.port, secret, dc=args.dc, timeout=args.timeout)
    else:

        def run() -> probe.Result:
            return probe.faketls_probe(args.host, args.port, secret, timeout=args.timeout, time_offset=args.time_offset)

    return _with_retries(args, run, lambda r: r.verdict == args.expect)


def cmd_replay(args: argparse.Namespace) -> int:
    secret = _secret(args)
    return _with_retries(
        args,
        lambda: probe.replay_probe(args.host, args.port, secret, timeout=args.timeout),
        lambda r: r.verdict == probe.FRONTED,
    )


def _http_ok(result: probe.Result, args: argparse.Namespace) -> bool:
    if result.verdict != probe.FRONTED:
        return False
    if args.expect_status and result.data.get("status") != args.expect_status:
        return False
    return not args.expect_text or args.expect_text in result.data.get("body", "")


def cmd_https(args: argparse.Namespace) -> int:
    def run() -> probe.Result:
        return probe.https_probe(
            args.host,
            args.port,
            args.sni,
            path=args.path,
            cafile=args.cafile,
            insecure=args.insecure,
            timeout=args.timeout,
        )

    return _with_retries(args, run, lambda r: _http_ok(r, args))


def cmd_plaintext(args: argparse.Namespace) -> int:
    return _with_retries(
        args,
        lambda: probe.plaintext_probe(args.host, args.port, timeout=args.timeout),
        lambda r: _http_ok(r, args),
    )


def cmd_qr(args: argparse.Namespace) -> int:
    # Imported here: segno is about a third of start-up time, and only this
    # command needs it. Every probe (status, smoke, the watchdog) starts faster.
    from . import qr  # noqa: PLC0415

    code = qr.make(args.text if args.text is not None else sys.stdin.read())
    if args.format == "terminal":
        sys.stdout.write(qr.terminal(code))
    else:
        sys.stdout.buffer.write(qr.render(code, args.format))
    return 0


def cmd_usage(args: argparse.Namespace) -> int:
    from . import usage  # noqa: PLC0415

    try:
        sys.stdout.write(usage.report(timeout=args.timeout))
    except usage.UsageError as exc:
        print(f"error: {printable(str(exc))}", file=sys.stderr)
        return 1
    return 0


def cmd_wait_applied(args: argparse.Namespace) -> int:
    from . import usage  # noqa: PLC0415

    if usage.wait_applied(timeout=args.timeout):
        return 0
    print(f"error: telemt has not applied the user list after {args.timeout:.0f} s", file=sys.stderr)
    return 1


def cmd_secret(args: argparse.Namespace) -> int:
    secret = _secret(args)
    print(json.dumps({"host": secret.host, "hex": secret.hex(), "base64": secret.base64()}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="burrowrs-tools", description=__doc__)
    parser.add_argument("--version", action="version", version=f"burrowrs-tools {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    def network(p: argparse.ArgumentParser, *, needs_secret: bool) -> None:
        p.add_argument("--host", required=True)
        p.add_argument("--port", type=_int_range(1, 65535), default=443)
        p.add_argument("--timeout", type=_float_range(0.1, 600), default=10.0)
        p.add_argument("--retries", type=_int_range(0, 1000), default=0, help="retry until the expectation holds")
        p.add_argument("--retry-delay", type=_float_range(0, 600), default=1.0)
        p.add_argument("--json", action="store_true")
        if needs_secret:
            p.add_argument("--secret", help="defaults to $BURROWRS_SECRET")

    p = sub.add_parser("probe", help="FakeTLS handshake (and optionally a Telegram round trip)")
    network(p, needs_secret=True)
    p.add_argument("--telegram", action="store_true", help="also relay req_pq_multi to a Telegram DC")
    p.add_argument("--dc", type=_int_range(-(1 << 15), (1 << 15) - 1), default=2)
    p.add_argument("--time-offset", type=int, default=0, help="skew the client clock by N seconds")
    p.add_argument("--expect", choices=VERDICTS, default=probe.PROXY)
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("replay", help="check that a replayed ClientHello is rejected")
    network(p, needs_secret=True)
    p.set_defaults(func=cmd_replay)

    for name, func, helptext in (
        ("https", cmd_https, "fetch the cover website over real TLS, as a browser or censor would"),
        ("plaintext", cmd_plaintext, "send plain HTTP to the TLS port, as a scanner would"),
    ):
        p = sub.add_parser(name, help=helptext)
        network(p, needs_secret=False)
        if name == "https":
            p.add_argument("--sni", required=True)
            p.add_argument("--path", default="/")
            p.add_argument("--cafile")
            p.add_argument("--insecure", action="store_true")
        p.add_argument("--expect-status", type=int, default=0)
        p.add_argument("--expect-text", default="")
        p.set_defaults(func=func)

    p = sub.add_parser("qr", help="render a QR code locally; text from --text or stdin, image to stdout")
    p.add_argument("--text")
    p.add_argument("--format", choices=("terminal", "png", "svg"), default="terminal")
    p.set_defaults(func=cmd_qr)

    p = sub.add_parser("usage", help="live per-user usage from telemt's API (inside telemt's network namespace)")
    p.add_argument("--timeout", type=_float_range(0.1, 60), default=5.0)
    p.set_defaults(func=cmd_usage)

    p = sub.add_parser("wait-applied", help="wait until telemt runs the user list on disk (inside its namespace)")
    p.add_argument("--timeout", type=_float_range(0.1, 120), default=15.0)
    p.set_defaults(func=cmd_wait_applied)

    p = sub.add_parser("secret", help="decode a secret (from $BURROWRS_SECRET)")
    p.add_argument("--secret")
    p.set_defaults(func=cmd_secret)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (SecretError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
