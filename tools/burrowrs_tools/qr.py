"""Offline QR codes for share links.

A QR code made by a public QR-rendering API would hand your proxy secret to
a third party. burrowrs renders them locally instead.
"""

from __future__ import annotations

import io

import segno


def make(text: str) -> segno.QRCode:
    if not text.strip():
        raise ValueError("nothing to encode")
    return segno.make(text.strip(), error="m", micro=False)


def terminal(code: segno.QRCode) -> str:
    out = io.StringIO()
    code.terminal(out=out, compact=True, border=2)
    return out.getvalue()


def render(code: segno.QRCode, kind: str, *, scale: int = 8) -> bytes:
    """PNG or SVG bytes. The caller decides where they go (and their permissions)."""
    if kind not in ("png", "svg"):
        raise ValueError(f"unsupported QR format: {kind}")
    out = io.BytesIO()
    code.save(out, kind=kind, scale=scale, border=4, dark="#1d1b26", light="#ffffff")
    return out.getvalue()
