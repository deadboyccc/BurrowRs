"""Client side of the MTProto "obfuscated2" transport used inside FakeTLS.

The client opens with a 64-byte frame. Bytes 8..56 seed two AES-256-CTR
streams (one per direction, the second from the reversed bytes); with a
proxy secret, each AES key is ``sha256(seed_key || secret_key)``. The last 8
bytes carry the encrypted transport tag and the target DC number.
Telegram apps use the padded-intermediate tag (0xdddddddd) in FakeTLS mode,
and some proxies (mtg) accept nothing else, so the probes use it too.
"""

from __future__ import annotations

import hashlib
import os
import struct

from cryptography.hazmat.primitives.ciphers import Cipher, CipherContext, algorithms, modes

from .faketls import RandomSource

FRAME_LEN = 64
TAG_PADDED_INTERMEDIATE = b"\xdd\xdd\xdd\xdd"

# First 4 bytes a frame must never start with, so it cannot be mistaken for
# HTTP, TLS, or the un-obfuscated MTProto transports.
FORBIDDEN_PREFIXES = frozenset(
    {
        0x44414548,  # HEAD
        0x54534F50,  # POST
        0x20544547,  # GET
        0x4954504F,  # OPTI
        0x02010316,  # TLS handshake
        0xDDDDDDDD,  # padded intermediate
        0xEEEEEEEE,  # intermediate
    }
)


def generate_frame(dc: int, rand: RandomSource = os.urandom) -> bytearray:
    if not -(1 << 15) <= dc < 1 << 15:
        raise ValueError(f"DC {dc} does not fit the protocol's int16 field")
    while True:
        frame = bytearray(rand(FRAME_LEN))
        if frame[0] == 0xEF:  # abridged transport marker
            continue
        if struct.unpack("<I", frame[:4])[0] in FORBIDDEN_PREFIXES:
            continue
        if frame[4:8] == b"\x00\x00\x00\x00":
            continue
        frame[56:60] = TAG_PADDED_INTERMEDIATE
        frame[60:62] = struct.pack("<h", dc)
        return frame


def _aes_ctr(key: bytes, iv: bytes) -> CipherContext:
    return Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()


class ObfuscatedStream:
    """Keeps the two AES-CTR keystreams of an obfuscated2 connection."""

    def __init__(self, secret_key: bytes, dc: int = 2, rand: RandomSource = os.urandom) -> None:
        frame = generate_frame(dc, rand)

        seed = bytes(frame[8:56])
        reversed_seed = seed[::-1]
        self._encryptor = _aes_ctr(hashlib.sha256(seed[:32] + secret_key).digest(), seed[32:48])
        self._decryptor = _aes_ctr(hashlib.sha256(reversed_seed[:32] + secret_key).digest(), reversed_seed[32:48])

        encrypted = self._encryptor.update(bytes(frame))
        self.handshake = bytes(frame[:56]) + encrypted[56:]
        self.dc = dc

    def encrypt(self, data: bytes) -> bytes:
        return self._encryptor.update(data)

    def decrypt(self, data: bytes) -> bytes:
        return self._decryptor.update(data)
