# BoF Reference: Linux Log Forensics & Troubleshooting

This runbook defines the distro-agnostic methodology for investigating Linux system logs, kernel events, authentication anomalies, reverse proxy errors, and service crashes without flooding the context window.

---

## 1. Golden Rules of Log Analysis

1. **Never `cat` an entire log file.** Production logs can be gigabytes in size. Always bound queries by time (`--since`), line count (`tail -n 200`), or severity/pattern (`grep`, `awk`, `journalctl -p`).
2. **Correlate timestamps across layers.** Check `timedatectl` or `date -u` first so you know whether logs are in UTC or local time before correlating Nginx/HAProxy access logs, application logs, and `journalctl`.
3. **Never delete an active log file to free disk space.** If a process holds an open file descriptor to `/var/log/huge.log`, running `rm` hides the filename while the disk blocks remain allocated (`lsof +L1`). Instead, rotate (`logrotate -f`) or, after user confirmation, truncate in place (`truncate -s 0 /var/log/huge.log`).

---

## 2. Distro-Agnostic Log Map

| Subsystem | systemd Distros (Debian, Ubuntu, RHEL, Arch, SUSE) | Debian / Ubuntu Files | RHEL / Rocky / Alma / Fedora Files | Alpine / OpenRC Files |
| :--- | :--- | :--- | :--- | :--- |
| **System / Daemon** | `journalctl -xe` | `/var/log/syslog` | `/var/log/messages` | `/var/log/messages` |
| **Authentication / SSH** | `journalctl -u ssh -u sshd` | `/var/log/auth.log` | `/var/log/secure` | `/var/log/messages` |
| **Kernel Ring Buffer** | `journalctl -k` / `dmesg -T` | `/var/log/kern.log` | `/var/log/messages` | `dmesg` |
| **Cron / Scheduled Jobs** | `journalctl -u cron -u crond` | `/var/log/syslog` (grep `CRON`) | `/var/log/cron` | `/var/log/cron` |
| **Package Manager** | N/A | `/var/log/apt/history.log`, `/var/log/dpkg.log` | `/var/log/dnf.log`, `/var/log/yum.log` | `/var/log/apk.log` |
| **Audit / MAC (SELinux/AppArmor)** | `journalctl _TRANSPORT=audit` | `/var/log/audit/audit.log`, `/var/log/kern.log` | `/var/log/audit/audit.log` (`ausearch`) | `/var/log/messages` |

---

## 3. High-Signal Diagnostic One-Liners

### 3.1 Systemd Journal Forensics
```bash
# All errors and critical events in the last 2 hours (no pager)
journalctl -p err..alert --since "2 hours ago" --no-pager -n 150

# Inspect a specific service with full unit restart history
journalctl -u <service_name> --since "24 hours ago" --no-pager -n 200

# Previous boot crash forensics (after an unexpected reboot)
journalctl -b -1 -p warning..emerg --no-pager | tail -n 150

# Disk usage of systemd journal
journalctl --disk-usage
```

### 3.2 Kernel, OOM Killer & Hardware/Storage Errors
When a container, database, or worker process vanishes without an application traceback, check the kernel ring buffer immediately:
```bash
# Check for Out-Of-Memory (OOM) kills, segfaults, I/O errors, or hung tasks
dmesg -T | grep -E -i "oom|killed process|out of memory|segfault|i/o error|ext4-fs error|btrfs.*error|zfs|blk_update_request|hung_task|hardware error" | tail -n 50

# Check thermal throttling or under-voltage (critical on ARM/Raspberry Pi/Odroid SBCs)
dmesg -T | grep -E -i "voltage|throttl|thermal|overcurrent|pcie.*error"
```

### 3.3 SSH & Authentication Forensics
```bash
# Detect top brute-force attacking IPs (works across Debian auth.log and RHEL secure)
LOG_AUTH=$( [ -f /var/log/auth.log ] && echo /var/log/auth.log || echo /var/log/secure )
grep -E "Failed password|Invalid user" "$LOG_AUTH" 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}' \
  | sort | uniq -c | sort -nr | head -n 20

# Check unexpected SSH disconnects or keepalive drops
grep -E "Connection reset|Timeout, client not responding|Disconnected from" "$LOG_AUTH" 2>/dev/null | tail -n 50
```
> **Field Lesson (HAProxy + SSH):** If SSH sessions routed through HAProxy drop unexpectedly or fail to log client IPs, verify that the HAProxy frontend/backend uses `mode tcp`, `option tcplog` (never `option httplog` on TCP proxies!), and has a `timeout tunnel` or `timeout client`/`timeout server` longer than the SSH `ClientAliveInterval`.

### 3.4 Reverse Proxy Forensics (Nginx & HAProxy)
```bash
# Top HTTP 5xx (500, 502, 503, 504) and 499 (client closed early) in Nginx access logs
awk '$9 ~ /^(499|50[0234])$/ {print $9, $7, $1}' /var/log/nginx/*access*.log 2>/dev/null \
  | sort | uniq -c | sort -nr | head -n 25

# Top request-flooding IPs in the last 5,000 log lines
tail -n 5000 /var/log/nginx/*access*.log 2>/dev/null \
  | awk '{print $1}' | sort | uniq -c | sort -nr | head -n 15

# Nginx upstream timeouts / permission errors (e.g., UNIX socket or SELinux)
grep -E "upstream timed out|connect\(\) failed|Permission denied|SSL_do_handshake" /var/log/nginx/*error*.log 2>/dev/null | tail -n 50
```

### 3.5 Phantom Disk Full Diagnosis (`df` vs `du` Mismatch)
When `df -h` shows a partition at 95–100% capacity, allow for three classic traps:
1. **Deleted files still held open by running processes:**
   ```bash
   lsof -nP +L1 2>/dev/null | sort -k7 -nr | head -n 20
   ```
   *Fix (after user confirmation):* Reload or restart the process holding the deleted file descriptor.
2. **Inode exhaustion (`No space left on device` when `df -h` shows free GBs):**
   ```bash
   df -i
   ```
3. **Files hidden underneath a mount point:**
   Large files written to `/mnt/backup` while the external disk or network share was unmounted remain hidden once the filesystem is mounted over `/mnt/backup`. Inspect via a bind mount of `/` to a temporary mountpoint (`mount --bind / /mnt/root_inspect`).
