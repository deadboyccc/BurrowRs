"""Parsing and formatting of FakeTLS ("ee") MTProto proxy secrets.

Wire layout of a FakeTLS secret::

    0xee | 16-byte key | fronting hostname (ASCII)

It is shared either as lowercase hex (``ee…``) or as unpadded base64url.
Only the 16-byte key is used in the cryptography; the hostname is what the
client puts in the TLS SNI extension.
"""

from __future__ import annotations

import base64
import binascii
import re
from dataclasses import dataclass, field

FAKETLS_MARKER = 0xEE
KEY_LEN = 16

_HOSTNAME_RE = re.compile(r"^(?=.{1,253}$)(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))*$")


class SecretError(ValueError):
    """Raised when a secret cannot be parsed."""


@dataclass(frozen=True)
class Secret:
    key: bytes = field(repr=False)  # never print the key, even in a traceback
    host: str

    def __post_init__(self) -> None:
        if len(self.key) != KEY_LEN:
            raise SecretError(f"key must be {KEY_LEN} bytes, got {len(self.key)}")
        if not _HOSTNAME_RE.fullmatch(self.host):
            raise SecretError(f"invalid fronting hostname: {self.host!r}")

    @classmethod
    def parse(cls, text: str) -> Secret:
        text = text.strip()
        if not text:
            raise SecretError("empty secret")

        raw = _decode(text)
        if not raw or raw[0] != FAKETLS_MARKER:
            raise SecretError(
                "only FakeTLS secrets (starting with 'ee') are supported; "
                "plain and 'dd' secrets are trivially detectable"
            )
        if len(raw) < 1 + KEY_LEN + 1:
            raise SecretError("secret is too short")

        try:
            host = raw[1 + KEY_LEN :].decode("ascii")
        except UnicodeDecodeError as exc:
            raise SecretError("hostname part is not ASCII") from exc

        return cls(key=raw[1 : 1 + KEY_LEN], host=host)

    def to_bytes(self) -> bytes:
        return bytes([FAKETLS_MARKER]) + self.key + self.host.encode("ascii")

    def hex(self) -> str:
        return self.to_bytes().hex()

    def base64(self) -> str:
        return base64.urlsafe_b64encode(self.to_bytes()).rstrip(b"=").decode("ascii")


def _decode(text: str) -> bytes:
    if re.fullmatch(r"(?:[0-9a-fA-F]{2})+", text):
        return binascii.unhexlify(text)

    padded = text + "=" * (-len(text) % 4)
    try:
        # Links use base64url, but be lenient and accept standard base64 too.
        return base64.b64decode(padded.replace("-", "+").replace("_", "/"), validate=True)
    except binascii.Error as exc:
        raise SecretError("secret is neither hex nor base64") from exc
