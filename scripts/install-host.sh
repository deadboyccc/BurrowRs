#!/usr/bin/env bash
# Prepare a fresh Debian/Ubuntu server for burrowrs. Idempotent: safe to re-run.
#
#   sudo scripts/install-host.sh [--dir /opt/burrowrs] [--ssh-port N] [--ports 80,443]
#                                [--no-docker] [--no-firewall] [--no-sysctl] [--no-swap]
#                                [--no-upgrades] [--no-watchdog] [--dry-run]
#
# What it does, and why:
#   swap      2 GiB swap file on servers with 2 GiB of RAM or less and no swap,
#             so a burst of connections or an image build can't OOM-kill the proxy
#   docker    Docker Engine + Compose plugin from Docker's signed apt repository
#   time      NTP sync: FakeTLS refuses clients when clocks disagree by > 5s
#   sysctl    BBR congestion control, fq qdisc, bigger queues and buffers
#   firewall  ufw: deny inbound except SSH (rate-limited), HTTP and HTTPS.
#             SSH stays open on --ssh-port AND every port sshd listens on.
#   upgrades  unattended security updates
#   watchdog  systemd timer: probe the proxy every 5 minutes, restart if stuck
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DIR=$ROOT
SSH_PORT='' # explicit --ssh-port
PORTS=80,443
DO_DOCKER=1 DO_FIREWALL=1 DO_SYSCTL=1 DO_SWAP=1 DO_UPGRADES=1 DO_WATCHDOG=1 DRY_RUN=0
# Overridable so tests can describe a machine other than the one they run on.
OS_RELEASE=${OS_RELEASE:-/etc/os-release}
MEMINFO=${MEMINFO:-/proc/meminfo}
SWAPS=${SWAPS:-/proc/swaps}

log() { printf '==> %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# run CMD...: execute, or only print it with --dry-run.
run() {
	if ((DRY_RUN)); then
		printf '    [dry-run] %s\n' "$*" >&2
	else
		"$@"
	fi
}

# install_file SRC DEST MODE: copy (or print) a file.
install_file() {
	if ((DRY_RUN)); then
		printf '    [dry-run] install -m %s %s %s\n' "$3" "$1" "$2" >&2
	else
		install -D -m "$3" "$1" "$2"
	fi
}

while (($#)); do
	case $1 in
	--dir) DIR=$2 && shift ;;
	--ssh-port) SSH_PORT=$2 && shift ;;
	--ports) PORTS=$2 && shift ;;
	--no-docker) DO_DOCKER=0 ;;
	--no-firewall) DO_FIREWALL=0 ;;
	--no-sysctl) DO_SYSCTL=0 ;;
	--no-swap) DO_SWAP=0 ;;
	--no-upgrades) DO_UPGRADES=0 ;;
	--no-watchdog) DO_WATCHDOG=0 ;;
	--dry-run) DRY_RUN=1 ;;
	-h | --help)
		sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die "unknown option: $1" ;;
	esac
	shift
done

[[ -z $SSH_PORT || $SSH_PORT =~ ^[0-9]{1,5}$ ]] || die "--ssh-port must be a number"
[[ $PORTS =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || die "--ports must look like 80,443"
# It is written into a systemd unit and a sed expression.
[[ $DIR =~ ^/[A-Za-z0-9._/-]+$ && $DIR != *..* ]] || die "--dir must be an absolute path of letters, digits, . _ - and /"
((DRY_RUN)) || ((EUID == 0)) || die "run as root (sudo $0 $*)"

# shellcheck source=/dev/null
[[ -r $OS_RELEASE ]] && source "$OS_RELEASE"
DISTRO=${ID:-unknown}
CODENAME=${VERSION_CODENAME:-}
case $DISTRO in
debian | ubuntu) APT=1 ;;
*)
	APT=0
	if [[ ${ID_LIKE:-} == *debian* || ${ID_LIKE:-} == *ubuntu* ]]; then
		APT=1
		if [[ ${ID_LIKE} == *ubuntu* ]]; then DISTRO=ubuntu; else DISTRO=debian; fi
		CODENAME=${UBUNTU_CODENAME:-$CODENAME}
	fi
	;;
