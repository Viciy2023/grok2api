#!/bin/sh
#
# Self-healing guard for the SQLite database on the Hugging Face bucket volume.
#
# /data lives on a bucket volume. That is fine for whole files, but a container
# stopped in the middle of a SQLite write - which is exactly what a Space
# rebuild does - can leave a torn page behind. Afterwards every query touching
# the damaged table fails with "database disk image is malformed": the service
# still starts, /healthz still answers, but the admin UI can no longer list
# accounts.
#
# Runs on every boot, before the application starts:
#   1. keeps a consistent rotating snapshot (sqlite3 .backup folds in the WAL)
#   2. verifies the database with PRAGMA integrity_check
#   3. when verification fails, rebuilds the database with sqlite3 .recover and
#      only accepts the result if it verifies AND did not lose accounts;
#      otherwise it falls back to the newest snapshot that verifies
#   4. when the database file is missing outright - the volume can drop it while
#      its WAL survives - restores/recover a snapshot instead of letting the
#      application create an empty database and silently lose every account
#
# The original file is never deleted: a failed repair leaves the database
# exactly as it was, and every replaced database is kept for inspection. A
# repaired database is additionally copied to backups/ under a fresh name, so a
# good copy exists independently of the swap in step 3.

# Install $1 as the live database $2. A plain byte copy, because the rename a
# previous repair used is what left the new file unsynced on the volume.
install_database() {
  [ -f "$1" ] || return 1
  rm -f "$2-wal" "$2-shm"
  cp "$1" "$2"
}

# Pick a usable database from the snapshot directory. Sets CHOSEN_SNAPSHOT (a
# global, never stdout: the sqlite3 CLI prints banner text such as
# "defensive off" around .recover, which silently corrupts a command
# substitution and once made this guard install an empty database).
# A snapshot that does not verify is repaired on the spot, because the damaged
# copies are exactly the ones that still hold every account row.
choose_snapshot() {
  _dir="$1"
  _want="$2"
  CHOSEN_SNAPSHOT=""
  for _candidate in $(ls -1t "$_dir"/backend.db.* 2>/dev/null); do
    case "$_candidate" in
      *.tmp) continue ;;
    esac
    [ -f "$_candidate" ] || continue
    if [ "$(timeout 300 sqlite3 "$_candidate" 'PRAGMA integrity_check;' 2>/dev/null | head -n 1)" = "ok" ]; then
      CHOSEN_SNAPSHOT="$_candidate"
      return 0
    fi
    _repaired="$_candidate.recovered"
    rm -f "$_repaired"
    if sqlite3 "$_candidate" .recover 2>/dev/null | sqlite3 "$_repaired" >/dev/null 2>&1; then
      if [ -s "$_repaired" ] && [ "$(timeout 300 sqlite3 "$_repaired" 'PRAGMA integrity_check;' 2>/dev/null | head -n 1)" = "ok" ]; then
        _accounts="$(timeout 60 sqlite3 "$_repaired" 'SELECT COUNT(*) FROM provider_accounts;' 2>/dev/null | head -n 1)"
        case "$_accounts" in
          ''|*[!0-9]*) _accounts="" ;;
        esac
        if [ -z "$_want" ] || [ -z "$_accounts" ] || [ "$_accounts" -ge "$_want" ]; then
          CHOSEN_SNAPSHOT="$_repaired"
          return 0
        fi
      fi
    fi
    rm -f "$_repaired"
  done
  return 1
}

sqlite_preflight() {
  db_dir="${1:-/data}"
  db="$db_dir/backend.db"

  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 not installed; skipping database preflight" >&2
    return 0
  fi

  backup_dir="$db_dir/backups"
  mkdir -p "$backup_dir" 2>/dev/null || true

  # ---- 0. the volume dropped the database but kept its WAL ---------------- #
  if [ ! -f "$db" ]; then
    if [ ! -f "$db-wal" ]; then
      echo "$db not present yet; nothing to verify"
      return 0
    fi
    echo "WARN: $db is missing while a WAL survives; the bucket volume lost the main file" >&2
    if ! choose_snapshot "$backup_dir" "" || [ -z "$CHOSEN_SNAPSHOT" ]; then
      echo "ERROR: no usable snapshot to restore after the main database went missing" >&2
      return 0
    fi
    if install_database "$CHOSEN_SNAPSHOT" "$db"; then
      sqlite3 "$db" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true
      echo "database restored from $CHOSEN_SNAPSHOT after the volume lost the main file" >&2
    else
      echo "ERROR: could not restore $CHOSEN_SNAPSHOT to $db" >&2
    fi
    return 0
  fi

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
      install_database "$recovered" "$db"
      # Keep the repaired content under its own name too: the swap above is a
      # rename, and this volume has been observed not to sync the file that a
      # rename creates.
      cp "$db" "$backup_dir/backend.db.repaired-$stamp" 2>/dev/null || true
      echo "database rebuilt from recovered pages; accounts=$new_accounts (damaged copy kept at $broken)" >&2
      return 0
    fi
  fi
  rm -f "$recovered"

  # ---- 3b. otherwise restore the newest snapshot that verifies ----------- #
  if choose_snapshot "$backup_dir" "$src_accounts" && [ -n "$CHOSEN_SNAPSHOT" ]; then
    mv "$db" "$broken"
    if install_database "$CHOSEN_SNAPSHOT" "$db"; then
      echo "database restored from $CHOSEN_SNAPSHOT (damaged copy kept at $broken)" >&2
      return 0
    fi
    echo "ERROR: could not install $CHOSEN_SNAPSHOT; restoring the damaged original" >&2
    mv "$broken" "$db" 2>/dev/null || true
    return 0
  fi

  echo "ERROR: automatic recovery failed and no valid snapshot exists; leaving the database untouched" >&2
  return 0
}
