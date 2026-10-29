## Build box (rx)

- Run heavy or Linux-only commands (cargo build/test/nextest/clippy on more than a small crate, cargo-fuzz, `tlc`, benchmarks, `docker build`) on the build box: `rx run -- <cmd>`. It syncs this worktree and exits with the command's code.
- Use `rx submit <name> -- <cmd>` for anything that may outlive your shell timeout, then `rx wait <name>`. Submitted jobs run on a snapshot taken at submit time.
- If a run was cut off by a timeout, it is still running: use `rx ps` and `rx wait run`. Don't restart it.
- Linux artifacts stay on the box. Use `rx pull <path> [name]` only for data. Never put secrets in commands or in un-ignored files.
- Before finishing, `rx kill` jobs you no longer need and report any still running (`rx ps`).
