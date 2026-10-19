# BoF Reference: Linux Server Optimization, Kernel & Storage Tuning

This runbook captures proven methodologies and production-tested configurations for diagnosing bottlenecks and tuning Linux servers across bare-metal, KVM/Proxmox, LXC, and ARM/x86 edge nodes.

---

## 1. Performance Methodologies: USE & RED

Before tuning any parameter, measure the bottleneck using two complementary frameworks:

1. **The USE Method (Hardware & OS Resources — Brendan Gregg):**
   For every resource (**CPU, Memory, Disk I/O, Network, Storage Capacity, File Descriptors**), check in order:
   - **Utilization:** % of time the resource was busy (`mpstat -P ALL 1 3`, `iostat -xz 1 3`, `sar -n DEV 1 3`).
   - **Saturation:** Degree of queued work waiting for the resource (Load Average > CPU count, `vmstat` `r` > CPU count, `iostat` `aqu-sz` > 1, `%iowait`, swap-in/swap-out `si`/`so`, TCP retransmits).
   - **Errors:** Hardware/driver/kernel errors (`dmesg -T`, `ip -s link`, `smartctl -a`, `zpool status`, `btrfs device stats`).

2. **The RED Method (Services & Proxies):**
   For every user-facing service (HAProxy, Nginx, FastAPI, Puma/Rails, PostgreSQL):
   - **Rate:** Requests per second.
   - **Errors:** HTTP 5xx, connection resets, failed queries.
   - **Duration:** Latency percentiles (p50, p95, p99) and upstream timeouts.

---

## 2. Kernel `sysctl` Optimization Profiles

Always place custom kernel parameters in a dedicated drop-in file (`/etc/sysctl.d/99-bof-tuning.conf`), back up any existing file first, and apply with `sysctl --system` after user confirmation.

### 2.1 Memory & Writeback Tuning (Low-RAM / Rotational HDD / DB Hosts)
On servers with rotational disks (HDDs), slow network storage, or tight RAM running containers/databases, default Linux dirty ratios (`dirty_ratio=20`) allow large bursts of dirty pages to accumulate in RAM before flushing all at once—causing severe I/O stalls and latency spikes.
```ini
# /etc/sysctl.d/99-bof-tuning.conf

# Prefer keeping application pages in RAM; only swap when genuinely pressured
# Set to 1-5 for DB/container hosts with HDD swap; 10-30 for zram/NVMe swap
vm.swappiness = 5

# Flush dirty pages earlier and in smaller, smoother increments to prevent I/O freezes
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10

# Retain directory and inode caches longer (improves filesystem traversal)
vm.vfs_cache_pressure = 50
```

### 2.2 High-Concurrency Network & Reverse Proxy Tuning (HAProxy / Nginx / MQTT)
```ini
# Increase socket listen backlog and SYN queue for bursty traffic
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# Enable TCP BBR congestion control (if kernel >= 4.9) for higher throughput over WAN/tunnels
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Safely reuse TIME_WAIT sockets for outbound upstream connections
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# Harden against SYN floods and ICMP redirects
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# File descriptor ceiling for high-connection proxies and container hosts
fs.file-max = 2097152
```

---

## 3. Storage & Filesystem Tuning (Field-Proven Patterns)

### 3.1 Btrfs Optimization (HDD & Flash Isolation)
- **Recommended `/etc/fstab` Mount Options:**
  ```text
  UUID=<uuid> /mnt/storage btrfs defaults,noatime,compress=zstd,space_cache=v2,autodefrag 0 0
  ```
  - `noatime`: Eliminates redundant metadata writes on every file read.
  - `compress=zstd`: Reduces physical disk I/O and saves space (actually increases effective throughput on rotational HDDs).
  - `space_cache=v2`: Essential for fast free-space tree mounting on large volumes.
  - `autodefrag`: Ideal for rotational HDDs handling small random writes (omit on NVMe/SSD if write amplification is a concern).
