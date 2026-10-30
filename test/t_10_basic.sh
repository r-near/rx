# shellcheck shell=bash disable=SC2016,SC2154,SC2034,SC2164,SC2015,SC2001 # sourced by run.sh; remote strings are single-quoted on purpose
# Basic run: exit codes, both streams, path rewriting, subdirectories, env allowlist, usage errors.
mkrepo basic
root=$(pwd -P)

out=$(rx run -- 'echo to-stdout; echo to-stderr >&2' 2>"$W/err"); rc=$?
eq "run exits 0" 0 "$rc"
has "stdout arrives" to-stdout "$out"
has "stderr arrives" to-stderr "$out$(cat "$W/err")"
rx run -- 'exit 1' >/dev/null 2>&1; eq "exit code 1 propagates" 1 $?
rx run -- 'exit 42' >/dev/null 2>&1; eq "exit code 42 propagates" 42 $?
rx run -- sh -c 'exit 7' >/dev/null 2>&1; eq "multi-arg exit code propagates" 7 $?

out=$(rx run -- 'echo "$PWD/src/main.rs:1:1: error"; ls "$PWD/src"')
eq "remote path rewritten to local path" "$root/src/main.rs:1:1: error
main.rs" "$out"

mkdir -p sub/deeper && echo x >sub/deeper/f && git add sub
out=$(cd sub/deeper && rx run -- 'pwd; cat f')
eq "runs in the matching subdirectory" "$root/sub/deeper
x" "$out"

out=$(rx run -- 'echo "color=$CARGO_TERM_COLOR log=${RUST_LOG-unset} secret=${RX_TEST_SECRET-unset}"')
eq "CARGO_TERM_COLOR=never, unset vars not forwarded" "color=never log=unset secret=unset" "$out"
out=$(RUST_LOG=debug RX_TEST_SECRET=hunter2 rx run -- 'echo "log=$RUST_LOG secret=${RX_TEST_SECRET-unset}"')
eq "allowlisted env forwarded, others not" "log=debug secret=unset" "$out"
out=$(RX_ENV="CARGO_TERM_COLOR FOO" CARGO_TERM_COLOR=always FOO='a b$c' rx run -- 'echo "$CARGO_TERM_COLOR|$FOO"')
eq "RX_ENV overrides, values kept verbatim" 'always|a b$c' "$out"

rx run >/dev/null 2>&1; eq "run without a command is a usage error" 2 $?
rx submit run -- true >/dev/null 2>&1; eq "submit name 'run' is refused" 2 $?
rx bogus >/dev/null 2>&1; eq "unknown command prints usage, exit 2" 2 $?
out=$(cd / && rx run -- true 2>&1); rc=$?
eq "outside a git worktree: exit 2" 2 $rc
has "outside a git worktree: message" "not inside a git worktree" "$out"
out=$(RX_RSYNC=/usr/bin/rsync rx run -- true 2>&1); rc=$?
eq "openrsync (/usr/bin/rsync) is rejected: exit 2" 2 $rc
has "openrsync is rejected: message" "need upstream rsync" "$out"

# Argument handling: one arg = shell string; several = argv, word by word.
args=('a b' "it's" '"dq"' '$HOME' '*' 'ü日本語' '' 'back\slash' '  lead' 'semi;colon' '$(touch /tmp/pwned)' $'tab\there')
want=$(printf '<%s>\n' "${args[@]}")
out=$(rx run -- printf '<%s>\n' "${args[@]}")
eq "multi-arg form preserves weird args exactly" "$want" "$out"
box 'test ! -e /tmp/pwned' && ok "no command substitution in argv form" || nok "argv form executed \$(...)"
out=$(rx run -- 'printf "<%s>\n" "a b" "$((6*7))" ü src/*; echo "it'"'"'s"')
eq "one-string form is a shell string (expansion, globs, quotes)" "<a b>
<42>
<ü>
<src/main.rs>
it's" "$out"
out=$(rx run -- 'for i in 1 2 3; do echo $i; done | tr "\n" ,; exit 3'); rc=$?
eq "one-string: pipes, loops, exit" "1,2,3,|3" "$out|$rc"

# rx sh (no tty here, so the remote login shell reads commands from stdin)
out=$(cd sub && echo 'pwd; ls' | rx sh 2>/dev/null)
has "rx sh opens in the worktree's box dir" "/rx/w/basic-" "$out"
has "rx sh opens in the matching subdirectory" "sub
deeper" "$(echo "$out" | sed 's|.*/||')"
out=$(cd sub && rx sh -- 'pwd; echo "it'\''s $((1 + 1))"' 2>/dev/null)
has "rx sh -- runs one command in the matching box dir" "/rx/w/basic-" "$out"
has "rx sh -- passes a shell string through" "it's 2" "$out"
rx sh -- 'exit 7' >/dev/null 2>&1
eq "rx sh -- exits with the command's code" 7 $?
out=$(rx ps -a)
has "ps -a lists jobs across worktrees" "/run" "$out"
has "ps -a counts running rx jobs" "rx jobs running on the box" "$out"

# Plain non-login ssh commands find the toolchain: setup.sh's PATH block sits at the top of ~/.bashrc,
# before Ubuntu's interactive guard. Reruns keep exactly one block and drop the old .profile lines.
out=$(ssh -F "$W/ssh_config" rx-test-box 'cargo --version; command -v cargo' 2>&1)
has "non-login ssh: cargo found" "cargo 1." "$out"
has "non-login ssh: cargo is the mbx shim" "/.local/share/mbx/bin/cargo" "$out"
box 'printf "# rx: toolchain PATH (added by setup.sh)\nexport PATH=/legacy:\$PATH\n" >>~/.profile'
boxroot '/opt/rx-box/setup.sh --minimal' >/dev/null 2>&1 || nok "setup.sh rerun failed"
eq "PATH block is the first line of ~/.bashrc" "# >>> rx toolchain (managed by setup.sh) >>>" "$(box 'head -1 ~/.bashrc')"
eq "exactly one block in .bashrc and .profile after reruns" "1 1" "$(box 'echo $(grep -c "^# >>> rx toolchain" ~/.bashrc) $(grep -c "^# >>> rx toolchain" ~/.profile)')"
eq "legacy .profile PATH lines removed" 0 "$(box 'grep -c "legacy\|rx: toolchain PATH" ~/.profile')"
has "Ubuntu's interactive guard still follows" 'case $- in' "$(box 'cat ~/.bashrc')"

# Not in a worktree, but worktrees sit just below (a track dir): suggest them.
trk=$(mktemp -d /tmp/rxt-track.XXXXXX)
git init -q "$trk/wt" && mkdir -p "$trk/nested" && git init -q "$trk/nested/wt2" && mkdir -p "$trk/deep/a/b" && git init -q "$trk/deep/a/b/c"
out=$(cd "$trk" && rx run -- true 2>&1); rc=$?
eq "track dir: exit 2" 2 $rc
eq "track dir: suggests worktrees within depth 2" "rx: not inside a git worktree; did you mean: cd nested/wt2, cd wt" "$out"
rm -rf "$trk"
