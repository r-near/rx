# shellcheck shell=bash disable=SC2016,SC2154,SC2034,SC2164,SC2015,SC2001 # sourced by run.sh; remote strings are single-quoted on purpose
# submit/wait/logs/ps/kill, frozen snapshots, target isolation, slices, same-worktree run queueing.
mkrepo jobs
echo v1 >version && git add version
rx run -- true >/dev/null
D=$(wtdir)
box "cd $D && mkdir -p /tmp/jobs-managed-target && ln -sfn /tmp/jobs-managed-target target && mkdir -p fuzz/corpus && echo seed >fuzz/corpus/s1 &&
  mkdir -p fuzz && ln -sfn /tmp/jobs-managed-target fuzz/target"

t0=$SECONDS
out=$(rx submit slow -- 'echo "start $(cat version)"; ls -la target 2>&1 | head -1; test -e fuzz/target && echo fuzz-target-shared; cat fuzz/corpus/s1; sleep 6; echo "end $(cat version)"; exit 5' 2>&1); rc=$?
eq "submit returns 0" 0 $rc
[ $((SECONDS - t0)) -lt 5 ] && ok "submit returns immediately ($((SECONDS - t0))s)" || nok "submit blocked ($((SECONDS - t0))s)"
has "submit prints how to follow" "rx wait slow" "$out"

out=$(rx submit slow -- true 2>&1); rc=$?
eq "duplicate running name refused (exit 2)" 2 $rc
has "duplicate refusal says why" "still running" "$out"

echo v2 >version
rx run -- 'cat version' >"$W/v.out"
eq "worktree mirror gets the new edit" v2 "$(cat "$W/v.out")"
out=$(rx ps)
has "ps shows the running job" "slow" "$out"
has "ps shows state running" "running" "$out"

out=$(rx wait slow 2>&1); rc=$?
eq "wait returns the job's exit code" 5 $rc
has "job saw the snapshot content at start" "start v1" "$out"
has "job still sees the snapshot after a later sync" "end v1" "$out"
has "snapshot has no inherited target symlink" "No such file" "$out"
hasnt "nested target symlink removed in snapshot" "fuzz-target-shared" "$out"
has "snapshot keeps remote-only data (fuzz corpus)" "seed" "$out"
eq "worktree's own target symlink untouched" /tmp/jobs-managed-target "$(box "readlink $D/target")"
out=$(rx logs slow 2); eq "logs n shows the last n lines" "seed
end v1" "$out"
out=$(rx ps); has "ps shows the finished exit code" "exit 5" "$out"
out=$(rx wait slow 2>&1); rc=$?
eq "wait on a finished job replays it with its code" "5" "$rc"
rx submit slow -- 'exit 0' >/dev/null 2>&1 && ok "finished name can be reused" || nok "finished name not reusable"
rx wait slow >/dev/null 2>&1; eq "reused name's new exit code" 0 $?

rx run -- 'mkdir -p out && echo data >out/result.txt' >/dev/null
rx pull out/result.txt >/dev/null && eq "pull copies into .rx-out" data "$(cat .rx-out/result.txt)"
out=$(git status --porcelain --untracked-files=all | grep rx-out); eq ".rx-out is ignored by git (and not synced)" "" "$out"
rx submit snapjob -- 'echo snapdata >snap.txt' >/dev/null 2>&1; rx wait snapjob >/dev/null 2>&1
rx pull snap.txt snapjob >/dev/null && eq "pull from a job's snapshot" snapdata "$(cat .rx-out/snap.txt)"

# kill: the whole unit goes, state is "killed", wait reports it
rx submit victim -- 'sleep 300' >/dev/null 2>&1
rx kill victim 2>/dev/null; eq "kill exits 0" 0 $?
out=$(rx ps); has "ps shows killed" "killed" "$out"
rx wait victim >/dev/null 2>&1; eq "wait on a killed job: 143" 143 $?
out=$(rx kill victim 2>&1); has "kill on a finished job says so" "not running" "$out"
out=$(rx wait nosuch 2>&1); rc=$?; eq "wait on an unknown job: exit 2" "2" "$rc"

