#!/usr/bin/env bash
# ==============================================================================
# BoF (Bastard Operator From Hell) — Distro-Agnostic Read-Only System Audit
# ==============================================================================
# 100% Read-Only Reconnaissance Script. Does NOT modify any file or setting.
# Works across Debian/Ubuntu, RHEL/Rocky/Alma/Fedora, Alpine, Arch, and SUSE.
#
# Usage:
#   ./bof_audit.sh [--output /path/to/audit_report.md]
# ==============================================================================

set -uo pipefail

OUTPUT_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|-o)
            OUTPUT_FILE="${2:-}"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--output /path/to/audit_report.md]"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

run_audit() {
    echo "# BoF Read-Only System Audit Report"
    echo ""
    echo "- **Timestamp (UTC):** $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "- **True Hostname:** $(hostname -f 2>/dev/null || hostname)"
    echo "- **Kernel & Arch:** $(uname -srmo 2>/dev/null || uname -a)"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        echo "- **Virtualization:** $(systemd-detect-virt 2>/dev/null || echo 'none')"
    fi
    echo "- **Uptime & Load:** $(uptime)"
    echo ""

    echo "## 1. Operating System & Init Fingerprint"
    echo '```text'
    if [[ -f /etc/os-release ]]; then
        cat /etc/os-release
    else
        uname -a
    fi
    echo "Init Process (PID 1): $(ps -p 1 -o comm= 2>/dev/null || echo 'unknown')"
    echo '```'
    echo ""

    echo "## 2. CPU, Memory & Swap Saturation (USE Method)"
    echo '```text'
    echo "--- CPU Cores: $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1) ---"
    free -h 2>/dev/null || free -m 2>/dev/null
    echo ""
    echo "--- Key VM/Memory Sysctls ---"
    sysctl vm.swappiness vm.dirty_background_ratio vm.dirty_ratio vm.vfs_cache_pressure 2>/dev/null || true
    echo '```'
    echo ""

    echo "## 3. Storage Capacity, Inodes & Advanced Pools (ZFS / Btrfs / LVM)"
    echo '```text'
    echo "--- Block Devices ---"
    lsblk -o NAME,FSTYPE,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true
    echo ""
    echo "--- Filesystem Space Usage ---"
    df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || df -h
    echo ""
    echo "--- Inode Usage (Top Mounts) ---"
    df -i -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || true
    if command -v zpool >/dev/null 2>&1; then
        echo ""
        echo "--- ZFS Pool Status ---"
        zpool list 2>/dev/null || true
    fi
    if command -v btrfs >/dev/null 2>&1; then
        echo ""
        echo "--- Btrfs Filesystems ---"
        btrfs filesystem show 2>/dev/null || true
    fi
    echo '```'
    echo ""

    echo "## 4. Deleted Open Files Holding Disk Space (lsof +L1)"
    echo '```text'
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP +L1 2>/dev/null | head -n 20 || echo "None detected (or insufficient privileges)."
    else
        echo "lsof not installed."
    fi
    echo '```'
    echo ""

    echo "## 5. Network Interfaces & Listening Sockets"
    echo '```text'
    ip -br addr 2>/dev/null || ifconfig -a 2>/dev/null || true
    echo ""
    echo "--- Listening TCP/UDP Sockets ---"
    ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || true
    echo '```'
    echo ""

    echo "## 6. Failed Services & Container Runtime Status"
    echo '```text'
    if command -v systemctl >/dev/null 2>&1; then
        echo "--- Failed Systemd Units ---"
        systemctl --failed --no-pager 2>/dev/null || true
    elif command -v rc-status >/dev/null 2>&1; then
        echo "--- OpenRC Crashed Services ---"
        rc-status -c 2>/dev/null || true
    fi
    if command -v docker >/dev/null 2>&1; then
        echo ""
        echo "--- Docker Containers ---"
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
    fi
    if command -v pct >/dev/null 2>&1; then
        echo ""
        echo "--- Proxmox LXC Containers ---"
        pct list 2>/dev/null || true
    fi
    echo '```'
    echo ""

    echo "## 7. Recent High-Priority Kernel & System Errors"
    echo '```text'
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -p err..emerg --since "24 hours ago" --no-pager -n 30 2>/dev/null || true
    fi
    dmesg -T 2>/dev/null | grep -E -i "oom|killed process|out of memory|segfault|i/o error|error|throttl" | tail -n 20 || true
    echo '```'
}

if [[ -n "$OUTPUT_FILE" ]]; then
    run_audit > "$OUTPUT_FILE"
    echo "[BoF AUDIT OK] Read-only system audit written to: $OUTPUT_FILE"
else
    run_audit
fi