- **Subvolume Architecture:**
  - Isolate `/var/lib/docker` into a dedicated subvolume (`subvol=/docker`) on external storage when running on SBCs/eMMC/SD cards so container churn does not wear out the boot flash.
  - Isolate swapfiles in a dedicated `/swap` subvolume so snapshots of data volumes never fail or capture swap data.
  - **Swapfile on Btrfs MUST be No-COW (`+C`) and uncompressed:**
    ```bash
    btrfs filesystem mkswapfile --size 16g /mnt/storage/swap/swapfile
    ```

### 3.2 ZFS Pool & Dataset Tuning
- **Pool Creation:** Always enforce sector alignment with `ashift=12` (4K sectors) or `ashift=13` (8K NVMe).
- **Dataset Properties:**
  ```bash
  zfs set compression=lz4 <pool>       # or zstd for cold/archive datasets
  zfs set atime=off <pool>
  zfs set xattr=sa <pool>              # stores extended attributes in inodes (huge speedup for Docker/LXC/SELinux)
  zfs set acltype=posixacl <pool>
  ```
- **ARC Memory Cap:** On hypervisors or container hosts where ZFS shares RAM with VMs/PostgreSQL/Docker, cap `zfs_arc_max` in `/etc/modprobe.d/zfs.conf` (e.g., 25–40% of RAM) so ZFS ARC does not starve guest workloads and trigger OOM kills.
- **Persistence:** Ensure `zfs-import-cache.service`, `zfs-mount.service`, and monthly `zfs-scrub@<pool>.timer` are enabled.

### 3.3 GlusterFS & Distributed Storage Tuning
Distributed FUSE filesystems suffer high latency on small random writes and metadata operations. Apply these proven optimizations (always test in a maintenance window with full backups):
1. **Replica 3 → Replica 2 + Arbiter:** If one node in a 3-way replica has weaker hardware or higher network latency (e.g., a backup server), convert the 3rd brick to an **Arbiter** (metadata-only voter). Writes only commit data to 2 full bricks while preserving split-brain quorum protection.
2. **Write-Behind & Eager-Lock:**
   ```bash
   gluster volume set <vol> performance.write-behind on
   gluster volume set <vol> performance.write-behind-window-size 128MB
   gluster volume set <vol> cluster.eager-lock enable
   gluster volume set <vol> performance.flush-behind on
   ```
3. **CRITICAL DATABASE RULE:** Never run high-transaction database WAL/data directories (PostgreSQL, MySQL, MongoDB) over GlusterFS/NFS FUSE mounts with `write-behind` enabled. Always bind-mount database data directories onto **local LVM-thin / ZFS / NVMe storage** while keeping only stateless container rootfs on shared storage.
4. **Memory Safety (`performance.cache-size`):** Never set `performance.cache-size` higher than 25% of the smallest node's RAM in the Gluster cluster, or `glusterfsd` will OOM-kill on the smallest node.

---

## 4. Application & Hardware Specific Tuning

### 4.1 Worker Process Right-Sizing (Puma / Unicorn / Gunicorn / PHP-FPM)
- Audit actual RSS memory per worker (`ps -o pid,rss,comm -C ruby`) before increasing worker counts.
- Over-provisioning workers on 4–8 GB RAM servers causes swap thrashing under load, which degrades latency far worse than queuing requests briefly in Nginx/HAProxy.

### 4.2 Edge AI / NPU & PCIe Gen 3 Tuning (Raspberry Pi 5 / Hailo / Coral)
- Verify PCIe link speed and width (`lspci -vv` → check `LnkSta: Speed 8GT/s (ok), Width x1`).
- **Single-Context NPU Contention:** Hardware accelerators like the Hailo-10H NPU enforce a single physical `VDevice` context when accessed via `hailo-ollama` or direct runtime APIs. Never run concurrent daemons competing for the raw NPU device; route all local LLM/embedding/vision requests through a single inference server or run lightweight tasks (e.g., SQLite FTS5 or CPU embeddings) on the host CPU to prevent `HAILO_OUT_OF_PHYSICAL_DEVICES` crashes.
