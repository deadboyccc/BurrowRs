"""Probe verdicts against small in-process servers that mimic a FakeTLS proxy and friends."""

from __future__ import annotations

import contextlib
import socket
import ssl
import struct
import subprocess
import threading
import time
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from burrowrs_tools import faketls, probe
from burrowrs_tools.__main__ import main
from burrowrs_tools.secret import Secret

from .reference_server import ServerObfuscation, app_record, check_client_hello, res_pq_packet, server_flight

SECRET = Secret(key=bytes(range(16)), host="notes.example.org")

# Set when a test ends, so handlers that "hang" release their thread promptly.
STOP = threading.Event()


class Server:
    """Accept connections on 127.0.0.1 and hand each one to ``handler``."""

    def __init__(self, handler: Callable[[socket.socket], None]) -> None:
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.handler = handler
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn, contextlib.suppress(OSError, ValueError, AssertionError):
                self.handler(conn)

    def close(self) -> None:
        # shutdown() wakes the thread blocked in accept(); close() alone does not.
        with contextlib.suppress(OSError):
            self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()
        self.thread.join(timeout=5)


def read_hello(conn: socket.socket) -> bytes:
    header = faketls.recv_exact(conn, 5)
    return header + faketls.recv_exact(conn, int.from_bytes(header[3:5], "big"))


def fake_proxy(seen: set[bytes] | None = None) -> Callable[[socket.socket], None]:
    seen = set() if seen is None else seen

    def handler(conn: socket.socket) -> None:
        record = read_hello(conn)
        try:
            hello = check_client_hello(SECRET.key, SECRET.host, record)
        except (ValueError, AssertionError):
            conn.sendall(b"\x15\x03\x03\x00\x02\x02\x28")  # what a real server would say
            return
        if hello["session_id"] in seen:
            conn.sendall(b"\x15\x03\x03\x00\x02\x02\x28")
            return
        seen.add(hello["session_id"])
        conn.sendall(server_flight(SECRET.key, hello))

    return handler


@pytest.fixture
def server(request):
    servers = []
    STOP.clear()

    def start(handler):
        srv = Server(handler)
        servers.append(srv)
        return srv

    yield start
    STOP.set()
    for srv in servers:
        srv.close()


def test_valid_secret_is_proxy(server):
    srv = server(fake_proxy())
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.PROXY


def test_wrong_secret_is_fronted(server):
    srv = server(fake_proxy())
    other = Secret(key=bytes(16), host=SECRET.host)
    assert probe.faketls_probe("127.0.0.1", srv.port, other).verdict == probe.FRONTED


def test_clock_skew_is_fronted(server):
    srv = server(fake_proxy())
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET, time_offset=3600).verdict == probe.FRONTED


def test_replay_is_detected(server):
    srv = server(fake_proxy())
    result = probe.replay_probe("127.0.0.1", srv.port, SECRET)
    assert result.verdict == probe.FRONTED
    assert result.data == {"first": probe.PROXY, "second": probe.FRONTED}


def test_replay_accepted_is_reported(server):
    always_new: set[bytes] = set()

    def forgetful(conn):
        always_new.clear()
        fake_proxy(always_new)(conn)

    srv = server(forgetful)
    assert probe.replay_probe("127.0.0.1", srv.port, SECRET).verdict == probe.PROXY


def test_immediate_close_is_closed(server):
    srv = server(lambda conn: None)
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.CLOSED


def test_regular_tls_flight_is_fronted(server):
    def tls_like(conn):
        read_hello(conn)
        hello = b"\x02\x00\x00\x46\x03\x03" + bytes(70)
        conn.sendall(b"\x16\x03\x03" + len(hello).to_bytes(2, "big") + hello)
        conn.sendall(b"\x14\x03\x03\x00\x01\x01\x17\x03\x03\x00\x04abcd")

    srv = server(tls_like)
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.FRONTED


def test_refused_port_is_error():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    assert probe.faketls_probe("127.0.0.1", port, SECRET, timeout=2).verdict == probe.ERROR