# --mem sets MemoryMax; submit runs in the low-weight slice, run in the high-weight one
rx submit --mem 300M memjob -- 'cat /proc/self/cgroup; sleep 3' >/dev/null 2>&1
U=rx-$(basename "$D")-memjob.service
eq "--mem sets MemoryMax on the unit" 314572800 "$(box "systemctl --user show -p MemoryMax --value $U")"
eq "submit jobs run in rx-job.slice" rx-job.slice "$(box "systemctl --user show -p Slice --value $U")"
eq "rx-run.slice has CPU weight 1000 (cgroup cpu.weight)" 1000 "$(box 'cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/rx.slice/rx-run.slice/cpu.weight 2>/dev/null || systemctl --user show -p CPUWeight --value rx-run.slice')"
eq "rx-job.slice has CPU weight 100" 100 "$(box 'cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/rx.slice/rx-job.slice/cpu.weight')"
rx wait memjob >/dev/null 2>&1
rx submit --mem 64M oom -- 'head -c 600M /dev/zero | tail >/dev/null' >/dev/null 2>&1
out=$(rx wait oom 2>&1); rc=$?
eq "a job over its --mem limit is OOM-killed and the exit code (137) is recorded" 137 $rc

# Same worktree: concurrent runs queue behind each other; no unit-name collisions.
rx run -- 'echo A-start; sleep 3; echo A-end' >"$W/A.out" 2>"$W/A.err" &
pa=$!
sleep 1
rx run -- 'echo B-ran' >"$W/B.out" 2>"$W/B.err" &
pb=$!
rx run -- 'echo C-ran' >"$W/C.out" 2>"$W/C.err" &
pc=$!
wait $pa; ra=$?; wait $pb; rb=$?; wait $pc; rc=$?
eq "concurrent runs all succeed" "0 0 0" "$ra $rb $rc"
eq "first run streamed its own output" "A-start
A-end" "$(cat "$W/A.out")"
eq "second run got its own output" "B-ran" "$(cat "$W/B.out")"
eq "third run got its own output" "C-ran" "$(cat "$W/C.out")"
has "queued run says it is waiting" "waiting for the running job" "$(cat "$W/B.err" "$W/C.err")"
hasnt "no unit collision errors" "already" "$(cat "$W/A.err" "$W/B.err" "$W/C.err")"
for i in 1 2 3 4 5 6; do rx run -- "echo r$i" >"$W/r$i.out" 2>"$W/r$i.err" & done
wait
all=$(cat "$W"/r[1-6].out | sort | tr '\n' ' ')
eq "six simultaneous runs, each gets exactly its output" "r1 r2 r3 r4 r5 r6 " "$all"
hasnt "six simultaneous runs: no unit collision errors" "already" "$(cat "$W"/r[1-6].err)"

# Kill is instance-scoped: a stale client's Ctrl-C (its token) must not stop a newer run.
id=$(basename "$D") U=rx-$(basename "$D")-run.service
rx run -- 'echo first' >/dev/null 2>&1
/bin/bash "$R/rx" run -- 'echo second; sleep 20' >"$W/second.out" 2>&1 &
p2=$!
wait_for 20 box "systemctl --user -q is-active $U" || nok "second run did not start"
cur=$(box "readlink ~/rx/jobs/$id/run")
old=$(box "cd ~/rx/jobs/$id && ls -d .run@* | grep -vx '$cur' | head -1")
out=$(box "\$(ls -t ~/.rx/bin/rx-* | head -1) __remote - kill $id run ${old#.run@} 2>&1")
has "kill with a superseded run's token refuses" "a newer run replaced it" "$out"
box "systemctl --user -q is-active $U" && ok "the newer run keeps running" || nok "stale token killed the newer run"
rx kill run >/dev/null 2>&1
wait $p2; eq "plain rx kill stops the newest run (its client sees 143)" 143 $?
