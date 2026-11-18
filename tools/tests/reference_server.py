"""Server-side reference logic for MTProto FakeTLS, used to check the client
implementation without a network.

Ported line by line from mtg v2.3.0 (mtglib/internal/tls/fake/
{client_side,server_side}.go and mtglib/obfuscation/obfuscator.go): an
independent server implementation of the same wire protocol that telemt,
burrowrs's proxy, speaks. The live end-to-end tests check the client against
telemt itself.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import struct
import time

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# Hard-coded from the server side rather than imported from the client, so a wrong client
# constant cannot be mirrored here and pass unnoticed.
RANDOM_OFFSET = 11  # record header (5) + handshake type (1) + length (3) + version (2)
RES_PQ = 0x05162463
VECTOR = 0x1CB5C415


def check_client_hello(key: bytes, hostname: str, record: bytes, tolerance: int = 5) -> dict:
    """Mirror of fake.ReadClientHello for an unfragmented hello."""
    assert record[0] == 0x16 and record[1:3] == b"\x03\x01", "record header"
    length = struct.unpack(">H", record[3:5])[0]
    assert len(record) == 5 + length, "record length"
    assert record[5] == 0x01, "handshake type"
    hs_len = int.from_bytes(record[6:9], "big")
    assert hs_len == length - 4, "handshake length"

    body = record[9:]
    random = body[2:34]
    sid_len = body[34]
    session_id = body[35 : 35 + sid_len]
    offset = 35 + sid_len
    (cs_len,) = struct.unpack(">H", body[offset : offset + 2])
    ciphers = [struct.unpack(">H", body[offset + 2 + i : offset + 4 + i])[0] for i in range(0, cs_len, 2)]
    cipher = next(c for c in ciphers if c & 0x0F0F != 0x0A0A)
    offset += 2 + cs_len
    offset += 1 + body[offset]  # compression methods
    (ext_len,) = struct.unpack(">H", body[offset : offset + 2])
    exts = body[offset + 2 : offset + 2 + ext_len]
    assert offset + 2 + ext_len == len(body), "extensions fill the body"

    names = []
    pos = 0
    while pos < len(exts):
        ext_type, elen = struct.unpack(">HH", exts[pos : pos + 4])
        data = exts[pos + 4 : pos + 4 + elen]
        pos += 4 + elen
        if ext_type == 0:
            assert data[2] == 0
            nlen = struct.unpack(">H", data[3:5])[0]
            names.append(data[5 : 5 + nlen].decode())
    assert hostname in names, f"SNI {names}"

    zeroed = record[:RANDOM_OFFSET] + bytes(32) + record[RANDOM_OFFSET + 32 :]
    computed = bytearray(hmac.new(key, zeroed, hashlib.sha256).digest())
    for i in range(32):
        computed[i] ^= random[i]
    if bytes(computed[:28]) != bytes(28):
        raise ValueError("bad digest")
    timestamp = struct.unpack("<I", bytes(computed[28:]))[0]
    if abs(time.time() - timestamp) > tolerance:
        raise ValueError("stale timestamp")
    return {"random": random, "session_id": session_id, "cipher": cipher, "timestamp": timestamp}


def server_flight(key: bytes, hello: dict) -> bytes:
    """Mirror of fake.SendServerHello."""
    hs_body = (
        b"\x03\x03"
        + bytes(32)
        + bytes([len(hello["session_id"])])
        + hello["session_id"]
        + struct.pack(">H", hello["cipher"])
        + bytes.fromhex("00002e002b0002030400330024001d0020")
        + os.urandom(32)
    )
    hs = b"\x02" + len(hs_body).to_bytes(3, "big") + hs_body
    packet = bytearray(b"\x16\x03\x03" + struct.pack(">H", len(hs)) + hs)
    packet += b"\x14\x03\x03\x00\x01\x01"
    noise = os.urandom(2500)
    packet += b"\x17\x03\x03" + struct.pack(">H", len(noise)) + noise
    digest = hmac.new(key, hello["random"] + bytes(packet), hashlib.sha256).digest()
    packet[RANDOM_OFFSET : RANDOM_OFFSET + 32] = digest
    return bytes(packet)


class ServerObfuscation:
    """Mirror of obfuscation.Obfuscator.ReadHandshake."""

    def __init__(self, key: bytes, frame: bytes) -> None:
        def ctr(k: bytes, iv: bytes):
            return Cipher(algorithms.AES(k), modes.CTR(iv)).encryptor()

        seed = frame[8:56]
        self.recv = ctr(hashlib.sha256(seed[:32] + key).digest(), seed[32:48])
        rev = seed[::-1]
        self.send = ctr(hashlib.sha256(rev[:32] + key).digest(), rev[32:48])
        decrypted = self.recv.update(frame)
        self.tag = decrypted[56:60]
        self.dc = struct.unpack("<h", decrypted[60:62])[0]


def res_pq_packet(nonce: bytes, server_nonce: bytes, pq: bytes, fingerprints: list[int]) -> bytes:
    """An unencrypted resPQ message, as a Telegram DC sends it."""
    pq_tl = bytes([len(pq)]) + pq
    pq_tl += bytes(-len(pq_tl) % 4)
    body = (
        struct.pack("<I", RES_PQ)
        + nonce
        + server_nonce
        + pq_tl
        + struct.pack("<Ii", VECTOR, len(fingerprints))
        + b"".join(struct.pack("<q", f) for f in fingerprints)
    )
    return struct.pack("<qqi", 0, 123 << 32, len(body)) + body


def app_record(payload: bytes) -> bytes:
    return b"\x17\x03\x03" + struct.pack(">H", len(payload)) + payload
