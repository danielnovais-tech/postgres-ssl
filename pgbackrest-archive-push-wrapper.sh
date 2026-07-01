#!/bin/bash
# pgbackrest-archive-push-wrapper.sh — invoked by Postgres as archive_command.
#
# Wraps `pgbackrest archive-push` so that any kind of archive failure (hard
# repo error, stuck async worker, anything else) cannot fill pg_wal/ and halt
# Postgres. When pgbackrest fails AND pg_wal/ has grown past a threshold
# (WAL_DROP_THRESHOLD_MB; sized by wrapper.sh's compute_volume_thresholds to
# min(5 GiB, ~50% of volume) with operator override via this env var), the
# wrapper returns success to Postgres anyway. Postgres recycles the WAL
# segment as if archiving were disabled. The PITR window gets a coverage
# gap from this segment forward; below the threshold
# pg_stat_archiver.failed_count climbs normally and the dashboard surfaces
# "PITR broken — fix archiving config", so the underlying issue (bad creds,
# deleted bucket, expired keys, …) gets fixed before the threshold trips
# and the failure signal disappears.
#
# Special case: if the bucket actively does not exist (S3 NoSuchBucket error)
# or its credentials were revoked (InvalidAccessKeyId), there is no recovery
# without operator action — retrying is pointless and letting WAL accumulate
# up to the threshold wastes disk. In that case the wrapper drops immediately
# (returns 0) regardless of pg_wal size.
#
# The env var name avoids the PGBACKREST_* prefix on purpose: pgBackRest
# treats every PGBACKREST_* variable as a config option and warns about
# unknown names on every invocation. WAL_DROP_THRESHOLD_MB sits outside
# that namespace so it doesn't pollute logs.
#
# WAL_DROP_THRESHOLD_MB matches pgBackRest's own archive-push-queue-max
# (also ≤5 GiB, same volume-proportional sizing — see wrapper.sh) rather than
# using a smaller cap. Before 2026-07-01 this threshold was 10x smaller
# (≤500 MiB) on the theory that anything reaching this wrapper's non-zero-exit
# path was a hard, unrecoverable failure (bad creds, deleted bucket) not worth
# holding disk for — but that's wrong for transient S3-side errors (500s,
# timeouts, connection resets), which is exactly what pgBackRest's own
# archive-push-queue-max spool is designed to absorb generously, "most
# segments eventually get pushed" once the outage clears. Those errors also
# return non-zero from pgbackrest's foreground and used to trip this
# threshold 10x sooner than the spool's own budget, silently truncating the
# PITR window during an outage the spool could otherwise have ridden out.
# Only the two explicit no-recovery-possible errors above bypass the
# threshold and drop immediately; every other failure — hard or transient —
# now gets the same budget as the spool before we give up on it.
#
# Below the threshold the wrapper surfaces pgbackrest's failure to Postgres
# normally, so transient errors retry on the next archive_timeout instead
# of being silently dropped.
#
# Cost of `du -sb $PGDATA/pg_wal` here: only fires when archive-push fails.
# Under normal operation pgbackrest succeeds in async mode (segment written
# to spool, returns in milliseconds) and the wrapper exits before du runs.
# When pgbackrest IS failing, archive_command retries on every WAL switch
# (default archive_timeout=60s) — and pg_wal has by definition stopped
# being recycled, so it's a few dozen segments at most. A directory
# traversal of a few dozen small files every minute is the cheapest
# thing happening on this host while S3 is unreachable. Not worth caching.

set -u

WAL_FILE="${1:-}"
if [ -z "$WAL_FILE" ]; then
  echo "pgbackrest-wrapper: missing WAL file argument" >&2
  exit 1
fi

PGDATA="${PGDATA:-/var/lib/postgresql/data}"

# Defensive gate: if WAL_ARCHIVE_BUCKET is unset or empty at the time
# archive_command fires, archiving is not configured for this service.
# The normal path is wrapper.sh's clear_pgbackrest_state_if_disabled
# removing $PGDATA/conf.d/pgbackrest.conf so postgres never picks up
# archive_command in the first place — but a redeploy that didn't run,
# pinning to an older postgres-ssl tag that predates the cleanup, or a
# leftover ALTER SYSTEM SET archive_command in postgresql.auto.conf can
# all leak the archive_command setting onto a postgres that has no
# bucket. Surfacing pgbackrest's FileMissingError (exit 103) to Postgres
# in that state produces tens of thousands of "archive_command failed"
# lines a day for a service whose PITR is intentionally off. Return 0
# so pg_wal recycles; the log line below is the only signal admins need
# to clear the stale config (redeploy, or unset archive_command).
if [ -z "${WAL_ARCHIVE_BUCKET:-}" ]; then
  echo "pgbackrest-wrapper: WAL_ARCHIVE_BUCKET is unset; archive_command should not be installed. Dropping ${WAL_FILE} to keep Postgres up — redeploy the service so wrapper.sh can clean up the stale conf, or update the source image if a redeploy doesn't fix it." >&2
  exit 0
