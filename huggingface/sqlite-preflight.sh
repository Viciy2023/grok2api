#!/bin/sh
#
# Self-healing guard for the SQLite database on the Hugging Face bucket volume.
#
# /data lives on a network-backed bucket volume. That is fine for whole files,
# but a container stopped in the middle of a SQLite write - which is exactly
# what a Space rebuild does - can leave a torn page behind. Afterwards every
# query touching the damaged table fails with "database disk image is
# malformed": the service still starts, /healthz still answers, but the admin UI
# can no longer list accounts.
#
# Runs on every boot, before the application starts:
#   1. keeps a consistent rotating snapshot (sqlite3 .backup folds in the WAL)
#   2. verifies the database with PRAGMA integrity_check
#   3. when verification fails, rebuilds the database with sqlite3 .recover and
#      only accepts the result if it verifies AND did not lose accounts;
#      otherwise it falls back to the newest snapshot that verifies
#
# The original file is never deleted - a failed repair leaves the database
# exactly as it was, and every replaced database is kept for inspection.

sqlite_preflight() {
  db_dir="${1:-/data}"
  db="$db_dir/backend.db"

  [ -f "$db" ] || return 0
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 not installed; skipping database preflight" >&2
    return 0
  fi

  backup_dir="$db_dir/backups"
  mkdir -p "$backup_dir" 2>/dev/null || true

  # ---- 1. rotating pre-boot snapshot ------------------------------------- #
  # Slot 1 is always "the database as it was found"; older slots hold previous
  # boots, so if slot 1 is itself damaged the fallback still has a candidate.
  if sqlite3 "$db" ".backup '$backup_dir/backend.db.tmp'" 2>/dev/null; then
    i=4
    while [ "$i" -ge 1 ]; do
      if [ -f "$backup_dir/backend.db.$i" ]; then
        mv "$backup_dir/backend.db.$i" "$backup_dir/backend.db.$((i + 1))"
      fi
      i=$((i - 1))
    done
    mv "$backup_dir/backend.db.tmp" "$backup_dir/backend.db.1"
    echo "database snapshot written to $backup_dir/backend.db.1"
  else
    echo "WARN: could not snapshot the database" >&2
  fi

  # ---- 2. verify (bounded so a huge database cannot stall the boot) ------- #
  check="$(timeout 300 sqlite3 "$db" 'PRAGMA integrity_check;' 2>&1 | head -n 1)"
  if [ "$check" = "ok" ]; then
    echo "database integrity check passed"
    return 0
  fi

  echo "WARN: database integrity check failed: $check" >&2

  # How many accounts the damaged database still exposes to a plain scan. The
  # repair must never end up with fewer than this.
  src_accounts="$(timeout 60 sqlite3 "$db" 'SELECT COUNT(*) FROM provider_accounts;' 2>/dev/null | head -n 1)"
  case "$src_accounts" in
    ''|*[!0-9]*) src_accounts="" ;;
  esac

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  broken="$db_dir/backend.db.corrupt-$stamp"
  recovered="$db_dir/backend.db.recovered-$stamp"

  # ---- 3a. rebuild from every page that is still readable ---------------- #
  # .recover is the canonical SQLite repair: it re-emits the schema and every
  # readable row into a fresh database, so indexes are rebuilt and mis-ordered
  # b-tree pages are rewritten.
  if sqlite3 "$db" .recover 2>/dev/null | sqlite3 "$recovered" 2>/dev/null; then
    new_check="$(timeout 300 sqlite3 "$recovered" 'PRAGMA integrity_check;' 2>/dev/null | head -n 1)"
    new_accounts="$(timeout 60 sqlite3 "$recovered" 'SELECT COUNT(*) FROM provider_accounts;' 2>/dev/null | head -n 1)"
    case "$new_accounts" in
      ''|*[!0-9]*) new_accounts="" ;;
    esac

    if [ "$new_check" != "ok" ]; then
      echo "WARN: recovered database still fails verification ($new_check)" >&2
    elif [ -n "$src_accounts" ] && [ -n "$new_accounts" ] && [ "$new_accounts" -lt "$src_accounts" ]; then
      echo "WARN: recovery would lose accounts ($new_accounts < $src_accounts); not using it" >&2
    else
      # The application opens the database with journal_mode(WAL); keep that.
      sqlite3 "$recovered" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true
      mv "$db" "$broken"
      rm -f "$db-wal" "$db-shm"
      mv "$recovered" "$db"
      echo "database rebuilt from recovered pages; accounts=$new_accounts (damaged copy kept at $broken)" >&2
      return 0
    fi
  fi
  rm -f "$recovered"

  # ---- 3b. otherwise restore the newest snapshot that verifies ----------- #
  i=1
  while [ "$i" -le 4 ]; do
    snapshot="$backup_dir/backend.db.$i"
    if [ -f "$snapshot" ]; then
      snapshot_check="$(timeout 300 sqlite3 "$snapshot" 'PRAGMA integrity_check;' 2>/dev/null | head -n 1)"
      if [ "$snapshot_check" = "ok" ]; then
        snapshot_accounts="$(timeout 60 sqlite3 "$snapshot" 'SELECT COUNT(*) FROM provider_accounts;' 2>/dev/null | head -n 1)"
        mv "$db" "$broken"
        rm -f "$db-wal" "$db-shm"
        cp "$snapshot" "$db"
        echo "database restored from snapshot $snapshot (accounts=$snapshot_accounts; damaged copy kept at $broken)" >&2
        return 0
      fi
    fi
    i=$((i + 1))
  done

  echo "ERROR: automatic recovery failed and no valid snapshot exists; leaving the database untouched" >&2
  return 0
}