esac
# Every port SSH may be reachable on: the explicit --ssh-port (possibly a NAT
# forward), the port of this very session (if sudo kept SSH_CONNECTION), and
# whatever sshd is configured for. Allowing all of them keeps a non-default
# or forwarded SSH port from being firewalled off.
ssh_ports() {
	{
		[[ -n $SSH_PORT ]] && echo "$SSH_PORT"
		[[ -n ${SSH_CONNECTION:-} ]] && awk '{print $4}' <<<"$SSH_CONNECTION"
		if command -v sshd >/dev/null 2>&1; then sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'; fi
		if command -v ss >/dev/null 2>&1; then
			ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
		fi
		# Socket-activated SSH (ssh.socket) may hold the port in systemd alone.
		if command -v systemctl >/dev/null 2>&1; then
			systemctl show -p Listen ssh.socket sshd.socket 2>/dev/null |
				grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+' || true
		fi
	} | grep -E '^[0-9]{1,5}$' | sort -un | paste -sd, - || true
}
SSH_PORTS=$(ssh_ports)

log "host: ${PRETTY_NAME:-$DISTRO} (apt: $([[ $APT == 1 ]] && echo yes || echo no)), ssh port(s) ${SSH_PORTS:-unknown}, burrowrs in $DIR"

# Fresh servers often run their first automatic updates right after boot, and
# apt then fails at once with "Could not get lock". Wait for it instead (up to
# 10 minutes), both before starting and, through DPkg::Lock::Timeout, in dpkg.
APT_OPTS=(-o DPkg::Lock::Timeout=600)
wait_for_apt() {
	((DRY_RUN)) && return 0
	command -v pgrep >/dev/null 2>&1 || return 0
	local waited=0
	while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null; do
		((waited == 0)) && note "waiting for another package manager (automatic updates?) to finish"
		((waited >= 600)) && return 0 # let apt report the lock itself
		sleep 5
		waited=$((waited + 5))
	done
}

# apt_install PKG...: install what is missing. Installed packages are skipped,
# so a re-run or an upgrade needs no package lists and no network.
APT_UPDATED=0
apt_install() {
	local pkg missing=()
	for pkg in "$@"; do
		dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q ' installed$' || missing+=("$pkg")
	done
	((${#missing[@]})) || return 0
	wait_for_apt
	if ((APT_UPDATED == 0)); then
		run apt-get "${APT_OPTS[@]}" update -qq
		APT_UPDATED=1
	fi
	run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y -qq --no-install-recommends "${missing[@]}"
}

# --- Swap --------------------------------------------------------------------
# A server with 2 GiB of RAM or less and no swap gets a 2 GiB swap file. With
# swappiness 10 the proxy's working set stays in RAM; swap only absorbs real
# pressure (a burst of connections, building the probe image), where the
# alternative is the kernel OOM-killing the proxy. Never touches existing swap,
# and skips anything unusual (containers, copy-on-write filesystems, low disk).
SWAP_FILE=/swapfile
setup_swap() {
	local mem_kib fs='' free_kib='' size_kib=$((2 * 1024 * 1024))
	mem_kib=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO" 2>/dev/null || true)
	[[ $mem_kib =~ ^[0-9]+$ ]] || return 0
	# "2 GB" plans report a little under 2 GiB; 4 GB plans don't need this.
	if ((mem_kib > 2560 * 1024)); then
		return 0
	fi
	log "swap (this server has $((mem_kib / 1024)) MiB of RAM)"
	if awk 'NR > 1 { found = 1 } END { exit !found }' "$SWAPS" 2>/dev/null; then
		note "swap is already on; leaving it as it is"
		return 0
	fi
	if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; then
		note "inside a container: swap belongs to the host; skipping"
		return 0
	fi
	if [[ -e $SWAP_FILE ]]; then
		note "$SWAP_FILE already exists but is not in use; leaving it alone"
		return 0
	fi
	read -r fs free_kib < <(df -PTk / 2>/dev/null | awk 'NR == 2 { print $2, $5 }') || true
	case ${fs:-} in
	ext2 | ext3 | ext4 | xfs) ;;
	*)
		note "the root filesystem is ${fs:-unknown}, not ext4 or xfs; skipping swap"
		return 0
		;;
	esac
	if ! [[ $free_kib =~ ^[0-9]+$ ]] || ((free_kib < size_kib + 2 * 1024 * 1024)); then
		note "less than 4 GiB of free disk; skipping swap"
		return 0
	fi
	if ! { run fallocate -l "${size_kib}K" "$SWAP_FILE" &&
		run chmod 600 "$SWAP_FILE" &&
		run mkswap -q "$SWAP_FILE" &&
		run swapon "$SWAP_FILE"; }; then
		((DRY_RUN)) || rm -f -- "$SWAP_FILE"
		note "this server does not allow a swap file; continuing without one"
		return 0
	fi
	if ((DRY_RUN)); then
		note "[dry-run] add $SWAP_FILE to /etc/fstab; vm.swappiness = 10"
	else
		grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>/etc/fstab
		printf '# burrowrs: keep the proxy in RAM; swap only absorbs real pressure.\nvm.swappiness = 10\n' \
			>/etc/sysctl.d/99-burrowrs-swap.conf
		sysctl --quiet -p /etc/sysctl.d/99-burrowrs-swap.conf || true
	fi
	note "2 GiB swap file at $SWAP_FILE"
}

# --- Docker ------------------------------------------------------------------
install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		note "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') with Compose is already installed"
		return 0
	fi
	((APT)) || die "Docker is missing and this is not Debian/Ubuntu. Install Docker Engine + Compose v2, then re-run with --no-docker."
	[[ -n $CODENAME ]] || die "cannot determine the distribution codename from $OS_RELEASE"
	log "installing Docker Engine from download.docker.com ($DISTRO $CODENAME)"
	apt_install ca-certificates curl
	# Before the packages: dockerd starts as soon as it is installed, and only
	# reads daemon.json at start.
	configure_docker_daemon
	run install -m 0755 -d /etc/apt/keyrings
	run curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
	run chmod a+r /etc/apt/keyrings/docker.asc
	local arch
	arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
	if ((DRY_RUN)); then
		note "[dry-run] write /etc/apt/sources.list.d/docker.sources ($DISTRO $CODENAME $arch)"
	else
		cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DISTRO
Suites: $CODENAME
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
	fi
	APT_UPDATED=0 # the new repository needs a fresh package list
	apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	run systemctl enable --now docker
}

