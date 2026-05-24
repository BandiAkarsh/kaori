# Edge OS — Btrfs Snapshot System

## Overview

Edge OS uses a Btrfs-based A/B snapshot model inspired by openSUSE Tumbleweed for atomic updates and rollback. Snapper is the primary backend with raw btrfs subvolume snapshots as fallback.

The system provides four layers of snapshot protection:

| Layer | Trigger | Frequency | Purpose |
|-------|---------|-----------|---------|
| APT hooks | `apt install/remove/upgrade` | Every operation | Rollback failed updates |
| Systemd timer | Timer | Daily at 3:00 AM | Periodic safety net |
| Timeline | Snapper | Hourly (configurable) | Granular recovery points |
| Manual | User command | On demand | Pre-maintenance snapshots |

## Subvolume Layout

```
@           → /            (root — snapshotted by snapper)
@home       → /home        (user data — excluded from snapshots)
@snapshots  → /.snapshots  (snapshot metadata and storage)
@swap       → /.swap       (swap files — nodatacow to avoid CoW issues)
@cache      → /var/cache   (package cache — excluded from snapshots)
@log        → /var/log     (system logs — excluded from snapshots)
```

The `@` subvolume is the default (mounted without `subvol=` option). `@home`, `@cache`, and `@log` are excluded from snapshots to save space and avoid restoring user data or cache during rollbacks.

## Creating the Subvolume Layout

### During Installation (Recommended)

The Calamares installer creates the layout automatically during installation via the `btrfs-layout` shellprocess module.

### Manual Setup on Existing Btrfs

If you already have a Btrfs filesystem (e.g., manually partitioned):

```bash
# Create the layout on a Btrfs device
sudo system/btrfs/layout.sh /dev/sda2

# Or using the deployed script on an installed system
sudo /usr/local/lib/edge/btrfs-layout /dev/nvme0n1p2
```

This will:
1. Format the device as Btrfs (⚠️ destroys all data)
2. Create all 6 subvolumes
3. Set `@` as the default subvolume
4. Generate `/etc/fstab` with optimized mount options

## Snapshot Management

### Using the CLI (`edge-btrfs-snapshot`)

The snapshot CLI is deployed to `/usr/local/sbin/edge-btrfs-snapshot` on the installed system.

```bash
# Initialize snapper configuration for root
sudo edge-btrfs-snapshot init

# Create a manual snapshot
sudo edge-btrfs-snapshot create "before-kernel-upgrade"

# Create pre/post snapshot pair (for manual operations)
sudo edge-btrfs-snapshot pre "installing-new-driver"
# ... do the operation ...
sudo edge-btrfs-snapshot post 1  # 1 = pair number from pre output

# List all snapshots
edge-btrfs-snapshot list

# Show snapshot status and disk usage
edge-btrfs-snapshot status

# Rollback to a specific snapshot
sudo edge-btrfs-snapshot rollback 42

# Run cleanup (per retention policy)
sudo edge-btrfs-snapshot cleanup

# Show file changes between two snapshots
edge-btrfs-snapshot diff 40 42
```

### Using Snapper Directly

If you prefer the native snapper interface:

```bash
# List all snapshots
sudo snapper -c edge_root list

# Create a snapshot
sudo snapper -c edge_root create -d "my-snapshot"

# View snapshot content
sudo snapper -c edge_root mount 42
ls /.snapshots/42/snapshot/

# Delete a snapshot
sudo snapper -c edge_root delete 42
```

## Automatic Snapshots

### APT Hooks

Every `apt install`, `apt remove`, or `apt upgrade` operation automatically creates pre/post snapshot pairs:

```
Pre-Invoke:  snapper create --type pre  ("apt-pre-20260524-103000")
  ↓
dpkg runs (install/upgrade/remove packages)
  ↓
Post-Invoke: snapper create --type post --pre-number <N>
             snapper cleanup (retention policy applied)
```

These hooks are configured in `/etc/apt/apt.conf.d/80edge-btrfs-snapshots` and the hook script is at `/usr/lib/edge/btrfs-apt-hook`.

### Daily Timer

A systemd timer creates a daily snapshot at 3:00 AM with randomized delay:

```bash
# View timer status
systemctl status edge-btrfs-snapshot.timer

# View last snapshot trigger
journalctl -u edge-btrfs-snapshot.service

# Manually trigger daily snapshot
sudo systemctl start edge-btrfs-snapshot.service
```

The timer uses `Persistent=true`, meaning it catches up if the system was off (anacron-style).

## Retention Policy

Snapshots are cleaned automatically by snapper's timeline cleanup:

