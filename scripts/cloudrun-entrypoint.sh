#!/usr/bin/env bash
# OpenFathom delta — allowed by ADR-002. Do not add upstream-facing logic here;
# this script only translates the Cloud Run env-var contract into the real
# `hermes` subcommands, confirmed by reading hermes_cli/main.py and
# hermes_cli/subcommands/gateway.py in this fork (2026-07-12).
#
# Actually built and run locally (2026-07-12): `docker build -t of-agent:base .`
# (the real upstream Dockerfile) then `docker build -f Dockerfile.cloudrun`,
# then both modes exercised for real. `job` reached a real Gemini API call
# with a live key (failed with HTTP 404 -- a model/provider question for
# OF-04, not a bug here). `service` bound $PORT and `/health` answered
# `{"status": "ok", ...}`; `/health/detailed` correctly rejected an
# unauthenticated request. Two real bugs were found and fixed by running
# this, not by reading it -- see the comments below.
#
# Invoked as the CMD passed through /init -> docker/main-wrapper.sh: since this
# file is executable, main-wrapper's routing execs it directly (no `hermes`
# prefix), after with-contenv has restored the container env and s6-setuidgid
# has dropped root -> the `hermes` user. Do NOT bypass /init in Dockerfile.cloudrun
# (ENTRYPOINT stays inherited from the base image) -- stage2-hook.sh's UID/GID
# remap and venv seed still have to run once as root, even for a single job.
#
# Env var contract:
#   HERMES_MODE     "service" (Cloud Run Service, default) or "job" (Cloud Run Job)
#   API_SERVER_KEY  required in service mode -- see the block below, this is enforced
#                   in gateway/platforms/api_server.py, not a preference of ours
#   HERMES_TASK     prompt to run in job mode (required when HERMES_MODE=job)
#   HERMES_SKILLS_OBJECT  service mode only, OPT-IN. Object name of the OpenFathom skills
#                   tarball inside HERMES_STATE_BUCKET. Unset -> the block is skipped
#                   entirely and behaviour is exactly what it was before OF-08. The Job
#                   is unaffected either way: it gcsfuse-mounts its own $HERMES_HOME and
#                   already sees the skills through that mount.
#   HERMES_PLUGINS_OBJECT  service mode only, OPT-IN (ADR-052). Object name of the
#                   OpenFathom plugin tarball inside HERMES_STATE_BUCKET, delivered into
#                   $HERMES_HOME/plugins/ and enabled via plugins.enabled. Same out-of-band
#                   contract as the skills tarball. Unset -> the block is skipped and the
#                   gateway has no delegation tool.
#   HERMES_JOB_OUTPUT  where to write the job's stdout (default $HERMES_HOME/job-output.txt)
#   HERMES_INFERENCE_PROVIDER / HERMES_INFERENCE_MODEL  honored in BOTH modes, but
#                   through two different mechanisms, because the two modes resolve the
#                   provider by different code paths. Neither mode can leave them as
#                   bare env vars.
#
#                   job mode -- passed as `hermes -z`'s own --provider/--model flags. A
#                   real OF-04 execution failed with "No inference provider configured"
#                   despite both env vars being set: hermes_cli/oneshot.py's
#                   _run_agent() only reads HERMES_INFERENCE_MODEL/PROVIDER to feed
#                   detect_provider_for_model() as an auto-detection HINT, and that
#                   detection silently failed for gemini-2.5-flash + vertex, falling
#                   through to auth.py's resolve_provider("auto") -- which has no
#                   knowledge of either env var at all. The CLI flags reach
#                   run_oneshot(model=, provider=) directly (hermes_cli/main.py).
#
#                   service mode -- `hermes gateway run` takes no such flags, so they
#                   are written into config.yaml via `hermes config set` below, before
#                   the gateway starts. Reading the env vars is not enough here either,
#                   for a subtler reason, measured on the real deployed config rather
#                   than assumed: runtime_provider.py's resolve_requested_provider()
#                   reads, in order, (1) an explicit arg, (2) config.yaml
#                   model.provider, (3) $HERMES_INFERENCE_PROVIDER, (4) "auto". The
#                   config.yaml that cont-init's schema migration writes ships
#                   `provider: "auto"` -- a NON-EMPTY string, so step 2 returns it and
#                   step 3 is never reached. The env var is shadowed by a default
#                   nobody chose. That is precisely how the deployed gateway answered
#                   "No inference provider configured" on the OF-09 end-to-end test
#                   while the Job, using CLI flags (step 1), reached Vertex fine from
#                   this same image. HERMES_INFERENCE_MODEL is worse still: outside
#                   oneshot.py nothing reads it, so config.yaml model.default is the
#                   only model input the gateway has.
#   HERMES_TIMEZONE  optional, service mode -- IANA name (e.g. America/Sao_Paulo)
#                   written to config.yaml `timezone`. hermes_time.py validates it with
#                   ZoneInfo and falls back to server-local when empty or invalid. This
#                   key steers hermes's own time handling only; set the container's TZ
#                   env var alongside it for everything else.
#   HERMES_SOUL     optional, service mode -- the declared agent identity (ENG-47),
#                   written verbatim over $HERMES_HOME/SOUL.md at boot (of_write_soul),
#                   AFTER any snapshot restore. Versioned in openfathom-infra; this is
#                   the only lever for the agent's spoken language (display.language does
#                   not accept pt-BR). Empty (default) keeps the image's default SOUL.md.
#   PORT            injected by Cloud Run; only consulted in service mode
#   HERMES_STATE_BUCKET  optional, service mode -- GCS bucket holding the state
#                   snapshot (ENG-45). Empty (default) disables persistence entirely
#                   and keeps the pre-ENG-45 behavior: state lives on the container's
#                   writable layer and dies with the instance.
#   HERMES_STATE_OBJECT  optional -- object name inside that bucket. Default
#                   gateway-state.tar.gz. Must not contain `/` (it goes into a URL
#                   path segment unescaped).
set -euo pipefail

# --- State persistence (ENG-45) ---------------------------------------------
# Why a snapshot to a single object instead of the GCS FUSE volume mount that
# ADR-003 specifies for Track A: openfathom-meta ADR-041. The short version,
# researched against the primary docs before writing this (not assumed):
# gcsfuse re-uploads the FULL object on every fsync, and SQLite's `state.db` and
# `state.db-wal` are two independent GCS objects with no atomicity across them --
# so a kill between their uploads pairs mismatched generations, which is the
# textbook SQLite corruption vector. That failure is SILENT, so "mount it and
# watch" cannot absolve it. Snapshotting instead keeps SQLite on a real POSIX
# filesystem (WAL exactly as designed) and ships ONE self-contained object, which
# GCS writes atomically.
#
# Deliberately NOT restored: config.yaml. cont-init's schema migration writes a
# fresh one every boot and the block below then sets our keys on it; restoring an
# old config.yaml would shadow that migration on the next image bump. Config is
# declared by Terraform here, not user state.
#
# No gcloud/gsutil/google-cloud-storage in this image (checked: uv.lock has
# google-auth but not google-cloud-storage; the Dockerfile installs neither CLI).
# curl + the metadata server is the whole dependency.
of_metadata_token() {
  curl -fsS --retry 2 --max-time 10 \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# OF-08. Fetch the OpenFathom skills tarball and extract it into $1. Returns non-zero
# (and says why) if the directory would not end up with at least one SKILL.md -- the
# caller uses that to decide whether to point skills.external_dirs at it. Reuses
# of_metadata_token + the JSON API exactly like of_state_restore: still no gcloud, no
# gsutil, no google-cloud-storage in this image.
#
# Unlike the state snapshot, a 404 here is NOT a normal first boot -- the object is
# published deliberately, so its absence means the publish step was skipped.
of_skills_fetch() {
  local dest="$1" tok code tarball="/tmp/of-skills.tar.gz"
  tok="$(of_metadata_token)" || { echo "[of-skills] WARN: no metadata token" >&2; return 1; }

  code="$(curl -sS -o "$tarball" -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_SKILLS_OBJECT}?alt=media" || echo 000)"
  if [[ "$code" != "200" ]]; then
    echo "[of-skills] WARN: fetch of gs://${HERMES_STATE_BUCKET}/${HERMES_SKILLS_OBJECT} failed (HTTP ${code})" >&2
    rm -f "$tarball"; return 1
  fi

  # Replace wholesale: a stale skill left behind by a previous boot would keep being
  # advertised to the model after it was deleted upstream.
  rm -rf "$dest"; mkdir -p "$dest"
  if ! tar xzf "$tarball" -C "$dest" 2>/dev/null; then
    echo "[of-skills] WARN: tarball present but did not extract" >&2
    rm -f "$tarball"; return 1
  fi
  rm -f "$tarball"

  local n
  n="$(find "$dest" -name SKILL.md -type f 2>/dev/null | wc -l)"
  if [[ "$n" -eq 0 ]]; then
    echo "[of-skills] WARN: extracted tarball contains no SKILL.md -- refusing to point external_dirs at an empty tree" >&2
    return 1
  fi
  echo "[of-skills] loaded ${n} skill(s) from gs://${HERMES_STATE_BUCKET}/${HERMES_SKILLS_OBJECT}"
  return 0
}

