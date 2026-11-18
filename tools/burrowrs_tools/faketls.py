"""Client side of MTProto FakeTLS, as implemented by Telegram apps and FakeTLS proxies.

The client sends something that is byte-for-byte a normal TLS 1.3
ClientHello, except that its 32-byte "random" field is an HMAC:

    random = HMAC-SHA256(key, hello_with_zeroed_random) XOR (0 * 28 || le32(unix_time))

The proxy recomputes the HMAC. If it matches (and the timestamp is fresh and
not replayed), it answers with a ServerHello whose random is::

    HMAC-SHA256(key, client_random || server_flight_with_zeroed_random)

Anything else (scanners, browsers, censors' probes) is spliced to the
fronting web server untouched, so they see an ordinary HTTPS site.

After the handshake both sides wrap the obfuscated2 stream in TLS
ApplicationData records (type 0x17).
"""

from __future__ import annotations

import hashlib
import hmac
import os
import socket
import struct
import time
from collections.abc import Callable
from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

RECORD_CHANGE_CIPHER_SPEC = 0x14
RECORD_ALERT = 0x15
RECORD_HANDSHAKE = 0x16
RECORD_APPLICATION_DATA = 0x17

HANDSHAKE_CLIENT_HELLO = 0x01
HANDSHAKE_SERVER_HELLO = 0x02

RECORD_HEADER_LEN = 5
RANDOM_LEN = 32
# record type(1) + version(2) + length(2) + handshake type(1) + uint24 length(3) + version(2)
RANDOM_OFFSET = 11
# Proxies reject records larger than TLS allows (mtg: payload over 16384 - header).
MAX_RECORD_PAYLOAD = 16384 - RECORD_HEADER_LEN
# Chrome pads its ClientHello handshake message to 512 bytes.
CLIENT_HELLO_TARGET_LEN = 512

CHANGE_CIPHER_SPEC_RECORD = bytes([RECORD_CHANGE_CIPHER_SPEC, 0x03, 0x03, 0x00, 0x01, 0x01])

_GREASE = tuple(0x0A0A + 0x1010 * i for i in range(16))

RandomSource = Callable[[int], bytes]


class FakeTLSError(Exception):
    """The peer did not behave like a FakeTLS proxy."""


@dataclass(frozen=True)
class Record:
    type: int
    payload: bytes
    raw: bytes


def _u8(value: int) -> bytes:
    return struct.pack(">B", value)


def _u16(value: int) -> bytes:
    return struct.pack(">H", value)


def _u24(value: int) -> bytes:
    return struct.pack(">I", value)[1:]


def _vec16(body: bytes) -> bytes:
    return _u16(len(body)) + body


def _ext(ext_type: int, body: bytes = b"") -> bytes:
    return _u16(ext_type) + _vec16(body)


def _grease(rand: RandomSource) -> int:
    return _GREASE[rand(1)[0] % len(_GREASE)]