def test_plaintext_probe_reads_http(server):
    def http(conn):
        conn.recv(4096)
        conn.sendall(b"HTTP/1.0 400 Bad Request\r\n\r\nClient sent an HTTP request to an HTTPS server.\n")

    srv = server(http)
    result = probe.plaintext_probe("127.0.0.1", srv.port)
    assert result.verdict == probe.FRONTED
    assert result.detail.startswith("HTTP/1.0 400")


@pytest.fixture(scope="module")
def tls_cert(tmp_path_factory) -> tuple[Path, Path]:
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, SECRET.host)])
    now = datetime.now(UTC)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(SECRET.host)]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    directory = tmp_path_factory.mktemp("tls")
    cert_path, key_path = directory / "cert.pem", directory / "key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    return cert_path, key_path


def https_server(server, cert: Path, key: Path):
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(cert, key)

    def handler(conn):
        with context.wrap_socket(conn, server_side=True) as tls:
            tls.recv(4096)
            tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello notes")

    return server(handler)


def test_https_probe_with_trusted_ca(server, tls_cert):
    srv = https_server(server, *tls_cert)
    result = probe.https_probe("127.0.0.1", srv.port, SECRET.host, cafile=str(tls_cert[0]))
    assert result.verdict == probe.FRONTED
    assert result.data["status"] == 200
    assert result.data["body"] == "hello notes"


def test_https_probe_rejects_untrusted_cert(server, tls_cert):
    srv = https_server(server, *tls_cert)
    result = probe.https_probe("127.0.0.1", srv.port, SECRET.host)
    assert result.verdict == probe.ERROR
    assert "certificate" in result.detail


def test_https_probe_insecure(server, tls_cert):
    srv = https_server(server, *tls_cert)
    assert probe.https_probe("127.0.0.1", srv.port, SECRET.host, insecure=True).data["status"] == 200


def test_cli_exit_codes(server):
    srv = server(fake_proxy())
    env = {"BURROWRS_SECRET": SECRET.hex(), "PATH": "/usr/local/bin:/usr/bin:/bin"}
    base = ["python", "-m", "burrowrs_tools", "probe", "--host", "127.0.0.1", "--port", str(srv.port)]
    assert subprocess.run(base, env=env, check=False, capture_output=True).returncode == 0
    failing = subprocess.run([*base, "--expect", "fronted"], env=env, check=False, capture_output=True)
    assert failing.returncode == 1
    assert b"FAIL faketls: proxy" in failing.stdout


# --- hostile and quirky servers (burrowrs smoke --link can point anywhere) ----


def valid_flight_then(after: Callable[[socket.socket], None]) -> Callable[[socket.socket], None]:
    def handler(conn: socket.socket) -> None:
        hello = check_client_hello(SECRET.key, SECRET.host, read_hello(conn))
        conn.sendall(server_flight(SECRET.key, hello))
        after(conn)

    return handler


def test_endless_empty_records_cannot_stall_the_telegram_probe(server):
    def flood(conn):
        while True:
            conn.sendall(app_record(b"") * 256)

    srv = server(valid_flight_then(flood))
    started = time.monotonic()
    result = probe.telegram_probe("127.0.0.1", srv.port, SECRET, timeout=3)
    assert result.verdict == probe.ERROR
    assert "without any data" in result.detail
    assert time.monotonic() - started < 3.5


def test_slow_drip_is_bounded_by_the_overall_budget(server):
    def drip(conn):
        read_hello(conn)
        for byte in b"\x16\x03\x03\x00\x20" + bytes(32):
            conn.sendall(bytes([byte]))
            time.sleep(0.4)

    srv = server(drip)
    started = time.monotonic()
    result = probe.faketls_probe("127.0.0.1", srv.port, SECRET, timeout=1.5)
    assert result.verdict in (probe.ERROR, probe.FRONTED)
    assert time.monotonic() - started < 2.5


