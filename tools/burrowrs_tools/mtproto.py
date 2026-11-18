"""The smallest useful MTProto exchange: ``req_pq_multi`` → ``resPQ``.

This is the first message of Telegram's auth-key handshake. It is
unencrypted, needs no account and no API keys, and gets a reply only from a
real Telegram data centre. That makes it a good end-to-end check that the proxy
really relays traffic to Telegram.
"""

from __future__ import annotations

import os
import struct
import time
from dataclasses import dataclass

from .faketls import RandomSource

REQ_PQ_MULTI = 0xBE7E8EF1
RES_PQ = 0x05162463
VECTOR = 0x1CB5C415

_HEADER = struct.Struct("<qqi")  # auth_key_id, message_id, message_length


class MTProtoError(Exception):
    """Telegram answered with something other than a valid resPQ."""


@dataclass(frozen=True)
class ResPQ:
    nonce: bytes
    server_nonce: bytes
    pq: bytes
    fingerprints: tuple[int, ...]


def message_id(now: float | None = None) -> int:
    """Client message ids are roughly unixtime * 2^32 and divisible by 4."""
    value = int((time.time() if now is None else now) * 2**32)
    return value - value % 4


def build_req_pq_multi(nonce: bytes, now: float | None = None) -> bytes:
    if len(nonce) != 16:
        raise ValueError("nonce must be 16 bytes")
    body = struct.pack("<I", REQ_PQ_MULTI) + nonce
    return _HEADER.pack(0, message_id(now), len(body)) + body


def wrap_padded_intermediate(payload: bytes, rand: RandomSource = os.urandom) -> bytes:
    padding = rand(rand(1)[0] % 16)
    return struct.pack("<I", len(payload) + len(padding)) + payload + padding


def _tl_bytes(data: bytes, offset: int) -> tuple[bytes, int]:
    first = data[offset]
    if first < 254:
        length, start = first, offset + 1
    else:
        length, start = int.from_bytes(data[offset + 1 : offset + 4], "little"), offset + 4
    end = start + length
    if end > len(data):
        raise MTProtoError("truncated TL bytes")
    consumed = end - offset
    return data[start:end], offset + consumed + (-consumed % 4)


def parse_res_pq(packet: bytes, nonce: bytes) -> ResPQ:
    if len(packet) == 4:
        code = struct.unpack("<i", packet)[0]
        raise MTProtoError(f"Telegram transport error {code}")
    if len(packet) < _HEADER.size + 4:
        raise MTProtoError(f"response too short ({len(packet)} bytes)")

    auth_key_id, _msg_id, length = _HEADER.unpack_from(packet)
    if auth_key_id != 0:
        raise MTProtoError("expected an unencrypted message")
    body = packet[_HEADER.size : _HEADER.size + length]

    try:
        (constructor,) = struct.unpack_from("<I", body)
        if constructor != RES_PQ:
            raise MTProtoError(f"unexpected constructor {constructor:#010x}")
        if body[4:20] != nonce:
            raise MTProtoError("nonce mismatch: the reply is not for our request")
        server_nonce = body[20:36]
        pq, offset = _tl_bytes(body, 36)
        vector_ctor, count = struct.unpack_from("<Ii", body, offset)
        if vector_ctor != VECTOR:
            raise MTProtoError("malformed fingerprint vector")
        fingerprints = struct.unpack_from(f"<{count}q", body, offset + 8)
    except (struct.error, IndexError) as exc:
        raise MTProtoError(f"malformed resPQ: {exc}") from exc

    return ResPQ(nonce=nonce, server_nonce=server_nonce, pq=pq, fingerprints=tuple(fingerprints))
