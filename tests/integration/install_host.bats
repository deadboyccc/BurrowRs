#!/usr/bin/env bats
# scripts/install-host.sh, exercised in a throwaway Debian container in
# --dry-run mode, so no test ever modifies the machine running it.

DEBIAN_IMAGE=python:3.12-slim

setup() {
	load ../helpers
	require_docker
	docker image inspect "$DEBIAN_IMAGE" >/dev/null 2>&1 || docker pull -q "$DEBIAN_IMAGE" >/dev/null
}

in_debian() {
	docker run --rm --network none --memory 128m -v "$BURROWRS_ROOT:/burrowrs:ro" "$@"
}

@test "dry run on a bare Debian plans every step" {
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --dir /opt/burrowrs --ssh-port 2222
	assert_success
	assert_output --partial "download.docker.com"
	assert_output --partial "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
	assert_output --partial "/etc/sysctl.d/99-burrowrs.conf"
	assert_output --partial "ufw limit 2222/tcp"
	assert_output --partial "ufw allow 80/tcp"
	assert_output --partial "ufw allow 443/tcp"
	assert_output --partial "ufw --force enable"
	assert_output --partial "unattended-upgrades"
	assert_output --partial "systemctl enable --now burrowrs-watchdog.timer"
	assert_output --partial "host ready"
}

@test "SSH is allowed before the firewall is enabled" {
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 2222
	limit=$(grep -n 'ufw limit 2222/tcp' <<<"$output" | cut -d: -f1)
	enable=$(grep -n 'ufw --force enable' <<<"$output" | cut -d: -f1)
	((limit < enable))
}

@test "steps can be switched off, custom ports respected" {
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22 \
		--no-docker --no-sysctl --no-upgrades --no-watchdog --ports 80,8443
	assert_success
	refute_output --partial "download.docker.com"
	refute_output --partial "99-burrowrs.conf"
	refute_output --partial "burrowrs-watchdog"
	assert_output --partial "ufw allow 8443/tcp"
}

@test "SSH lockout guard: no known SSH port means no firewall" {
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --no-docker
	assert_success
	assert_output --partial "NOT enabling the firewall"
	refute_output --partial "ufw --force enable"
}

@test "SSH lockout guard: the session port and the explicit port are both allowed" {
	run in_debian -e SSH_CONNECTION="198.51.100.9 50000 203.0.113.7 2200" "$DEBIAN_IMAGE" \
		bash /burrowrs/scripts/install-host.sh --dry-run --no-docker --ssh-port 22
	assert_output --partial "ufw limit 22/tcp"
	assert_output --partial "ufw limit 2200/tcp"
}

@test "Docker daemon config is written before the packages start dockerd" {
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	daemon=$(grep -n 'daemon.json' <<<"$output" | head -n1 | cut -d: -f1)
	packages=$(grep -n 'docker-ce docker-ce-cli' <<<"$output" | cut -d: -f1)
	((daemon < packages))
	assert_output --partial "52burrowrs-docker-upgrades"
}

@test "refuses to run without root (outside --dry-run) and validates input" {
	run in_debian --user 65534:65534 "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh
	assert_failure
	assert_output --partial "run as root"
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port abc
	assert_failure
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ports '80;reboot'
	assert_failure
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --dir '/opt/a b|c'
	assert_failure
}

@test "unsupported distributions without Docker get a clear message" {
	printf 'ID=arch\nPRETTY_NAME="Arch Linux"\n' >"$BATS_TEST_TMPDIR/os-release"
	run in_debian -v "$BATS_TEST_TMPDIR/os-release:/os-release:ro" -e OS_RELEASE=/os-release \
		"$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run
	assert_failure
	assert_output --partial "not Debian/Ubuntu"
}

@test "systemd units are templated with the install directory" {
	grep -q '^ExecStart=@BURROWRS_DIR@/burrowrs watchdog$' "$BURROWRS_ROOT/deploy/systemd/burrowrs-watchdog.service"
	grep -q '^OnUnitActiveSec=5min$' "$BURROWRS_ROOT/deploy/systemd/burrowrs-watchdog.timer"
}

@test "sysctl tuning enables BBR and fq" {
	grep -q '^net.ipv4.tcp_congestion_control = bbr$' "$BURROWRS_ROOT/deploy/sysctl/99-burrowrs.conf"
	grep -q '^net.core.default_qdisc = fq$' "$BURROWRS_ROOT/deploy/sysctl/99-burrowrs.conf"
}

@test "install.sh dry run plans the whole one-command install" {
	run in_debian -e BURROWRS_DRY_RUN=1 -e BURROWRS_DOMAIN=Notes.Example.org -e BURROWRS_EMAIL=you@example.com \
		-e BURROWRS_SSH_PORT=2222 "$DEBIAN_IMAGE" bash /burrowrs/install.sh
	assert_success
	assert_output --partial "apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends git curl ca-certificates"
	refute_output --partial $'\033[' # no colour codes when the output is not a terminal
	assert_output --partial "git clone --depth 1 --branch v"
	assert_output --partial "install-host.sh --dir /opt/burrowrs --ports 80,443 --ssh-port 2222"
	assert_output --partial "burrowrs init --port 443 --quiet --domain notes.example.org --email you@example.com --access shared"
	assert_output --partial "/opt/burrowrs/burrowrs up"
	assert_output --partial "/opt/burrowrs/burrowrs smoke"
	assert_output --partial "/opt/burrowrs/burrowrs share"
}

@test "install.sh dry run in simple mode opens only the proxy port" {
	run in_debian -e BURROWRS_DRY_RUN=1 -e BURROWRS_COVER_DOMAIN=www.wikipedia.org "$DEBIAN_IMAGE" bash /burrowrs/install.sh
	assert_success
	assert_output --partial "--ports 443"
	refute_output --partial "--ports 80,443"
	assert_output --partial "init --port 443 --quiet --mode simple --cover-domain www.wikipedia.org"
}

