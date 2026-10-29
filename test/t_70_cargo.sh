# shellcheck shell=bash disable=SC2016,SC2154,SC2034,SC2164,SC2015,SC2001 # sourced by run.sh; remote strings are single-quoted on purpose
# Real cargo through mbx on the box: build + test a tiny crate, warm rebuilds, submit gets its own target.
mkrepo tinycrate
rm -rf src && mkdir -p src tests
cat >Cargo.toml <<'EOF'
[package]
name = "tinycrate"
version = "0.1.0"
edition = "2021"
EOF
cat >src/lib.rs <<'EOF'
pub fn add(a: u64, b: u64) -> u64 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(2, 2), 4);
    }
}
EOF
cat >tests/it.rs <<'EOF'
#[test]
fn integration() {
    assert_eq!(tinycrate::add(40, 2), 42);
}
EOF
printf '/target\n' >.gitignore
git add -A

out=$(rx run -- cargo test 2>&1); rc=$?
eq "rx run -- cargo test exits 0" 0 $rc
has "unit test ran" "test tests::adds ... ok" "$out"
has "integration test ran" "test integration ... ok" "$out"
has "cargo ran through mbx" "mbx[" "$out"
D=$(wtdir)
has "target is an mbx managed target symlink on /data" "/data/mbx/targets/" "$(box "readlink $D/target")"
hasnt "no ANSI color codes (CARGO_TERM_COLOR=never)" $'\033[' "$out"

out=$(rx run -- cargo test 2>&1)
hasnt "second run is warm (no recompile)" "Compiling tinycrate" "$out"

sed -i '' 's/a + b/a + b + 1/' src/lib.rs
out=$(rx run -- cargo test 2>&1); rc=$?
eq "failing test propagates cargo's exit code" 101 $rc
has "failure output arrives" "assertion" "$out"
has "failure has a usable file:line" "src/lib.rs:" "$out"
sed -i '' 's/a + b + 1/a + b/' src/lib.rs
rx run -- cargo test >/dev/null 2>&1 || nok "cargo test after restoring the source failed"

rx submit cargojob -- cargo test --quiet >/dev/null 2>&1
rx wait cargojob >"$W/cargojob.out" 2>&1; rc=$?
eq "submitted cargo test passes" 0 $rc
S=$(box "echo ~/rx/snap/$(basename "$D")-cargojob")
t1=$(box "readlink $D/target") t2=$(box "readlink $S/target")
[ -n "$t2" ] && [ "$t1" != "$t2" ] && ok "snapshot got its own managed target ($t2)" || nok "snapshot shares the worktree target" "$t1 vs $t2"

rx submit cargojob -- cargo test >/dev/null 2>&1
out=$(rx wait cargojob 2>&1); rc=$?
eq "rerun under the same name passes" 0 $rc
hasnt "rerun under the same name builds warm" "Compiling tinycrate" "$out"

out=$(rx run -- cargo test 2>&1)
hasnt "the worktree's target is still warm after the job" "Compiling tinycrate" "$out"
