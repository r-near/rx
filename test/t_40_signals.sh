# shellcheck shell=bash disable=SC2016,SC2154,SC2034,SC2164,SC2015,SC2001 # sourced by run.sh; remote strings are single-quoted on purpose
# Signals: Ctrl-C stops the remote tree; TERM/HUP/KILL only detach; rx wait never kills.
mkrepo signals
RXC=(/bin/bash "$R/rx")
set -m # background jobs get their own process group and don't ignore SIGINT (like a terminal)
running() { box "pgrep -f '[${1:0:1}]${1:1}' >/dev/null"; } # [r]x... so pgrep can't match this shell
gone() { ! running "$1"; }
grep_q() { grep -q "$1" "$2" 2>/dev/null; }
local_followers() { pgrep -f "__remote .rx/stage/.* follow" | wc -l | tr -d ' '; }
before=$(local_followers)

# Ctrl-C as a terminal sends it: SIGINT to the whole foreground process group.
"${RXC[@]}" run -- 'setsid bash -c "exec -a rxgc_pg sleep 300" & bash -c "exec -a rxchild_pg sleep 300"' >"$W/int1.out" 2>&1 &
pid=$!
wait_for 20 running rxgc_pg && wait_for 20 running rxchild_pg && ok "job and setsid grandchild started" || nok "job did not start"
kill -INT -- -$pid
wait $pid; rc=$?
eq "Ctrl-C (process group): rx exits 130" 130 $rc
wait_for 15 gone rxchild_pg && ok "Ctrl-C killed the child" || nok "child survived Ctrl-C"
wait_for 15 gone rxgc_pg && ok "Ctrl-C killed the setsid grandchild" || nok "setsid grandchild survived Ctrl-C" "$(box 'ps -ef | grep rxgc')"
has "Ctrl-C says it killed the job" "rx: killed run" "$(cat "$W/int1.out")"
has "ps shows the run as killed" "killed" "$(rx ps)"

# SIGINT to the rx process only (how an agent would interrupt it)
"${RXC[@]}" run -- 'setsid bash -c "exec -a rxgc_pid sleep 300" & exec -a rxchild_pid sleep 300' >"$W/int2.out" 2>&1 &
pid=$!
wait_for 20 running rxgc_pid || nok "job 2 did not start"
kill -INT $pid
wait $pid; eq "SIGINT to rx: exits 130" 130 $?
wait_for 15 gone rxgc_pid && wait_for 15 gone rxchild_pid && ok "SIGINT to rx killed the whole remote tree" || nok "remote tree survived SIGINT"

# TERM (agent shell timeout): detach, job keeps running, rx wait reattaches with the real code.
"${RXC[@]}" run -- 'echo begin; sleep 5; echo finish; exit 9' >"$W/term.out" 2>"$W/term.err" &
pid=$!
wait_for 20 grep_q begin "$W/term.out" || nok "TERM job did not start"
kill -TERM $pid
wait $pid; eq "TERM: rx exits 143" 143 $?
has "TERM: prints how to reattach" "rx wait run" "$(cat "$W/term.err")"
has "TERM: job still running" "running" "$(rx ps)"
eq "TERM: no local follower ssh left behind" "$before" "$(local_followers)"
out=$(rx wait run 2>&1); rc=$?
eq "rx wait after TERM: real exit code" 9 $rc
has "rx wait after TERM: replays the whole log" "begin" "$out"
has "rx wait after TERM: gets the rest" "finish" "$out"

# HUP (terminal or agent session closed): same as TERM
"${RXC[@]}" run -- 'echo up; sleep 3; exit 4' >"$W/hup.out" 2>"$W/hup.err" &
pid=$!
wait_for 20 grep_q up "$W/hup.out"
kill -HUP $pid
wait $pid; eq "HUP: rx exits 143" 143 $?
rx wait run >/dev/null 2>&1; eq "rx wait after HUP: real exit code" 4 $?

# KILL (hard timeout): the job survives the client disappearing.
"${RXC[@]}" run -- 'echo k; sleep 3; echo survived; exit 6' >"$W/kill.out" 2>&1 &
pid=$!
wait_for 20 grep_q k "$W/kill.out"
kill -KILL $pid; wait $pid 2>/dev/null
out=$(rx wait run 2>&1); rc=$?
eq "after SIGKILL of the client the job finishes (code)" 6 $rc
has "after SIGKILL of the client the job finishes (output)" survived "$out"
pkill -f "__remote .rx/stage/.* follow" 2>/dev/null # the killed client's orphaned ssh

# rx wait never kills: INT and TERM on wait only detach.
rx submit longjob -- 'sleep 6; exit 3' >/dev/null 2>&1
"${RXC[@]}" wait longjob >/dev/null 2>"$W/w.err" &
pid=$!
sleep 1.5; kill -INT -- -$pid; wait $pid; rc=$?
eq "INT on rx wait: exits 130" 130 $rc
has "INT on rx wait: job keeps running" running "$(rx ps)"
"${RXC[@]}" wait longjob >/dev/null 2>&1 &
pid=$!
sleep 1.5; kill -TERM $pid; wait $pid
has "TERM on rx wait: job keeps running" running "$(rx ps)"
rx wait longjob >/dev/null 2>&1; eq "the job still finishes with its code" 3 $?
set +m
