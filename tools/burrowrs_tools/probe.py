"""Network probes: look at a burrowrs proxy the way Telegram and a censor would.

Verdicts:

``proxy``
    The peer completed a FakeTLS handshake that only someone holding the
    secret can produce.
``fronted``
    The peer answered like an ordinary TLS or HTTP server. This is the
    expected result for wrong secrets, replays, stale timestamps and
    scanners.
``closed``
    The peer accepted the TCP connection and dropped it without sending
    anything (for example an IP blocklist or allowlist rejection).
``error``
    Connection refused, timeout, DNS failure, and so on.

Every connection gets a bounded time budget (``timeout``) for connecting, and
a fresh one of the same size for the exchange that follows, so a hostile
server reached through ``burrowrs smoke --link`` cannot stall a probe. (The
replay probe makes two connections, each with its own budget.)
"""

from __future__ import annotations

import os
import socket
import ssl
import time
from dataclasses import dataclass, field
from typing import Any

from . import faketls, mtproto
from .faketls import Deadline
from .obfuscated2 import ObfuscatedStream
from .secret import Secret

PROXY = "proxy"
FRONTED = "fronted"
CLOSED = "closed"
ERROR = "error"

MAX_HTTP_RESPONSE = 4 << 20
MAX_PLAINTEXT_RESPONSE = 64 << 10


@dataclass
class Result:
    check: str
    verdict: str
    detail: str
    elapsed_ms: float
    data: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "check": self.check,
            "verdict": self.verdict,
            "detail": self.detail,
            "elapsed_ms": round(self.elapsed_ms, 1),
            **self.data,
        }


class _Clock:
    def __init__(self) -> None:
        self.started = time.perf_counter()

    def ms(self) -> float:
        return (time.perf_counter() - self.started) * 1000


def _connect(host: str, port: int, timeout: float) -> socket.socket:
    """Connect within ``timeout``, shared fairly by every resolved address.

    ``socket.create_connection`` gives each address the full timeout in turn,
    so one blackholed address (say an AAAA record whose port 443 is
    firewalled) would use up the budget before the working one is tried.
    """
    deadline = Deadline(timeout)
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    last_error: OSError = OSError(f"no addresses for {host}")
    for index, (family, kind, proto, _name, address) in enumerate(infos):
        left = deadline.remaining()
        if left <= 0:
            break
        sock = socket.socket(family, kind, proto)
        try:
            sock.settimeout(left / (len(infos) - index))
            sock.connect(address)
        except OSError as exc:
            sock.close()
            last_error = exc
            continue
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock
    raise last_error


def _error(check: str, exc: BaseException, clock: _Clock) -> Result:
    return Result(check, ERROR, f"{type(exc).__name__}: {exc}", clock.ms())


def _status(status_line: str) -> int:
    parts = status_line.split(" ", 2)
    code = parts[1] if len(parts) > 1 else ""
    return int(code) if code.isascii() and code.isdigit() else 0


def _handshake(
    sock: socket.socket, key: bytes, hello: bytes, client_random: bytes, deadline: Deadline
) -> tuple[str, str]:
    try:
        deadline.apply(sock)
        sock.sendall(hello)
        records = faketls.read_server_flight(sock, deadline)
    except faketls.ConnectionClosed as exc:
        if exc.received == 0:
            return CLOSED, "connection closed without a response"
        return FRONTED, f"short non-FakeTLS response ({exc})"
    except (ConnectionResetError, BrokenPipeError):
        return CLOSED, "connection reset by peer"
    except faketls.FakeTLSError as exc:
        return FRONTED, str(exc)

    if faketls.is_proxy_flight(key, client_random, records):
        return PROXY, "FakeTLS ServerHello verified with the secret"

    kinds = ",".join(f"{r.type:#04x}" for r in records)
    return FRONTED, f"peer answered as a regular TLS server (records {kinds})"


def faketls_probe(
    host: str,
    port: int,
    secret: Secret,
    *,
    timeout: float = 10.0,
    time_offset: int = 0,
) -> Result:
    """One FakeTLS handshake; ``time_offset`` simulates client clock skew."""
    clock = _Clock()
    try:
        with _connect(host, port, timeout) as sock:
            deadline = Deadline(timeout)
            hello, client_random = faketls.build_client_hello(
                secret.key, secret.host, timestamp=int(time.time()) + time_offset
            )
            verdict, detail = _handshake(sock, secret.key, hello, client_random, deadline)
    except OSError as exc:
        return _error("faketls", exc, clock)
    return Result("faketls", verdict, detail, clock.ms())


def replay_probe(host: str, port: int, secret: Secret, *, timeout: float = 10.0) -> Result:
    """Send one valid ClientHello twice. The second copy must not be accepted."""
    clock = _Clock()
    hello, client_random = faketls.build_client_hello(secret.key, secret.host)
    verdicts = []
    try:
        for _ in range(2):
            with _connect(host, port, timeout) as sock:
                deadline = Deadline(timeout)
                verdicts.append(_handshake(sock, secret.key, hello, client_random, deadline)[0])
    except OSError as exc:
        return _error("replay", exc, clock)

    first, second = verdicts
    data = {"first": first, "second": second}
    if first == PROXY and second != PROXY:
        return Result("replay", FRONTED, f"replayed hello was rejected ({second})", clock.ms(), data)
    if first == PROXY and second == PROXY:
        return Result("replay", PROXY, "replayed hello was ACCEPTED: anti-replay is off", clock.ms(), data)
    # The proxy never accepted the original, so it may never have recorded it:
    # nothing can be concluded about anti-replay.
    return Result("replay", ERROR, f"inconclusive: the first handshake did not succeed ({first})", clock.ms(), data)