@test "install.sh: BURROWRS_ACCESS=users sets up per-user secrets; anything else is refused" {
	run in_debian -e BURROWRS_DRY_RUN=1 -e BURROWRS_DOMAIN=notes.example.org -e BURROWRS_ACCESS=users "$DEBIAN_IMAGE" bash /burrowrs/install.sh
	assert_success
	assert_output --partial "--domain notes.example.org --access users"
	run in_debian -e BURROWRS_DRY_RUN=1 -e BURROWRS_DOMAIN=notes.example.org -e BURROWRS_ACCESS=everyone "$DEBIAN_IMAGE" bash /burrowrs/install.sh
	assert_failure
	assert_output --partial "BURROWRS_ACCESS must be shared or users"
}

@test "install.sh: 'true' means true for dry runs and skipping host setup" {
	run in_debian -e BURROWRS_DRY_RUN=true -e BURROWRS_SKIP_HOST_SETUP=yes -e BURROWRS_DOMAIN=notes.example.org \
		"$DEBIAN_IMAGE" bash /burrowrs/install.sh
	assert_success
	assert_output --partial "DRY RUN: nothing will be changed"
	assert_output --partial "host preparation skipped"
	refute_output --partial "install-host.sh"
	assert_output --partial "Dry run complete: nothing was changed"
	refute_output --partial "Done. burrowrs is running"
}

# A machine description for the swap tests: RAM, active swap, and a `df` that
# reports the root filesystem type and free space.
small_server() { # MEM_KIB SWAP_LINE FS FREE_KIB
	mkdir -p "$BATS_TEST_TMPDIR/stubs"
	printf 'MemTotal:       %s kB\n' "$1" >"$BATS_TEST_TMPDIR/meminfo"
	printf 'Filename\tType\tSize\tUsed\tPriority\n%s' "$2" >"$BATS_TEST_TMPDIR/swaps"
	printf '#!/bin/sh\necho "Filesystem Type 1024-blocks Used Available Capacity Mounted"\necho "/dev/sda1 %s 40000000 1000 %s 1%% /"\n' \
		"$3" "$4" >"$BATS_TEST_TMPDIR/stubs/df"
	chmod +x "$BATS_TEST_TMPDIR/stubs/df"
}

in_small_server() {
	in_debian -v "$BATS_TEST_TMPDIR:/machine:ro" -e MEMINFO=/machine/meminfo -e SWAPS=/machine/swaps \
		-e PATH=/machine/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

@test "swap: a 1 GB server without swap gets a 2 GiB swap file" {
	small_server 1003000 "" ext4 30000000
	run in_small_server "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	assert_success
	assert_output --partial "swap (this server has 979 MiB of RAM)"
	assert_output --partial "fallocate -l 2097152K /swapfile"
	assert_output --partial "chmod 600 /swapfile"
	assert_output --partial "mkswap -q /swapfile"
	assert_output --partial "swapon /swapfile"
	assert_output --partial "vm.swappiness = 10"
}

@test "swap: existing swap, enough RAM, odd filesystems, low disk and --no-swap are left alone" {
	small_server 1003000 "/dev/sda2 partition 1048572 0 -2" ext4 30000000
	run in_small_server "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	assert_output --partial "swap is already on"
	refute_output --partial "fallocate"

	small_server 4030000 "" ext4 30000000
	run in_small_server "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	refute_output --partial "swap ("
	refute_output --partial "fallocate"

	small_server 1003000 "" btrfs 30000000
	run in_small_server "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	assert_output --partial "the root filesystem is btrfs"
	refute_output --partial "fallocate"

	small_server 1003000 "" ext4 3000000
	run in_small_server "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	assert_output --partial "less than 4 GiB of free disk"
	refute_output --partial "fallocate"

	small_server 1003000 "" ext4 30000000
	run in_small_server "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22 --no-swap
	assert_success
	refute_output --partial "swap ("
	refute_output --partial "fallocate"
}

@test "install.sh: BURROWRS_SWAP=0 is passed on; anything but yes/no is refused" {
	run in_debian -e BURROWRS_DRY_RUN=1 -e BURROWRS_DOMAIN=notes.example.org -e BURROWRS_SWAP=0 "$DEBIAN_IMAGE" bash /burrowrs/install.sh
	assert_success
	assert_output --partial "install-host.sh --dir /opt/burrowrs --ports 80,443 --no-swap"
	run in_debian -e BURROWRS_DRY_RUN=1 -e BURROWRS_DOMAIN=notes.example.org -e BURROWRS_SWAP=maybe "$DEBIAN_IMAGE" bash /burrowrs/install.sh
	assert_failure
	assert_output --partial "BURROWRS_SWAP must be 1 or 0"
}

@test "apt waits for the package lock and skips installed packages" {
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	assert_success
	assert_output --partial "apt-get -o DPkg::Lock::Timeout=600 update -qq"
	# ca-certificates is already in the image; curl is not.
	assert_output --partial "--no-install-recommends curl"
	refute_output --partial "ca-certificates curl"
}

@test "kernel tuning: the conntrack hash table is sized to the connection limit" {
	run in_debian "$DEBIAN_IMAGE" bash /burrowrs/scripts/install-host.sh --dry-run --ssh-port 22
	assert_success
	assert_output --partial "/etc/modprobe.d/burrowrs.conf"
	assert_output --partial "nf_conntrack hash table: 65536 buckets"
	grep -q '^options nf_conntrack hashsize=65536$' "$BURROWRS_ROOT/deploy/sysctl/modprobe-burrowrs.conf"
}