fi

PGWAL_THRESHOLD_MB="${WAL_DROP_THRESHOLD_MB:-5120}"
PGWAL_THRESHOLD_BYTES=$(( PGWAL_THRESHOLD_MB * 1024 * 1024 ))

# Per-cluster repo-path: read the marker written by pgbackrest-init.sh /
# wrapper.sh's bootstrap subshell. Without this, every archive-push would
# go to the ${WAL_ARCHIVE_PATH} root and a wipe-and-reuse-bucket scenario
# would collide on stanza identity. With it, archive-push targets
# ${WAL_ARCHIVE_PATH}/cluster-<sysid> and post-wipe clusters get their own
# sub-prefix instead of trying to overwrite the predecessor's repo.
if [ -f "$PGDATA/.pgbackrest_repo_path" ]; then
  PGBACKREST_REPO1_PATH=$(cat "$PGDATA/.pgbackrest_repo_path")
  export PGBACKREST_REPO1_PATH
fi

# pgBackRest 2.58 rejects --repo on archive-push (it pushes to whatever
# repos are configured). Multi-repo scoping for forks is enforced upstream
# by ensuring repo2 is dropped from the rendered config post-promote, not
# at the archive-push call site.
pgb_out=$(pgbackrest --stanza=main archive-push "$WAL_FILE" 2>&1)
PGB_RC=$?
[ -n "$pgb_out" ] && printf '%s\n' "$pgb_out" >&2
if [ "$PGB_RC" -eq 0 ]; then
  exit 0
fi

# In async mode the foreground output above is brief (just "command begin").
# The async worker writes the real error (HTTP response, S3 error code, etc.)
# to a spool status file. Print it so the actual failure reason appears in
# deployment logs instead of being invisible.
WAL_BASENAME=$(basename "$WAL_FILE")
SPOOL_ERR="${PGDATA}/pgbackrest-spool/archive/main/out/${WAL_BASENAME}.error"
if [ -f "$SPOOL_ERR" ]; then
  printf 'pgbackrest-wrapper: async spool error for %s (rc=%s):\n' "$WAL_BASENAME" "$PGB_RC" >&2
  cat "$SPOOL_ERR" >&2
fi

# Bucket deleted: when the bucket no longer exists Tigris returns NoSuchBucket
# on read paths, but validates credentials before checking bucket existence on
# write paths (archive-push is a PUT). Railway revokes the bucket credentials
# when the bucket is deleted, so in practice pgBackRest sees InvalidAccessKeyId
# on the PUT. Both errors mean no recovery without operator action — drop
# immediately rather than accumulating WAL up to the threshold.
if printf '%s\n' "$pgb_out" | grep -qE 'NoSuchBucket|InvalidAccessKeyId'; then
  echo "pgbackrest-wrapper: bucket gone or credentials revoked; dropping ${WAL_FILE} immediately" >&2
  touch "$PGDATA/.pgbackrest_gap_pending" 2>/dev/null || true
  exit 0
fi

PGWAL_BYTES=$(du -sb "$PGDATA/pg_wal" 2>/dev/null | awk '{print $1}')
if [ -z "${PGWAL_BYTES:-}" ]; then
  exit "$PGB_RC"
fi

if [ "$PGWAL_BYTES" -ge "$PGWAL_THRESHOLD_BYTES" ]; then
  PGWAL_MB=$(( PGWAL_BYTES / 1024 / 1024 ))
  echo "pgbackrest-wrapper: pg_wal at ${PGWAL_MB} MiB (threshold ${PGWAL_THRESHOLD_MB} MiB) and archive-push failing; dropping ${WAL_FILE} to keep Postgres up" >&2
  # Signal to pgbackrest-backup-watcher.sh that a gap was just created. The
  # watcher takes a fresh full backup once archiving recovers, sealing the
  # gap forward (the dropped segment itself is unrestorable, as before).
  touch "$PGDATA/.pgbackrest_gap_pending" 2>/dev/null || true
  exit 0
fi

exit "$PGB_RC"
