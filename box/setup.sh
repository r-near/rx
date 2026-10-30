#!/usr/bin/env bash
# setup.sh: prepare an Ubuntu 24.04 machine as an rx build box. Run as root; safe to re-run.
#   sudo ./setup.sh [--user dev] [--data-disk DEV | --data-loop FILE:SIZE] [--mbx-budget SIZE] [--minimal]
# --data-disk DEV   format DEV as XFS (reflink) if it has no filesystem (never reformats), mount at /data
# --data-loop F:S   same, backed by a loopback file of size S (tests)
# --mbx-budget SIZE mbx gc.max_total_size (default: 50% of the /data filesystem, computed on each run)
# --minimal         base packages, sshd, rsync, Rust stable and mbx only (test container)
# Layout: /data/rx (rx root, ~dev/rx links here), /data/mbx (mbx cache_dir), /data/docker (Docker data-root).
# Not done here: VM creation, networking, `tailscale up` (the provisioner holds the auth key).
# shellcheck disable=SC2016 # as_user takes single-quoted scripts for the user's shell
set -euo pipefail
USER_NAME=dev DISK='' LOOP='' BUDGET='' MINIMAL=0 DATA=/data
while [ $# -gt 0 ]; do
  case $1 in
    --user) USER_NAME=$2; shift ;;
    --data-disk) DISK=$2; shift ;;
    --data-loop) LOOP=$2; shift ;;
    --mbx-budget) BUDGET=$2; shift ;;
    --minimal) MINIMAL=1 ;;
    *) echo "setup.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$(id -u)" = 0 ] || { echo "setup.sh: run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
log() { echo "== setup: $*"; }
systemd_up() { [ -d /run/systemd/system ]; }
as_user() { runuser -u "$USER_NAME" -- env -C "$HOME_DIR" HOME="$HOME_DIR" bash -lc "$1"; }
ARCH=$(uname -m) # x86_64 | aarch64
# shellcheck disable=SC1091
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
apt_updated=0
apt_install() {
  local p missing=()
  for p in "$@"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return
  [ $apt_updated = 1 ] || { apt-get update -qq; apt_updated=1; }
  apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

log "packages"
apt_install ca-certificates curl gnupg git rsync openssh-server libpam-systemd dbus-user-session sudo procps iproute2 util-linux xfsprogs \
  build-essential pkg-config jq xz-utils unzip
if [ $MINIMAL = 0 ]; then
  apt_install clang libclang-dev lld cmake libssl-dev protobuf-compiler mold ripgrep tmux btop ncdu \
    unattended-upgrades python3 fd-find fzf bat eza zoxide
fi

log "user $USER_NAME"
id "$USER_NAME" >/dev/null 2>&1 || useradd -m -s /bin/bash "$USER_NAME"
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
ROOT=$DATA/rx
mkdir -p /var/lib/systemd/linger && touch "/var/lib/systemd/linger/$USER_NAME"
systemd_up && loginctl enable-linger "$USER_NAME" 2>/dev/null || true
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" >"/etc/sudoers.d/90-rx-$USER_NAME"
chmod 440 "/etc/sudoers.d/90-rx-$USER_NAME"
mkdir -p /etc/ssh/sshd_config.d
printf 'MaxSessions 200\nMaxStartups 100:30:200\nClientAliveInterval 30\n' >/etc/ssh/sshd_config.d/90-rx.conf
printf 'fs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 1048576\n' >/etc/sysctl.d/90-rx.conf
systemd_up && sysctl -q -p /etc/sysctl.d/90-rx.conf >/dev/null 2>&1 || true # --system would re-apply GCE's ip_forward=0 under Docker

mkdir -p "$DATA"
if [ -n "$DISK$LOOP" ]; then
  log "data disk at $DATA"
  if [ -n "$DISK" ]; then
    DISK=$(readlink -f "$DISK")
    [ -b "$DISK" ] || { echo "setup.sh: $DISK is not a block device" >&2; exit 1; }
    blkid "$DISK" >/dev/null 2>&1 || mkfs.xfs -q -m reflink=1 -L rxdata "$DISK"
    entry="UUID=$(blkid -s UUID -o value "$DISK") $DATA xfs defaults,nofail 0 2"
  else
    file=${LOOP%%:*} size=${LOOP#*:}
    [ -f "$file" ] || { truncate -s "$size" "$file"; mkfs.xfs -q -m reflink=1 "$file"; }
    entry="$file $DATA xfs loop,nofail 0 0"
  fi
  grep -qE "^[^#]*[[:space:]]${DATA}[[:space:]]" /etc/fstab || echo "$entry" >>/etc/fstab
  systemd_up && systemctl daemon-reload
  mountpoint -q "$DATA" || mount "$DATA"
fi
mkdir -p "$ROOT" "$DATA/mbx" && chown "$USER_NAME:" "$ROOT" "$DATA/mbx"
if [ ! -L "$HOME_DIR/rx" ]; then # rx addresses its root as ~/rx
  [ ! -d "$HOME_DIR/rx" ] || rmdir "$HOME_DIR/rx" || { echo "setup.sh: $HOME_DIR/rx is a non-empty directory; move it into $ROOT" >&2; exit 1; }
  ln -s "$ROOT" "$HOME_DIR/rx" && chown -h "$USER_NAME:" "$HOME_DIR/rx"
fi

log "rust (rustup)"
if [ ! -x "$HOME_DIR/.cargo/bin/rustup" ]; then
  as_user 'curl -fsSL --proto =https --tlsv1.2 https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain stable'
fi
if [ $MINIMAL = 0 ]; then
  as_user 'rustup component add clippy rustfmt llvm-tools-preview rust-src &&
    rustup toolchain install nightly --profile minimal -c rust-src -c llvm-tools-preview -c clippy -c rustfmt'
fi

log "mbx"
if [ ! -x "$HOME_DIR/.local/bin/mbx" ]; then
  as_user "set -e; mkdir -p ~/.local/bin; t=\$(mktemp -d); cd \$t
    a=mbx-$ARCH-unknown-linux-gnu.tar.gz; r=https://github.com/jdx/mr-boxington/releases/latest/download
    curl -fsSLO \$r/\$a; curl -fsSLO \$r/SHA256SUMS; grep \"  \$a\$\" SHA256SUMS | sha256sum --check --strict --quiet -
    tar -xzf \$a -C ~/.local/bin mbx; cd; rm -rf \$t"
fi
DATA_GIB=$(($(df -B1 --output=size "$DATA/" | tail -1) / 1073741824))
[ -n "$BUDGET" ] || BUDGET=$((DATA_GIB / 2))GiB
MINFREE=$((DATA_GIB / 10 > 1 ? DATA_GIB / 10 : 1))GiB
log "mbx: cache_dir $DATA/mbx, budget $BUDGET, min free $MINFREE (data fs ${DATA_GIB}GiB)"
as_user "m=\$HOME/.local/bin/mbx; \$m setup --yes >/dev/null && \$m settings set cache_dir $DATA/mbx &&
  \$m settings set gc.max_total_size $BUDGET && \$m settings set gc.min_free_size $MINFREE"
# Toolchain PATH (mbx's cargo shim first, then mise shims and cargo) at the top of ~/.bashrc, before
# Ubuntu's interactive guard, so non-login commands like `ssh buildbox cargo --version` see it, and of
# ~/.profile for login shells (rx jobs run under bash -l). Reruns replace the block in place.
read -r -d '' ENV_BLOCK <<'EOF' || true
# >>> rx toolchain (managed by setup.sh) >>>
case ":$PATH:" in *":$HOME/.local/share/mbx/bin:"*) ;; *)
  export PATH="$HOME/.local/share/mbx/bin:$HOME/.local/share/mise/shims:$HOME/.cargo/bin:$HOME/.local/bin:$PATH" ;;
esac
# <<< rx toolchain <<<
EOF
for f in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile"; do
  [ -f "$f" ] || install -o "$USER_NAME" -g "$USER_NAME" -m 644 /dev/null "$f"
  rest=$(sed -e '/^# >>> rx toolchain/,/^# <<< rx toolchain/d' -e '/^# rx: toolchain PATH (added by setup.sh)$/,+1d' "$f")
  printf '%s\n%s\n' "$ENV_BLOCK" "$rest" >"$f" # same file, so owner and mode stay
done

if [ $MINIMAL = 0 ]; then
  log "mise"
  [ -x "$HOME_DIR/.local/bin/mise" ] || as_user 'curl -fsSL https://mise.run | sh'
  as_user '$HOME/.local/bin/mise use -g node@lts'

  log "cargo tools"
  if [ ! -x "$HOME_DIR/.cargo/bin/cargo-binstall" ]; then
    as_user 'curl -fsSL --proto =https --tlsv1.2 https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash'
  fi
  as_user 'for t in cargo-nextest cargo-fuzz cargo-llvm-cov; do
    [ -x ~/.cargo/bin/$t ] || cargo binstall -y --locked "$t" || exit 1; done'

  log "java + TLA+"
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -f /etc/apt/sources.list.d/adoptium.list ]; then
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $CODENAME main" \
      >/etc/apt/sources.list.d/adoptium.list
    apt_updated=0
  fi
  apt_install temurin-21-jdk
  mkdir -p /opt/tla
  [ -s /opt/tla/tla2tools.jar ] || curl -fsSL -o /opt/tla/tla2tools.jar \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
  printf '#!/bin/sh\nexec java -XX:+UseParallelGC -cp /opt/tla/tla2tools.jar tlc2.TLC "$@"\n' >/usr/local/bin/tlc
  printf '#!/bin/sh\nexec java -cp /opt/tla/tla2tools.jar "$@"\n' >/usr/local/bin/tla2tools
  chmod 755 /usr/local/bin/tlc /usr/local/bin/tla2tools

  log "docker"
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
      >/etc/apt/sources.list.d/docker.list
    apt_updated=0
  fi
  if [ ! -f /etc/docker/daemon.json ]; then # images and build cache on the data disk
    mkdir -p /etc/docker "$DATA/docker"
    printf '{ "data-root": "%s/docker" }\n' "$DATA" >/etc/docker/daemon.json
  fi
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "$USER_NAME"
  if systemd_up && ! grep -qs '^root = ' /etc/containerd/config.toml; then # Docker 29 keeps images in containerd, not data-root
    if [ -n "$(docker ps -q 2>/dev/null)" ]; then echo "setup.sh: containers running; rerun when idle to move containerd to $DATA" >&2
    else
      systemctl stop docker docker.socket containerd
      [ ! -d /var/lib/containerd ] || [ -e "$DATA/containerd" ] || mv /var/lib/containerd "$DATA/containerd"
      { echo "root = \"$DATA/containerd\""; cat /etc/containerd/config.toml 2>/dev/null; } >/etc/containerd/config.toml.rx &&
        mv /etc/containerd/config.toml.rx /etc/containerd/config.toml
    fi
  fi
  systemctl enable containerd docker >/dev/null 2>&1 || true
  systemd_up && { systemctl start containerd docker || echo "setup.sh: warning: docker did not start" >&2; }

  for t in bat:batcat fd:fdfind; do # Ubuntu renames these binaries
    [ -e "/usr/local/bin/${t%%:*}" ] || ln -s "/usr/bin/${t#*:}" "/usr/local/bin/${t%%:*}"
  done

  log "tailscale (package only; the provisioner runs tailscale up)"
  if [ ! -f /etc/apt/sources.list.d/tailscale.list ]; then
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$CODENAME.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$CODENAME.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
    apt_updated=0
  fi
  apt_install tailscale

  log "unattended-upgrades (security updates, no automatic reboot)"
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
fi

log "rx timers"
install -m 755 "$HERE/rx-box" /usr/local/bin/rx-box
cat >/etc/systemd/system/rx-idle.service <<EOF
[Unit]
Description=rx: power off the box about 30 minutes after the last rx call or ssh session
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rx-box idle --user $USER_NAME
EOF
cat >/etc/systemd/system/rx-idle.timer <<'EOF'
[Unit]
Description=rx: idle check every 5 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
cat >/etc/systemd/system/rx-cleanup.service <<EOF
[Unit]
Description=rx: prune old worktree dirs, job snapshots and logs
[Service]
Type=oneshot
User=$USER_NAME
ExecStart=/usr/local/bin/rx-box cleanup
EOF
cat >/etc/systemd/system/rx-cleanup.timer <<'EOF'
[Unit]
Description=rx: daily cleanup
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl enable rx-idle.timer rx-cleanup.timer ssh.socket >/dev/null 2>&1 || systemctl enable rx-idle.timer rx-cleanup.timer
if systemd_up; then
  systemctl daemon-reload
  systemctl start rx-idle.timer rx-cleanup.timer
  systemctl start "user@$(id -u "$USER_NAME").service" || true
  systemctl reload ssh.service 2>/dev/null || true
fi
log "done"
