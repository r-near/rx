# shellcheck shell=bash disable=SC2016,SC2154,SC2034,SC2164,SC2015,SC2001 # sourced by run.sh; remote strings are single-quoted on purpose
# Idle shutdown decisions (rx-box idle --dry-run) and the cleanup timer's pruning (rx-box cleanup).
mkrepo idle
idle() { boxroot 'RX_IDLE_STATE=/run/rx-idle-test /usr/local/bin/rx-box idle --dry-run --user dev'; }
close_master() {
  ssh -F "$W/ssh_config" -o "ControlPath=$RX_CONTROL_DIR/rx-%C" -O exit rx-test-box >/dev/null 2>&1
  wait_for 15 boxroot '! pgrep -f "^sshd: [^ ]+@" >/dev/null'
}
old_activity() { box 'touch -d "-45 min" ~/.rx/last-activity'; }

eq "idle and cleanup timers are installed and enabled" "enabled enabled " "$TIMERS"
boxroot 'rm -f /run/rx-idle-test'
rx run -- true >/dev/null
out=$(idle)
has "reports the last activity age" "last rx activity 0m ago" "$out"

old_activity
out=$(idle)
has "open ssh connection keeps the box up" "busy: 0 rx jobs, 1 ssh sessions" "$out"
has "dry run lists the sessions it counted" "session:" "$out"
has "ssh session is the sshd process" "sshd: dev@" "$out"

close_master && ok "control master closed" || nok "sshd sessions linger"
out=$(idle)
has "no jobs or sessions: idle clock starts, stay up" "idle: no jobs or sessions for 0m, last rx activity 45m ago; power off once both reach 30m" "$out"
boxroot 'test -e /run/rx-idle-test' && ok "idle-since recorded in /run (reset by reboot)" || nok "no idle state file"
boxroot 'touch -d "-20 min" /run/rx-idle-test'
has "20 idle minutes: stay up" "no jobs or sessions for 20m" "$(idle)"
boxroot 'touch -d "-40 min" /run/rx-idle-test'; box 'touch -d "-10 min" ~/.rx/last-activity'
has "recent rx activity alone keeps the box up" "last rx activity 10m ago; power off once" "$(idle)"
# 30, not 60: sessions ended and the last rx call happened 31 minutes ago -> off on this tick
boxroot 'touch -d "-31 min" /run/rx-idle-test'; box 'touch -d "-31 min" ~/.rx/last-activity'
has "31 minutes after the last activity and session: would power off" \
  "idle: no jobs or sessions for 31m, last rx activity 31m ago: would power off" "$(idle)"
boxroot 'systemctl is-system-running >/dev/null; true'
docker inspect -f '{{.State.Running}}' "$C" | grep -q true && ok "dry run did not power off" || nok "dry run powered off"

# Tailscale SSH sessions (no sshd involved) are direct children of the tailscaled daemon (parent
# PID 1): a "tailscaled be-child ssh" incubator, or whatever it exec'd (login, the shell).
boxroot 'mkdir -p /tmp/ts && cp /bin/bash /tmp/ts/tailscaled'
ts_daemon() { boxroot "systemd-run --quiet --unit=fake-tailscaled /tmp/ts/tailscaled -c '$1; true'"; }
ts_stop() { boxroot 'systemctl stop fake-tailscaled 2>/dev/null; true'; }
ts_daemon 'bash -c "exec -a \"tailscaled be-child ssh --uid=1001\" sleep 30"'
out=$(idle)
has "Tailscale SSH incubator keeps the box up" "busy: 0 rx jobs, 1 ssh sessions" "$out"
has "dry run lists the Tailscale session" "(tailscale ssh)" "$out"
has "rx-box sessions prints what it counts" "1 ssh sessions" "$(boxroot '/usr/local/bin/rx-box sessions')"
ts_stop
ts_daemon 'exec -a bash sleep 30 & wait' # incubator already exec'd the login shell: no be-child title
has "Tailscale session after the incubator exec'd the shell still counts" "busy: 0 rx jobs, 1 ssh sessions" "$(idle)"
ts_stop
has "a session resets the idle clock" "no jobs or sessions for 0m" "$(idle)"

# A running rx job keeps the box up even with no sessions and old activity.
rx submit idlejob -- 'sleep 40' >/dev/null 2>&1
close_master; old_activity
has "running rx job keeps the box up" "busy: 1 rx jobs, 0 ssh sessions" "$(idle)"
rx kill idlejob >/dev/null 2>&1

# --- cleanup ---
rx run -- true >/dev/null
rx submit oldjob -- 'echo old' >/dev/null 2>&1; rx wait oldjob >/dev/null 2>&1
rx submit newjob -- 'echo new' >/dev/null 2>&1; rx wait newjob >/dev/null 2>&1
D=$(wtdir); id=$(basename "$D")
box "mkdir -p ~/rx/w/stale_repo-0000000000/src && echo x >~/rx/w/stale_repo-0000000000/src/f && printf 'src/f\0' >~/rx/m/stale_repo-0000000000 &&
  touch -d '-15 days' ~/rx/m/stale_repo-0000000000 && touch -d '-4 days' ~/rx/jobs/$id/.oldjob@*/log"
out=$(box 'rx-box cleanup --dry-run')
has "cleanup dry run lists the stale worktree" "remove /home/dev/rx/w/stale_repo-0000000000" "$out"
has "cleanup dry run lists the old job" "/.oldjob@" "$out"
box 'test -d ~/rx/w/stale_repo-0000000000' && ok "dry run deletes nothing" || nok "dry run deleted"
box 'rx-box cleanup' >/dev/null
box 'test ! -e ~/rx/w/stale_repo-0000000000 && test ! -e ~/rx/m/stale_repo-0000000000' && ok "stale worktree dir pruned" || nok "stale worktree kept"
box "test ! -e ~/rx/jobs/$id/oldjob && test ! -e ~/rx/snap/$id-oldjob" && ok "old job, its link and snapshot pruned" || nok "old job kept"
box "test -d $D && test -e ~/rx/jobs/$id/newjob" && ok "recent worktree and job kept" || nok "recent data pruned"
out=$(rx ps); hasnt "ps no longer lists the pruned job" oldjob "$out"
has "ps still lists the recent job" newjob "$out"