def telegram_probe(
    host: str,
    port: int,
    secret: Secret,
    *,
    dc: int = 2,
    timeout: float = 15.0,
) -> Result:
    """Full path: FakeTLS → obfuscated2 → Telegram DC → resPQ back."""
    clock = _Clock()
    try:
        stream = ObfuscatedStream(secret.key, dc=dc)
        with _connect(host, port, timeout) as sock:
            deadline = Deadline(timeout)
            hello, client_random = faketls.build_client_hello(secret.key, secret.host)
            verdict, detail = _handshake(sock, secret.key, hello, client_random, deadline)
            if verdict != PROXY:
                return Result("telegram", verdict, detail, clock.ms())

            conn = faketls.FakeTLSConnection(sock, deadline)
            nonce = os.urandom(16)
            request = mtproto.wrap_padded_intermediate(mtproto.build_req_pq_multi(nonce))

            sent = time.perf_counter()
            conn.send(stream.handshake + stream.encrypt(request))
            length = int.from_bytes(stream.decrypt(conn.recv_exact(4)), "little")
            if not 0 < length <= 1 << 20:
                raise mtproto.MTProtoError(f"implausible packet length {length}")
            answer = mtproto.parse_res_pq(stream.decrypt(conn.recv_exact(length)), nonce)
            rtt = (time.perf_counter() - sent) * 1000
    except (OSError, EOFError, faketls.FakeTLSError, mtproto.MTProtoError) as exc:
        return _error("telegram", exc, clock)

    return Result(
        "telegram",
        PROXY,
        f"Telegram DC{dc} answered resPQ through the proxy (rtt {rtt:.0f} ms)",
        clock.ms(),
        {"dc": dc, "rtt_ms": round(rtt, 1), "fingerprints": len(answer.fingerprints)},
    )


def _read_until_close(sock: socket.socket, deadline: Deadline, limit: int) -> bytes:
    """Read until EOF, ``limit`` bytes, or (once something arrived) a stall or reset.

    A server that sends a complete answer and then keeps the connection open
    (or resets it) has still answered.
    """
    response = bytearray()
    while len(response) < limit:
        try:
            deadline.apply(sock)
            chunk = sock.recv(65536)
        except (TimeoutError, ConnectionResetError, ssl.SSLError):
            if response:
                break
            raise
        if not chunk:
            break
        response += chunk
    return bytes(response[:limit])


def https_probe(
    host: str,
    port: int,
    sni: str,
    *,
    path: str = "/",
    cafile: str | None = None,
    insecure: bool = False,
    timeout: float = 10.0,
) -> Result:
    """What a browser or censor sees: a real TLS handshake plus an HTTP GET."""
    clock = _Clock()
    request = (
        f"GET {path} HTTP/1.1\r\nHost: {sni}\r\n"
        "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)\r\n"
        "Accept: text/html,*/*;q=0.8\r\nConnection: close\r\n\r\n"
    ).encode("ascii")

    try:
        context = ssl.create_default_context(cafile=cafile)
        if insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        context.set_alpn_protocols(["http/1.1"])
        with _connect(host, port, timeout) as raw:
            deadline = Deadline(timeout)
            deadline.apply(raw)  # the TLS handshake in wrap_socket counts too
            with context.wrap_socket(raw, server_hostname=sni) as tls:
                cert = tls.getpeercert() or {}
                tls_version = tls.version()
                deadline.apply(tls)
                tls.sendall(request)
                response = _read_until_close(tls, deadline, MAX_HTTP_RESPONSE)
    except ssl.SSLCertVerificationError as exc:
        return Result("https", ERROR, f"certificate rejected: {exc.verify_message}", clock.ms())
    except OSError as exc:  # includes ssl.SSLError, timeouts and a bad --cafile
        return _error("https", exc, clock)

    head, _, body = response.partition(b"\r\n\r\n")
    status_line = head.split(b"\r\n", 1)[0].decode("latin-1")
    issuer = dict(item[0] for item in cert.get("issuer", ())) if cert else {}

    return Result(
        "https",
        FRONTED,
        f"{status_line} over {tls_version}",
        clock.ms(),
        {
            "status": _status(status_line),
            "tls_version": tls_version,
            "issuer": issuer.get("organizationName") or issuer.get("commonName", ""),
            "body": body.decode("utf-8", "replace"),
        },
    )


def plaintext_probe(host: str, port: int, *, timeout: float = 10.0) -> Result:
    """Send plain HTTP to the TLS port, as lazy scanners do."""
    clock = _Clock()
    try:
        with _connect(host, port, timeout) as sock:
            deadline = Deadline(timeout)
            deadline.apply(sock)
            sock.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            response = _read_until_close(sock, deadline, MAX_PLAINTEXT_RESPONSE)
    except (ConnectionResetError, BrokenPipeError):
        return Result("plaintext", CLOSED, "connection reset", clock.ms())
    except OSError as exc:
        return _error("plaintext", exc, clock)

    if not response:
        return Result("plaintext", CLOSED, "no response", clock.ms())
    first_line = response.split(b"\r\n", 1)[0].decode("latin-1")
    return Result(
        "plaintext",
        FRONTED,
        first_line,
        clock.ms(),
        {"status": _status(first_line), "body": response.decode("utf-8", "replace")},
    )
