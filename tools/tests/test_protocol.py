"""Wire-level tests for the FakeTLS, obfuscated2 and MTProto client code."""

from __future__ import annotations

import os
import struct
import time

import pytest

from burrowrs_tools import faketls, mtproto
from burrowrs_tools.obfuscated2 import FORBIDDEN_PREFIXES, ObfuscatedStream, generate_frame

from .reference_server import ServerObfuscation, check_client_hello, res_pq_packet, server_flight

KEY = bytes.fromhex("00112233445566778899aabbccddeeff")
HOST = "notes.example.org"


class TestClientHello:
    def test_accepted_by_reference_server(self):
        record, client_random = faketls.build_client_hello(KEY, HOST)
        hello = check_client_hello(KEY, HOST, record)
        assert hello["random"] == client_random
        assert len(hello["session_id"]) == 32

    def test_looks_like_chrome(self):
        record, _ = faketls.build_client_hello(KEY, HOST)
        # Chrome pads the handshake message to 512 bytes: 517 on the wire.
        assert len(record) == 517
        assert b"\x02h2\x08http/1.1" in record
        assert HOST.encode() in record

    def test_timestamp_is_embedded(self):
        ts = int(time.time())
        record, _ = faketls.build_client_hello(KEY, HOST, timestamp=ts)
        assert check_client_hello(KEY, HOST, record)["timestamp"] == ts

    def test_wrong_key_is_rejected(self):
        record, _ = faketls.build_client_hello(os.urandom(16), HOST)
        with pytest.raises(ValueError, match="bad digest"):
            check_client_hello(KEY, HOST, record)

    def test_stale_timestamp_is_rejected(self):
        record, _ = faketls.build_client_hello(KEY, HOST, timestamp=int(time.time()) - 600)
        with pytest.raises(ValueError, match="stale"):
            check_client_hello(KEY, HOST, record)

    def test_first_non_grease_cipher_is_tls13(self):
        record, _ = faketls.build_client_hello(KEY, HOST)
        assert check_client_hello(KEY, HOST, record)["cipher"] == 0x1301

    def test_hellos_are_unique(self):
        a, _ = faketls.build_client_hello(KEY, HOST)
        b, _ = faketls.build_client_hello(KEY, HOST)
        assert a != b

    def test_long_hostname_needs_no_padding(self):
        host = ".".join(c * 60 for c in "abcd") + ".org"  # 247 characters
        record, _ = faketls.build_client_hello(KEY, host)
        assert len(record) > 517
        assert check_client_hello(KEY, host, record)


class TestServerFlight:
    def test_genuine_flight_verifies(self):
        record, client_random = faketls.build_client_hello(KEY, HOST)
        flight = server_flight(KEY, check_client_hello(KEY, HOST, record))
        assert faketls.verify_server_flight(KEY, client_random, flight)

    def test_tampered_flight_fails(self):
        record, client_random = faketls.build_client_hello(KEY, HOST)
        flight = bytearray(server_flight(KEY, check_client_hello(KEY, HOST, record)))
        flight[-1] ^= 1
        assert not faketls.verify_server_flight(KEY, client_random, bytes(flight))

    def test_other_key_fails(self):
        record, client_random = faketls.build_client_hello(KEY, HOST)
        flight = server_flight(KEY, check_client_hello(KEY, HOST, record))
        assert not faketls.verify_server_flight(os.urandom(16), client_random, flight)

    def test_short_flight_fails(self):
        assert not faketls.verify_server_flight(KEY, bytes(32), b"\x16\x03\x03")


class TestObfuscated2:
    def test_frame_constraints(self):
        for _ in range(2000):
            frame = generate_frame(2)
            assert frame[0] != 0xEF
            assert struct.unpack("<I", frame[:4])[0] not in FORBIDDEN_PREFIXES
            assert frame[4:8] != b"\x00\x00\x00\x00"
            assert frame[56:60] == b"\xdd\xdd\xdd\xdd"

    def test_forbidden_prefix_is_regenerated(self):
        frames = iter([b"HEAD" + os.urandom(60), b"\xef" + os.urandom(63), bytes(range(1, 65))])
        frame = generate_frame(2, rand=lambda n: next(frames))
        assert frame[:4] != b"HEAD" and frame[0] != 0xEF

    @pytest.mark.parametrize("dc", [1, 2, 5, -2, 203])
    def test_server_recovers_tag_and_dc(self, dc):
        stream = ObfuscatedStream(KEY, dc=dc)
        server = ServerObfuscation(KEY, stream.handshake)
        assert server.tag == b"\xdd\xdd\xdd\xdd"
        assert server.dc == dc

    @pytest.mark.parametrize("dc", [1 << 15, -(1 << 15) - 1])
    def test_dc_must_fit_int16(self, dc):
        with pytest.raises(ValueError, match="int16"):
            ObfuscatedStream(KEY, dc=dc)

    def test_both_directions_roundtrip(self):
        stream = ObfuscatedStream(KEY, dc=2)
        server = ServerObfuscation(KEY, stream.handshake)
        upstream = os.urandom(1000)
        assert server.recv.update(stream.encrypt(upstream)) == upstream
        downstream = os.urandom(1000)
        assert stream.decrypt(server.send.update(downstream)) == downstream

    def test_wrong_secret_garbles_tag(self):
        stream = ObfuscatedStream(KEY, dc=2)
        assert ServerObfuscation(os.urandom(16), stream.handshake).tag != b"\xdd\xdd\xdd\xdd"


class TestMTProto:
    def test_req_pq_multi_layout(self):
        nonce = os.urandom(16)
        msg = mtproto.build_req_pq_multi(nonce, now=1_700_000_000.5)
        auth_key_id, msg_id, length = struct.unpack("<qqi", msg[:20])
        assert auth_key_id == 0
        assert msg_id % 4 == 0 and msg_id >> 32 == 1_700_000_000
        assert length == 20
        assert struct.unpack("<I", msg[20:24])[0] == mtproto.REQ_PQ_MULTI
        assert msg[24:] == nonce

    def test_nonce_length_is_checked(self):
        with pytest.raises(ValueError):
            mtproto.build_req_pq_multi(b"short")

    def test_padded_intermediate(self):
        payload = os.urandom(40)
        for _ in range(50):
            packet = mtproto.wrap_padded_intermediate(payload)
            length = struct.unpack("<I", packet[:4])[0]
            assert length == len(packet) - 4
            assert 0 <= length - len(payload) < 16
            assert packet[4:44] == payload

    def test_parse_res_pq(self):
        nonce, server_nonce = os.urandom(16), os.urandom(16)
        res = mtproto.parse_res_pq(
            res_pq_packet(nonce, server_nonce, b"\x17\xed\x48\x94\x1a\x08\xf9\x81", [1, -2]), nonce
        )
        assert res.server_nonce == server_nonce
        assert res.pq == b"\x17\xed\x48\x94\x1a\x08\xf9\x81"
        assert res.fingerprints == (1, -2)

    def test_nonce_mismatch(self):
        packet = res_pq_packet(os.urandom(16), os.urandom(16), b"12345678", [1])
        with pytest.raises(mtproto.MTProtoError, match="nonce"):
            mtproto.parse_res_pq(packet, os.urandom(16))

    def test_transport_error(self):
        with pytest.raises(mtproto.MTProtoError, match="-404"):
            mtproto.parse_res_pq(struct.pack("<i", -404), os.urandom(16))

    def test_garbage(self):
        with pytest.raises(mtproto.MTProtoError):
            mtproto.parse_res_pq(os.urandom(64), os.urandom(16))
