#!/bin/sh
# Backup and point-in-time restore for the user-mode cluster (server.md 8.4):
# base backup, write rows, WAL switch, drop the table, restore to the time
# before the drop into a new data directory, check the rows. Runs as the
# server user after pg-user-mode.sh setup.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pg-common.sh
. "$here/pg-common.sh"
[ -n "${HOME:-}" ] || HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
STATE="$HOME/.local/state/cmux/server"
PGSTATE="$STATE/postgres"
RUN="$PGSTATE/run"
WAL="$STATE/backups/wal"
port=$(cat "$PGSTATE/port")
ms() { date +%s%3N; }
admin() { "$PGBIN/psql" -h "$RUN" -p "$port" -U cmux_admin -v ON_ERROR_STOP=1 -Atq "$@"; }

base="$STATE/backups/base/$(date -u +%Y%m%dT%H%M%SZ)"
t0=$(ms)
"$PGBIN/pg_basebackup" -h "$RUN" -p "$port" -U cmux_admin -D "$base" -Ft -z -X none -c fast 2>&1 | grep -v 'WAL archiving' || true
echo "base_backup_ms=$(($(ms) - t0)) size=$(du -sh "$base" | cut -f1)"

admin -d app_notes -c 'set role app_notes; create table notes(id int primary key, body text); insert into notes select g, md5(g::text) from generate_series(1,10000) g;'
admin -d postgres -c 'select pg_switch_wal()' >/dev/null
target=$(admin -d postgres -c "select now()")
admin -d postgres -c 'select pg_sleep(1.1)' >/dev/null
admin -d app_notes -c 'drop table notes;'
seg=$(admin -d postgres -c 'select pg_walfile_name(pg_switch_wal())')
# The archiver copies the closed segment asynchronously; wait on its own
# counter with a bounded server-side sleep, not a fixed shell sleep.
i=0
until [ "$(admin -d postgres -c "select coalesce(last_archived_wal, '') >= '$seg' from pg_stat_archiver")" = t ]; do
  i=$((i + 1))
  [ "$i" -lt 200 ] || { echo "archiver did not archive $seg"; exit 1; }
  admin -d postgres -c 'select pg_sleep(0.05)' >/dev/null
done
echo "target_time=$target archived_segments=$(find "$WAL" -maxdepth 1 -type f ! -name '.*' | wc -l) archiver=$(admin -d postgres -c "select format('%s archived, %s failed', archived_count, failed_count) from pg_stat_archiver")"
gone=$(admin -d app_notes -c "select count(*) from pg_class where relname='notes'")
echo "live cluster: notes table present=$gone (dropped)"

t0=$(ms)
rdata="$PGSTATE/17/restore-$(date +%s)"
rrun="$PGSTATE/run-restore"
mkdir -p "$rdata" "$rrun"
chmod 700 "$rdata" "$rrun"
tar -xzf "$base/base.tar.gz" -C "$rdata"
rport=$((port + 2))
cat >>"$rdata/cmux.conf" <<CONF
# restore overrides
port = $rport
unix_socket_directories = '$rrun'
archive_mode = off
restore_command = 'cp $WAL/%f %p'
recovery_target_time = '$target'
recovery_target_action = 'promote'
CONF
touch "$rdata/recovery.signal"
"$PGBIN/pg_ctl" -D "$rdata" -l "$rdata/restore.log" -w -t 120 start >/dev/null
# pg_ctl -w returns when connections are accepted; promotion follows replay.
until [ "$("$PGBIN/psql" -h "$rrun" -p "$rport" -U cmux_admin -d postgres -Atc 'select pg_is_in_recovery()')" = f ]; do
  "$PGBIN/psql" -h "$rrun" -p "$rport" -U cmux_admin -d postgres -Atqc 'select pg_sleep(0.05)' >/dev/null
done
rows=$("$PGBIN/psql" -h "$rrun" -p "$rport" -U cmux_admin -d app_notes -Atc 'select count(*) from notes')
restore_ms=$(($(ms) - t0))
echo "restore_ms=$restore_ms rows_after_restore=$rows"
grep -E 'recovery stopping|starting point-in-time|archive recovery complete' "$rdata/restore.log" | sed 's/^/  log| /'
"$PGBIN/pg_ctl" -D "$rdata" -m fast stop >/dev/null
if [ "$rows" = 10000 ]; then echo "RESULT pg-pitr PASS 10000 rows back in ${restore_ms} ms"; else echo "RESULT pg-pitr FAIL rows=$rows"; fi