# ADR-052. Fetch the OpenFathom plugin tarball and extract it into $1 -- a
# $HERMES_HOME/plugins/ directory Hermes scans for user plugins. Returns non-zero (and
# says why) unless the directory ends up with at least one plugin.yaml; the caller uses
# that to decide whether to enable the plugin. Same transport and same fail-loud contract
# as of_skills_fetch: a 404 means the publish step was skipped, not a normal first boot.
of_plugins_fetch() {
  local dest="$1" tok code tarball="/tmp/of-plugins.tar.gz"
  tok="$(of_metadata_token)" || { echo "[of-plugins] WARN: no metadata token" >&2; return 1; }

  code="$(curl -sS -o "$tarball" -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_PLUGINS_OBJECT}?alt=media" || echo 000)"
  if [[ "$code" != "200" ]]; then
    echo "[of-plugins] WARN: fetch of gs://${HERMES_STATE_BUCKET}/${HERMES_PLUGINS_OBJECT} failed (HTTP ${code})" >&2
    rm -f "$tarball"; return 1
  fi

  # Replace wholesale: a stale plugin left by a previous boot would keep loading after it
  # was removed upstream.
  rm -rf "$dest"; mkdir -p "$dest"
  if ! tar xzf "$tarball" -C "$dest" 2>/dev/null; then
    echo "[of-plugins] WARN: tarball present but did not extract" >&2
    rm -f "$tarball"; return 1
  fi
  rm -f "$tarball"

  local n
  n="$(find "$dest" -name plugin.yaml -type f 2>/dev/null | wc -l)"
  if [[ "$n" -eq 0 ]]; then
    echo "[of-plugins] WARN: extracted tarball contains no plugin.yaml -- refusing to enable an empty plugins dir" >&2
    return 1
  fi
  echo "[of-plugins] loaded ${n} plugin(s) from gs://${HERMES_STATE_BUCKET}/${HERMES_PLUGINS_OBJECT}"
  return 0
}

# Restore is best-effort BY DESIGN: a gateway that boots empty is degraded, but a
# gateway that refuses to boot is down (Dogma 2). HTTP 404 is the first-boot case
# and is not an error.
of_state_restore() {
  local tok code tarball="/tmp/of-state-restore.tar.gz"
  tok="$(of_metadata_token)" || { echo "[of-state] WARN: no metadata token; starting with empty state" >&2; return 0; }

  # Record the generation we are about to read, for the compare-and-swap in
  # of_state_snapshot(). A metadata GET (no alt=media) is the documented way to
  # obtain it; `x-goog-generation` on the alt=media download is documented only for
  # the XML API and was NOT confirmed for this JSON endpoint, so we do not rely on
  # it. 404 -> no live version -> generation 0, which GCS defines as "only proceed
  # if no live object exists".
  of_state_generation="$(curl -sS --max-time 30 \
    -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_STATE_OBJECT}" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("generation") or 0)
except Exception: print(0)' 2>/dev/null || echo 0)"

  code="$(curl -sS -o "$tarball" -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_STATE_OBJECT}?alt=media" || echo 000)"
  case "$code" in
    200) ;;
    404) echo "[of-state] no snapshot yet (first boot) -- starting with empty state"; rm -f "$tarball"; return 0 ;;
    *)   echo "[of-state] WARN: restore failed (HTTP ${code}); starting with empty state" >&2; rm -f "$tarball"; return 0 ;;
  esac
  if tar xzf "$tarball" -C "${HERMES_HOME:-/opt/data}" 2>/dev/null; then
    echo "[of-state] restored snapshot from gs://${HERMES_STATE_BUCKET}/${HERMES_STATE_OBJECT}"
  else
    echo "[of-state] WARN: snapshot present but did not extract; starting with empty state" >&2
  fi
  rm -f "$tarball"

  # openfathom-meta ADR-049. Carry the state epoch forward. Deliberately NOT in the
  # `local` list above -- same reason of_state_generation is not: of_state_snapshot reads
  # it at shutdown, hours later, so it has to survive this function's return. Making it
  # local would silently degrade the reset guard to "always 0", which is the failure this
  # variable exists to prevent.
  #
  # Absent or unreadable -> 0. Everything written before this ADR has no .state_epoch, so
  # 0 is what they all get, comparisons are `>=`, and nothing needs migrating.
  of_state_epoch="$(of_state_read_local_epoch)"
  echo "[of-state] state epoch ${of_state_epoch}"
}

# openfathom-meta ADR-049. Read the epoch of the state that was just restored onto disk.
# Always prints an integer; absent, empty, unreadable or non-numeric all print 0.
#
# THIS FUNCTION EXISTS BECAUSE ITS FIRST VERSION TOOK PRODUCTION DOWN (2026-07-20).
# It was one inline line inside of_state_restore:
#
#     of_state_epoch="$(cat "$home/.state_epoch" 2>/dev/null | tr -cd '0-9')"
#
# Under `set -euo pipefail` (line 83) that is a landmine, and it detonates on the ONLY
# input that existed at the time: no snapshot written before ADR-049 carries the file, so
# `cat` exits 1, `pipefail` promotes the pipeline's failure, the assignment inherits it,
# and `set -e` kills the shell -- between "restored snapshot" and this line. Revision
# 00033-lcr never listened on PORT and Cloud Run refused to give it traffic.
#
# `< file` instead of `cat file |` removes the pipeline entirely, the `[[ -r ]]` guard
# removes the failing command, and being a named function makes it testable -- which the
# inline version was not, and is exactly why the test suite passed while this was broken.
of_state_read_local_epoch() {
  local f="${HERMES_HOME:-/opt/data}/.state_epoch" v=""
  if [[ -r "$f" ]]; then
    v="$(tr -cd '0-9' < "$f")" || v=""
  fi
  printf '%s' "${v:-0}"
}

# openfathom-meta ADR-049. Read `.state_epoch` out of a state tarball WITHOUT unpacking
# it. Prints an integer; absent, unreadable or non-numeric all print 0, because every
# tarball written before ADR-049 lacks the file and must compare as "oldest".
of_state_tarball_epoch() {
  python3 - "$1" <<'PY' 2>/dev/null || echo 0
import sys, tarfile, os
try:
    with tarfile.open(sys.argv[1]) as t:
        m = next((x for x in t.getmembers()
                  if os.path.basename(x.name) == ".state_epoch" and x.isfile()), None)
        if m is None:
            print(0); raise SystemExit(0)
        raw = t.extractfile(m).read().decode("utf-8", "replace").strip()
    print(int(raw) if raw.isdigit() else 0)
except Exception:
    print(0)
PY
}

