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
rx run -- 'cd crates/core && cargo test -- --nocapture'   # one arg = shell string
rx submit fuzz-parser --mem 64G -- cargo fuzz run parser -- -max_total_time=3600
rx ps            # this worktree's jobs: running, exit N, killed, lost (box restarted)
rx wait <name>   # reattach and stream; exits with the job's code (to block, raise your shell tool's timeout to its max, e.g. 600000 ms, and run `timeout 590 rx wait <name>`; never loop or sleep on rx ps)
rx logs <name> 100
rx kill <name>
rx pull fuzz/artifacts fuzz-parser          # data into ./.rx-out/ (from that job's snapshot)
```

- After `--`, a single argument is a shell string (pipes, `&&`, globs work). Several arguments are run as an argv, word by word, with no shell.
- Commands run in the box copy of your current directory. `rx run` reuses one warm dir per worktree; `rx sh` opens a shell there.
- For quick looks (`uptime`, `docker ps`, `ls target/`), use `rx sh -- <cmd>`: no sync, no job, and it doesn't wait behind a running `rx run`. It sees the files as last synced.
- Prefer `rx run` for anything that finishes within your tool timeout; its dir is the warmest and it has the least overhead. Use `submit` only for jobs that may outlive the timeout.
- Job names are `[A-Za-z0-9_-]`; `run` is the `rx run` job. Reuse a finished job's name for reruns: its snapshot and build stay warm. Only a name that's still running is refused.
- Keep output on stdout (`cmd 2>&1 | tee out.log`, not `>out.log`), so `rx logs` and `rx wait` show progress. A pipe inside the job (`| tail`, `| grep`, `| tee`) makes the job's exit code the last command's, so start the string with `set -o pipefail;`. Filters like `tail` or `grep` hold back output from `rx logs`, so filter afterwards (`rx logs <name> 50`) instead.
- In shell strings, chain setup steps with `&&`, so a failed step doesn't run the job on missing files.
- Install a new Rust toolchain or target once (`rx run -- rustup toolchain install <tc>`, `rx run -- rustup target add --toolchain <tc> wasm32-unknown-unknown wasm32-wasip2`) before starting parallel jobs that need it; concurrent installs of the same toolchain fail. `E0463 can't find crate for 'std'` means the box lacks the target, not that the check must run locally.
- For near-workspaces tests, set `NEAR_SANDBOX_BIN_PATH=~/.near/near-sandbox-2.14.0/Linux-x86_64/near-sandbox` in the job, on every run in that worktree (changing it rebuilds near-workspaces). The sandbox's own download into mbx's read-only shared OUT_DIR fails with `could not create download path`. The override wins over any version the project asks for, so if yours differs, download that version next to it. `cargo-near` (0.21.0) is preinstalled; `compiling test-contract ...: IO` means it's missing.
- Put big scratch data (clones, downloads, Docker `-v` output dirs) under `~/rx/scratch/<name>`, which is on the data disk and never cleaned by rx, and delete it when done. The box `$HOME` and `/tmp` are on the small boot disk.
- `.git` isn't synced. To apply a patch on the box, use `patch -p1 <x.patch`, not `git apply` or `git diff`.

## Rules

1. **Linux artifacts stay on the box.** Run tests and binaries remotely. Pull only data (corpora, crash inputs, coverage reports, logs) with `rx pull`, never binaries to run on the Mac.
2. **Timeouts detach; they don't kill.** If your shell timeout interrupts `rx run`, the job keeps running. Don't restart it. Run `rx ps` and then `rx wait run` to get the result. (A hard kill may skip the detach message, so check `rx ps` whenever a run was cut off.) Use `rx submit` up front for anything that may outlive your timeout, then `rx wait <name>`, chained with `&&`: `rx submit ... | tail` hides a refused submit ("still running"), and you end up waiting on the old job.
3. **A second `rx run` in the same worktree waits** for the first. That's expected; don't kill the first to get ahead. Parallel agents or subagents sharing one worktree should each `rx submit` under their own name instead of all using `rx run`, so they don't queue behind each other.
4. **Submitted jobs run on a snapshot** taken at submit time. Edits you make afterwards don't reach them. Resubmit to test new code, and `rx pull <path> <name>` to get a job's outputs (paths are relative to your directory's box copy, not `~`). Each job name keeps its snapshot between runs and the next submit syncs your changes into it, so rerun under the same name to build incrementally (any build tool). A new name starts from a copy of the worktree's box dir, which only `rx run` updates; after a passing full build, run it once with `rx run` and let it finish before submitting new names, so they start warm. Use a new name when you want a clean slate.
5. **No local locks or parallelism caps for rx.** Local shared-machine rules (build locks, `-j 2`, TLC `-workers 2`, small `--test-threads`) apply only on the Mac. Use the whole box (60 cores): `-workers auto` for TLC, and cargo's default `-j` and `--test-threads`. Run as many jobs at once as you need; the box shares its CPUs between them. Never hold a local lock while running or waiting on an rx job. Heavy oversubscription slows every job, so timing-sensitive tests and timeouts (proptest deadlines, harness timeouts) can fail spuriously; check `rx sh -- uptime` first and treat a timeout under heavy load as no result, not a finding.
6. **No secrets.** Only `RUST_LOG` and `RUST_BACKTRACE` are forwarded (more via `RX_ENV`). Untracked files are synced unless ignored (`.gitignore`, `.git/info/exclude`, global excludes), so never put secrets in them, and never paste tokens into commands. Files inside submodules are synced, but untracked files inside submodules are not. If rx prints `warning: syncing untracked <path>, which looks like a secret`, tell the user.
7. **Exit codes:** the command's own, 130 Ctrl-C, 143 killed (or rx detached), 255 box unreachable or job lost (box restarted; a job can also exit 255 itself, so check `rx ps` before rerunning: `exit 255` is the job's own code, `lost` means rerun it), 75 box stocked out (retry later, or run locally if you can't wait; don't loop tightly, and never create VMs yourself), 2 usage error or refused.
8. **Clean up.** `rx kill` jobs you no longer need, from the worktree that started them (job names are per worktree) and before you remove that worktree. When you finish, run `rx ps` and report any jobs you left running, with their names and how to check them (`rx wait <name>`). Docker containers run outside rx's CPU weights, so a long container sweep competes equally with every agent's builds; give it `--cpus <n>` when others are busy (`rx sh -- uptime`). They belong to Docker, not the job, so `rx kill` can leave them running; check `rx sh -- docker ps` and stop your own with `rx sh -- docker stop <id>`.
