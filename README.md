# rx

Offload your coding agents' heavy work to one big Linux box.

Coding agents are cheap to run but their builds aren't. A few agents running `cargo test`, fuzzers, Miri or TLA+ in parallel will flatten a laptop. `rx` keeps the agents where they are (a laptop, or an always-on Mac mini) and sends the heavy commands to a cloud VM:

```sh
rx run -- cargo test --workspace
```

That syncs the current git worktree to the box, runs the command there, streams the output back (with box paths rewritten to your local ones) and exits with the command's exit code. To the agent it looks like running the command locally, just faster and without melting your machine.

In its first 30 hours on one 60-vCPU Spot VM, agents ran about 400 jobs from 58 worktrees: Rust builds and test suites, Miri and Kani sweeps, fuzzers, TLA+ model checking, Lean proofs and Docker builds. At peak the box was running about 17,000 processes. None of that touched the Mac.

## What you get

- **One bash script** (`rx`) on your Mac, plus a setup script for the box. No daemon, no server, nothing to deploy: the client ships its own box half on every call.
- **A skill file for agents** ([`skill/SKILL.md`](skill/SKILL.md)) so Claude Code and Codex know when and how to use it, and a short version for `AGENTS.md`/`CLAUDE.md` ([`AGENTS-snippet.md`](AGENTS-snippet.md)).
- **A box that turns itself off.** It powers down about 45 minutes after the last rx call and `rx` wakes it again on the next one (about 45 s). You pay for the hours agents actually use it.
- **Warm builds.** Each worktree keeps its own dir on the box, so incremental builds stay incremental. Cargo builds share a compile cache across worktrees through [mbx](https://github.com/jdx/mr-boxington).

## Commands

```sh
rx run -- cargo test --workspace         # sync, run, stream, exit with its code
rx submit fuzz -- cargo fuzz run parser  # long job on its own snapshot; returns at once
rx wait fuzz                             # reattach: stream the log, exit with the job's code
rx logs fuzz 50; rx ps; rx kill fuzz
rx pull fuzz/artifacts fuzz              # copy data from the box into ./.rx-out/
rx sh                                    # shell in this worktree's box dir
rx sh -- uptime                          # one quick command: no sync, no job, no queue
rx up | rx status | rx stop | rx grow 1000GB
```

`rx run` is for anything that finishes within the agent's shell timeout. `rx submit` is for jobs that may outlive it, like fuzzers or long model checks; reuse the same name to rerun incrementally.

## What it costs

The reference box is a GCE `c3d-standard-60` Spot VM (60 vCPUs, 240 GB RAM): about $0.31/hour while it runs, plus about $60/month for the boot and 500 GB data disks. A full working day of agent use comes to a few dollars.

## Setup

You need a GCP project with Spot quota, a Tailscale tailnet, and on the Mac `gcloud`, Tailscale and Homebrew's `rsync` (macOS's `/usr/bin/rsync` is openrsync, which won't work).

1. **Create the VM.** Follow [`box/README.md`](box/README.md): a dedicated network with no inbound firewall rules, a Spot VM with a separate data disk, and Tailscale SSH as the only way in. The box gets no GCP credentials.
2. **Set up the box.** Copy `box/` over and run `setup.sh` (also in [`box/README.md`](box/README.md)). It installs Docker, Rust, mbx, Node, Java and TLA+, common build tools, and the idle-shutdown and cleanup timers. It's idempotent, so rerun it after changes.
3. **Install the client:**

   ```sh
   brew install rsync
   ln -s "$PWD/rx" ~/.local/bin/rx          # any dir on the agent's PATH; check with `command -v rx`
   mkdir -p ~/.config/rx && cat >~/.config/rx/config <<'EOF'
   RX_HOST=buildbox                         # ssh alias of the box
   RX_GCE_INSTANCE=buildbox RX_GCE_ZONE=your-zone RX_GCE_PROJECT=your-project
   RX_GCE_DATA_DISK=buildbox-data
   EOF
   ```

   Agent shells often read no rc file, so pick a directory that's on PATH without your shell config, such as `~/.local/bin` (if your agent's PATH has it) or `/usr/local/bin`.

4. **Teach your agents.** Symlink the skill and paste [`AGENTS-snippet.md`](AGENTS-snippet.md) into your global `CLAUDE.md` or `AGENTS.md`:

   ```sh
   ln -s "$PWD/skill" ~/.claude/skills/remote-exec    # Claude Code
   ln -s "$PWD/skill" ~/.agents/skills/remote-exec    # Codex
   ```

   Codex's workspace-write sandbox blocks network access by default, so `rx` fails until you set `sandbox_workspace_write.network_access = true` in `~/.codex/config.toml` or approve the command to run outside the sandbox.

5. **Try it:** `rx run -- uname -a` from any git worktree.

### Config

`~/.config/rx/config` (or `$RX_CONFIG`) is a sourced shell file:

