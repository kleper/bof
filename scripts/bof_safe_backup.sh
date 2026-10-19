#!/usr/bin/env bash
# ==============================================================================
# BoF (Bastard Operator From Hell) — Safe Config Backup & Pre-Deletion Validator
# ==============================================================================
# Enforces BoF Law 2 (No Recursive Delete / Pre-Deletion Validation) and
# BoF Law 3 (Mandatory Timestamped Config Backups + Diff & Rollback).
#
# Usage:
#   ./bof_safe_backup.sh backup <file>
#   ./bof_safe_backup.sh diff <file>
#   ./bof_safe_backup.sh restore <file> [specific_backup_path]
#   ./bof_safe_backup.sh check-delete <file>
# ==============================================================================

set -euo pipefail

ACTION="${1:-}"
TARGET="${2:-}"
BACKUP_ARG="${3:-}"

usage() {
    cat <<'EOF'
Usage:
  bof_safe_backup.sh backup <file>                 Create timestamped .bof.bak.<UTC> copy
  bof_safe_backup.sh diff <file>                   Show unified diff against latest backup
  bof_safe_backup.sh restore <file> [backup_file]  Restore file from latest (or given) backup
  bof_safe_backup.sh check-delete <file>           Read-only safety check before single-file deletion
EOF
    exit 1
}

if [[ -z "$ACTION" || -z "$TARGET" ]]; then
    usage
fi

sha256_file() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        echo "unavailable"
    fi
}

latest_backup_for() {
    local f="$1"
    # List matching backups sorted by name (timestamp is YYYYMMDD_HHMMSS)
    ls -1 "${f}.bof.bak."* 2>/dev/null | sort | tail -n 1 || true
}

case "$ACTION" in
    backup)
        if [[ ! -f "$TARGET" ]]; then
            echo "[BoF ERROR] Target '$TARGET' does not exist or is not a regular file." >&2
            exit 1
        fi
        REAL_TARGET="$(realpath "$TARGET")"
        TS="$(date -u +%Y%m%d_%H%M%S)"
        BAK_PATH="${REAL_TARGET}.bof.bak.${TS}"
        cp -p "$REAL_TARGET" "$BAK_PATH"
        ORIG_HASH="$(sha256_file "$REAL_TARGET")"
        BAK_HASH="$(sha256_file "$BAK_PATH")"
        if [[ "$ORIG_HASH" != "$BAK_HASH" ]]; then
            echo "[BoF ERROR] Checksum mismatch after backup! Aborting." >&2
            exit 1
        fi
        echo "[BoF BACKUP OK] Created backup: $BAK_PATH"
        echo "  Source : $REAL_TARGET"
        echo "  SHA256 : $BAK_HASH"
        ;;

    diff)
        if [[ ! -f "$TARGET" ]]; then
            echo "[BoF ERROR] Target '$TARGET' does not exist." >&2
            exit 1
        fi
        REAL_TARGET="$(realpath "$TARGET")"
        LATEST_BAK="${BACKUP_ARG:-$(latest_backup_for "$REAL_TARGET")}"
        if [[ -z "$LATEST_BAK" || ! -f "$LATEST_BAK" ]]; then
            echo "[BoF ERROR] No .bof.bak.* backup found for '$REAL_TARGET'." >&2
            exit 1
        fi
        echo "[BoF DIFF] Comparing $LATEST_BAK -> $REAL_TARGET"
        diff -u "$LATEST_BAK" "$REAL_TARGET" || true
        ;;

    restore)
        REAL_TARGET="$(realpath "$TARGET" 2>/dev/null || echo "$TARGET")"
        LATEST_BAK="${BACKUP_ARG:-$(latest_backup_for "$REAL_TARGET")}"
        if [[ -z "$LATEST_BAK" || ! -f "$LATEST_BAK" ]]; then
            echo "[BoF ERROR] No backup file found to restore '$REAL_TARGET'." >&2
            exit 1
        fi
        cp -p "$LATEST_BAK" "$REAL_TARGET"
        echo "[BoF RESTORE OK] Restored '$REAL_TARGET' from '$LATEST_BAK'"
        echo "  SHA256 : $(sha256_file "$REAL_TARGET")"
        ;;

    check-delete)
        echo "=================================================================="
        echo "[BoF PRE-DELETION SAFETY AUDIT] (Read-Only — File Is NOT Deleted)"
        echo "=================================================================="
        if [[ ! -e "$TARGET" && ! -L "$TARGET" ]]; then
            echo "[BoF ERROR] Path '$TARGET' does not exist." >&2
            exit 1
        fi
        if [[ -d "$TARGET" && ! -L "$TARGET" ]]; then
            echo "[BoF BLOCKED] '$TARGET' is a DIRECTORY." >&2
            echo "  BoF Law 2 strictly forbids recursive directory deletion (rm -rf)." >&2
            echo "  If an empty directory must be removed, verify with 'ls -la' and use 'rmdir'." >&2
            exit 2
        fi
        REAL_TARGET="$(realpath "$TARGET")"
        echo "1. Canonical Path : $REAL_TARGET"
        echo "2. File Metadata  : $(ls -ld "$REAL_TARGET")"
        echo "3. SHA256 Hash    : $(sha256_file "$REAL_TARGET")"

        # Check open file descriptors
        echo "4. Open File Descriptors (lsof / fuser):"
        OPEN_PROCS=""
        if command -v lsof >/dev/null 2>&1; then
            OPEN_PROCS="$(lsof "$REAL_TARGET" 2>/dev/null || true)"
        elif command -v fuser >/dev/null 2>&1; then
            OPEN_PROCS="$(fuser -v "$REAL_TARGET" 2>&1 || true)"
        fi
        if [[ -n "$OPEN_PROCS" ]]; then
            echo "   [WARNING] File is currently held OPEN by running process(es):"
            echo "$OPEN_PROCS" | sed 's/^/     /'
            echo "   [NOTE] Deleting an open file will NOT free disk space until the process reloads!"
        else
            echo "   [OK] No running process holds an open descriptor to this file."
        fi

        # Check OS package ownership (Distro-Agnostic)
        echo "5. OS Package Ownership Check:"
        PKG_OWNER=""
        if command -v dpkg >/dev/null 2>&1; then
            PKG_OWNER="$(dpkg -S "$REAL_TARGET" 2>/dev/null || true)"
        elif command -v rpm >/dev/null 2>&1; then
            PKG_OWNER="$(rpm -qf "$REAL_TARGET" 2>/dev/null | grep -v 'not owned' || true)"
        elif command -v apk >/dev/null 2>&1; then
            PKG_OWNER="$(apk info -W "$REAL_TARGET" 2>/dev/null | grep -v 'ERROR' || true)"
        elif command -v pacman >/dev/null 2>&1; then
            PKG_OWNER="$(pacman -Qo "$REAL_TARGET" 2>/dev/null || true)"
        fi
        if [[ -n "$PKG_OWNER" ]]; then
            echo "   [DANGER] File is owned by an installed system package:"
            echo "     $PKG_OWNER"
            echo "   Do NOT manually delete package-managed files!"
        else
            echo "   [OK] File is not owned by any system package."
        fi

        echo "=================================================================="
        echo "Next Step: Present this audit to the user and ask for explicit"
        echo "confirmation before running 'rm \"$REAL_TARGET\"'."
        echo "=================================================================="
        ;;

    *)
        usage
        ;;
esac
