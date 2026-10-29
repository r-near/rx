# shellcheck shell=bash disable=SC2016,SC2154,SC2034,SC2164,SC2015,SC2001 # sourced by run.sh; remote strings are single-quoted on purpose
# Lifecycle: jobs lost to a restart (preemption), wake via (fake) gcloud, stockout, up/status/stop,
# data-disk warning and rx grow.
mkrepo lifecycle
echo keep >kept.txt && git add kept.txt
gl() { cat "$RX_TEST_GCLOUD_LOG"; }
running_state() { [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "$1" ]; }

# --- preemption: processes die, disk survives ---
rx submit lostjob -- 'echo working; sleep 300' >/dev/null 2>&1
/bin/bash "$R/rx" run -- 'echo started; sleep 300' >"$W/lost.out" 2>"$W/lost.err" &
pid=$!
wait_for 20 grep -q started "$W/lost.out" || nok "lost-run did not start"
docker restart -t 2 "$C" >/dev/null
wait $pid; rc=$?
eq "rx run whose box restarted exits 255" 255 $rc
has "rx run whose box restarted explains" "rx wait run" "$(cat "$W/lost.err")"
wait_for 60 ssh_ready || nok "box did not come back after restart"
t0=$SECONDS
out=$(rx ps 2>&1)
has "ps reports the submitted job lost" "lost (box restarted)" "$(echo "$out" | grep lostjob)"
has "ps reports the run lost" "lost (box restarted)" "$(echo "$out" | grep '^run ')"
out=$(rx wait lostjob 2>&1); rc=$?
eq "wait on a lost job exits 255" 255 $rc
has "wait on a lost job says so" "lost (box restarted)" "$out"
has "wait on a lost job still shows its log" working "$out"
[ $((SECONDS - t0)) -lt 25 ] && ok "lost-job reporting is quick, no hang ($((SECONDS - t0))s)" || nok "lost-job reporting slow ($((SECONDS - t0))s)"
out=$(rx run -- 'cat kept.txt; echo ok-after-restart'); rc=$?
eq "sync and run work after a restart (data disk remounted)" "0 keep
ok-after-restart" "$rc $out"
eq "data disk is XFS after restart" xfs "$(boxroot 'findmnt -n -o FSTYPE /data')"

# --- reflink: job snapshots are reflinked copies on XFS ---
box 'echo r >/data/rx/reflink-probe && cp --reflink=always /data/rx/reflink-probe /data/rx/reflink-probe2' &&
  ok "reflink works on the data disk (snapshots are instant)" || nok "reflink failed on the data disk"

# --- wake: box stopped, rx run starts it through gcloud and succeeds ---
docker stop -t 2 "$C" >/dev/null
: >"$RX_TEST_GCLOUD_LOG"
out=$(rx run -- 'echo woke' 2>"$W/wake.err"); rc=$?
eq "rx run on a stopped box wakes it and succeeds" "0 woke" "$rc $out"
has "wake prints the waking message" "rx: waking box…" "$(cat "$W/wake.err")"
has "wake called gcloud start with instance, zone, project" \
  "compute instances start rx-test-box --zone test-zone-a --project test-project --quiet" "$(gl)"

# --- stockout: clear, distinct, immediate ---
docker stop -t 2 "$C" >/dev/null
t0=$SECONDS
out=$(RX_TEST_GCLOUD_STOCKOUT=1 rx run -- true 2>&1); rc=$?
eq "stockout exits 75" 75 $rc
has "stockout message" "rx: box is stocked out in test-zone-a; try again later" "$out"
[ $((SECONDS - t0)) -lt 30 ] && ok "stockout fails fast ($((SECONDS - t0))s)" || nok "stockout took $((SECONDS - t0))s"
out=$(RX_TEST_GCLOUD_STOCKOUT="$T/fixtures/gce-stockout-create.txt" rx run -- true 2>&1); rc=$?
eq "real GCE stockout text (ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS fixture) exits 75" 75 $rc
has "real GCE stockout text: clear message" "rx: box is stocked out in test-zone-a; try again later" "$out"

# --- up / status / stop ---
out=$(rx up 2>&1); rc=$?
eq "rx up starts the box" 0 $rc
has "rx up shows box status" "running rx jobs: 0" "$out"
running_state true && ok "container running after rx up" || nok "container not running after rx up"
out=$(rx status 2>&1)
has "status shows instance state" "instance rx-test-box: RUNNING" "$out"
has "status shows data disk usage" "data disk /data:" "$out"
rx submit blocker -- 'sleep 30' >/dev/null 2>&1
out=$(rx stop 2>&1); rc=$?
eq "rx stop refuses while jobs run" 2 $rc
has "rx stop says why" "still running" "$out"
rx kill blocker >/dev/null 2>&1
rx stop >/dev/null 2>&1; eq "rx stop with no jobs exits 0" 0 $?
wait_for 20 running_state false && ok "container stopped by rx stop" || nok "container still running after rx stop"
out=$(rx status 2>&1)
has "status on a stopped box" "TERMINATED" "$out"
has "status on a stopped box: unreachable" "unreachable" "$out"
rx up >/dev/null 2>&1 || nok "rx up after stop failed"

# --- data disk warning above 85%, rx grow ---
box 'fallocate -l 3500M /data/rx/filler'
out=$(rx status 2>&1)
has "status warns when the data disk is over 85% full" "rx: warning: the box data disk is" "$out"
out=$(rx run -- true 2>&1)
eq "rx run warns about the full disk once" 1 "$(echo "$out" | grep -c 'data disk is')"
before=$(box "df -B1M --output=size /data | tail -1" | tr -d ' ')
out=$(rx grow 8GB 2>&1); rc=$?
eq "rx grow exits 0" 0 $rc
has "rx grow called gcloud disks resize" "compute disks resize rx-data --zone test-zone-a --project test-project --quiet --size 8GB" "$(gl)"
after=$(box "df -B1M --output=size /data | tail -1" | tr -d ' ')
[ "$after" -gt $((before + 3000)) ] && ok "filesystem grew ($before MiB -> $after MiB)" || nok "filesystem did not grow ($before -> $after)" "$out"
hasnt "no warning after growing" "warning" "$out"
box 'rm -f /data/rx/filler'
RX_GCE_DATA_DISK='' rx grow 9GB >/dev/null 2>&1; eq "rx grow without RX_GCE_DATA_DISK: usage error" 2 $?