# live-restore keeps containers running while dockerd restarts or upgrades.
configure_docker_daemon() {
	if [[ -e /etc/docker/daemon.json ]]; then
		note "keeping the existing /etc/docker/daemon.json (consider \"live-restore\": true)"
		return 0
	fi
	if ((DRY_RUN)); then
		note "[dry-run] write /etc/docker/daemon.json {live-restore, local log driver}"
		return 0
	fi
	install -d -m 0755 /etc/docker
	cat >/etc/docker/daemon.json <<'EOF'
{
  "live-restore": true,
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
}

# --- Time --------------------------------------------------------------------
setup_time() {
	log "time synchronisation"
	if command -v chronyc >/dev/null 2>&1 || systemctl is-active --quiet chrony 2>/dev/null; then
		note "chrony is installed"
		return 0
	fi
	if ((APT)) && ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
		apt_install systemd-timesyncd
	fi
	if command -v timedatectl >/dev/null 2>&1; then
		run timedatectl set-ntp true
	else
		note "no timedatectl: make sure NTP is running"
	fi
}

# --- Kernel tuning -----------------------------------------------------------
# net.core.default_qdisc only applies to interfaces brought up after it is
# set, so the uplink keeps its boot-time qdisc (usually fq_codel) until the
# next reboot. Switch it to fq now: one fq for a single-queue NIC, or one fq
# per hardware queue under mq. Idempotent, and never fatal.
apply_fq() {
	local dev queues i
	command -v tc >/dev/null 2>&1 || return 0
	dev=$(ip -o route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
	[[ -n $dev && -d /sys/class/net/$dev/queues ]] || return 0
	queues=$(find "/sys/class/net/$dev/queues" -maxdepth 1 -name 'tx-*' | wc -l)
	if ((queues <= 1)); then
		run tc qdisc replace dev "$dev" root fq || note "could not set fq on $dev; it applies after a reboot"
	else
		run tc qdisc replace dev "$dev" root handle 1: mq || {
			note "could not set fq on $dev; it applies after a reboot"
			return 0
		}
		for ((i = 1; i <= queues; i++)); do
			run tc qdisc replace dev "$dev" parent "1:$(printf '%x' "$i")" fq || true
		done
	fi
}

# The modprobe option only applies when the module loads (at boot); resize
# the live table now. Never shrinks a table that is already larger.
size_conntrack_hash() {
	local param=/sys/module/nf_conntrack/parameters/hashsize current
	if ((DRY_RUN)); then
		note "[dry-run] nf_conntrack hash table: 65536 buckets"
		return 0
	fi
	[[ -w $param ]] || return 0
	current=$(<"$param")
	[[ $current =~ ^[0-9]+$ ]] && ((current < 65536)) || return 0
	echo 65536 2>/dev/null >"$param" || note "could not resize the conntrack table; it applies after a reboot"
}

setup_sysctl() {
	log "kernel network tuning (BBR, fq, larger queues)"
	if ((DRY_RUN)) || modprobe tcp_bbr 2>/dev/null || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		install_file "$ROOT/deploy/sysctl/99-burrowrs.conf" /etc/sysctl.d/99-burrowrs.conf 0644
		install_file "$ROOT/deploy/sysctl/modules-load-burrowrs.conf" /etc/modules-load.d/burrowrs.conf 0644
		install_file "$ROOT/deploy/sysctl/modprobe-burrowrs.conf" /etc/modprobe.d/burrowrs.conf 0644
		((DRY_RUN)) || modprobe nf_conntrack 2>/dev/null || true
		size_conntrack_hash
		# Some keys are read-only in containers (LXC/OpenVZ); that must not stop
		# the firewall and the rest of the setup.
		run sysctl --quiet --system || note "some kernel settings could not be applied (normal in containers); continuing"
		apply_fq
	else
		note "this kernel has no BBR module; skipping (common inside OpenVZ/LXC containers)"
	fi
}

# --- Firewall ----------------------------------------------------------------
setup_firewall() {
	if [[ -z $SSH_PORTS ]]; then
		note "could not determine the SSH port: NOT enabling the firewall (that could lock you out)."
		note "Re-run with --ssh-port N, or allow TCP ${PORTS} and your SSH port yourself."
		return 0
	fi
	log "firewall (ufw): allow SSH ${SSH_PORTS//,/, } (rate-limited) and ${PORTS//,/, }; deny other inbound"
	if ! command -v ufw >/dev/null 2>&1; then
		((APT)) || {
			note "ufw is not available; configure your firewall to allow TCP $SSH_PORTS,$PORTS"
			return 0
		}
		apt_install ufw
	fi
	run ufw default deny incoming
	run ufw default allow outgoing
	# Allow SSH *before* enabling, so the current session survives.
	local port
	for port in ${SSH_PORTS//,/ }; do
		run ufw limit "$port/tcp" comment 'ssh'
	done
	for port in ${PORTS//,/ }; do
		run ufw allow "$port/tcp" comment 'burrowrs'
	done
	run ufw --force enable
	note "Docker publishes ports through its own iptables rules, before ufw sees"
	note "them: burrowrs publishes only $PORTS publicly; metrics stay on 127.0.0.1."
}

# --- Unattended upgrades -----------------------------------------------------
setup_upgrades() {
	((APT)) || return 0
	log "unattended security upgrades"
	apt_install unattended-upgrades
	if ((DRY_RUN)); then
		note "[dry-run] write /etc/apt/apt.conf.d/20auto-upgrades and 52burrowrs-docker-upgrades"
	else
		cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
		# Docker's repository is not in the default allowed origins, but runc and
		# containerd fixes are exactly the security updates worth having.
		# live-restore keeps containers running while dockerd restarts.
		cat >/etc/apt/apt.conf.d/52burrowrs-docker-upgrades <<'EOF'
Unattended-Upgrade::Origins-Pattern { "origin=Docker"; };
EOF
	fi
}

# --- Watchdog ----------------------------------------------------------------
setup_watchdog() {
	if ! command -v systemctl >/dev/null 2>&1 && ((DRY_RUN == 0)); then
		note "no systemd: skipping the watchdog timer"
		return 0
	fi
	log "watchdog timer (probes the proxy every 5 minutes)"
	local unit tmp
	tmp=$(mktemp -d)
	for unit in burrowrs-watchdog.service burrowrs-watchdog.timer; do
		sed "s|@BURROWRS_DIR@|$DIR|g" "$ROOT/deploy/systemd/$unit" >"$tmp/$unit"
		install_file "$tmp/$unit" "/etc/systemd/system/$unit" 0644
	done
	rm -rf -- "$tmp"
	run systemctl daemon-reload
	run systemctl enable --now burrowrs-watchdog.timer
}

((DO_SWAP)) && setup_swap
((DO_DOCKER)) && install_docker
setup_time
((DO_SYSCTL)) && setup_sysctl
((DO_FIREWALL)) && setup_firewall
((DO_UPGRADES)) && setup_upgrades
((DO_WATCHDOG)) && setup_watchdog
log "host ready"