| Variable | Meaning |
| --- | --- |
| `RX_HOST` | ssh host alias of the box (default `buildbox`) |
| `RX_GCE_INSTANCE`, `RX_GCE_ZONE`, `RX_GCE_PROJECT` | enable wake, `rx up`, `rx status` and `rx stop` via gcloud |
| `RX_GCE_DATA_DISK` | data disk name, for `rx grow <size>` |
| `RX_SSH_CONFIG` | optional ssh config file passed as `ssh -F` |
| `RX_ENV` | env var names forwarded to jobs (default `RUST_LOG RUST_BACKTRACE`); nothing else from your environment goes over |

Jobs get `CARGO_TERM_COLOR=never` unless you forward your own.

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

- **Remote dirs.** Each worktree gets `~/rx/w/<repo>-<hash of the worktree path>` on the box, so worktrees never collide. `rx run` uses it in place, so builds stay warm. `rx submit` runs in a per-name snapshot, `~/rx/snap/<wtid>-<name>`: on a name's first submit, a `cp -a --reflink` of the mirror (instant on XFS) minus `target` symlinks, so mbx gives it its own target dir and lock, and later syncs and edits never touch a running job. A rerun under the same name keeps that snapshot and syncs into it like `rx run` does, so every build tool stays warm; a new name starts from a fresh copy. There is no cap; mbx's GC budget and the daily cleanup bound disk use.
- **Latency.** Each call costs a few ssh round trips (the ControlMaster saves the handshake), so about 10 s per submit to a box in a far region. RTT matters more than bandwidth, so put the box in the region closest to you. `rx run` is the fast path: one call, the warmest dir, and output streams as it's produced.
- **Sync.** The file set is `git ls-files --cached --others --exclude-standard` (plus files inside submodules), so `.gitignore`, `.git/info/exclude` and global excludes apply. Untracked symlinks (e.g. a local mbx `target`) and `.git` are never sent. The box keeps the last manifest and deletes exactly the paths that left it, so build output, fuzz corpora and the box's own `target` symlink are never deleted. rsync `-a` keeps mtimes, so cargo doesn't rebuild needlessly.
- **One lock.** The client's rsync starts its box side through `rx __remote recv`. That takes a box-side `flock`, waits for (run) or refuses (submit) a still-active job of that name, deletes, receives, and starts the systemd unit, all under the same lock. A second `rx run` in the same worktree waits for the first.
- **Jobs.** Each job is a `systemd-run --user --collect` unit whose log and exit code live in `~/rx/jobs/<wtid>/.<name>@<token>/`. Stopping the unit kills its whole cgroup, setsid'd children included; Docker containers run under dockerd, outside it. `rx run` units go in `rx-run.slice` (CPUWeight 1000) and submitted ones in `rx-job.slice` (CPUWeight 100), so background fuzzers can't starve interactive builds. `submit --mem 64G` sets MemoryMax.
- **Signals.** Ctrl-C on `rx run` stops the job. TERM and HUP (an agent's shell timeout) only detach and print `rx wait run`. `rx wait` never kills.
- **Lost jobs.** Each job records the boot ID plus the systemd user manager's invocation ID. If the box restarted (Spot preemption stops the VM; the disk survives), `rx ps` and `rx wait` say `lost (box restarted)` instead of hanging or inventing an exit code.
- **Self-install.** Every call pipes a tar of the client script and the job spec over ssh. A small prelude installs it as `~/.rx/bin/rx-<hash>` when it changed, so there is no quoting across ssh and nothing to deploy.
- **Wake and idle.** If ssh fails and GCE settings exist, rx runs `gcloud compute instances start` and waits for ssh (about 3 minutes max). The box powers itself off about 45 minutes after the last rx call (the 15-minute ControlPersist, then 30 idle minutes), or 30 minutes after a plain ssh session ends.
- **Connection.** ssh with ControlMaster/ControlPersist (sockets in `~/.ssh/rx-%C`, or `$RX_CONTROL_DIR`). A hung master, e.g. after a preemption, is detected and replaced.

## Limits

- One box. Agents share it, and CPU weights favor `rx run` over submitted jobs, but nothing stops one job from using all of it.
- Untracked files inside submodules aren't synced.
- Remote stdout and stderr arrive merged on stdout; jobs get no stdin.
- Untracked files that aren't ignored get synced, so keep secrets gitignored. rx warns (it doesn't block) when an untracked, un-ignored file looks like one (`.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `*credentials*`, `*.p12`). It prints at most 5 names per sync.
- A client killed with SIGKILL can leave its local ssh follower printing until the job ends; the job itself is unaffected.
- The client runs on macOS (`/bin/bash` 3.2 or newer); the box setup targets Ubuntu 24.04 on GCE. Another cloud or your own server should work with no `RX_GCE_*` settings, minus wake, `rx stop` and `rx grow`. The idle timer still powers the box off, so you'd start it yourself.

## Tests

`test/run.sh [pattern]` builds an Ubuntu 24.04 systemd container (the stand-in box, with loopback XFS at `/data`), boots it with `--privileged`, and runs `test/t_*.sh` through macOS `/bin/bash` 3.2. A fake `gcloud` on PATH maps start, stop and resize onto Docker. The real gcloud is never called. It needs a local Docker.

## License

[MIT](LICENSE)