# openfathom-meta ADR-049. Exit 0 iff the messages in tarball $1 (MINE) are a superset of
# those in tarball $2 (THEIRS) -- i.e. promoting mine over theirs destroys nothing.
#
# The key is (session_id, role, timestamp, sha1(content)) and NEVER the `id` column. `id`
# is an autoincrement primary key assigned per-database, so two states that diverged
# reuse the same ids for different messages; comparing on it would report bogus overlap.
# Measured 2026-07-20 on four real snapshots from production.
#
# FAIL CLOSED, and the reason is specific rather than generic caution: if THEIRS has no
# state.db, its message set is empty, and "mine is a superset of nothing" is trivially
# true -- which would promote right over a deliberately emptied state. That is exactly
# the curated tarball the reset runbook uploads. The epoch guard already refuses that
# case; this is the second, independent lock on the same door.
of_state_messages_superset() {
  python3 - "$1" "$2" <<'PY'
import sys, tarfile, sqlite3, hashlib, os, tempfile

def keys(path):
    """Message identity set, or None when the tarball carries no state.db."""
    with tarfile.open(path) as t:
        m = next((x for x in t.getmembers()
                  if os.path.basename(x.name) == "state.db" and x.isfile()), None)
        if m is None:
            return None
        # extractfile + explicit write: never t.extract(), which would honour whatever
        # path the archive claims.
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as fh:
            fh.write(t.extractfile(m).read())
            tmp = fh.name
    try:
        con = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
        try:
            return {
                (s, r, ts, hashlib.sha1((c or "").encode()).hexdigest())
                for s, r, c, ts in con.execute(
                    "select session_id, role, content, timestamp from messages")
            }
        finally:
            con.close()
    finally:
        os.unlink(tmp)

try:
    mine, theirs = keys(sys.argv[1]), keys(sys.argv[2])
except Exception as e:
    print(f"comparison failed: {e}", file=sys.stderr)
    raise SystemExit(2)

if theirs is None:
    print("the live snapshot has no state.db -- refusing to call that a subset", file=sys.stderr)
    raise SystemExit(3)
if mine is None:
    print("this instance has no state.db to promote", file=sys.stderr)
    raise SystemExit(4)

missing = theirs - mine
if missing:
    print(f"{len(missing)} message(s) exist only in the live snapshot", file=sys.stderr)
    raise SystemExit(1)
print(f"superset confirmed: {len(mine)} mine vs {len(theirs)} live, {len(mine - theirs)} added")
PY
}

# openfathom-meta ADR-049. Called ONLY after a 412 and ONLY after the conflict has been
# safely parked. Tries to turn "refused, parked for a human" into "written", for the case
# the measurement showed to be the common one: the outgoing instance holding strictly MORE
# than the live object and being refused anyway.
#
# WHY THE ORDER IS THE SAFETY ARGUMENT. Parking happens first, unconditionally. Every way
# this function can die -- SIGKILL mid-download, a broken tarball, a network fault -- ends
# with the state parked exactly as it is today. It can improve on the current behaviour;
# it cannot regress below it. That is what makes doing network work inside Cloud Run's
# ~10s shutdown budget defensible here, when the same work on the happy path would not be.
#
# THREE GUARDS, all of which must pass:
#   1. the live object still EXISTS -- a 404 means someone deleted it on purpose
#   2. our epoch >= its epoch      -- a newer epoch means a deliberate reset, never override
#   3. its messages ⊆ ours         -- promoting must not drop anything
of_state_try_promote() {
  local mine="$1" conflict="$2" tok="$3"
  local live="/tmp/of-state-live.tar.gz" code gen live_epoch

  code="$(curl -sS -o "$live" -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_STATE_OBJECT}?alt=media" || echo 000)"
  if [[ "$code" != "200" ]]; then
    rm -f "$live"
    echo "[of-state] not promoting: live snapshot unreadable (HTTP ${code}). A 404 here means it was deleted deliberately; the conflict stays parked." >&2
    return 0
  fi

  live_epoch="$(of_state_tarball_epoch "$live")"
  if [[ "${of_state_epoch:-0}" -lt "$live_epoch" ]]; then
    rm -f "$live"
    echo "[of-state] not promoting: live epoch ${live_epoch} is newer than ours (${of_state_epoch:-0}) -- a deliberate reset happened. The conflict stays parked." >&2
    return 0
  fi

  if ! of_state_messages_superset "$mine" "$live"; then
    rm -f "$live"
    echo "[of-state] not promoting: this state is NOT a superset of the live one -- genuine divergence. The conflict stays parked for a human." >&2
    return 0
  fi
  rm -f "$live"

  # Re-read the generation we just downloaded, so the promoting write is itself a CAS.
  # Without this a third writer landing in between would be clobbered -- which is the
  # very defect this whole mechanism exists to prevent.
  gen="$(curl -sS --max-time 20 -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_STATE_OBJECT}" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("generation") or 0)
except Exception: print(0)' 2>/dev/null || echo 0)"
  [[ -n "$gen" && "$gen" != "0" ]] || { echo "[of-state] not promoting: could not re-read the live generation. Conflict stays parked." >&2; return 0; }

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
    -H "Authorization: Bearer ${tok}" -H "Content-Type: application/gzip" \
    --data-binary "@${mine}" \
    "https://storage.googleapis.com/upload/storage/v1/b/${HERMES_STATE_BUCKET}/o?uploadType=media&name=${HERMES_STATE_OBJECT}&ifGenerationMatch=${gen}" || echo 000)"
  if [[ "$code" != "200" ]]; then
    echo "[of-state] not promoting: promoting write failed (HTTP ${code}). The conflict stays parked -- nothing lost." >&2
    return 0
  fi
  echo "[of-state] PROMOTED this state to gs://${HERMES_STATE_BUCKET}/${HERMES_STATE_OBJECT} -- it contained everything the live snapshot had, plus more"

  # Only now, and only on a confirmed 200: the parked conflict is byte-identical in
  # content to what is now canonical, so it is redundant by construction.
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X DELETE \
    -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${conflict}" || echo 000)"
  case "$code" in
    200|204) echo "[of-state] removed the now-redundant ${conflict}" ;;
    *)       echo "[of-state] WARN: could not remove the redundant ${conflict} (HTTP ${code}); harmless, it is a duplicate of the canonical object" >&2 ;;
  esac
}

