# Build box

STATUS: ready (setup.sh: full mode verified on a fresh Ubuntu 24.04 systemd container (aarch64), re-run idempotently; minimal mode is the test box for the 183-test suite. Still to verify on the real VM: Tailscale SSH session counting, see below)

## Interface (stable)

Client config, `~/.config/rx/config` (a sourced shell file):

| Variable | Meaning |
| --- | --- |
| `RX_HOST` | ssh host alias of the box (default `buildbox`) |
| `RX_GCE_INSTANCE`, `RX_GCE_ZONE`, `RX_GCE_PROJECT` | enable wake, `rx up`, `rx status`, `rx stop` via gcloud |
| `RX_GCE_DATA_DISK` | data disk name, for `rx grow <size>` |
| `RX_SSH_CONFIG` | optional ssh config file passed as `ssh -F` |
| `RX_ENV` | env var names forwarded to jobs (default `RUST_LOG RUST_BACKTRACE`) |

Box layout, all on one XFS data filesystem so reflinks work between them:

| Path | Contents |
| --- | --- |
| `/data` | data disk mount (fstab by UUID, `xfs defaults,nofail 0 2`) |
| `/data/rx` | rx root; `~dev/rx` is a symlink to it. `w/` worktree mirrors, `snap/<wtid>-<name>` per-name job snapshots, `m/` manifests, `jobs/` job state and logs |
| `/data/mbx` | mbx `cache_dir` (store and managed targets) |
| `/data/docker` | Docker `data-root` (`/etc/docker/daemon.json`) |

`setup.sh` runs as root on Ubuntu 24.04 and is idempotent:

```
sudo ./setup.sh [--user dev] [--data-disk DEV | --data-loop FILE:SIZE] [--mbx-budget SIZE] [--minimal]
```

- `--data-disk DEV`: format DEV as XFS with reflink if it has no filesystem, then mount it at `/data`. It never reformats a disk that already has a filesystem. On GCE use `/dev/disk/by-id/google-data` (device-name `data`).
- `--data-loop FILE:SIZE`: the same, backed by a loopback file (tests only).
- `--mbx-budget SIZE`: mbx `gc.max_total_size`. The default is 50% of the `/data` filesystem, recomputed on every run. `gc.min_free_size` is set to 10% of the filesystem.
- `--minimal`: base packages, sshd, rsync, Rust stable and mbx only (the test container).

What setup.sh owns: the `dev` user with passwordless sudo and linger, the data disk, Docker with buildx (data-root on `/data`), rustup with stable and nightly, mise with Node LTS (`mise use -g node@lts`), mbx, mold, cargo-binstall, cargo-nextest, cargo-fuzz and cargo-llvm-cov, Temurin 21 with `tla2tools.jar` (`tlc` wrapper), build deps, the utilities (jq, ripgrep, fd, fzf, bat, eza, zoxide, tmux, btop, ncdu), unattended security upgrades without automatic reboots, the `tailscale` package, and two timers:

- `rx-idle.timer`, every 5 minutes, runs `rx-box idle`. It powers off once there have been no active rx units and no ssh sessions for 30 straight minutes and the last rx call (`~/.rx/last-activity`) is at least 30 minutes old. That's about 30 minutes after the last rx call or session ends, give or take one tick. An idle ControlMaster counts as a session until `ControlPersist` (15 minutes) expires.
- `rx-cleanup.timer`, daily, runs `rx-box cleanup`. It prunes worktree mirrors (with their snapshots) untouched for 14 days, and finished jobs older than 3 days along with their snapshots.

It doesn't create the VM, set up networking, or run `tailscale up`.

### Idle detection and Tailscale SSH

`rx-box sessions` prints exactly what the idle check counts, and `rx-box idle --dry-run` prints the full decision. A session is:

- an OpenSSH connection: a process matching `^sshd(-session)?: [^ ]+@` (an idle ControlMaster counts until `ControlPersist` expires);
- a Tailscale SSH session: any direct child of the `tailscaled` daemon (the `tailscaled` whose parent is PID 1). Tailscale SSH never touches sshd. On the real box the tree is `tailscaled` → `tailscaled be-child ssh-monitor --local-user=dev …` (one per session) → `be-child ssh --login-shell=…` → the command, so each session is exactly one direct child. Listed as `(tailscale ssh)`.

Counts based on port 22, `who` or `loginctl` would miss Tailscale SSH. This was verified only against a simulated daemon in the test container. On the real box, open `ssh buildbox` (Tailscale SSH) and run `sudo rx-box sessions`. Expect at least 1 `(tailscale ssh)` line both while sitting in the shell and while a long command runs (`ssh buildbox sleep 60`).

## Create the VM (what worked on the real box; fill in the placeholders)

Placeholders: `PROJECT`, `ZONE` and its `REGION`. Pick the zone with the lowest RTT from the Mac: every rx call pays a few round trips (see the main README). No secrets appear on any command line or in metadata.