def test_header_then_close_is_fronted_not_closed(server):
    def header_only(conn):
        read_hello(conn)
        conn.sendall(b"\x16\x03\x03\x00\x40")

    srv = server(header_only)
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.FRONTED


def reset(conn: socket.socket) -> None:
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()


def test_server_hello_then_reset_is_fronted(server):
    def hello_then_reset(conn):
        read_hello(conn)
        body = b"\x02\x00\x00\x46\x03\x03" + bytes(70)
        conn.sendall(b"\x16\x03\x03" + struct.pack(">H", len(body)) + body + b"\x14\x03")
        time.sleep(0.1)
        reset(conn)

    srv = server(hello_then_reset)
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.FRONTED


def test_partial_flight_then_silence_is_fronted_quickly(server):
    def hello_retry_and_wait(conn):
        read_hello(conn)
        body = b"\x02\x00\x00\x46\x03\x03" + bytes(70)
        conn.sendall(b"\x16\x03\x03" + struct.pack(">H", len(body)) + body + b"\x14\x03\x03\x00\x01\x01")
        STOP.wait(8)

    srv = server(hello_retry_and_wait)
    started = time.monotonic()
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET, timeout=6).verdict == probe.FRONTED
    assert time.monotonic() - started < faketls.FLIGHT_FOLLOW_UP + 1


def test_replay_is_inconclusive_if_the_first_attempt_failed(server):
    attempts = []

    def flaky_first(conn):
        attempts.append(1)
        if len(attempts) == 1:
            return  # dropped before the proxy could remember the hello
        fake_proxy()(conn)

    srv = server(flaky_first)
    result = probe.replay_probe("127.0.0.1", srv.port, SECRET)
    assert result.verdict == probe.ERROR
    assert "inconclusive" in result.detail


def test_telegram_round_trip_through_a_fake_relay(server):
    """The whole client path: FakeTLS, obfuscated2, padded intermediate, resPQ."""
    seen = {}

    def relay(conn):
        hello = check_client_hello(SECRET.key, SECRET.host, read_hello(conn))
        conn.sendall(server_flight(SECRET.key, hello))
        buffer = bytearray()

        def read_app(size):
            while len(buffer) < size:
                record = read_hello(conn)  # same 5-byte header framing
                if record[0] == 0x17:
                    buffer.extend(record[5:])
            data = bytes(buffer[:size])
            del buffer[:size]
            return data

        obf = ServerObfuscation(SECRET.key, read_app(64))
        seen["tag"], seen["dc"] = obf.tag, obf.dc
        length = int.from_bytes(obf.recv.update(read_app(4)), "little")
        request = obf.recv.update(read_app(length))
        nonce = request[24:40]
        answer = res_pq_packet(nonce, bytes(16), b"\x17\xed\x48\x94\x1a\x08\xf9\x81", [7, 8])
        packet = obf.send.update(struct.pack("<I", len(answer)) + answer)
        # Split across records, with an empty record in between, like a real relay may.
        conn.sendall(app_record(packet[:10]) + app_record(b"") + app_record(packet[10:]))

    srv = server(relay)
    result = probe.telegram_probe("127.0.0.1", srv.port, SECRET, dc=4)
    assert result.verdict == probe.PROXY, result.detail
    assert result.data["fingerprints"] == 2
    assert seen == {"tag": b"\xdd\xdd\xdd\xdd", "dc": 4}


def http_server(server, response: bytes, *, then: Callable[[socket.socket], None] | None = None):
    def handler(conn):
        conn.recv(4096)
        conn.sendall(response)
        if then:
            then(conn)

    return server(handler)


def test_plaintext_keeps_the_answer_when_the_server_then_resets(server):
    srv = http_server(server, b"HTTP/1.1 400 Bad Request\r\n\r\n", then=lambda c: (time.sleep(0.1), reset(c)))
    result = probe.plaintext_probe("127.0.0.1", srv.port)
    assert result.verdict == probe.FRONTED
    assert result.data["status"] == 400


