#!/usr/bin/env bats

setup() {
	load ../helpers
	load_libs
}

@test "key_new: 16 random bytes as 32 lowercase hex characters, never repeated" {
	a=$(key_new)
	b=$(key_new)
	[[ $a =~ ^[0-9a-f]{32}$ && $b =~ ^[0-9a-f]{32}$ && $a != "$b" ]]
}

@test "is_key: exactly 32 lowercase hex characters" {
	run is_key 00112233445566778899aabbccddeeff # gitleaks:allow (fake fixture)
	assert_success
	for k in "" 0011 00112233445566778899AABBCCDDEEFF ee00112233445566778899aabbccddeeff \
		00112233445566778899aabbccddeef 00112233445566778899aabbccddeeff00 g0112233445566778899aabbccddeeff; do
		run is_key "$k"
		assert_failure
	done
}

@test "key_link_secret: ee + key + hex hostname" {
	run key_link_secret 00112233445566778899aabbccddeeff notes.example.org # gitleaks:allow (fake fixture)
	assert_success
	assert_output ee00112233445566778899aabbccddeeff6e6f7465732e6578616d706c652e6f7267 # gitleaks:allow (fake fixture)
}

@test "key_link_secret: refuses bad keys and hostnames" {
	run key_link_secret 0011 notes.example.org
	assert_failure
	run key_link_secret 00112233445566778899aabbccddeeff 'Bad Host' # gitleaks:allow (fake fixture)
	assert_failure
	run key_link_secret 00112233445566778899aabbccddeeff 203.0.113.7 # gitleaks:allow (fake fixture)
	assert_failure
}

@test "secret_host decodes the fronting hostname" {
	run secret_host "$(key_link_secret "$(key_new)" my-site.example.net)"
	assert_output my-site.example.net
	run secret_host dd00112233445566778899aabbccddeeff6162 # gitleaks:allow (fake fixture)
	assert_failure
}

@test "secret_is_valid" {
	run secret_is_valid "$(key_link_secret "$(key_new)" a.example.org)"
	assert_success
	for s in "" dd00112233445566778899aabbccddeeff 00112233445566778899aabbccddeeff \
		ee00112233445566778899aabbccddee "ee00112233445566778899aabbccddeeff$(hex_encode 'BAD HOST')" \
		EE00112233445566778899AABBCCDDEEFF6162; do
		run secret_is_valid "$s"
		assert_failure
	done
}

@test "hex encode/decode round trip" {
	run hex_encode "abc.example"
	assert_output 6162632e6578616d706c65
	run hex_decode 6162632e6578616d706c65
	assert_output abc.example
	run hex_decode zz
	assert_failure
}

@test "secret_redact never shows the key" {
	secret=ee00112233445566778899aabbccddeeff6162632e6f7267 # gitleaks:allow (test fixture, not a real secret)
	run secret_redact "$secret"
	assert_output "ee0011…7267"
	refute_output --partial 445566778899
}

@test "random_hex length and alphabet" {
	run random_hex 16
	assert_output --regexp '^[0-9a-f]{32}$'
}

@test "urlencode leaves unreserved characters and encodes the rest" {
	run urlencode "abc-._~XYZ019"
	assert_output "abc-._~XYZ019"
	run urlencode "2001:db8::1"
	assert_output "2001%3Adb8%3A%3A1"
	run urlencode "a b&c=d"
	assert_output "a%20b%26c%3Dd"
}

@test "links: tg:// and t.me formats" {
	run link_tg notes.example.org 443 ee00ff
	assert_output "tg://proxy?server=notes.example.org&port=443&secret=ee00ff"
	run link_tme 203.0.113.7 8443 ee00ff
	assert_output "https://t.me/proxy?server=203.0.113.7&port=8443&secret=ee00ff"
	run link_tg 2001:db8::1 443 ee00
	assert_output "tg://proxy?server=2001%3Adb8%3A%3A1&port=443&secret=ee00"
}

@test "version_ge compares dotted versions" {
	run version_ge 2.24.4 2.24.4
	assert_success
	run version_ge v5.7.1 2.24.4
	assert_success
	run version_ge 2.24.10 2.24.4
	assert_success
	run version_ge 2.23.9 2.24.4
	assert_failure
	run version_ge 2.3 2.24.4
	assert_failure
}

@test "free_port returns an unused high port" {
	run free_port
	assert_success
	assert_output --regexp '^[0-9]+$'
	((output >= 20000 && output < 60000))
}

@test "write_if_changed keeps the inode when nothing changed" {
	f=$BATS_TEST_TMPDIR/file
	printf 'one\n' | write_if_changed "$f" 644
	inode=$(stat -c %i "$f")
	printf 'one\n' | write_if_changed "$f" 644
	[[ $(stat -c %i "$f") == "$inode" ]]
	printf 'two\n' | write_if_changed "$f" 600
	[[ $(stat -c %i "$f") != "$inode" ]]
	[[ $(stat -c %a "$f") == 600 ]]
	[[ $(<"$f") == two ]]
}

@test "join_by" {
	run join_by ', ' a b c
	assert_output "a, b, c"
	run join_by ', '
	assert_output ""
}

@test "secret_normalize: hex in any case, base64 and base64url, padded or not" {
	hex=ee00112233445566778899aabbccddeeff6e6f7465732e6578616d706c652e6f7267 # gitleaks:allow (fake fixture)
	for s in "$hex" "${hex^^}" 7gARIjNEVWZ3iJmqu8zd7v9ub3Rlcy5leGFtcGxlLm9yZw \
		7gARIjNEVWZ3iJmqu8zd7v9ub3Rlcy5leGFtcGxlLm9yZw==; do
		run secret_normalize "$s"
		assert_success
		assert_output "$hex"
	done
}

@test "secret_normalize: rejects non-FakeTLS and malformed secrets" {
	# 3QAR... is the base64 of a legacy dd... secret.
	for s in "" 'bad!' 3QARIjNEVWZ3iJmqu8zd7v9ub3Rlcy5leGFtcGxlLm9yZw dd00112233445566778899aabbccddeeff ee00 ee0011; do
		run secret_normalize "$s"
		assert_failure
	done
}
