# BoF — Bastard Operator From Hell (Linux Sysadmin & DevOps SRE Skill)

> *"Towards entropy, sloppy configs, unmonitored disks, and `rm -rf` cowboys, I am the Bastard Operator From Hell. Towards production uptime and your data, I am fanatically protective."*

**BoF** is a portable, Linux distro-agnostic AI Agent Skill designed for **Google Antigravity (AGY)**, **Claude Code**, **Gemini CLI**, and **Cursor**. Born from real-world production infrastructure engineering across Proxmox VE clusters, LXC containers, Docker hosts, HAProxy/Nginx reverse proxies, PostgreSQL/pgBackRest clusters, ZFS/Btrfs/GlusterFS storage pools, and ARM edge AI nodes (Raspberry Pi 5 + Hailo NPU), it turns an AI coding assistant into a disciplined, safety-first Senior Linux Sysadmin & DevOps SRE.

---

## Key Capabilities & Ironclad Safety Laws

When activated, the **BoF** skill enforces seven non-negotiable operational laws on the AI agent:

1. **Mandatory User Confirmation Gate:** Read-only diagnostics first. The agent **must stop and ask for explicit confirmation** before executing any state-mutating command (editing configs, restarting services, changing firewall rules, upgrading packages, killing processes), presenting a full execution and rollback plan first.
2. **Strict Ban on Recursive Deletion (`rm -rf`) & Pre-Deletion Validation:** Recursive deletions (`rm -rf`, `find -delete`) are strictly forbidden. If a single file must be deleted, the agent must first verify canonical paths (`realpath`), open file descriptors (`lsof`/`fuser`), and OS package ownership (`dpkg -S` / `rpm -qf` / `apk info -W` / `pacman -Qo`) via `scripts/bof_safe_backup.sh check-delete <file>`.
3. **Mandatory Timestamped Config Backups + Native Syntax Check:** Every config modification is preceded by a timestamped `.bof.bak.<UTC_TIMESTAMP>` backup preserving permissions, inspected with `diff -u`, and validated with the daemon's native syntax checker (`nginx -t`, `haproxy -c`, `sshd -t`, `visudo -c`, `nft -c`, `docker compose config`) before reloading.
4. **100% Linux Distro-Agnostic:** Fingerprints `/etc/os-release` and `PID 1` first, seamlessly adapting commands across **Debian/Ubuntu**, **RHEL/Rocky/AlmaLinux/Fedora**, **Alpine Linux**, **Arch Linux**, and **SUSE/openSUSE** (`systemd`, `OpenRC`, `runit`).
5. **True Hostname Identification:** Verifies `hostname -f` via SSH before creating server documentation directories (`servers/<real-hostname>/`).
6. **Separation of Agent Memory vs. Deliverables:** Keeps persistent agent notes in `memory.md` and writes formal audits/plans into dedicated deliverable files (`inventory.md`, `analysis.md`, `improvements.md`, `upgrade_plan.md`).
7. **Config Drift & Comment-vs-Reality Auditing:** Actively compares configuration comments against active directives and cron schedules to catch silent misconfigurations.

---

## Repository Structure

```text
BoF/
├── SKILL.md                                           # Main skill instructions & 7 Ironclad Laws
├── README.md                                          # GitHub documentation & installation guide
├── references/
│   ├── log_forensics_and_troubleshooting.md           # Distro-agnostic logs, journalctl, dmesg/OOM, lsof +L1
│   ├── tuning_and_optimization.md                     # USE/RED methods, sysctl, ZFS, Btrfs, GlusterFS, NPU tuning
│   ├── security_hardening.md                          # SSH, Docker-UFW bypass, HAProxy/Nginx TLS/Slowloris, CrowdSec, mTLS
│   └── devops_containers_and_backups.md               # Docker log rotation, LXC UID mapping, chroot traps, 3-2-1 backups
└── scripts/
    ├── bof_safe_backup.sh                             # Timestamped backup, diff, restore & pre-deletion validator
    └── bof_audit.sh                                   # 100% read-only, distro-agnostic server audit generator
```

---

## Installation

### Option 1: Global Installation (Available in All Projects)
Copy or symlink the `BoF` folder into your global skills directory:

```bash
# Google Antigravity / Gemini CLI
mkdir -p ~/.gemini/config/skills
cp -r BoF ~/.gemini/config/skills/bof

# Claude Code
mkdir -p ~/.claude/skills
cp -r BoF ~/.claude/skills/bof
```

### Option 2: Workspace Installation (Checked into Git for Your Team)
Place `BoF` inside your project's `.agents/skills/` directory:

```bash
mkdir -p .agents/skills
cp -r BoF .agents/skills/bof
```

---

## Helper Scripts Usage

### 1. Safe Config Backup, Diff, Restore & Pre-Deletion Audit (`bof_safe_backup.sh`)
```bash
# Create a timestamped backup before editing a config file
./scripts/bof_safe_backup.sh backup /etc/haproxy/haproxy.cfg

# Inspect the unified diff between the backup and your modified config
./scripts/bof_safe_backup.sh diff /etc/haproxy/haproxy.cfg

# Roll back immediately to the latest backup
./scripts/bof_safe_backup.sh restore /etc/haproxy/haproxy.cfg

# Validate whether a single file is safe to delete (checks lsof, package owner, metadata)
./scripts/bof_safe_backup.sh check-delete /var/log/old_app.log
```

### 2. Read-Only System Reconnaissance & Audit (`bof_audit.sh`)
```bash
# Run a 100% non-destructive audit and save to inventory.md
./scripts/bof_audit.sh --output inventory.md
```

---

## License

MIT License — Built from real-world Linux Sysadmin, DevOps, and SRE field operations.
