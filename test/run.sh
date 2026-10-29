#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2015 # t_*.sh are sourced and use these globals; some strings are literal on purpose
# test/run.sh [pattern]: build and boot the stand-in box container, then run test/t_*.sh (matching pattern).
# Needs docker (systemd-capable: --privileged), upstream rsync, git. Never calls the real gcloud.
set -u
T=$(cd "$(dirname "$0")" && pwd)
R=$(dirname "$T")
W=$T/.work
C=rx-test-box
PORT=${RX_TEST_PORT:-22722}
PATTERN=${1:-}
mkdir -p "$W"
rm -rf "$W/repos" && mkdir -p "$W/repos"

# ---- helpers used by the t_*.sh files ----
PASS=0 FAIL=0 FAILED=''
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
nok() { FAIL=$((FAIL + 1)); FAILED="$FAILED
  $1"; echo "  FAIL $1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/       | /' | head -40; return 0; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: $2
actual:   $3"; fi; }
has() { case $3 in *"$2"*) ok "$1" ;; *) nok "$1" "missing: $2
in:      $3" ;; esac; }
hasnt() { case $3 in *"$2"*) nok "$1" "unexpected: $2
in:         $3" ;; *) ok "$1" ;; esac; }
box() { docker exec -u dev "$C" bash -lc 'export XDG_RUNTIME_DIR=/run/user/$(id -u); eval "$1"' _ "$1"; }
boxroot() { docker exec "$C" bash -c "$1"; }
rx() { /bin/bash "$R/rx" "$@"; } # always macOS /bin/bash 3.2
mkrepo() { # mkrepo name: fresh git repo with a few tracked files, cd into it
  local d=$W/repos/$1
  mkdir -p "$d" && cd "$d" && git init -q . &&
    mkdir -p src && echo 'fn main() {}' >src/main.rs && echo hello >a.txt && git add -A
}
wtdir() { # box dir of the repo in the current directory (most recent match by repo name)
  box "ls -td ~/rx/w/$(basename "$(git rev-parse --show-toplevel)" | tr -c 'A-Za-z0-9_\n' _)-* | head -1"
}
wait_for() { # seconds cmd...: poll until cmd succeeds
  local n=$(($1 * 5)); shift
  while [ $n -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; n=$((n - 1)); done
  return 1
}
ssh_ready() { ssh -F "$W/ssh_config" -o ConnectTimeout=3 rx-test-box true; }

# ---- box container ----
echo "== building image"
docker build -q -t $C -f "$T/Dockerfile" "$R" >/dev/null || { echo "docker build failed"; exit 1; }
[ -f "$W/key" ] || ssh-keygen -q -t ed25519 -N '' -C rx-test -f "$W/key"
cat >"$W/ssh_config" <<EOF
Host rx-test-box
  HostName 127.0.0.1
  Port $PORT
  User dev
  IdentityFile $W/key
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile $W/known_hosts
  LogLevel ERROR
EOF
echo "== starting container"
docker rm -f $C >/dev/null 2>&1
docker run -d --name $C --hostname buildbox --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
  -p "127.0.0.1:$PORT:22" $C >/dev/null || exit 1
wait_for 60 boxroot 'systemctl is-system-running | grep -qE "running|degraded"' || { echo "systemd did not boot"; exit 1; }
docker exec -i $C sh -c 'install -d -o dev -g dev -m 700 ~dev/.ssh && cat >~dev/.ssh/authorized_keys && chown dev: ~dev/.ssh/authorized_keys' <"$W/key.pub"
echo "== data disk (loopback XFS) and timers"
boxroot '/opt/rx-box/setup.sh --minimal --data-loop /var/lib/rx-data.img:4G' >"$W/setup.log" 2>&1 || { cat "$W/setup.log"; exit 1; }
TIMERS=$(boxroot 'systemctl is-enabled rx-idle.timer rx-cleanup.timer | tr "\n" " "')
boxroot 'systemctl stop rx-idle.timer' # the idle test drives the script directly
wait_for 30 ssh_ready || { echo "ssh not reachable"; exit 1; }

export RX_CONFIG=$W/config RX_CONTROL_DIR RX_TEST_CONTAINER=$C RX_TEST_GCLOUD_LOG=$W/gcloud.log
RX_CONTROL_DIR=$(mktemp -d /tmp/rxt.XXXXXX)
cat >"$RX_CONFIG" <<EOF
RX_HOST=rx-test-box
RX_SSH_CONFIG=$W/ssh_config
RX_GCE_INSTANCE=rx-test-box
RX_GCE_ZONE=test-zone-a
RX_GCE_PROJECT=test-project
RX_GCE_DATA_DISK=\${RX_GCE_DATA_DISK-rx-data}
EOF
export PATH="$T/fake-bin:$PATH" CLOUDSDK_CONFIG=$W/gcloud-config
[ "$(command -v gcloud)" = "$T/fake-bin/gcloud" ] || { echo "fake gcloud not first on PATH"; exit 1; }
unset RUST_LOG RUST_BACKTRACE RX_ENV
: >"$RX_TEST_GCLOUD_LOG"
printf 'export RX_CONFIG=%s RX_CONTROL_DIR=/tmp/rxt.manual RX_TEST_CONTAINER=%s PATH="%s:$PATH"\nmkdir -p /tmp/rxt.manual\n' \
  "$RX_CONFIG" $C "$T/fake-bin" >"$W/env" # for poking at the box by hand: . test/.work/env

echo "== static"
eq "tests drive the client with macOS /bin/bash 3.2" 3 "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')"
if command -v shellcheck >/dev/null; then
  out=$(shellcheck "$R/rx" "$R/box/rx-box" "$R/box/setup.sh" "$T"/*.sh "$T/fake-bin/gcloud" 2>&1) && ok "shellcheck clean" || nok "shellcheck" "$out"
fi
for f in "$T"/t_*.sh; do
  case $f in *"$PATTERN"*) ;; *) continue ;; esac
  echo "== $(basename "$f")"
  cd "$W" || exit 1
  # shellcheck disable=SC1090
  . "$f"
done
cd "$W" && ssh -F "$W/ssh_config" -o "ControlPath=$RX_CONTROL_DIR/rx-%C" -O exit rx-test-box >/dev/null 2>&1
rm -rf "$RX_CONTROL_DIR"
echo
echo "== summary: $PASS passed, $FAIL failed"
[ $FAIL = 0 ] || { echo "failed:$FAILED"; exit 1; }