def _x25519_public_key() -> bytes:
    return X25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def build_client_hello(
    key: bytes,
    hostname: str,
    *,
    timestamp: int | None = None,
    session_id: bytes | None = None,
    rand: RandomSource = os.urandom,
) -> tuple[bytes, bytes]:
    """Build a browser-like FakeTLS ClientHello record.

    Returns ``(record_bytes, client_random)``.
    """
    if timestamp is None:
        timestamp = int(time.time())
    if session_id is None:
        session_id = rand(32)

    grease_cipher, grease_ext1, grease_group, grease_ext2, grease_version = (_grease(rand) for _ in range(5))
    if grease_ext2 == grease_ext1:  # duplicate extension types are illegal
        grease_ext2 = _GREASE[(_GREASE.index(grease_ext1) + 1) % len(_GREASE)]

    host = hostname.encode("ascii")
    ciphers = [
        grease_cipher,
        0x1301,
        0x1302,
        0x1303,
        0xC02B,
        0xC02F,
        0xC02C,
        0xC030,
        0xCCA9,
        0xCCA8,
        0xC013,
        0xC014,
        0x009C,
        0x009D,
        0x002F,
        0x0035,
    ]
    sig_algs = [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601]

    extensions = b"".join(
        [
            _ext(grease_ext1),
            _ext(0x0000, _vec16(b"\x00" + _vec16(host))),  # server_name
            _ext(0x0017),  # extended_master_secret
            _ext(0xFF01, b"\x00"),  # renegotiation_info
            _ext(0x000A, _vec16(b"".join(_u16(g) for g in (grease_group, 0x001D, 0x0017, 0x0018)))),
            _ext(0x000B, b"\x01\x00"),  # ec_point_formats: uncompressed
            _ext(0x0023),  # session_ticket
            _ext(0x0010, _vec16(b"\x02h2\x08http/1.1")),  # ALPN
            _ext(0x0005, b"\x01\x00\x00\x00\x00"),  # status_request (OCSP)
            _ext(0x000D, _vec16(b"".join(_u16(a) for a in sig_algs))),
            _ext(0x0012),  # signed_certificate_timestamp
            _ext(
                0x0033,  # key_share
                _vec16(_u16(grease_group) + _vec16(b"\x00") + _u16(0x001D) + _vec16(_x25519_public_key())),
            ),
            _ext(0x002D, b"\x01\x01"),  # psk_key_exchange_modes: psk_dhe_ke
            _ext(0x002B, _u8(6) + _u16(grease_version) + b"\x03\x04\x03\x03"),  # supported_versions
            _ext(0x001B, b"\x02\x00\x02"),  # compress_certificate: brotli
            _ext(grease_ext2, b"\x00"),
        ]
    )

    def body_with(padding_ext: bytes) -> bytes:
        return b"".join(
            [
                b"\x03\x03",  # legacy_version: TLS 1.2
                bytes(RANDOM_LEN),  # random, filled in after the HMAC
                _u8(len(session_id)) + session_id,
                _vec16(b"".join(_u16(c) for c in ciphers)),
                b"\x01\x00",  # compression methods: null
                _vec16(extensions + padding_ext),
            ]
        )

    unpadded = 4 + len(body_with(b""))  # 4 = handshake type + uint24 length
    pad_len = max(0, CLIENT_HELLO_TARGET_LEN - unpadded - 4)  # 4 = extension header
    body = body_with(_ext(0x0015, bytes(pad_len)))

    handshake = _u8(HANDSHAKE_CLIENT_HELLO) + _u24(len(body)) + body
    record = bytearray(_u8(RECORD_HANDSHAKE) + b"\x03\x01" + _vec16(handshake))

    digest = hmac.new(key, bytes(record), hashlib.sha256).digest()
    mask = bytes(RANDOM_LEN - 4) + struct.pack("<I", timestamp & 0xFFFFFFFF)
    client_random = bytes(d ^ m for d, m in zip(digest, mask, strict=True))
    record[RANDOM_OFFSET : RANDOM_OFFSET + RANDOM_LEN] = client_random

    return bytes(record), client_random


def verify_server_flight(key: bytes, client_random: bytes, flight: bytes) -> bool:
    """Check the HMAC a FakeTLS proxy puts in its ServerHello random."""
    if len(flight) < RANDOM_OFFSET + RANDOM_LEN:
        return False

    server_random = flight[RANDOM_OFFSET : RANDOM_OFFSET + RANDOM_LEN]
    zeroed = flight[:RANDOM_OFFSET] + bytes(RANDOM_LEN) + flight[RANDOM_OFFSET + RANDOM_LEN :]
    expected = hmac.new(key, client_random + zeroed, hashlib.sha256).digest()

    return hmac.compare_digest(expected, server_random)


class ConnectionClosed(EOFError):
    """The peer closed the connection before sending everything we needed.

    ``received`` counts every byte of the current TLS record that did arrive,
    so callers can tell "said nothing" (0) from "said something, then hung up".
    """

    def __init__(self, received: int, expected: int) -> None:
        super().__init__(f"connection closed after {received}/{expected} bytes")
        self.received = received
        self.expected = expected


class Deadline:
    """One time budget for a whole probe, applied before every blocking call.

    A per-call socket timeout is not enough: a hostile server can drip one
    byte just before each timeout and keep a probe busy forever.
    """

    def __init__(self, seconds: float) -> None:
        self.end = time.monotonic() + seconds

    def remaining(self) -> float:
        return self.end - time.monotonic()

    def apply(self, sock: socket.socket) -> None:
        left = self.remaining()
        if left <= 0:
            raise TimeoutError("probe time budget exhausted")
        sock.settimeout(left)

    def within(self, seconds: float) -> Deadline:
        """A deadline that ends after ``seconds`` or with this one, whichever is first."""
        tighter = Deadline(0)
        tighter.end = min(self.end, time.monotonic() + seconds)
        return tighter