```sh
PROJECT=your-project ZONE=your-zone REGION=your-region NAME=buildbox

# A dedicated VPC with ZERO firewall rules: no ingress at all. Never use the project's `default`
# network, which may carry 0.0.0.0/0 ingress rules. Egress is allowed by GCP's implied rule.
gcloud compute networks create rx-net --project=$PROJECT --subnet-mode=custom
gcloud compute networks subnets create rx-subnet --project=$PROJECT --region=$REGION \
  --network=rx-net --range=10.90.0.0/24

# Temporary bootstrap: create dev, install Tailscale, start an interactive `tailscale up` whose login
# URL lands on the serial console. No auth key anywhere.
cat >/tmp/rx-bootstrap.sh <<'EOF'
#!/bin/bash
id dev >/dev/null 2>&1 || useradd -m -s /bin/bash dev
echo 'dev ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-rx-dev && chmod 440 /etc/sudoers.d/90-rx-dev
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
tailscale status >/dev/null 2>&1 || tailscale up --ssh --hostname=buildbox --advertise-tags=tag:buildbox 2>&1 | tee /dev/ttyS0
EOF

# Spot, stop on preemption (disks survive, rx reports lost jobs), no service account or scopes
# (the box has no GCP credentials), ephemeral external IP (cheaper than Cloud NAT, released on stop,
# lets Tailscale connect directly). Both disks are created with the instance, so after a stockout
# you can retry another zone without stranding a pre-created disk.
gcloud compute instances create $NAME --project=$PROJECT --zone=$ZONE \
  --machine-type=c3d-standard-60 \
  --provisioning-model=SPOT --instance-termination-action=STOP \
  --no-service-account --no-scopes \
  --network-interface=subnet=rx-subnet \
  --create-disk=boot=yes,auto-delete=yes,image-family=ubuntu-2404-lts-amd64,image-project=ubuntu-os-cloud,size=100GB,type=hyperdisk-balanced,provisioned-iops=3000,provisioned-throughput=140 \
  --create-disk=name=$NAME-data,device-name=data,auto-delete=no,size=500GB,type=hyperdisk-balanced,provisioned-iops=3000,provisioned-throughput=140 \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --metadata-from-file=startup-script=/tmp/rx-bootstrap.sh

# Apply the Tailscale policy below (tag:buildbox in tagOwners) BEFORE approving the URL. Otherwise
# `tailscale up` fails with "requested tags [tag:buildbox] are invalid or not permitted", the startup
# script exits, and you need `gcloud compute instances reset` to rerun it and get a fresh URL.
# Read the newest login URL from the serial console (it keeps old ones across boots) and approve it...
gcloud compute instances get-serial-port-output $NAME --project=$PROJECT --zone=$ZONE | grep -o 'https://login.tailscale.com/[^ ]*' | tail -1
# ...then remove the bootstrap so it never runs again.
gcloud compute instances remove-metadata $NAME --project=$PROJECT --zone=$ZONE --keys=startup-script
```

Then copy the box files and run setup over Tailscale SSH. Use a transient unit so a dropped connection doesn't kill it:

```sh
rsync -a box/ buildbox:/tmp/rx-box/      # ssh alias below; user dev, Tailscale SSH
ssh buildbox 'sudo systemd-run --unit=rx-setup --collect /tmp/rx-box/setup.sh --data-disk /dev/disk/by-id/google-data'
ssh buildbox 'journalctl -fu rx-setup'   # until "== setup: done"
```

Avoid these:

- IAP tunnels: they need `roles/iap.tunnelResourceAccessor`, which Editor doesn't include.
- `gcloud compute ssh`: it writes your local username and a key into instance metadata.
- `tailscale up --auth-key=$KEY` on a command line or in metadata: the key leaks into shell history, the process list and the metadata server.

Measured on the real box: from stopped to ssh-ready in 44 s (12 s for the start API call, 32 s for boot and Tailscale). Within rx's 3-minute wake budget.

### Tailscale policy

Apply this before approving the box's login URL. Tag the box, keep your devices' access to everything, and block the box from reaching them. Add the SSH entry to your existing `ssh` rules (don't replace them, or you lose the default `autogroup:self` rule), with `accept` (not `check`) so agents never hit an interactive re-auth. With `grants`:

```json
"tagOwners": { "tag:buildbox": ["autogroup:admin"] },
"grants": [
  { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] }
],
"ssh": [ /* existing rules, plus: */ { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:buildbox"], "users": ["dev"] } ]
```

The same with legacy `acls`:

```json
"tagOwners": { "tag:buildbox": ["autogroup:admin"] },
"acls": [
  { "action": "accept", "src": ["autogroup:member"], "dst": ["*:*"] }
],
"ssh": [ /* existing rules, plus: */ { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:buildbox"], "users": ["dev"] } ]
```

The default policy allows `src: ["*"]` → `dst: ["*"]`, which lets the box (a tagged node) reach all your devices. To block that, change only the default rule's `src` from `["*"]` to `["autogroup:member"]`, as above. Tagged nodes aren't members, so the box gets nothing, while keeping `dst: *` preserves exit nodes (`autogroup:internet`), subnet routes and other tagged nodes. Adding a rule alone doesn't restrict anything, because rules only ever add access.

### Mac side

```sshconfig
# ~/.ssh/config
Host buildbox
  HostName buildbox      # MagicDNS name
  User dev
```

```sh
# ~/.config/rx/config
RX_HOST=buildbox
RX_GCE_INSTANCE=buildbox RX_GCE_ZONE=your-zone RX_GCE_PROJECT=your-project
RX_GCE_DATA_DISK=buildbox-data
```

The box has no GCP credentials by design. Wake (`gcloud compute instances start`), `rx stop` and `rx grow` (`gcloud compute disks resize`) run from the Mac. A Spot stockout on wake exits 75 with `rx: box is stocked out in <zone>; try again later`. The matcher covers the real *create* stockout text (`ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS`, `reason: resource_availability`, `state:STOCKOUT`; kept as a test fixture). The exact wording `start` uses is unverified.

If a stockout lasts, switch the stopped box to a smaller type in the same zone. It keeps its disks and caches, and the type must support hyperdisk (C3D, C3, C4):

```
gcloud compute instances set-machine-type buildbox --zone your-zone --machine-type c3d-standard-30
```

Switch back once capacity returns.