def test_plaintext_server_that_keeps_the_connection_open(server):
    srv = http_server(server, b"HTTP/1.1 400 Bad Request\r\n\r\n", then=lambda c: STOP.wait(5))
    started = time.monotonic()
    result = probe.plaintext_probe("127.0.0.1", srv.port, timeout=1)
    assert result.verdict == probe.FRONTED
    assert time.monotonic() - started < 2


def test_https_keep_alive_response_counts(server, tls_cert):
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(*tls_cert)

    def handler(conn):
        with context.wrap_socket(conn, server_side=True) as tls:
            tls.recv(4096)
            tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            STOP.wait(5)  # ignores Connection: close

    srv = server(handler)
    result = probe.https_probe("127.0.0.1", srv.port, SECRET.host, insecure=True, timeout=1.5)
    assert result.verdict == probe.FRONTED
    assert result.data["status"] == 200


def test_https_non_ascii_status_does_not_crash(server, tls_cert):
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(*tls_cert)

    def handler(conn):
        with context.wrap_socket(conn, server_side=True) as tls:
            tls.recv(4096)
            tls.sendall("HTTP/1.1 ² OK\r\n\r\n".encode("latin-1"))

    srv = server(handler)
    result = probe.https_probe("127.0.0.1", srv.port, SECRET.host, insecure=True)
    assert result.verdict == probe.FRONTED
    assert result.data["status"] == 0


def test_https_missing_cafile_is_a_verdict_not_a_crash():
    result = probe.https_probe("127.0.0.1", 9, SECRET.host, cafile="/nonexistent/ca.pem")
    assert result.verdict == probe.ERROR


def test_cli_neutralises_terminal_escapes(server):
    evil = b"\x1b]0;pwned\x07\x1b[2K\rPASS all good\r\n\r\n"
    srv = http_server(server, evil)
    env = {"PATH": "/usr/local/bin:/usr/bin:/bin"}
    out = subprocess.run(
        [
            "python",
            "-m",
            "burrowrs_tools",
            "plaintext",
            "--host",
            "127.0.0.1",
            "--port",
            str(srv.port),
            "--expect-status",
            "200",
        ],
        env=env,
        check=False,
        capture_output=True,  # bytes: text mode would turn \r into \n
    )
    assert out.returncode == 1
    assert b"\x1b" not in out.stdout and b"\r" not in out.stdout
    assert out.stdout.startswith(b"FAIL plaintext:")


@pytest.fixture
def blackhole():
    """An address whose connects hang: a listener with a full accept queue."""
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(0)
    fillers = []
    for _ in range(3):
        filler = socket.socket()
        filler.setblocking(False)
        with contextlib.suppress(BlockingIOError):
            filler.connect(listener.getsockname())
        fillers.append(filler)
    time.sleep(0.2)
    yield listener.getsockname()
    for sock in [*fillers, listener]:
        sock.close()


def test_a_blackholed_address_cannot_use_up_the_connect_budget(server, blackhole, monkeypatch):
    """Like an AAAA record whose port 443 is firewalled, listed before a working A record."""
    srv = server(fake_proxy())
    real = socket.getaddrinfo

    def two_addresses(host, port, *args, **kwargs):
        live = real("127.0.0.1", srv.port, *args, **kwargs)[0]
        dead = (live[0], live[1], live[2], live[3], blackhole)
        return [dead, live]

    monkeypatch.setattr(socket, "getaddrinfo", two_addresses)
    started = time.monotonic()
    result = probe.faketls_probe("proxy.invalid", srv.port, SECRET, timeout=2)
    assert result.verdict == probe.PROXY, result.detail
    assert time.monotonic() - started < 3


@pytest.mark.parametrize("flag", ["--timeout", "--retry-delay"])
@pytest.mark.parametrize("value", ["inf", "nan", "-1", "1e10"])
def test_time_arguments_are_bounded(flag, value):
    with pytest.raises(SystemExit) as exc:
        main(["probe", "--host", "127.0.0.1", flag, value])
    assert exc.value.code == 2