# Runs after `hermes` has exited, so every *.db is closed and WAL-checkpointed and
# a plain tar of it is consistent. `VACUUM INTO` is still used for the .db files:
# it is the one documented way to get a consistent single-file copy even if hermes
# did NOT exit cleanly, and it costs milliseconds at this size.
#
# Excludes are caches and logs -- re-derivable, and `.cache/uv` alone is 209
# objects. `skills/` is excluded because the image re-syncs bundled skills into it
# on every boot anyway.
of_state_snapshot() {
  local home="${HERMES_HOME:-/opt/data}" stage="/tmp/of-state-stage" tarball="/tmp/of-state-snap.tar.gz" tok code
  rm -rf "$stage" "$tarball"; mkdir -p "$stage"
  # Consistent copy of each SQLite DB, live-writer-safe.
  local db
  for db in "$home"/*.db; do
    [[ -e "$db" ]] || continue
    python3 - "$db" "$stage/$(basename "$db")" <<'PY' || echo "[of-state] WARN: VACUUM INTO failed for $db" >&2
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
con = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
try:
    con.execute("VACUUM INTO ?", (dst,))
finally:
    con.close()
PY
  done
  # Everything else that is real MUTABLE state, copied into the same staging dir so
  # the tar below is a plain `-C "$stage" .` -- no generated -C arguments to get wrong.
  #
  # Deliberately NOT snapshotted (declared config or cache -- reconciled from the
  # image/env at boot, so snapshotting them only risks a stale copy shadowing the
  # canonical one, the exact drift SOUL.md had):
  #   - SOUL.md              -> declared at boot from $HERMES_SOUL (of_write_soul)
  #   - hooks/               -> author-time behavior code; Hermes treats it as image
  #                             content (backup.py _QUICK_STATE_FILES omits it), same
  #                             class as skills/, which is already re-synced each boot
  #   - .skills_prompt_snapshot.json -> pure cache keyed on skill mtimes; skills/ is
  #                             re-synced every boot so the manifest never matches and
  #                             it is discarded and rebuilt regardless
  local p
  for p in memories plans pairing cron; do
    [[ -e "$home/$p" ]] && cp -a "$home/$p" "$stage/$p"
  done
  # openfathom-meta ADR-049. Carry the epoch we booted with into the tarball we write.
  # A deliberate wipe bumps this (see the reset runbook); an instance still holding the
  # older epoch is then refused promotion, which is the only reason deleting on purpose
  # can survive at all -- an empty state is a subset of every state, so the superset rule
  # alone would resurrect it.
  printf '%s\n' "${of_state_epoch:-0}" > "$stage/.state_epoch"
  tar czf "$tarball" -C "$stage" . || { echo "[of-state] ERROR: tar failed; SNAPSHOT LOST" >&2; return 0; }
  [[ -s "$tarball" ]] || { echo "[of-state] WARN: nothing to snapshot" >&2; return 0; }
  tok="$(of_metadata_token)" || { echo "[of-state] ERROR: no metadata token; SNAPSHOT LOST" >&2; return 0; }

  # Compare-and-swap, and this is not belt-and-braces -- it fixes a real, MEASURED
  # data-destruction path (execution/of-09.md section 11). Cloud Run brings the new
  # revision up BEFORE draining the old one: on 2026-07-17 revision 00012 restored
  # at 13:29:36 (bucket still empty) while 00011 wrote its snapshot at 13:30:03, 27s
  # later. The incoming revision therefore boots from stale-or-absent state and, on
  # ITS shutdown, would overwrite the outgoing revision's good snapshot with its own
  # emptier one. That is silent loss of the user's real conversation.
  #
  # ifGenerationMatch turns that into a refusal: we write only if the object is
  # still at the generation we restored from (0 = "no live version existed"). GCS
  # answers 412 when it moved, which is exactly the case where writing would
  # destroy. We then park the snapshot in a conflict object instead of dropping it
  # -- neither side is lost, and the log says so.
  #
  # This does NOT fix the ordering (the incoming revision still starts stale); it
  # fixes the destruction. The ordering has no fix from in here: hermes holds the
  # SQLite connection open for the process lifetime, so re-restoring underneath a
  # running gateway is the documented corruption path, and restarting it would cost
  # a ~21s outage plus dropped requests. At min=0 -- the ADR-039 target -- the
  # overlap does not arise at all: the instance dies whole, then a later request
  # cold-starts and restores.
  local url="https://storage.googleapis.com/upload/storage/v1/b/${HERMES_STATE_BUCKET}/o?uploadType=media&name=${HERMES_STATE_OBJECT}&ifGenerationMatch=${of_state_generation:-0}"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
    -H "Authorization: Bearer ${tok}" -H "Content-Type: application/gzip" \
    --data-binary "@${tarball}" "$url" || echo 000)"

  if [[ "$code" == "412" ]]; then
    local conflict="${HERMES_STATE_OBJECT%.tar.gz}.conflict-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
    echo "[of-state] WARN: snapshot NOT written -- gs://${HERMES_STATE_BUCKET}/${HERMES_STATE_OBJECT} changed since this instance restored (generation ${of_state_generation:-0})." >&2
    echo "[of-state] WARN: another revision wrote a newer snapshot; overwriting it would destroy it. Parking this one at ${conflict} instead." >&2
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
      -H "Authorization: Bearer ${tok}" -H "Content-Type: application/gzip" \
      --data-binary "@${tarball}" \
      "https://storage.googleapis.com/upload/storage/v1/b/${HERMES_STATE_BUCKET}/o?uploadType=media&name=${conflict}" || echo 000)"
    if [[ "$code" == "200" ]]; then
      echo "[of-state] conflict snapshot parked at gs://${HERMES_STATE_BUCKET}/${conflict} -- BOTH states survive" >&2
      # openfathom-meta ADR-049. The state is safe on the line above; everything past this
      # point can only improve on it. Measured on 2026-07-20, the common case here is not
      # divergence at all -- it is this instance holding strictly MORE than the live object
      # and being refused anyway, because "the generation moved" is only a proxy for "I
      # would destroy something". of_state_try_promote checks the real question.
      of_state_try_promote "$tarball" "$conflict" "$tok"
    else
      echo "[of-state] ERROR: conflict snapshot upload failed (HTTP ${code}); THIS SESSION IS LOST" >&2
    fi
  elif [[ "$code" == "200" ]]; then
    echo "[of-state] snapshot uploaded to gs://${HERMES_STATE_BUCKET}/${HERMES_STATE_OBJECT} ($(stat -c%s "$tarball") bytes, generation matched ${of_state_generation:-0})"
  else
    echo "[of-state] ERROR: snapshot upload failed (HTTP ${code}); THIS SESSION IS LOST" >&2
  fi
  rm -rf "$stage" "$tarball"
}

# openfathom-meta ADR-048, decision 2. Deposit the skills the AGENT wrote this session
# into an inbox prefix, so a human can review them before any of them ever reaches the
# catalog. Dogma 5 asks WHO VOUCHES, and today nobody does: the agent is nudged to write
# skills (`creation_nudge_interval: 15`), writes them to $HERMES_HOME/skills, and the
# snapshot deliberately skips that directory -- so they evaporate on the next deploy,
# unreviewed and unread. That is the dogma being satisfied BY ACCIDENT.
#
# The rejected fix was adding `skills` to of_state_snapshot's list. One word, and wrong:
# it would restore UNREVIEWED machine-written content into the live catalog on every
# boot, turning an accidental pass into a designed bypass -- worse, because it would then
# LOOK compliant. ADR-048 records the reasoning.
#
# WHY THIS IS AN UPLOAD AND NOT A REDIRECT. Preferred design was to point skill creation
# at a separate directory. Measured 2026-07-20, upstream does not allow it:
# tools/skill_manager_tool.py::_resolve_skill_dir writes to _skills_dir(), which is
# get_hermes_home()/"skills", with no env or config override. `skills.external_dirs`
# extends READS only (agent/skill_utils.py::get_all_skills_dirs). Redirecting the write
# would mean patching upstream, which ADR-002 forbids. So the separation happens at
# shutdown instead, from out here.
#
# THE DISCRIMINATOR. $HERMES_HOME/skills holds 72 skills from the image plus whatever the
# agent wrote, in the same tree. `.bundled_manifest` (upstream tools/skills_sync.py, v2
# format `name:hash` per line) is upstream's own record of which ones came from the image,
# rewritten by every sync -- so it is correct no matter when sync ran, which a boot-time
# listing would not be (sync runs twice: docker/stage2-hook.sh, then again inside
# `hermes gateway run`). Validated against the real artifact in BOTH directions, not just
# the convenient one: `apple-notes` is in it, `arch-brainstorm` is not.
#
# Bundled skills nest one level under a category (skills/apple/apple-notes/), while the
# manifest keys are flat basenames -- so the match is on the SKILL DIRECTORY NAME, not on
# the path. That is safe from collisions because upstream's _create_skill refuses a name
# that already exists in any skills dir.
#
# NOTE this sweeps `service` mode only, and that is what makes the manifest sufficient:
# on the Service our own OpenFathom skills live in $HERMES_HOME/openfathom-skills (read
# via external_dirs), NOT in skills/, so they are never candidates. On the JOB they DO
# land in skills/ via the gcsfuse mount and are absent from the manifest -- they would be
# swept as if the agent had written them. The Job never calls this.
#
# FAIL CLOSED. No manifest means no way to tell a machine-written skill from one of the
# 72 that shipped in the image. Uploading all 72 into a review queue would train the
# reviewer to ignore the queue, which is the failure this whole mechanism exists to
# prevent. So: refuse, and say so.
of_skills_inbox_deposit() {
  local home="${HERMES_HOME:-/opt/data}" skills manifest stage tarball tok code obj n
  skills="$home/skills"
  manifest="$skills/.bundled_manifest"
  [[ -d "$skills" ]] || return 0

  if [[ ! -s "$manifest" ]]; then
    echo "[of-inbox] ERROR: $manifest missing or empty -- cannot tell agent-written skills" \
         "from the image's own. Refusing to deposit rather than flooding the review queue." >&2
    return 0
  fi

  stage="/tmp/of-inbox-stage"; tarball="/tmp/of-inbox.tar.gz"
  rm -rf "$stage" "$tarball"; mkdir -p "$stage"

  local skill_md dir name
  while IFS= read -r skill_md; do
    dir="$(dirname "$skill_md")"
    # A SKILL.md sitting at the ROOT of skills/ would make name="skills" and stage the
    # WHOLE tree -- the 72 bundled ones included. Not a shape upstream produces, but the
    # blast radius is exactly what this function exists to avoid, so it is cheaper to
    # refuse it than to reason about whether it can happen.
    [[ "$dir" == "$skills" ]] && { echo "[of-inbox] WARN: ignoring a SKILL.md at the root of $skills" >&2; continue; }
    name="$(basename "$dir")"
    grep -q "^${name}:" "$manifest" && continue
    cp -a "$dir" "$stage/$name" 2>/dev/null || echo "[of-inbox] WARN: could not stage $dir" >&2
  done < <(find "$skills" -name SKILL.md -type f 2>/dev/null)

  n="$(find "$stage" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  if [[ "$n" -eq 0 ]]; then
    echo "[of-inbox] no agent-written skills this session -- nothing to deposit"
    rm -rf "$stage"; return 0
  fi

  tar czf "$tarball" -C "$stage" . || { echo "[of-inbox] ERROR: tar failed; ${n} skill(s) LOST" >&2; rm -rf "$stage"; return 0; }
  tok="$(of_metadata_token)" || { echo "[of-inbox] ERROR: no metadata token; ${n} skill(s) LOST" >&2; rm -rf "$stage" "$tarball"; return 0; }

  # Unique name per deposit, so no compare-and-swap is needed here (unlike the state
  # snapshot, which has exactly one live object two revisions race over). Two overlapping
  # revisions each deposit their own; neither can clobber the other.
  #
  # The prefix is OUTSIDE the restore path BY CONSTRUCTION, not by convention:
  # of_skills_fetch reads only $HERMES_SKILLS_OBJECT and of_state_restore reads only
  # $HERMES_STATE_OBJECT. Nothing in this script -- or in the image -- ever reads
  # skills-inbox/. It reaches the catalog only through the openfathom-skills repo, which
  # is where the human review happens.
  obj="skills-inbox/${K_REVISION:-unknown}-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
    -H "Authorization: Bearer ${tok}" -H "Content-Type: application/gzip" \
    --data-binary "@${tarball}" \
    "https://storage.googleapis.com/upload/storage/v1/b/${HERMES_STATE_BUCKET}/o?uploadType=media&name=${obj//\//%2F}" || echo 000)"

  if [[ "$code" == "200" ]]; then
    echo "[of-inbox] deposited ${n} agent-written skill(s) at gs://${HERMES_STATE_BUCKET}/${obj} -- AWAITING HUMAN REVIEW (Dogma 5); they are NOT in the catalog"
  else
    echo "[of-inbox] ERROR: deposit failed (HTTP ${code}); ${n} agent-written skill(s) LOST" >&2
  fi
  rm -rf "$stage" "$tarball"
}

# openfathom-meta ADR-053. Turns the skill-usage counter Hermes ALREADY writes
# natively (tools/skill_usage.py, upstream, no patch) into a signal openfathom-infra
# can read: a plain `echo` to this process's own stdout, which Cloud Run ships to
# Cloud Logging automatically. No upload, no credential, no new failure mode beyond
# "the line never printed" -- unlike of_state_snapshot/of_skills_inbox_deposit above,
# there is no network call here at all.
#
# WHY A LOG LINE PER USE, NOT ONE SUMMARY LINE WITH THE COUNT. Verified against the
# real Cloud Logging docs before writing the Terraform side (openfathom-infra), not
# assumed: a counter (non-DISTRIBUTION) log-based metric increments by 1 per matching
# log entry -- "valueExtractor and bucketOptions have no purpose and are omitted" for
# counters. A single `skill=X use_count=5` line would only ever count as 1, not 5. So
# this emits the line once per actual use.
#
# WHY NOT PATCH THE POINT OF CALL. Same wall openfathom-meta ADR-038 already named for
# `llm_tokens`: the only place a skill is actually invoked is inside Hermes core
# (tools/skills_tool.py's skill_view tool, or agent/skill_commands.py's slash-command
# path), and this fork is restricted to 8 files (ADR-002/ADR-035/ADR-050) -- no core
# patch. Reading the sidecar file Hermes already maintains sidesteps that wall
# entirely, the same resolution ADR-038 pointed at without anyone building it.
#
# LOWEST PRIORITY OF THE THREE SHUTDOWN STEPS, DELIBERATELY LAST. Losing a boot's worth
# of usage counts costs a few missed metric points; losing the state snapshot costs the
# user's conversation, and losing an inbox deposit costs an unreviewed skill draft. Same
# ordering argument as of_skills_inbox_deposit above, one step further out.
#
# .usage.json lives under skills/, which of_state_snapshot deliberately never tars (see
# the comment there) -- so every fresh instance starts it empty, and what gets read here
# at shutdown is already that instance's own delta. No cross-instance double-count.
of_skill_usage_report() {
  local home="${HERMES_HOME:-/opt/data}"
  local usage="$home/skills/.usage.json"
  if [[ ! -s "$usage" ]]; then
    echo "[of-skill-usage] no .usage.json this session -- nothing used"
    return 0
  fi
  python3 - "$usage" <<'PY' || echo "[of-skill-usage] WARN: could not parse $usage" >&2
import json, re, sys

path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(0)

# Skill names are directory basenames Hermes itself validates on creation, but an
# autogenerated skill's name still traces back to model output on untrusted input
# (Dogma 5 / ADR-029) -- so this refuses to print anything a name could use to forge
# extra log lines (a newline) or slip past the Terraform-side REGEXP_EXTRACT.
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

for name in sorted(data):
    rec = data[name]
    if not isinstance(rec, dict) or not NAME_RE.match(name):
        continue
    try:
        n = int(rec.get("use_count") or 0)
    except (TypeError, ValueError):
        continue
    for i in range(1, n + 1):
        print(f"[of-skill-usage] skill={name} occurrence={i}/{n}")
PY
}

# ENG-47 (openfathom-meta BACKLOG). Declared-config-wins, reconciled at boot: the
# agent identity is versioned in openfathom-infra as the HERMES_SOUL env var, and
# written over $HERMES_HOME/SOUL.md every boot -- overwriting whatever the snapshot
# restored. SOUL.md is therefore EXCLUDED from the snapshot (of_state_snapshot above),
# so the declared copy is the single source of truth and cannot drift.
#
# This MUST run AFTER of_state_restore (an old snapshot still carries a SOUL.md that
# restore would extract), and before `hermes gateway run` reads it. SOUL.md is the
# ONLY lever for the agent's spoken language: display.language does not accept pt/pt-BR
# (config.py supports en/zh/ja/de/es/fr/tr/uk only) and localizes just static UI
# strings, not agent output. The pt-BR requirement lives here.
of_write_soul() {
  [[ -n "${HERMES_SOUL:-}" ]] || return 0
  local home="${HERMES_HOME:-/opt/data}"
  mkdir -p "$home"
  printf '%s\n' "${HERMES_SOUL}" > "$home/SOUL.md"
  echo "[of-soul] wrote declared SOUL.md (${#HERMES_SOUL} chars) to $home/SOUL.md"
}

case "${HERMES_MODE:-service}" in
  service)
    # Same command docker-compose.yml already runs today (`gateway: command:
    # ["gateway", "run"]`), but with two corrections found only by actually
    # running this image (2026-07-12), not by reading it:
    #
    # 1. This image starts `main-hermes` as an s6-supervised service at boot,
    #    from a container_environment snapshot taken BEFORE this script ever
    #    runs -- so exporting API_SERVER_* here has no effect on it. Confirmed
    #    via `docker exec ... cat /run/s6/container_environment/API_SERVER_*`
    #    (absent). HERMES_GATEWAY_NO_SUPERVISE=1 makes `hermes gateway run`
    #    itself become the foreground gateway process (the one this script
    #    exec's into), which DOES inherit these exports normally.
    # 2. gateway/config.py's API_SERVER_ENABLED/HOST/PORT only get the
    #    platform registered; gateway/platforms/api_server.py then refuses to
    #    start without API_SERVER_KEY >= 16 chars, even bound to localhost
    #    ("a guessable key is remote code execution" -- this endpoint
    #    dispatches agent work). Not optional, confirmed by the adapter
    #    erroring out with only HOST/PORT set. Same shape as HERMES_TASK
    #    below: fail fast and loud instead of silently running unreachable.
    if [[ -z "${API_SERVER_KEY:-}" ]]; then
      echo "ERROR: API_SERVER_KEY must be set when HERMES_MODE=service (>=16 chars, e.g. \`openssl rand -hex 32\` from Secret Manager)" >&2
      exit 1
    fi
    export HERMES_GATEWAY_NO_SUPERVISE=1
    export API_SERVER_ENABLED=true
    export API_SERVER_HOST="0.0.0.0"
    export API_SERVER_PORT="${PORT:-8080}"
    # Translate the env-var contract into config.yaml, which is the only input the
    # gateway path actually honors (see the header). Written here, after cont-init's
    # schema migration has already produced config.yaml, and before `hermes gateway
    # run` reads it. Each call costs one CLI start (~1s) and lands on the cold-start
    # path -- the reason this only writes keys that were explicitly asked for instead
    # of setting defaults unconditionally.
    #
    # `hermes config set` failing must be loud: a silently unset provider is exactly
    # the failure this block exists to prevent, and it would resurface as the same
    # "No inference provider configured" that cost the OF-09 end-to-end test. `set -e`
    # already aborts on a non-zero exit; these run before the exec so a failure kills
    # the container instead of serving a gateway that cannot answer.
    if [[ -n "${HERMES_INFERENCE_PROVIDER:-}" ]]; then
      hermes config set model.provider "${HERMES_INFERENCE_PROVIDER}"
    fi
    if [[ -n "${HERMES_INFERENCE_MODEL:-}" ]]; then
      hermes config set model.default "${HERMES_INFERENCE_MODEL}"
    fi
    if [[ -n "${HERMES_TIMEZONE:-}" ]]; then
      hermes config set timezone "${HERMES_TIMEZONE}"
    fi

    # ENG-46 / ENG-56 (openfathom-meta BACKLOG). The auxiliary client -- context
    # compression, conversation-title generation -- had NO working provider while the
    # gateway ran on Vertex: `vertex` has auth_type=vertex, which the aux router skips,
    # so resolve_provider_client returned (None, None) and every aux turn failed
    # silently. Switching the provider to OpenRouter fixes it: `openrouter` is an
    # api_key provider with a first-class resolution branch (agent/auxiliary_client.py
    # _try_openrouter), so the aux resolves to a real client off OPENROUTER_API_KEY. The
    # aux does NOT share the main agent's resolve_runtime_provider(); it reads
    # auxiliary.<task>.provider/model directly, and the model MUST be pinned to a valid
    # model string FOR THAT PROVIDER -- a bare `google/gemini-2.5-flash` here would
    # silently bill Gemini through OpenRouter instead of running Haiku. These are
    # scalar keys two levels deep -- `hermes config set` writes them fine (unlike the
    # LIST at agent.disabled_toolsets below, which needs the python heredoc).
    #
    # openfathom-meta ENG-83: the model string used to be hardcoded to the OpenRouter
    # routing slug (`anthropic/claude-haiku-4.5`), which is wrong the moment
    # HERMES_INFERENCE_PROVIDER stops being openrouter -- the Anthropic-direct and
    # Vertex providers each expect a bare model id, not an aggregator slug. Reusing
    # $HERMES_INFERENCE_MODEL fixes that for any provider without hardcoding a second
    # place that has to be kept in sync with the primary model: today primary and aux
    # are deliberately the same cheap model, so this is not a behavior change, only the
    # removal of a value that would have gone stale on this exact switch.
    if [[ -n "${HERMES_INFERENCE_PROVIDER:-}" ]]; then
      hermes config set auxiliary.compression.provider      "${HERMES_INFERENCE_PROVIDER}"
      hermes config set auxiliary.compression.model         "${HERMES_INFERENCE_MODEL}"
      hermes config set auxiliary.title_generation.provider "${HERMES_INFERENCE_PROVIDER}"
      hermes config set auxiliary.title_generation.model    "${HERMES_INFERENCE_MODEL}"
    fi

    # openfathom-meta ENG-83. Two real production outages (2026-07-24, HTTP 402 --
    # OpenRouter credit insufficient for the requested max_tokens) with NO fallback
    # configured: agent/conversation_loop.py's is_client_error branch already tries
    # agent._fallback_chain BEFORE aborting on exactly this class of non-retryable
    # error -- it found nothing to try because fallback_providers was never set here.
    # This is not a mechanism built for this switch; it is Hermes' own native fallback
    # (hermes_cli/fallback_config.py), unused until now.
    #
    # vertex/google/gemini-3.6-flash, not gemini-2.5-flash: confirmed live against the
    # real Vertex model catalog (publishers/google/models/gemini-3.6-flash,
    # launchStage=GA, us-central1, openfathom-prod project) before writing this, not
    # assumed from the 2.5-era config elsewhere in this file. The `google/` publisher
    # prefix is mandatory on the Vertex OpenAI-compatible path (same lesson
    # cloud_run_job already paid for with a real HTTP 400 "Malformed publisher").
    # enable_vertex_access already grants the ADC this needs -- no new IAM.
    #
    # A LIST value (even of one entry) -- `hermes config set` cannot write it; needs
    # the python heredoc, same reason agent.disabled_toolsets does.
    python3 - <<'PYEOF'
from hermes_cli.config import get_config_path, fast_safe_load, ensure_hermes_home, _set_nested
from utils import atomic_yaml_write
p = get_config_path()
cfg = (fast_safe_load(open(p)) or {}) if p.exists() else {}
_set_nested(cfg, "fallback_providers", [{"provider": "vertex", "model": "google/gemini-3.6-flash"}])
ensure_hermes_home()
atomic_yaml_write(p, cfg, sort_keys=False)
print(f"✓ Set fallback_providers = [vertex/google/gemini-3.6-flash] in {p}")
PYEOF

    # ENG-49. Unconditional, not env-gated, because there is no deployment of this
    # image where leaking the model's private reasoning to the user is wanted.
    #
    # The chain, measured end to end against the real Vertex endpoint (2026-07-17),
    # not inferred: the migrated config.yaml ships `agent.reasoning_effort: "medium"`
    # -> plugins/model-providers/vertex/VertexProfile.build_extra_body() feeds it to
    # agent/transports/chat_completions.py's _build_gemini_thinking_config(), which
    # returns {"includeThoughts": True} for any effort other than "none" -> Gemini
    # then returns its thought summary, and the OpenAI-compat surface has nowhere to
    # put it but `content`. The gateway stores that content verbatim in state.db, so
    # the reasoning is not merely displayed once -- it becomes conversation history
    # and is replayed as context on every subsequent turn.
    #
    # Proven with a controlled experiment on the same request: with
    # include_thoughts=true the content came back '<think>\nAlright, so I'm
    # thinking, "The user wants..."'; with false, content was None. One field, whole
    # defect.
    #
    # Why config and not code: the leak lives in agent/ and plugins/, which ADR-002
    # puts outside this fork's 7 files. This is the only lever we have -- and it
    # happens to be the intended one, not a workaround: `none` is a documented value
    # of this key.
    #
    # Do not trust the key's own comment in config.yaml ("Reasoning effort level
    # (OpenRouter and Nous Portal)"). It is wrong by omission -- VertexProfile reads
    # the same key, which is exactly why this cause was dismissed on the first pass.
    #
    # Gemini still thinks internally (the reasoning_tokens are still billed); what
    # this turns off is returning the thoughts. Suppressing the thinking itself
    # would be thinkingBudget, a different knob, and would trade answer quality for
    # tokens -- not this item's call to make.
    hermes config set agent.reasoning_effort none

    # openfathom-meta ADR-043 / ENG-51: scope host-execution tools OUT of the
    # always-on gateway. The inventory (references/gateway-tool-surface.md) measured
    # that `terminal`, `process` and `execute_code` run UNSANDBOXED as the host user
    # here -- a live RCE vector now that web_search brings untrusted web content into
    # the agent. Per ADR-043 the gateway only ORCHESTRATES; code execution moves to the
    # dev machine (Claude Code). Disabling the `terminal` toolset drops terminal+process;
    # `code_execution` drops execute_code (toolset membership measured in the fork).
    #
    # Two levers were rejected, both measured, not assumed:
    #   - `hermes config set agent.disabled_toolsets ...` coerces only bool/int/float
    #     (config.py set_config_value), so it stores a STRING, but the consumer
    #     (tools_config.py) iterates a LIST -- it would silently misbehave.
    #   - `hermes tools disable` writes per-platform platform_toolsets and defaults to
    #     the `cli` platform, missing the gateway entirely.
    # So set the GLOBAL agent.disabled_toolsets directly, reusing hermes's own config
    # machinery. Verified end to end INSIDE this image (2026-07-17): write lands a real
    # YAML list, preserves agent.reasoning_effort, and _get_platform_tools resolves both
    # toolsets as absent for the telegram platform.
    #
    # ENG-57: also drop the GENERATION toolsets `image_gen`, `video_gen`, `tts`. Two
    # reasons: (1) cost -- their tool schemas ride in the per-turn prompt for a feature
    # the Tech Lead does not want; dropping them shrinks input tokens. (2) honesty -- with
    # them in the toolset the model advertised "gera imagens/áudio", a capability the
    # headless gateway lacks; removing them kills the over-claim at the source, cleaner
    # than a SOUL instruction. This does NOT touch voice INPUT: transcription is the
    # gateway's stt_enabled auto-enrich pipeline (gateway/run.py), not a toolset, so it is
    # unaffected -- only audio/image/video GENERATION goes away.
    python3 - <<'PYEOF'
from hermes_cli.config import get_config_path, fast_safe_load, ensure_hermes_home, _set_nested
from utils import atomic_yaml_write
p = get_config_path()
cfg = (fast_safe_load(open(p)) or {}) if p.exists() else {}
_set_nested(cfg, "agent.disabled_toolsets", ["terminal", "code_execution", "image_gen", "video_gen", "tts"])
ensure_hermes_home()
atomic_yaml_write(p, cfg, sort_keys=False)
print(f"✓ Set agent.disabled_toolsets = [terminal, code_execution, image_gen, video_gen, tts] in {p}")
PYEOF

    # openfathom-meta ENG-52 / OF-15, ADR-043 Desenho 2. The GitHub MCP client that lets
    # the (thin, exec-less) gateway CREATE the issue a local daemon later picks up and
    # runs `claude -p` against -- the gateway never opens the PR itself, so the token is
    # scoped to Issues: Read and write only (openfathom-meta execution/of-15.md has the
    # full trail).
    #
    # Verified locally before writing this (not assumed): `hermes mcp add github --url
    # https://api.githubcopilot.com/mcp/ --auth header` writes exactly this shape --
    # `headers.Authorization: "Bearer ${VAR}"` as a LITERAL placeholder string, never the
    # raw secret -- and tools/mcp_tool.py's _interpolate_env_vars() resolves ${VAR} from
    # os.environ at CONNECT time (its own docstring: "resolved from os.environ (which
    # includes ~/.hermes/.env loaded at startup)"). A plain container env var satisfies
    # that lookup exactly like ~/.hermes/.env does locally -- confirmed against the real
    # server (47 tools discovered, a real issue created and closed) before this line was
    # written.
    #
    # Gated on MCP_GITHUB_API_KEY like every other optional secret-backed block here:
    # empty (default) skips this entirely and the gateway has no GitHub MCP server, same
    # as before this line existed. `mcp_servers` is its own top-level key -- untouched by
    # (and not touching) agent.disabled_toolsets above, which stays the actual RCE
    # mitigation. This block does not undo ENG-51: the gateway still never runs `terminal`
    # or `code_execution`; it only gains one more MCP tool call surface, same class as the
    # `web_search`/`browser_*` tools it already has.
    # TEMPORARILY DISABLED (2026-07-20) -- `enabled: False`, not removed. GitHub's hosted
    # MCP ships `issue_write` with `issue_fields[].value` typed as
    # `["string", "number", "boolean"]` (a multi-type array). Anthropic's tool-schema
    # validator rejects an array-valued `type` ("JSON schema is invalid ... draft 2020-12"),
    # so once the GitHub MCP tools are offered, EVERY Claude-backed turn 400s with
    # `tools.57.custom.input_schema: JSON schema is invalid` -- measured in production, the
    # gateway was down for tool-use. The bug is in hermes core (`_normalize_mcp_input_schema`
    # applies only the nullable-union sanitizer, not the multi-type-array one), which
    # ADR-002 forbids us to patch in this fork; the fix went upstream as
    # NousResearch/hermes-agent#68241 and returns via the weekly sync.
    #
    # Config, secret and IAM stay fully wired -- flipping `enabled` back to True re-enables
    # everything with no other change -- so this is a pause, not a teardown of the OF-15
    # work. Re-enable once the upstream fix lands in our image.
    if [[ -n "${MCP_GITHUB_API_KEY:-}" ]]; then
      python3 - <<'PYEOF'
from hermes_cli.config import get_config_path, fast_safe_load, ensure_hermes_home, _set_nested
from utils import atomic_yaml_write
p = get_config_path()
cfg = (fast_safe_load(open(p)) or {}) if p.exists() else {}
_set_nested(cfg, "mcp_servers.github", {
    "url": "https://api.githubcopilot.com/mcp/",
    "headers": {"Authorization": "Bearer ${MCP_GITHUB_API_KEY}"},
    "enabled": False,  # bridge: see comment above (upstream#68241). Flip to True on sync.
})
ensure_hermes_home()
atomic_yaml_write(p, cfg, sort_keys=False)
print(f"✓ Set mcp_servers.github (url present, DISABLED pending upstream#68241) in {p}")
PYEOF
    fi

    # ENG-57: pin speech-to-text to Groq (free tier, uses the already-installed openai
    # SDK) so incoming Telegram voice notes are transcribed reliably. STT is ON by default
    # (gateway stt_enabled=True), but the default `local` faster-whisper is NOT in this
    # image -- it lazy-installs a ~150 MB model onto the ephemeral fs on every cold start.
    # Groq needs no local package. Gated on GROQ_API_KEY: without the secret it falls back
    # to the (lazy) local default instead of a broken groq provider. The OpenRouter key
    # cannot drive STT -- OpenRouter is chat-only, no transcription endpoint. This is voice
    # INPUT only; audio OUTPUT (tts) is disabled with the generation toolsets above.
    if [[ -n "${GROQ_API_KEY:-}" ]]; then
      hermes config set stt.provider groq
    fi

    # openfathom-meta OF-08: make the OpenFathom skills (openfathom-skills repo) reachable
    # by the SERVICE. They were not, and nobody noticed for five days.
    #
    # The chain, measured 2026-07-18, not assumed: skills reach $HERMES_HOME/skills only
    # via upstream's tools/skills_sync.py (docker/stage2-hook.sh), which syncs from the
    # image's own skills/ directory. ADR-002 keeps our repo at 7 files, so our skills are
    # NOT in the image. The Job sees them only because it gcsfuse-mounts a bucket at its
    # $HERMES_HOME; the Service has no such mount, and of_state_snapshot deliberately
    # tars only `memories plans pairing cron` -- so anything dropped into
    # $HERMES_HOME/skills on a Service instance dies with the revision.
    #
    # skills.external_dirs is upstream's supported answer (agent/skill_utils.py
    # get_external_skills_dirs; external dirs are READ-ONLY, and skill creation still
    # writes to the local dir). We populate one from a tarball in the bucket the gateway
    # ALREADY reads -- no new bucket, no new IAM binding, no new credential, and no copy
    # of the private skills repo inside this public fork.
    #
    # Extract INSIDE $HERMES_HOME, not /opt: this script runs after s6-setuidgid has
    # dropped to the `hermes` user, so /opt is not ours to write. $HERMES_HOME is (state
    # restore already extracts there) and it is not swept by the snapshot.
    #
    # FAIL LOUD, BOOT ANYWAY. get_external_skills_dirs() silently DROPS a path that does
    # not exist -- fail-open: a typo yields a bot with no skills, no error, no signal.
    # So the config key is written only after the directory is confirmed non-empty, and a
    # failed fetch screams. Boot still proceeds (Dogma 2: a degraded gateway beats a
    # gateway that is down) -- unlike of_state_restore, though, absence here is never the
    # normal first-boot case: if HERMES_SKILLS_OBJECT is set, missing skills are a defect.
    if [[ -n "${HERMES_SKILLS_OBJECT:-}" && -n "${HERMES_STATE_BUCKET:-}" ]]; then
      of_skills_dir="${HERMES_HOME:-/opt/data}/openfathom-skills"
      if of_skills_fetch "$of_skills_dir"; then
        python3 - "$of_skills_dir" <<'PYEOF'
import sys
from hermes_cli.config import get_config_path, fast_safe_load, ensure_hermes_home, _set_nested
from utils import atomic_yaml_write
p = get_config_path()
cfg = (fast_safe_load(open(p)) or {}) if p.exists() else {}
_set_nested(cfg, "skills.external_dirs", [sys.argv[1]])
ensure_hermes_home()
atomic_yaml_write(p, cfg, sort_keys=False)
print(f"✓ Set skills.external_dirs = [{sys.argv[1]}] in {p}")
PYEOF
      else
        echo "[of-skills] ERROR: HERMES_SKILLS_OBJECT is set but no skills were loaded --" \
             "the gateway is starting WITHOUT the OpenFathom skills" >&2
      fi
    fi

    # ADR-052 (+ its follow-up). The Sonda's tools ship as user plugins delivered here, the
    # same out-of-band contract as the skills tarball (the CI does not write the object). Two
    # config writes, both deliberate: plugins.enabled opts EVERY delivered plugin in --
    # enumerating the delivered dir rather than a hardcoded name means adding a plugin needs
    # only a re-published tarball, no fork change, and the tarball is Tech-Lead-published so
    # its contents are vouched-for. And approvals.mode is pinned to `manual` so an
    # approval-gated tool's request_tool_approval actually prompts -- the gate bypasses under
    # `off`, and trusting the default to stay `manual` is the kind of silent assumption this
    # repo pays for. Neither reopens exec on the gateway (ADR-043 holds): a delivered tool
    # files an issue or reads a clock, it is not a shell.
    if [[ -n "${HERMES_PLUGINS_OBJECT:-}" && -n "${HERMES_STATE_BUCKET:-}" ]]; then
      of_plugins_dir="${HERMES_HOME:-/opt/data}/plugins"
      if of_plugins_fetch "$of_plugins_dir"; then
        python3 - "$of_plugins_dir" <<'PYEOF'
import os
import sys
from hermes_cli.config import get_config_path, fast_safe_load, ensure_hermes_home, _set_nested
from utils import atomic_yaml_write
plugins_dir = sys.argv[1]
p = get_config_path()
cfg = (fast_safe_load(open(p)) or {}) if p.exists() else {}
# Every delivered plugin is a subdir carrying a plugin.yaml. Enable each -- no hardcoded list.
delivered = sorted(
    name
    for name in os.listdir(plugins_dir)
    if os.path.isfile(os.path.join(plugins_dir, name, "plugin.yaml"))
)
enabled = (cfg.get("plugins") or {}).get("enabled") or []
for name in delivered:
    if name not in enabled:
        enabled = [*enabled, name]
_set_nested(cfg, "plugins.enabled", enabled)
_set_nested(cfg, "approvals.mode", "manual")
ensure_hermes_home()
atomic_yaml_write(p, cfg, sort_keys=False)
print(f"✓ Enabled plugin(s) {delivered} and set approvals.mode = manual in {p}")
PYEOF
      else
        echo "[of-plugins] ERROR: HERMES_PLUGINS_OBJECT is set but no plugin was loaded --" \
             "the gateway is starting WITHOUT the delivered plugins" >&2
      fi
    fi

    # ENG-45. Without a bucket configured this whole block is skipped and the old
    # `exec hermes gateway run` semantics are kept exactly -- that is the contract
    # the OF-05/OF-09 placeholder stages relied on, and it stays valid.
    if [[ -z "${HERMES_STATE_BUCKET:-}" ]]; then
      of_write_soul
      exec hermes gateway run
    fi

    HERMES_STATE_OBJECT="${HERMES_STATE_OBJECT:-gateway-state.tar.gz}"
    of_state_restore
    of_write_soul

    # We can no longer `exec`: something has to outlive `hermes` to take the
    # snapshot after it exits. So `hermes` runs in the background and this shell
    # stays as the container's CMD, waiting on it.
    #
    # This needs S6_CMD_RECEIVE_SIGNALS=1 in the Cloud Run env (openfathom-infra
    # cloud_run_service) -- and the reason is NOT the one first written here, which
    # a mutant against this very image disproved (2026-07-17).
    #
    # The claim was "without it the SIGTERM never reaches this shell and the
    # snapshot never runs". FALSE: running the real image with `docker stop` (which
    # sends SIGTERM to PID 1 exactly like Cloud Run), the snapshot ran and uploaded
    # WITHOUT the var. s6's shutdown nukes every remaining process with SIGTERM at
    # the end of its sequence, and this trap fires from that.
    #
    # What is true, and is why the var stays -- measured by re-running the same
    # mutant with a 5s upload instead of an instant stub: WITHOUT the var the
    # snapshot is SIGKILLed mid-upload and lost (s6's own S6_KILL_GRACETIME, ~3s,
    # starts the moment the nuke fires). WITH it, s6's rc.init runs this CMD as
    # `$arg0 "$@" &`, records /run/s6/cmdpid, and skel/CMDSIG forwards SIGTERM here
    # FIRST -- before the halt sequence -- so the snapshot owns Cloud Run's full 10s
    # ("During this period, the instance is allocated CPU and billed" -- container
    # runtime contract; true even under request-based billing).
    #
    # So: the var does not make the signal arrive. It buys the ~7 extra seconds
    # that make the difference between a snapshot and a truncated one. An instant
    # stub cannot see that; only a realistic upload can.
    hermes gateway run &
    of_gateway_pid=$!

    of_on_term() {
      trap - TERM INT
      kill -TERM "${of_gateway_pid}" 2>/dev/null || true
      wait "${of_gateway_pid}" 2>/dev/null || true
      of_state_snapshot
      # AFTER the snapshot, deliberately, and the ordering is the whole safety argument.
      # Cloud Run allocates ~10s of shutdown and the snapshot is sized to own it (see the
      # S6_CMD_RECEIVE_SIGNALS reasoning below). If the budget runs out, SIGKILL lands on
      # THIS call, not on the conversation state -- a lost skill deposit costs one
      # session's unreviewed drafts, a lost snapshot costs the user's real conversation.
      of_skills_inbox_deposit
      # LAST of the three, deliberately: no network call, so if the budget is already
      # gone by here the only casualty is a boot's worth of usage-count log lines.
      of_skill_usage_report
      exit 0
    }
    trap of_on_term TERM INT

    # Two waits: the first is interrupted by the trap (bash runs the handler and
    # `wait` returns >128); the second reaps `hermes` on the normal-exit path, where
    # no signal ever arrives and the gateway simply died on its own.
    wait "${of_gateway_pid}" || true
    of_state_snapshot
    of_skills_inbox_deposit
    of_skill_usage_report
    ;;
  job)
    if [[ -z "${HERMES_TASK:-}" ]]; then
      echo "ERROR: HERMES_TASK must be set when HERMES_MODE=job" >&2
      exit 1
    fi
    # `hermes -z`/`--oneshot` (hermes_cli/main.py, hermes_cli/oneshot.py):
    # sends HERMES_TASK as a single prompt, prints the final answer to stdout,
    # exits -- no chat loop, no TUI. HERMES_YOLO_MODE=1 auto-bypasses the
    # dangerous-command approval prompt that has nobody to answer it in a job.
    #
    # NOT YET CONFIRMED: whether the printed answer is valid JSON on its own,
    # or needs parsing/wrapping before OF-04 treats it as job-output.json.
    # oneshot.py's docstring only promises "the final text block" -- OF-04
    # must verify the shape against a real `gcloud run jobs execute` before
    # relying on it.
    export HERMES_YOLO_MODE=1
    # Default under $HERMES_HOME (stage2-hook.sh already created/chowned it,
    # /opt/data by default) -- NOT a hardcoded /data/hermes, which doesn't
    # exist unless something happens to mount a volume there. A real Cloud
    # Run Job (OF-04) sets HERMES_HOME to wherever its GCS FUSE volume is
    # mounted; this then follows it with no extra flag needed. Confirmed by
    # running this container without any volume mount and hitting
    # `mkdir: cannot create directory '/data': Permission denied` against
    # the old hardcoded default (2026-07-12) -- fixed here, not asserted fixed.
    out="${HERMES_JOB_OUTPUT:-${HERMES_HOME:-/opt/data}/job-output.txt}"
    mkdir -p "$(dirname "$out")"
    hermes_z_args=()
    [[ -n "${HERMES_INFERENCE_PROVIDER:-}" ]] && hermes_z_args+=(--provider "${HERMES_INFERENCE_PROVIDER}")
    [[ -n "${HERMES_INFERENCE_MODEL:-}" ]] && hermes_z_args+=(--model "${HERMES_INFERENCE_MODEL}")
    hermes -z "${HERMES_TASK}" "${hermes_z_args[@]}" | tee "$out"
    ;;
  *)
    echo "ERROR: HERMES_MODE must be 'service' or 'job' (got '${HERMES_MODE:-}')" >&2
    exit 1
    ;;
esac
