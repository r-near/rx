## Build box (rx)

- Run heavy or Linux-only commands (cargo build/test/nextest/clippy on more than a small crate, cargo-fuzz, `tlc`, benchmarks, `docker build`) on the build box: `rx run -- <cmd>`. It syncs this worktree and exits with the command's code. Prefer `rx run` for anything that finishes within your tool timeout; it's the warmest and fastest.
- Use `rx submit <name> -- <cmd>` only for jobs that may outlive your timeout, then `rx wait <name>`. Submitted jobs run on a snapshot taken at submit time. Reusing a finished job's name is fine.
- rx jobs take no local build locks and no parallelism caps (`-j`, TLC `-workers 2`, `--test-threads`); those rules are for the Mac. Use the whole box: TLC `-workers auto`, cargo defaults, and as many jobs at once as you need. Never hold a local lock while waiting on an rx job.
- Keep job output on stdout (`| tee`, not `>file`). Start piped commands with `set -o pipefail;`. Chain setup steps with `&&`. `.git` isn't on the box: use `patch -p1`, not `git apply`.
- If a run was cut off by a timeout, it is still running: use `rx ps` and `rx wait run`. Don't restart it.
- Linux artifacts stay on the box. Use `rx pull <path> [name]` only for data. Never put secrets in commands or in un-ignored files.
- Before finishing, `rx kill` jobs you no longer need and report any still running (`rx ps`).