def recv_exact(sock: socket.socket, size: int, deadline: Deadline | None = None) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        if deadline is not None:
            deadline.apply(sock)
        try:
            chunk = sock.recv(size - len(chunks))
        except ConnectionResetError as exc:
            if chunks:
                raise ConnectionClosed(len(chunks), size) from exc
            raise
        if not chunk:
            raise ConnectionClosed(len(chunks), size)
        chunks.extend(chunk)
    return bytes(chunks)


def read_record(sock: socket.socket, deadline: Deadline | None = None) -> Record:
    header = recv_exact(sock, RECORD_HEADER_LEN, deadline)
    if header[1] != 0x03:
        raise FakeTLSError(f"not a TLS record: {header.hex()}")
    length = struct.unpack(">H", header[3:5])[0]
    try:
        payload = recv_exact(sock, length, deadline)
    except ConnectionClosed as exc:
        raise ConnectionClosed(RECORD_HEADER_LEN + exc.received, RECORD_HEADER_LEN + length) from exc
    except ConnectionResetError as exc:
        raise ConnectionClosed(RECORD_HEADER_LEN, RECORD_HEADER_LEN + length) from exc
    return Record(type=header[0], payload=payload, raw=header + payload)


# A real FakeTLS proxy writes its whole flight at once. Anything slower than
# this after the first record is a regular TLS server waiting for us.
FLIGHT_FOLLOW_UP = 2.0


def read_server_flight(sock: socket.socket, deadline: Deadline | None = None) -> list[Record]:
    """Read the 3-record flight a FakeTLS proxy sends: ServerHello, CCS, data.

    Raises :class:`ConnectionClosed` with ``received == 0`` only when the peer
    sent nothing at all. A flight cut short after the first record (closed,
    reset, garbage or silence) comes back truncated: that is still an answer,
    just not a proxy's answer.
    """
    records = [read_record(sock, deadline)]
    if records[0].type != RECORD_HANDSHAKE:
        return records
    rest = deadline.within(FLIGHT_FOLLOW_UP) if deadline is not None else Deadline(FLIGHT_FOLLOW_UP)
    try:
        for _ in range(2):
            records.append(read_record(sock, rest))
    except (ConnectionClosed, ConnectionResetError, TimeoutError, FakeTLSError):
        pass
    return records


def is_proxy_flight(key: bytes, client_random: bytes, records: list[Record]) -> bool:
    if [r.type for r in records] != [RECORD_HANDSHAKE, RECORD_CHANGE_CIPHER_SPEC, RECORD_APPLICATION_DATA]:
        return False
    if not records[0].payload or records[0].payload[0] != HANDSHAKE_SERVER_HELLO:
        return False
    return verify_server_flight(key, client_random, b"".join(r.raw for r in records))


class FakeTLSConnection:
    """Wraps a socket after a successful FakeTLS handshake."""

    # Records that carry no application data (empty, CCS, handshake) are
    # skipped, but only this many in a row: a hostile peer could otherwise
    # stream them forever.
    MAX_IDLE_RECORDS = 64

    def __init__(self, sock: socket.socket, deadline: Deadline | None = None) -> None:
        self.sock = sock
        self.deadline = deadline
        self._buffer = bytearray()
        self._sent_ccs = False

    def send(self, data: bytes) -> None:
        out = bytearray()
        if not self._sent_ccs:
            # Real clients send ChangeCipherSpec right before their first data record.
            out += CHANGE_CIPHER_SPEC_RECORD
            self._sent_ccs = True
        for offset in range(0, len(data), MAX_RECORD_PAYLOAD):
            chunk = data[offset : offset + MAX_RECORD_PAYLOAD]
            out += _u8(RECORD_APPLICATION_DATA) + b"\x03\x03" + _vec16(chunk)
        if self.deadline is not None:
            self.deadline.apply(self.sock)
        self.sock.sendall(bytes(out))

    def recv_exact(self, size: int) -> bytes:
        idle = 0
        while len(self._buffer) < size:
            record = read_record(self.sock, self.deadline)
            if record.type == RECORD_ALERT:
                raise FakeTLSError(f"peer sent TLS alert {record.payload.hex()}")
            if record.type == RECORD_APPLICATION_DATA and record.payload:
                self._buffer += record.payload
                idle = 0
                continue
            idle += 1
            if idle > self.MAX_IDLE_RECORDS:
                raise FakeTLSError(f"peer sent {idle} records without any data")
        data = bytes(self._buffer[:size])
        del self._buffer[:size]
        return data
