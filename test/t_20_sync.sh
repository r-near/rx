# shellcheck shell=bash disable=SC2016,SC2154,SC2034,SC2164,SC2015,SC2001 # sourced by run.sh; remote strings are single-quoted on purpose
# Sync: the manifest-driven file set, deletions and renames, remote-only paths, mtimes, .git.
mkrepo syncrepo
printf '*.log\n/ignored-dir/\n' >.gitignore
echo 'secret-global' >global.tmp && printf '*.tmp\n' >"$W/global-ignore"
git config core.excludesFile "$W/global-ignore"
echo info >info-excluded && echo info-excluded >>.git/info/exclude
echo log >build.log && mkdir -p ignored-dir && echo x >ignored-dir/x
mkdir -p dir && echo b >dir/b.txt && echo c >c.txt && echo gone >staged-rm.txt && echo 'with space' >'sp ace ü.txt'
git add -A && echo untracked >untracked.txt
rx run -- true || nok "first sync run failed"
D=$(wtdir)
list() { box "cd $D && find . -path ./target -prune -o -type f -print -o -type l -print | sed 's|^\./||' | LC_ALL=C sort"; }
eq "first sync sends tracked + untracked, not ignored/excluded/.git" ".gitignore
a.txt
c.txt
dir/b.txt
sp ace ü.txt
src/main.rs
staged-rm.txt
untracked.txt" "$(list)"
box "test ! -e $D/.git" && ok ".git is not synced" || nok ".git is synced"

# Remote-only state the build creates: mbx target symlink, real target dirs, fuzz corpus, outputs.
box "cd $D && mkdir -p /tmp/managed-target && ln -sfn /tmp/managed-target target && mkdir -p sub/target fuzz/corpus fuzz/artifacts &&
  echo o >sub/target/out && echo s >fuzz/corpus/seed1 && echo crash >fuzz/artifacts/crash-1 && echo bin >build-output.bin"

rm a.txt                    # deleted, still in the index
mkdir -p dir2 && mv dir/b.txt dir2/b.txt # renamed without git (old path tracked+missing, new untracked)
git mv c.txt d.txt          # renamed with git
git rm -qf staged-rm.txt    # removed with git
echo changed >untracked.txt
ln -s /nonexistent/mac/path target-like && ln -sfn /nonexistent/mbx/target target # untracked local symlinks
touch -t 202001020304.05 'sp ace ü.txt'
rx run -- true || nok "second sync run failed"
eq "deletions and renames propagate; remote-only files survive" ".gitignore
build-output.bin
d.txt
dir2/b.txt
fuzz/artifacts/crash-1
fuzz/corpus/seed1
sp ace ü.txt
src/main.rs
sub/target/out
untracked.txt" "$(list)"
eq "remote mbx target symlink survives (not replaced by the local one)" /tmp/managed-target "$(box "readlink $D/target")"
box "test ! -d $D/dir" && ok "emptied directory removed" || nok "emptied directory left behind"
eq "file content updated" changed "$(box "cat $D/untracked.txt")"
eq "mtime preserved" "$(stat -f %m 'sp ace ü.txt')" "$(box "stat -c %Y '$D/sp ace ü.txt'")"
want=$( (git ls-files -z --cached; git ls-files -z --others --exclude-standard) | tr '\0' '\n' | grep -vx -e target -e target-like | LC_ALL=C sort)
eq "box manifest matches the local file set" "$want" "$(box "tr '\0' '\n' <~/rx/m/$(basename "$D") | LC_ALL=C sort")"

# file -> directory and directory -> file at the same path
echo f >flip && git add flip && rx run -- true
rm flip && mkdir flip && echo inner >flip/inner && git add -A
out=$(rx run -- 'cat flip/inner'); eq "file replaced by a directory" inner "$out"
rm -rf flip && echo back >flip && git add -A
out=$(rx run -- 'cat flip'); eq "directory replaced by a file" back "$out"

# repeated syncs are stable
m1=$(box "md5sum <~/rx/m/$(basename "$D")"); rx run -- true; m2=$(box "md5sum <~/rx/m/$(basename "$D")")
eq "manifest stable across a no-op sync" "$m1" "$m2"
eq "remote-only files still there after repeated syncs" "o s crash" "$(box "cd $D && echo \$(cat sub/target/out fuzz/corpus/seed1 fuzz/artifacts/crash-1)")"

# Worktree isolation: two worktrees of one repo get separate dirs and run concurrently.
git worktree add -q --orphan -b wt2 "$W/repos/syncrepo-wt2"
(cd "$W/repos/syncrepo-wt2" && echo wt2 > owner.txt && git add owner.txt)
echo wt1 > owner.txt && git add owner.txt
rx run -- 'sleep 2; cat owner.txt' >"$W/wt1.out" 2>&1 &
p1=$!
(cd "$W/repos/syncrepo-wt2" && rx run -- 'sleep 2; cat owner.txt') >"$W/wt2.out" 2>&1 &
p2=$!
t0=$SECONDS; wait $p1; r1=$?; wait $p2; r2=$?
eq "worktree 1 sees its own files" "0 wt1" "$r1 $(cat "$W/wt1.out")"
eq "worktree 2 sees its own files" "0 wt2" "$r2 $(cat "$W/wt2.out")"
[ $((SECONDS - t0)) -lt 6 ] && ok "worktrees ran concurrently ($((SECONDS - t0))s)" || nok "worktrees serialized ($((SECONDS - t0))s)"
eq "two box dirs for one repo" 2 "$(box 'ls -d ~/rx/w/syncrepo-* | wc -l' | tr -d ' ')"

# Untracked, un-ignored secret-looking files: warn (capped), don't block; tracked/ignored: silent.
mkrepo secrets
printf 'ignored.pem\n' >.gitignore && echo x >ignored.pem
echo x >tracked.key && git add tracked.key .gitignore
mkdir -p keys && for f in .env .env.local a.p12 aws-credentials.json b.key id_ed25519 keys/server.pem; do echo x >"$f"; done
out=$(rx run -- 'test -f .env && echo synced' 2>"$W/secrets.err"); rc=$?
err=$(cat "$W/secrets.err")
eq "secret-looking files don't block the run (and are synced)" "0 synced" "$rc $out"
has "warning names the file" "rx: warning: syncing untracked .env, which looks like a secret; gitignore it if it shouldn't leave this Mac" "$err"
eq "at most 5 per-file warnings" 5 "$(grep -c 'rx: warning: syncing untracked' "$W/secrets.err")"
has "then a summary line" "more untracked secret-looking files not listed" "$err"
hasnt "no warning for tracked files" tracked.key "$err"
hasnt "no warning for ignored files" ignored.pem "$err"
