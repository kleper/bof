# BoF Reference: DevOps, Containers, Virtualization & Backup Architecture

This runbook covers safe operational patterns for Docker/Compose, Proxmox VE & LXC containers, major OS/database upgrades, and fault-tolerant backup architectures.

---

## 1. Docker & Container Operations

### 1.1 Mandatory Daemon Log Rotation (`/etc/docker/daemon.json`)
Left unconfigured, Docker's `json-file` log driver retains container stdout forever, eventually filling `/var/lib/docker` and crashing the host. Always verify `/etc/docker/daemon.json` contains bounded log rotation:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```
Match `storage-driver` (`overlay2`, `btrfs`, `zfs`) to the underlying filesystem of `/var/lib/docker`.

### 1.2 Container Safety Rules
- **Never run `docker system prune -a --volumes` blindly.** If a container is currently stopped (e.g., during a failed deploy or maintenance), `--volumes` will **permanently destroy its anonymous and unmounted volumes**. Always run `docker ps -a` and `docker volume ls` first, and ask for explicit user confirmation.
- **Non-Root Execution (`gosu` / `USER`):** In official database and app images (e.g., PostgreSQL 17), when overriding `entrypoint` or running custom wrapper scripts (such as `pgbackrest` + `postgres`), drop privileges from `root` to the service user (`gosu postgres ...`) after fixing volume ownership.
- **Healthchecks & Thread Watchdogs:** A container process (`PID 1`) can remain alive even when an internal background thread (e.g., a TCP socket reader `_rxThread` or queue worker) dies silently. Implement an HTTP `/health` endpoint that inspects internal thread liveness (`thread.is_alive()`) and wire it to Docker's `HEALTHCHECK` + `restart: unless-stopped`.

---

## 2. Proxmox VE (PVE) & LXC Container Administration

### 2.1 Unprivileged LXC UID/GID Mapping Pitfalls
In unprivileged Proxmox LXC containers, container `root` (`UID 0`) maps to host `UID 100000`.
- **Symptom:** `apt update` inside an unprivileged LXC fails with `Permission denied` on `/var/lib/apt/lists/partial` after a migration or backup restore.
- **Fix (from host or inside container):** Ensure `/var/lib/apt/lists/partial` is owned by `_apt:root` (`100:0` inside the container, or `100100:100000` from the PVE host) with `chmod 700`.

### 2.2 Safe Chroot Maintenance Pattern for LXC Rootfs
When repairing or upgrading an LXC container from the Proxmox host via `pct mount <CTID>` + `chroot`:
1. Always register a `trap teardown_chroot EXIT INT TERM` in any script so `/dev`, `/proc`, `/sys`, and `/dev/pts` bind mounts are cleanly unmounted even if a command fails mid-upgrade.
2. Never run recursive deletions on a mounted rootfs while bind mounts (`/dev`, `/proc`) are active!

### 2.3 Major In-Place Upgrade Runbook (Debian 12 → 13 / PVE 8 → 9 / PG 14 → 17)
Never perform a major OS or database upgrade without executing this sequence:
1. **Pre-Flight Gate:**
   - Verify free disk space (`df -h` — at least 5–10 GB free on `/`).
   - Take a verified Proxmox Backup Server (PBS) snapshot or LVM/ZFS snapshot **and confirm completion**.
   - Check held packages (`apt-mark showhold`) and third-party repositories (`/etc/apt/sources.list.d/`).
2. **Non-Interactive Safe Execution:**
   - Use `DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"` so existing hardened config files are preserved rather than overwritten by package maintainers.
3. **Database Major Version Upgrades (PostgreSQL):**
   - Back up globals (`pg_dumpall --globals-only`) and take a full `pgBackRest` / `pg_dump` backup.
   - After `pg_upgrade` or dump/restore to PG 17, remember to run `pgbackrest --stanza=<name> stanza-upgrade` so automated backups do not fail on version mismatch!

---

## 3. Backup Architecture & Verification (The 3-2-1 Law)

A backup that lives on the same physical disk or Volume Group as the production data is **not a backup**—it is a single point of failure waiting to happen.

### 3.1 Auditing for Single Points of Failure (SPOF)
Always run `lsblk -f` and `df -hT` to trace where backup directories actually reside:
- **Critical Anti-Pattern:** Mounting `/mnt/PG_DATA` (live database) and `/mnt/PG_BK` (backups) from the **same** LVM volume group (`/dev/mapper/vg-data`) or the same physical RAID array. If `vg-data` corrupts, both live data and backups are lost simultaneously.
- **Remediation:** Always configure a second offsite repository (`repo2` in `pgBackRest` pointing to S3/MinIO/remote NAS, or `restic` / `Proxmox Backup Server` syncing to offsite object storage like OVH S3 / AWS S3 / Backblaze B2).

### 3.2 `pgBackRest` Tuning & Config Drift Checklist
When auditing `/etc/pgbackrest/pgbackrest.conf` and its `cron` schedule:
1. **Compression Level vs. CPU Starvation:** `compress-type=zst` with `compress-level=12` consumes massive CPU during full backups and starves live database queries. Tune to **`compress-level=6`** (or `3–6`) for optimal compression-to-CPU balance.
2. **Align Cron Schedules with Retention Policies:**
   - If `repo1-retention-diff=2` is set in `pgbackrest.conf`, verify that `crontab` actually runs `diff` backups! Running a `full` backup every single night (`0 0 * * *`) wastes massive disk I/O on multi-terabyte databases.
   - **Recommended Schedule:** Weekly `full` (Sunday `0 0 * * 0`), Daily `diff` (Mon–Sat `0 0 * * 1-6`), and Hourly `incr` (`0 * * * *`).
3. **Verify Comments Match Directives:** If a comment says `# Keep 3 full backups` but the directive says `repo1-retention-full=2`, flag the discrepancy to the user immediately.
