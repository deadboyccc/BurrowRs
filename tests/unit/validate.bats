#!/usr/bin/env bats

setup() {
	load ../helpers
	load_libs
}

@test "hostnames: accepts lowercase FQDNs" {
	for h in example.org notes.alice.dev a-b.c-d.io xn--80ak6aa92e.com "$(printf 'a%.0s' {1..63}).org"; do
		run is_hostname "$h"
		assert_success
	done
}

@test "hostnames: rejects everything else" {
	for h in "" localhost Example.org -a.org a-.org a..org .a.org a.org. "a b.org" 'a$.org' 1.2.3.4 \
		"$(printf 'a%.0s' {1..64}).org" "a.org;rm" 'a.org"' "a.org'"; do
		run is_hostname "$h"
		assert_failure
	done
}

@test "ipv4: valid and invalid" {
	for ip in 0.0.0.0 127.0.0.1 203.0.113.7 255.255.255.255; do
		run is_ipv4 "$ip"
		assert_success
	done
	for ip in "" 256.1.1.1 1.2.3 1.2.3.4.5 01.2.3.4 a.b.c.d " 1.2.3.4"; do
		run is_ipv4 "$ip"
		assert_failure
	done
}

@test "ipv6: valid and invalid" {
	for ip in ::1 2001:db8::1 fd42:7572:726f:77::10 2001:0db8:0000:0000:0000:0000:0000:0001; do
		run is_ipv6 "$ip"
		assert_success
	done
	for ip in "" 1.2.3.4 2001:db8:::1 1::2::3 'fe80::1%eth0' g::1; do
		run is_ipv6 "$ip"
		assert_failure
	done
}

@test "ports" {
	for p in 1 80 443 65535; do
		run is_port "$p"
		assert_success
	done
	for p in 0 65536 -1 "" 44a 080000; do
		run is_port "$p"
		assert_failure
	done
}

@test "cidrs" {
	run is_cidr4 10.204.47.0/28
	assert_success
	run is_cidr4 10.0.0.0/33
	assert_failure
	run is_cidr4 10.0.0.0
	assert_failure
	run is_cidr6 fd42:7761:7272:656e::/64
	assert_success
	run is_cidr6 fd42::/129
	assert_failure
}

@test "memory limits" {
	run is_mem 512m
	assert_success
	run is_mem 1g
	assert_success
	for v in 512mb 512 m 1.5g; do
		run is_mem "$v"
		assert_failure
	done
}

@test "urls: https, http and socks5" {
	run is_https_url https://acme-staging-v02.api.letsencrypt.org/directory
	assert_success
	run is_https_url 'https://a.org/x"y'
	assert_failure
	run is_https_url http://example.org/
	assert_failure
	run is_http_url http://example.org/list.netset
	assert_success
	run is_socks5_url socks5://user:pa55@10.0.0.2:1080
	assert_success
	run is_socks5_url socks5://10.0.0.2
	assert_failure
	run is_socks5_url 'socks5://u:p"@h:1'
	assert_failure
}

@test "enumerations" {
	run is_mode stealth
	assert_success
	run is_mode fast
	assert_failure
	run is_tls_mode internal
	assert_success
	run is_tls_mode letsencrypt
	assert_failure
	run is_bool true
	assert_success
	run is_bool yes
	assert_failure
}

@test "access modes: shared or users" {
	run is_access_mode shared
	assert_success
	run is_access_mode users
	assert_success
	for v in "" Shared user per-user all; do
		run is_access_mode "$v"
		assert_failure
	done
}

@test "usernames: small lowercase alphabet, up to 32 characters" {
	for n in alice bob2 a 0day mary.jane j_doe x-y "$(printf 'a%.0s' {1..32})"; do
		run is_username "$n"
		assert_success
	done
	# shellcheck disable=SC2016 # a literal $ is one of the rejected characters
	for n in "" Alice .alice -bob _x "a b" 'a"b' "a'b" 'a$b' 'a]b' 'a=b' a/b "$(printf 'a%.0s' {1..33})" $'a\tb'; do
		run is_username "$n"
		assert_failure
	done
}

@test "sizes: a whole number with K, M, G or T" {
	for v in 1K 500M 50G 2T 50g 999999G; do
		run is_size "$v"
		assert_success
	done
	for v in "" 0G 05G 50 50GB 1.5G -1G G 1000000G 50P; do
		run is_size "$v"
		assert_failure
	done
}

@test "utc times: exactly YYYY-MM-DDTHH:MM:SSZ with sane fields" {
	for t in 2026-12-31T23:59:59Z 2027-01-01T00:00:00Z 2026-02-28T12:30:00Z; do
		run is_utc_time "$t"
		assert_success
	done
	for t in "" 2026-12-31 2026-12-31T23:59:59 2026-12-31 23:59:59Z 2026-13-01T00:00:00Z 2026-00-10T00:00:00Z \
		2026-12-32T00:00:00Z 2026-12-00T00:00:00Z 2026-12-31T24:00:00Z 2026-12-31T23:60:00Z \
		2026-12-31T23:59:60Z 2026-12-31T23:59:59+00:00 never; do
		run is_utc_time "$t"
		assert_failure
	done
}

@test "dates: YYYY-MM-DD" {
	run is_date 2026-12-31
	assert_success
	for d in "" 2026-12-31T00:00:00Z 2026-13-01 2026-1-1 31-12-2026 tomorrow; do
		run is_date "$d"
		assert_failure
	done
}

@test "quota periods, ad tags and log levels" {
	for v in daily weekly monthly; do
		run is_quota_period "$v"
		assert_success
	done
	for v in "" none yearly Monthly; do
		run is_quota_period "$v"
		assert_failure
	done
	run is_ad_tag 00112233445566778899aabbccddeeff # gitleaks:allow (fake fixture)
	assert_success
	for v in "" 0011 00112233445566778899AABBCCDDEEFF 00112233445566778899aabbccddeeff00 zz112233445566778899aabbccddeeff; do
		run is_ad_tag "$v"
		assert_failure
	done
	for v in silent normal verbose debug; do
		run is_log_level "$v"
		assert_success
	done
	for v in "" info warn trace quiet; do
		run is_log_level "$v"
		assert_failure
	done
}

@test "absolute paths" {
	run is_abs_path /etc/burrowrs/block.netset
	assert_success
	for p in relative/path /a/../etc/shadow '/a b' '/a;b'; do
		run is_abs_path "$p"
		assert_failure
	done
}

@test "ipv6: strict group structure" {
	for ip in :: ::1 1:: 2001:db8:0:0:0:0:0:1 fe80::a:b:c:d; do
		run is_ipv6 "$ip"
		assert_success
	done
	for ip in : 1:2:3 1:2:3:4:5:6:7:8:9 :1:2:3:4:5:6:7 12345::1 1::2:3:4:5:6:7:8 ::ffff:1.2.3.4; do
		run is_ipv6 "$ip"
		assert_failure
	done
}

@test "counts are positive and TOML-safe" {
	run is_count 8192
	assert_success
	for v in 0 0123 -1 "" 1e3 99999999999; do
		run is_count "$v"
		assert_failure
	done
}