| Policy | Count | Description |
|--------|-------|-------------|
| Hourly | — | Timeline snapshots (configurable interval) |
| Daily | 7 | Keep 7 daily snapshots |
| Weekly | 4 | Keep 4 weekly snapshots |
| Monthly | 3 | Keep 3 monthly snapshots |
| Manual | 10 | Keep 10 manual snapshots |
| Important | 5 | Keep 5 important snapshots |

Configured in `/etc/snapper/configs/edge_root`:

```ini
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
```

## GRUB Integration

Snapshot boot entries are managed by `edge-grub-snapshot` (deployed to `/usr/local/sbin/`).

```bash
# Generate snapshot entries in GRUB
sudo edge-grub-snapshot install

# Update after creating/deleting snapshots
sudo edge-grub-snapshot update

# Remove snapshot entries
sudo edge-grub-snapshot remove

# Check current status
edge-grub-snapshot status
```

After running `install` or `update`, the GRUB menu will contain:

```
Edge OS — Current System          (boots current @ subvolume)
Edge OS — Recovery Mode           (boots with single/kernel params)
📸 Edge OS — Snapshot #42: ...    (boots into snapshot #42)
📸 Edge OS — Snapshot #41: ...
...
```

Up to 10 snapshot entries are shown (configurable via `MAX_SNAPSHOT_ENTRIES` in the script).

## Rolling Back

### Rollback via Snapper (Recommended)

```bash
# 1. List snapshots to find the target
sudo edge-btrfs-snapshot list

# 2. Rollback to snapshot #42
sudo edge-btrfs-snapshot rollback 42

# 3. Reboot to activate
sudo reboot
```

### Rollback via GRUB Menu

1. Reboot the system
2. At the GRUB menu, select a snapshot entry (prefixed with 📸)
3. Boot into the snapshot (read-only)
4. From the snapshot, run `sudo edge-btrfs-snapshot rollback <number>`
5. Reboot again to the Current System entry

### Manual Rollback (Emergency)

If snapper is unavailable:

```bash
# Find the snapshot subvolume
ls /.snapshots/
# Example: @-before-upgrade-20260524

# Boot from a live USB, mount the root Btrfs, then:
sudo mount -t btrfs -o subvolid=5 /dev/sda2 /mnt
sudo mv /mnt/@ /mnt/@-broken
sudo btrfs subvolume snapshot /mnt/.snapshots/@-before-upgrade-20260524 /mnt/@
sudo btrfs subvolume set-default $(btrfs subvolume list /mnt | grep ' @$' | awk '{print $2}') /mnt
sudo umount /mnt
reboot
```

## Script Source Reference

| Script | Location | Deployed As |
|--------|----------|-------------|
| Layout Creator | `system/btrfs/layout.sh` | `/usr/local/lib/edge/btrfs-layout` |
| Snapshot Manager | `system/btrfs/snapshot.sh` | `/usr/local/sbin/edge-btrfs-snapshot` |
| GRUB Integration | `system/btrfs/grub-update.sh` | `/usr/local/sbin/edge-grub-snapshot` |
| APT Hook | `system/apt-hooks/btrfs-snapshot` | `/usr/lib/edge/btrfs-apt-hook` |
| APT Config | `system/apt-hooks/80edge-btrfs-snapshots` | `/etc/apt/apt.conf.d/80edge-btrfs-snapshots` |
| Systemd Service | `system/systemd/edge-btrfs-snapshot.service` | `/etc/systemd/system/` |
| Systemd Timer | `system/systemd/edge-btrfs-snapshot.timer` | `/etc/systemd/system/` |

## Benchmarks

The `scripts/benchmark-btrfs.sh` script provides:

```bash
# Full Btrfs system analysis
./scripts/benchmark-btrfs.sh

# Subvolume layout only
./scripts/benchmark-btrfs.sh --layout

# Snapshot performance and usage
sudo ./scripts/benchmark-btrfs.sh --snapshots

# Compression ratio analysis
./scripts/benchmark-btrfs.sh --compression

# I/O benchmark (sequential read/write)
sudo ./scripts/benchmark-btrfs.sh --perf
```

## Known Limitations

- **Snapper required for rollback** — Raw btrfs snapshots can only be created and listed (not rolled back via the CLI)
- **Live ISO has no snapshots** — The live environment uses overlayfs; snapshots only work on installed systems
- **GRUB snapshot entries** — Manual `edge-grub-snapshot update` required after creating/deleting snapshots if not using snapper's timeline
- **Post-snapshot pairing** — If `apt` is interrupted, a post snapshot may not be created; orphaned pre snapshots can be deleted manually with `snapper -c edge_root delete <number>`
