# rx

`rx` lets coding agents on a Mac run heavy commands on one big Linux box: cargo build and test, cargo-fuzz, TLA+ model checking, docker build. It syncs the current git worktree, runs the command there under systemd, streams the output back with paths rewritten to local ones, and exits with the remote exit code.

```sh
rx run -- cargo test --workspace         # sync, run, stream, exit with its code
rx submit fuzz -- cargo fuzz run parser  # long job on a frozen snapshot; returns at once
rx wait fuzz; rx logs fuzz 50; rx ps; rx kill fuzz
rx pull fuzz/artifacts fuzz              # data from the box into ./.rx-out/
rx sh                                    # shell in this worktree's box dir
rx up | rx status | rx stop | rx grow 1000GB
```

## Install

```sh
brew install rsync                       # needs upstream rsync >= 3.1; /usr/bin/rsync is openrsync
ln -s "$PWD/rx" ~/.local/bin/rx          # or /usr/local/bin: a dir on the *default* PATH
mkdir -p ~/.config/rx && cat >~/.config/rx/config <<'EOF'
RX_HOST=buildbox                         # ssh alias (Tailscale SSH in production)
RX_GCE_INSTANCE=buildbox RX_GCE_ZONE=us-central1-a RX_GCE_PROJECT=your-project
RX_GCE_DATA_DISK=buildbox-data
EOF
```

Agent shells often read no rc file, so put the `rx` symlink in a directory that's on PATH without your shell config, such as `~/.local/bin` (if your agent's PATH has it) or `/usr/local/bin`. Check by asking the agent to run `command -v rx`.

To install the skill, copy or symlink `skill/` to `~/.claude/skills/remote-exec/` for Claude Code, and to `~/.agents/skills/remote-exec/` for Codex:

```sh
ln -s "$PWD/skill" ~/.claude/skills/remote-exec
ln -s "$PWD/skill" ~/.agents/skills/remote-exec
```

Codex: its workspace-write sandbox blocks network access by default, so `rx`'s ssh fails until you enable network for the sandbox (`sandbox_workspace_write.network_access = true` in `~/.codex/config.toml`) or approve the command to run outside the sandbox.

Set up the box with [`box/setup.sh`](box/README.md). The client is one bash file that runs under macOS `/bin/bash` 3.2. Agents get [`skill/SKILL.md`](skill/SKILL.md), or the short [`AGENTS-snippet.md`](AGENTS-snippet.md).

Config is sourced from `~/.config/rx/config` (or `$RX_CONFIG`): `RX_HOST`, `RX_GCE_INSTANCE`, `RX_GCE_ZONE`, `RX_GCE_PROJECT`, `RX_GCE_DATA_DISK`, `RX_SSH_CONFIG` (passed as `ssh -F`), and `RX_ENV`. `RX_ENV` lists the env var names forwarded to jobs (default `RUST_LOG RUST_BACKTRACE`); nothing else from your environment goes over. Jobs get `CARGO_TERM_COLOR=never` unless you forward your own.

## Exit codes

| Code | Meaning |
| --- | --- |
| the job's | the command finished (`rx run`, `rx wait`) |
| 130 | Ctrl-C (`rx run` stops the job; `rx wait` only detaches) |
| 143 | the job was killed or stopped; or rx itself got TERM/HUP and detached (the job keeps running) |
| 255 | box unreachable, connection lost, or the job was lost because the box restarted |
| 75 | wake failed because the Spot zone is stocked out; try again later |
| 2 | usage error, or refused (e.g. `submit` with a name that's still running) |

## How it works

- **Remote dirs.** Each worktree gets `~/rx/w/<repo>-<hash of the worktree path>` on the box, so worktrees never collide. `rx run` uses it in place, so builds stay warm. `rx submit` makes a `cp -a --reflink` snapshot in `~/rx/snap/` (instant on XFS), so later syncs and edits never touch a running job. The snapshot drops `target` symlinks so mbx gives it its own target dir and lock.
- **Sync.** The file set is `git ls-files --cached --others --exclude-standard`, so `.gitignore`, `.git/info/exclude` and global excludes apply. Untracked symlinks (e.g. a local mbx `target`) and `.git` are never sent. The box keeps the last manifest and deletes exactly the paths that left it (plus tracked files deleted locally), so build output, fuzz corpora and the box's own `target` symlink are never deleted. rsync `-a` keeps mtimes, so cargo doesn't rebuild needlessly.
- **One lock.** The client's rsync starts its box side through `rx __remote recv`. That takes a box-side `flock`, waits for (run) or refuses (submit) a still-active job of that name, deletes, receives, and starts the systemd unit, all under the same lock. A second `rx run` in the same worktree waits for the first.
- **Jobs.** Each job is a `systemd-run --user --collect` unit (linger is on) whose log and exit code live in `~/rx/jobs/<wtid>/.<name>@<token>/`. Stopping the unit kills its whole cgroup, setsid'd children included. `rx run` units go in `rx-run.slice` (CPUWeight 1000) and submitted ones in `rx-job.slice` (CPUWeight 100), so fuzzers can't starve interactive builds. `submit --mem 64G` sets MemoryMax.
- **Signals.** Ctrl-C (INT) on `rx run` stops the job. TERM and HUP (an agent's shell timeout) only detach and print `rx wait run`. `rx wait` never kills.
- **Lost jobs.** Each job records the boot ID plus the systemd user manager's invocation ID. If the box restarted (Spot preemption stops the VM; the disk survives), `rx ps` and `rx wait` say `lost (box restarted)` instead of hanging or inventing an exit code.
- **Self-install.** Every call pipes a tar of the client script and the job spec over ssh. A small prelude installs it as `~/.rx/bin/rx-<hash>` when it changed, so there is no quoting across ssh and nothing to deploy.
- **Wake and idle.** If ssh fails and GCE settings exist, rx runs `gcloud compute instances start` and waits for ssh (about 3 minutes max). The box powers itself off about 30 minutes after the last rx call or ssh session ends (see `box/README.md`).
- **Connection.** ssh with ControlMaster/ControlPersist (sockets in `~/.ssh/rx-%C`, or `$RX_CONTROL_DIR`). A hung master, e.g. after a preemption, is detected and replaced.

## Limits

- Submodule contents aren't synced (only the gitlink path).
- Remote stdout and stderr arrive merged on stdout; jobs get no stdin.
- Untracked files that aren't ignored get synced, so keep secrets gitignored. rx warns (it doesn't block) when an untracked, un-ignored file looks like one (`.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `*credentials*`, `*.p12`). It prints at most 5 names per sync.
- A client killed with SIGKILL can leave its local ssh follower printing until the job ends; the job itself is unaffected.

## Tests

`test/run.sh [pattern]` builds an Ubuntu 24.04 systemd container (the stand-in box, with loopback XFS at `/data`), boots it with `--privileged`, and runs `test/t_*.sh` through macOS `/bin/bash` 3.2. A fake `gcloud` on PATH maps start, stop and resize onto docker. The real gcloud is never called.
