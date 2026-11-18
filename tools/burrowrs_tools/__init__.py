"""burrowrs-tools: probes, smoke checks and QR codes for a burrowrs MTProto proxy.

Everything in here is a *client*. The proxy itself is telemt
(https://github.com/telemt/telemt); this package only talks to it the same way
a Telegram app or a censor's active prober would, so the tests exercise the
real wire protocol end to end. The one exception is ``usage``, which reads
telemt's read-only control API.
"""

__version__ = "1.0.1"
