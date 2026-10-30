---
name: remote-exec
description: Offload heavy or Linux-only commands to the build box with `rx`, including cargo build/test/clippy/nextest beyond one small crate, full test suites, cargo-fuzz, TLA+ model checking (tlc), benchmarks and docker build. Use when a command would take more than about a minute locally, needs Linux, or may outlive your shell timeout.
---

# Remote execution with rx

`rx` syncs the current git worktree to a 60-core Linux box, runs a command there, streams the output (paths rewritten to local ones), and exits with the command's exit code. It installs and updates its box side itself.

## Offload or stay local

- **Offload:** builds and tests beyond one small crate, `--workspace` runs, clippy on big workspaces, nextest, cargo-fuzz, llvm-cov, `tlc`, benchmarks, `docker build`, and anything Linux-only.
- **Stay local:** `git`, file edits, searches, `cargo fmt`, `cargo check` on a small crate, and quick one-off scripts.

## Commands

```sh
rx run -- cargo nextest run --workspace     # foreground; exit code is the command's
rx run -- 'cd crates/core && cargo test -- --nocapture 2>&1 | tail -50'   # one arg = shell string
rx submit fuzz-parser --mem 64G -- cargo fuzz run parser -- -max_total_time=3600
rx ps            # this worktree's jobs: running, exit N, killed, lost (box restarted)
rx wait <name>   # reattach and stream; exits with the job's code
rx logs <name> 100
rx kill <name>
rx pull fuzz/artifacts fuzz-parser          # data into ./.rx-out/ (from that job's snapshot)
```

- After `--`, a single argument is a shell string (pipes, `&&`, globs work). Several arguments are run as an argv, word by word, with no shell.
- Commands run in the box copy of your current directory. `rx run` reuses one warm dir per worktree; `rx sh` opens a shell there.
- Prefer `rx run` for anything that finishes within your tool timeout; its dir is the warmest and it has the least overhead. Use `submit` only for jobs that may outlive the timeout.
- Job names are `[A-Za-z0-9_-]`; `run` is the `rx run` job. Reuse a finished job's name for reruns: its snapshot and build stay warm. Only a name that's still running is refused.
- Keep output on stdout (`cmd 2>&1 | tee out.log`, not `>out.log`), so `rx logs` and `rx wait` show progress.
- In shell strings, chain setup steps with `&&`, so a failed step doesn't run the job on missing files.
- `.git` isn't synced. To apply a patch on the box, use `patch -p1 <x.patch`, not `git apply` or `git diff`.

## Rules

1. **Linux artifacts stay on the box.** Run tests and binaries remotely. Pull only data (corpora, crash inputs, coverage reports, logs) with `rx pull`, never binaries to run on the Mac.
2. **Timeouts detach; they don't kill.** If your shell timeout interrupts `rx run`, the job keeps running. Don't restart it. Run `rx ps` and then `rx wait run` to get the result. (A hard kill may skip the detach message, so check `rx ps` whenever a run was cut off.) Use `rx submit` up front for anything that may outlive your timeout, then `rx wait <name>`.
3. **A second `rx run` in the same worktree waits** for the first. That's expected; don't kill the first to get ahead.
4. **Submitted jobs run on a snapshot** taken at submit time. Edits you make afterwards don't reach them. Resubmit to test new code, and `rx pull <path> <name>` to get a job's outputs. Each job name has its own snapshot, kept warm between runs, so rerun under the same name to build incrementally; a new name starts a cold build.
5. **No local locks or parallelism caps for rx.** Local shared-machine rules (build locks, `-j 2`, TLC `-workers 2`, small `--test-threads`) apply only on the Mac. Use the whole box (60 cores): `-workers auto` for TLC, and cargo's default `-j` and `--test-threads`. Run as many jobs at once as you need; the box shares its CPUs between them. Never hold a local lock while running or waiting on an rx job.
6. **No secrets.** Only `RUST_LOG` and `RUST_BACKTRACE` are forwarded (more via `RX_ENV`). Untracked files that aren't gitignored are synced, so never put secrets in them, and never paste tokens into commands. If rx prints `warning: syncing untracked <path>, which looks like a secret`, tell the user.
7. **Exit codes:** the command's own, 130 Ctrl-C, 143 killed (or rx detached), 255 box unreachable or job lost (box restarted, so rerun it), 75 box stocked out (retry later, or run locally if you can't wait; don't loop tightly, and never create VMs yourself), 2 usage error or refused.
8. **Clean up.** `rx kill` jobs you no longer need. When you finish, run `rx ps` and report any jobs you left running, with their names and how to check them (`rx wait <name>`).
