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
#                   the only lever for the agent's OWN spoken language -- the model's
#                   conversational output. NOT the same knob as display.language, which
#                   this script also sets to `pt` unconditionally: that one translates
#                   the curated static UI strings agent/i18n.py owns, and nothing the
#                   model generates. (An earlier version of this line claimed
#                   display.language "does not accept pt-BR". That went stale after an
#                   upstream sync widened SUPPORTED_LANGUAGES -- see the correction dated
#                   2026-07-24 above of_write_soul, and the boot log, which shows `pt`
#                   accepted in production.) Empty (default) keeps the image's SOUL.md.
#   PORT            injected by Cloud Run; only consulted in service mode
#   HERMES_STATE_BUCKET  optional, service mode -- GCS bucket holding the state
#                   snapshot (ENG-45). Empty (default) disables persistence entirely
#                   and keeps the pre-ENG-45 behavior: state lives on the container's
#                   writable layer and dies with the instance.
#   HERMES_STATE_OBJECT  optional -- object name inside that bucket. Default
#                   gateway-state.tar.gz. Must not contain `/` (it goes into a URL
#                   path segment unescaped).
#   HERMES_MEMORIES_OBJECT  optional, service mode -- openfathom-meta ENG-103. Object
#                   name for memories/ (MEMORY.md, USER.md), inside the SAME bucket as
#                   HERMES_STATE_OBJECT but its own independent compare-and-swap. Default
#                   memories.tar.gz. Split out of the combined state tarball so a
#                   memory-only write conflict no longer competes with, or waits on,
#                   messages' much higher write-conflict rate.
set -euo pipefail

# openfathom-meta ENG-103. Retry ceiling for both CAS merge loops (of_state_snapshot_upload
# and of_memories_write_with_merge_retry). A hardcoded constant, DELIBERATELY not an env
# var: this number is a design decision about how much shutdown-budget network work is
# acceptable before falling back to parking, not a per-deploy tuning knob -- an env var
# here would invite "just bump the number" as a substitute for understanding why 3
# attempts stopped being enough.
readonly OF_STATE_MERGE_MAX_ATTEMPTS=3

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
# Under the `set -euo pipefail` this file opens with -- named, not cited by line number,
# because the number this comment used to carry went stale as the script grew above it --
# that is a landmine, and it detonates on the ONLY
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

# openfathom-meta ADR-049. Exit 0 iff the messages AND the memory entries in tarball $1
# (MINE) are a superset of those in tarball $2 (THEIRS) -- i.e. promoting mine over theirs
# destroys nothing.
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
#
# MEMORY, ADDED -- openfathom-meta ENG-66. Before this, the function's name lied by
# omission: it decided every real promotion (3 confirmed in production, 2026-07-24/26/27)
# on messages alone, while memories/ (MEMORY.md, USER.md) rode along in the same tarball
# with NOTHING checked. A promotion could be a strict superset of messages and a strict
# SUBSET of memories, silently -- exactly the gap a product whose pitch is "learns from
# use" cannot afford. Compared at ENTRY granularity (tools/memory_tool.py's own
# ENTRY_DELIMITER = "\n§\n" split), not whole-file bytes: a memory file grows by
# appending entries, so two files that both contain entry X but differ elsewhere (order,
# an entry only one side has) must not register as "X changed" -- the same reasoning that
# already keeps messages compared row-by-row instead of as one table hash. Absence of a
# memories/ directory is NOT fail-closed the way a missing state.db is: an instance that
# never wrote a memory is ordinary, not a signal of a deliberate reset (that guard is the
# epoch check, upstream of this function).
of_state_messages_superset() {
  python3 - "$1" "$2" <<'PY'
import sys, tarfile, sqlite3, hashlib, os, tempfile

MEMORY_ENTRY_DELIMITER = "\n§\n"  # tools/memory_tool.py::ENTRY_DELIMITER

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

def memory_keys(path):
    """(relative_path, sha1(entry)) for every memory entry under memories/ in the
    tarball. Empty set if the tarball has no memories/ at all -- that is a normal
    state, not the fail-closed signal state.db's absence is."""
    result = set()
    with tarfile.open(path) as t:
        for m in t.getmembers():
            if not m.isfile():
                continue
            parts = [p for p in m.name.split("/") if p not in (".", "")]
            if len(parts) < 2 or parts[0] != "memories":
                continue
            rel = "/".join(parts[1:])
            raw = t.extractfile(m).read().decode("utf-8", errors="replace")
            for entry in raw.split(MEMORY_ENTRY_DELIMITER):
                entry = entry.strip()
                if entry:
                    result.add((rel, hashlib.sha1(entry.encode()).hexdigest()))
    return result

try:
    mine, theirs = keys(sys.argv[1]), keys(sys.argv[2])
    mine_mem, theirs_mem = memory_keys(sys.argv[1]), memory_keys(sys.argv[2])
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
missing_mem = theirs_mem - mine_mem
if missing or missing_mem:
    if missing:
        print(f"{len(missing)} message(s) exist only in the live snapshot", file=sys.stderr)
    if missing_mem:
        print(f"{len(missing_mem)} memory entry/entries exist only in the live snapshot", file=sys.stderr)
    raise SystemExit(1)
print(f"superset confirmed: {len(mine)} mine vs {len(theirs)} live messages, "
      f"{len(mine - theirs)} added; {len(mine_mem)} mine vs {len(theirs_mem)} live "
      f"memory entries, {len(mine_mem - theirs_mem)} added")
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

# openfathom-meta ENG-103. Called on a 412 BEFORE giving up: copies into $1 (a live
# state.db path, writable) every message that exists only in $2 (a downloaded live
# tarball), so a retried conditional upload has a chance to succeed instead of parking
# on the first genuine divergence. Read-only comparison is of_state_messages_superset
# above; this one writes.
#
# hermes_state.py declares `messages.session_id TEXT NOT NULL REFERENCES sessions(id)`
# and opens its connection with `PRAGMA foreign_keys=ON` (hermes_state.py:1995) -- a
# message copied without its session row violates the FK on the next real boot, even if
# this staging copy's own connection does not happen to enforce it. So the session row
# is copied first, `INSERT OR IGNORE` (never overwriting a session the destination
# already has).
#
# `id` is NEVER copied -- same reason of_state_messages_superset never compares on it:
# autoincrement, reused across diverging databases. Letting the destination assign a
# fresh id also means messages_fts/messages_fts_trigram's own `AFTER INSERT` triggers
# (keyed on `new.id`) fire correctly with no special handling.
#
# Column set is the INTERSECTION of both sides' schemas (a deploy can straddle two
# schema versions), never a hardcoded list -- the schema carries ~20 columns beyond the
# 4-column dedup key. If the 4 key columns are not all in that intersection, the schemas
# are too divergent to merge safely: fail closed (non-zero exit), the caller parks
# exactly as before this function existed.
of_state_merge_messages() {
  python3 - "$1" "$2" <<'PY'
import sys, tarfile, sqlite3, hashlib, os, tempfile

dest_path, live_tarball = sys.argv[1], sys.argv[2]

def extract_live_db(tarball_path):
    with tarfile.open(tarball_path) as t:
        m = next((x for x in t.getmembers()
                  if os.path.basename(x.name) == "state.db" and x.isfile()), None)
        if m is None:
            return None
        fd, tmp = tempfile.mkstemp(suffix=".db")
        with os.fdopen(fd, "wb") as fh:
            fh.write(t.extractfile(m).read())
        return tmp

def cols(con, table):
    return [r[1] for r in con.execute(f"PRAGMA table_info({table})")]

live_db = extract_live_db(live_tarball)
if live_db is None:
    print("live tarball has no state.db -- nothing to merge", file=sys.stderr)
    raise SystemExit(3)

try:
    dest = sqlite3.connect(dest_path)
    dest.execute(f"ATTACH DATABASE ? AS live_attach", (live_db,))
    dest.execute("PRAGMA foreign_keys=ON")

    dest_msg_cols = cols(dest, "messages")
    live_msg_cols = set(r[1] for r in dest.execute("PRAGMA live_attach.table_info(messages)"))
    common_msg = [c for c in dest_msg_cols if c in live_msg_cols and c != "id"]
    REQUIRED = {"session_id", "role", "content", "timestamp"}
    if not REQUIRED.issubset(set(common_msg)):
        print(f"schema too divergent to merge safely (missing {REQUIRED - set(common_msg)})",
              file=sys.stderr)
        raise SystemExit(4)

    dest_sess_cols = cols(dest, "sessions")
    live_sess_cols = set(r[1] for r in dest.execute("PRAGMA live_attach.table_info(sessions)"))
    common_sess = [c for c in dest_sess_cols if c in live_sess_cols]

    dest_keys = {
        (s, r, ts, hashlib.sha1((c or "").encode()).hexdigest())
        for s, r, c, ts in dest.execute(
            "select session_id, role, content, timestamp from messages")
    }

    col_list = ", ".join(common_msg)
    sess_col_list = ", ".join(common_sess)
    merged_msgs = merged_sess = 0

    for row in dest.execute(
            f"select id, {col_list} from live_attach.messages").fetchall():
        live_id = row[0]
        rec = dict(zip(common_msg, row[1:]))
        key = (rec["session_id"], rec["role"], rec["timestamp"],
               hashlib.sha1((rec.get("content") or "").encode()).hexdigest())
        if key in dest_keys:
            continue
        before = dest.execute("select total_changes()").fetchone()[0]
        dest.execute(
            f"insert or ignore into sessions ({sess_col_list}) "
            f"select {sess_col_list} from live_attach.sessions where id = ?",
            (rec["session_id"],))
        merged_sess += dest.execute("select total_changes()").fetchone()[0] - before
        dest.execute(
            f"insert into messages ({col_list}) "
            f"select {col_list} from live_attach.messages where id = ?", (live_id,))
        merged_msgs += 1
        dest_keys.add(key)

    dest.commit()
    print(f"[of-state-merge] merged {merged_msgs} message(s), {merged_sess} session(s) "
          f"from the live snapshot")
finally:
    os.unlink(live_db)
PY
}

# Runs after `hermes` has exited, so every *.db is closed and WAL-checkpointed and
# a plain tar of it is consistent. `VACUUM INTO` is still used for the .db files:
# it is the one documented way to get a consistent single-file copy even if hermes
# did NOT exit cleanly, and it costs milliseconds at this size.
#
# Excludes are caches and logs -- re-derivable, and `.cache/uv` alone is 209
# objects. `skills/` is excluded because the image re-syncs bundled skills into it
# on every boot anyway.
# openfathom-meta ENG-103. Uploads $2 (a tarball built from staging dir $1) to
# HERMES_STATE_OBJECT with a compare-and-swap (ifGenerationMatch=of_state_generation).
# On a 412 -- the object moved since this instance restored -- instead of parking
# immediately (the old behaviour, ADR-049), it downloads the live object, merges its
# messages into $1/state.db (of_state_merge_messages), re-tars, and retries the
# conditional write against the freshly-read generation, up to
# OF_STATE_MERGE_MAX_ATTEMPTS times. Only once that is exhausted (or a step along the
# way itself fails: live epoch newer, download fails, merge fails) does it fall back to
# the original park + of_state_try_promote path -- UNCHANGED, still the final safety
# net for genuine, unmergeable contention.
of_state_snapshot_upload() {
  local stage="$1" tarball="$2" tok="$3"
  local max_attempts="$OF_STATE_MERGE_MAX_ATTEMPTS"
  local gen="${of_state_generation:-0}" attempt=0 code

  while :; do
    attempt=$((attempt + 1))
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
      -H "Authorization: Bearer ${tok}" -H "Content-Type: application/gzip" \
      --data-binary "@${tarball}" \
      "https://storage.googleapis.com/upload/storage/v1/b/${HERMES_STATE_BUCKET}/o?uploadType=media&name=${HERMES_STATE_OBJECT}&ifGenerationMatch=${gen}" \
      || echo 000)"

    if [[ "$code" == "200" ]]; then
      echo "[of-state] snapshot uploaded to gs://${HERMES_STATE_BUCKET}/${HERMES_STATE_OBJECT} (attempt ${attempt}, generation matched ${gen})"
      return 0
    fi
    if [[ "$code" != "412" ]]; then
      echo "[of-state] ERROR: snapshot upload failed (HTTP ${code}); THIS SESSION IS LOST" >&2
      return 0
    fi
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "[of-state] WARN: still conflicting after ${attempt} attempt(s) -- parking" >&2
      break
    fi

    echo "[of-state] WARN: gs://${HERMES_STATE_BUCKET}/${HERMES_STATE_OBJECT} changed since this instance restored (attempt ${attempt}/${max_attempts}, generation ${gen}) -- merging instead of parking" >&2
    local live="/tmp/of-state-live-merge.tar.gz" live_code
    live_code="$(curl -sS -o "$live" -w '%{http_code}' --max-time 20 \
      -H "Authorization: Bearer ${tok}" \
      "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_STATE_OBJECT}?alt=media" || echo 000)"
    if [[ "$live_code" != "200" ]]; then
      echo "[of-state] WARN: could not download live snapshot to merge (HTTP ${live_code}) -- parking" >&2
      rm -f "$live"; break
    fi

    local live_epoch; live_epoch="$(of_state_tarball_epoch "$live")"
    if [[ "${of_state_epoch:-0}" -lt "$live_epoch" ]]; then
      echo "[of-state] WARN: live epoch ${live_epoch} is newer than ours (${of_state_epoch:-0}) -- a deliberate reset happened, NOT merging. Parking." >&2
      rm -f "$live"; break
    fi

    if ! of_state_merge_messages "$stage/state.db" "$live"; then
      echo "[of-state] WARN: merge failed -- parking" >&2
      rm -f "$live"; break
    fi
    rm -f "$live"

    tar czf "$tarball" -C "$stage" . || { echo "[of-state] ERROR: re-tar after merge failed; SESSION LOST" >&2; return 0; }

    gen="$(curl -sS --max-time 20 -H "Authorization: Bearer ${tok}" \
      "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_STATE_OBJECT}" 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("generation") or 0)
except Exception: print(0)' 2>/dev/null || echo 0)"
    if [[ -z "$gen" || "$gen" == "0" ]]; then
      echo "[of-state] WARN: could not re-read the live generation -- parking" >&2
      break
    fi
  done

  # Exhausted or aborted: park exactly as before this function existed, then let
  # of_state_try_promote have the final say -- it independently re-checks the three
  # guards (live exists, epoch not regressed, superset), so it stays correct even
  # though this loop already tried a merge.
  local conflict="${HERMES_STATE_OBJECT%.tar.gz}.conflict-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
    -H "Authorization: Bearer ${tok}" -H "Content-Type: application/gzip" \
    --data-binary "@${tarball}" \
    "https://storage.googleapis.com/upload/storage/v1/b/${HERMES_STATE_BUCKET}/o?uploadType=media&name=${conflict}" || echo 000)"
  if [[ "$code" == "200" ]]; then
    echo "[of-state] conflict snapshot parked at gs://${HERMES_STATE_BUCKET}/${conflict} -- BOTH states survive" >&2
    of_state_try_promote "$tarball" "$conflict" "$tok"
  else
    echo "[of-state] ERROR: conflict snapshot upload failed (HTTP ${code}); THIS SESSION IS LOST" >&2
  fi
}

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
  for p in plans pairing cron; do
    [[ -e "$home/$p" ]] && cp -a "$home/$p" "$stage/$p"
  done
  # openfathom-meta ENG-103. memories/ used to be copied here too, into the same tarball
  # and the same compare-and-swap as messages. It now has its own object and its own CAS
  # (of_memories_snapshot) -- a memory-only conflict no longer competes with, or waits
  # on, the message tarball's much higher write-conflict rate.
  #
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
  # destroy. openfathom-meta ENG-103: of_state_snapshot_upload now retries with a
  # merge before falling back to parking -- see that function for the full contract.
  of_state_snapshot_upload "$stage" "$tarball" "$tok"
  rm -rf "$stage" "$tarball"
}

# openfathom-meta ENG-103. Shared GET-then-parse-generation idiom for the memories
# functions below, several of which need to read an object's current GCS generation.
# NOT applied to the of_state_* call sites that already inline this same idiom (in
# of_state_restore, of_state_try_promote, of_state_snapshot_upload) -- those predate this
# helper, and touching already-tested code for a pure DRY gain is out of scope here.
of_gcs_read_generation() {
  local bucket="$1" object="$2" tok="$3"
  curl -sS --max-time 15 -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${object}" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("generation") or 0)
except Exception: print(0)' 2>/dev/null || echo 0
}

# openfathom-meta ENG-103. Union-merge every memory entry under $2 (src_dir) into $1
# (dest_dir), by entry content -- ENTRY_DELIMITER = "\n§\n", the same split
# tools/memory_tool.py uses (confirmed at tools/memory_tool.py:69,866-874). Only ADDS
# entries dest does not already have; never removes or reorders dest's own entries, so
# two instances that each wrote independently converge to the union with no "winner" to
# pick -- a memory entry that exists on both sides with different wording is simply kept
# as two distinct entries, not coalesced. Writes with the SAME atomic temp-file+rename
# pattern tools/memory_tool.py::_write_file uses, for the same reason: a reader must
# never observe a half-written file.
#
# EXCLUDED, never treated as a mergeable entry file:
#   - `*.lock`       -- tools/memory_tool.py's own per-file lock, transient by construction
#   - `.mem_*.tmp`   -- its atomic-write staging file, same reason
#   - `.memories_epoch` -- this mechanism's OWN control file (see of_memories_tarball_epoch
#     below). Unioning it as if it were prose would append two integers with the entry
#     delimiter and corrupt the one thing that must read back as a bare integer -- the
#     exact bug class that took production down once already for `.state_epoch` (see
#     of_state_read_local_epoch above). Epoch is written directly by the caller, never by
#     this function.
#
# Absence of src_dir is not an error (first boot, before any memories snapshot exists);
# dest_dir is created if missing.
of_memory_union() {
  python3 - "$1" "$2" <<'PY'
import sys, os, tempfile

dest_dir, src_dir = sys.argv[1], sys.argv[2]
DELIM = "\n§\n"  # tools/memory_tool.py::ENTRY_DELIMITER == "\n§\n"

def entries_of(path):
    if not os.path.isfile(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    return [e.strip() for e in raw.split(DELIM) if e.strip()]

def excluded(rel):
    base = os.path.basename(rel)
    if base.endswith(".lock"):
        return True
    if base.startswith(".mem_") and base.endswith(".tmp"):
        return True
    if rel == ".memories_epoch":
        return True
    return False

if not os.path.isdir(src_dir):
    raise SystemExit(0)

os.makedirs(dest_dir, exist_ok=True)
merged_entries = merged_files = 0
for root, _dirs, files in os.walk(src_dir):
    for name in files:
        src_path = os.path.join(root, name)
        rel = os.path.relpath(src_path, src_dir)
        if excluded(rel):
            continue
        dest_path = os.path.join(dest_dir, rel)
        dest_entries = entries_of(dest_path)
        src_entries = entries_of(src_path)
        seen = set(dest_entries)
        added = [e for e in src_entries if e not in seen]
        if not added:
            continue
        merged = dest_entries + added
        dest_parent = os.path.dirname(dest_path) or dest_dir
        os.makedirs(dest_parent, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=dest_parent, prefix=".mem_", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(DELIM.join(merged))
            os.replace(tmp, dest_path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        merged_entries += len(added)
        merged_files += 1
print(f"[of-memory-union] merged {merged_entries} new entry/entries across {merged_files} file(s)")
PY
}

# openfathom-meta ENG-103. Same contract as of_state_tarball_epoch, but reads
# `.memories_epoch` instead of `.state_epoch` -- memories now travel in their own
# tarball with their own epoch, independent of the messages/plans/pairing/cron one.
of_memories_tarball_epoch() {
  python3 - "$1" <<'PY' 2>/dev/null || echo 0
import sys, tarfile, os
try:
    with tarfile.open(sys.argv[1]) as t:
        m = next((x for x in t.getmembers()
                  if os.path.basename(x.name) == ".memories_epoch" and x.isfile()), None)
        if m is None:
            print(0); raise SystemExit(0)
        raw = t.extractfile(m).read().decode("utf-8", "replace").strip()
    print(int(raw) if raw.isdigit() else 0)
except Exception:
    print(0)
PY
}

# openfathom-meta ENG-103. Restores memories/ from its OWN object (HERMES_MEMORIES_OBJECT),
# independent of of_state_restore -- a memories-only conflict no longer competes with the
# much higher write-conflict rate of the messages tarball.
#
# Called AFTER of_state_restore (which may still extract a memories/ directory out of a
# LEGACY combined tarball written before this split existed) and BEFORE of_write_soul.
# UNION, never overwrite: whatever of_state_restore already put on disk from a legacy
# tarball is the destination; what THIS object holds is the source. Union is commutative,
# so there is no "which one wins" question at boot (unlike
# of_memories_write_with_merge_retry, where the epoch guard exists precisely because a
# decision has to be made about resurrection).
#
# Best-effort by design, same as of_state_restore (Dogma 2): a gateway that boots with
# fewer memories than it should is degraded, not down.
of_memories_restore() {
  local tok code tarball="/tmp/of-memories-restore.tar.gz"
  local mem_dir="${HERMES_HOME:-/opt/data}/memories"
  tok="$(of_metadata_token)" || { echo "[of-memories] WARN: no metadata token; starting with restored state only" >&2; return 0; }

  of_memories_generation="$(of_gcs_read_generation "$HERMES_STATE_BUCKET" "$HERMES_MEMORIES_OBJECT" "$tok")"

  code="$(curl -sS -o "$tarball" -w '%{http_code}' --max-time 30 \
    -H "Authorization: Bearer ${tok}" \
    "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_MEMORIES_OBJECT}?alt=media" || echo 000)"
  case "$code" in
    200) ;;
    404) echo "[of-memories] no memories snapshot yet (first boot)"; rm -f "$tarball"; return 0 ;;
    *)   echo "[of-memories] WARN: memories restore failed (HTTP ${code}); starting with restored state only" >&2; rm -f "$tarball"; return 0 ;;
  esac

  local extract_dir; extract_dir="$(mktemp -d)"
  if tar xzf "$tarball" -C "$extract_dir" 2>/dev/null; then
    of_memory_union "$mem_dir" "$extract_dir"
    echo "[of-memories] merged memories from gs://${HERMES_STATE_BUCKET}/${HERMES_MEMORIES_OBJECT}"
  else
    echo "[of-memories] WARN: memories snapshot present but did not extract" >&2
  fi
  rm -rf "$extract_dir" "$tarball"
}

# openfathom-meta ENG-103. Retry-with-merge for the memories CAS, same shape as
# of_state_snapshot_upload but simpler: the merge step (of_memory_union) is safe and
# commutative by construction, so it never "fails" the way a message merge can on
# divergent schema -- the only way this loop runs out is persistent generation
# contention. On exhaustion (or an aborted guard) it gives up THIS cycle rather than
# parking a conflict object: memories are re-synced every
# HERMES_MEMORY_SYNC_INTERVAL_SECONDS (Passo 3), so the next tick retries from a fresh
# generation read. The one case this leaves exposed -- persistent contention on the
# FINAL, shutdown-triggered call, with no next tick to retry on -- is accepted: periodic
# ticks already carried forward everything older than one interval, so at most the last
# interval's worth of entries is at risk, never the whole session's memory.
of_memories_write_with_merge_retry() {
  local mem_dir="$1" tarball="$2" tok="$3"
  local max_attempts="$OF_STATE_MERGE_MAX_ATTEMPTS"
  local gen="${of_memories_generation:-0}" attempt=0 code

  while :; do
    attempt=$((attempt + 1))
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
      -H "Authorization: Bearer ${tok}" -H "Content-Type: application/gzip" \
      --data-binary "@${tarball}" \
      "https://storage.googleapis.com/upload/storage/v1/b/${HERMES_STATE_BUCKET}/o?uploadType=media&name=${HERMES_MEMORIES_OBJECT}&ifGenerationMatch=${gen}" \
      || echo 000)"

    if [[ "$code" == "200" ]]; then
      echo "[of-memories] snapshot uploaded to gs://${HERMES_STATE_BUCKET}/${HERMES_MEMORIES_OBJECT} (attempt ${attempt}, generation matched ${gen})"
      # Carry the new generation forward into the GLOBAL (no `local` -- same reason
      # of_state_generation is not local) so the NEXT periodic tick (Passo 3) targets it.
      # Without this every subsequent cycle would still CAS against the generation this
      # instance started with, which the object has already moved past, and would 412
      # into an unnecessary merge forever.
      of_memories_generation="$(of_gcs_read_generation "$HERMES_STATE_BUCKET" "$HERMES_MEMORIES_OBJECT" "$tok")"
      return 0
    fi
    if [[ "$code" != "412" ]]; then
      echo "[of-memories] ERROR: snapshot upload failed (HTTP ${code}); this cycle's memories are lost" >&2
      return 0
    fi
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "[of-memories] WARN: still conflicting after ${attempt} attempt(s) -- giving up this cycle" >&2
      return 0
    fi

    echo "[of-memories] WARN: gs://${HERMES_STATE_BUCKET}/${HERMES_MEMORIES_OBJECT} changed since last read (attempt ${attempt}/${max_attempts}, generation ${gen}) -- merging" >&2
    # mktemp, not a fixed name: this loop's own SIGTERM-vs-final-flush race (see
    # of_memories_snapshot below) means two invocations of this function can be in
    # flight at once -- a fixed path here would let one instance's `rm -f` race the
    # other's `curl -o`.
    local live live_code; live="$(mktemp --suffix=.tar.gz)"
    live_code="$(curl -sS -o "$live" -w '%{http_code}' --max-time 15 \
      -H "Authorization: Bearer ${tok}" \
      "https://storage.googleapis.com/storage/v1/b/${HERMES_STATE_BUCKET}/o/${HERMES_MEMORIES_OBJECT}?alt=media" || echo 000)"
    if [[ "$live_code" != "200" ]]; then
      echo "[of-memories] WARN: could not download live memories to merge (HTTP ${live_code}) -- giving up this cycle" >&2
      rm -f "$live"; return 0
    fi

    local live_epoch; live_epoch="$(of_memories_tarball_epoch "$live")"
    if [[ "${of_state_epoch:-0}" -lt "$live_epoch" ]]; then
      echo "[of-memories] WARN: live memories epoch ${live_epoch} is newer than ours (${of_state_epoch:-0}) -- a deliberate reset happened, NOT merging. Giving up this cycle." >&2
      rm -f "$live"; return 0
    fi

    local live_extract; live_extract="$(mktemp -d)"
    if ! tar xzf "$live" -C "$live_extract" 2>/dev/null; then
      echo "[of-memories] WARN: live memories tarball did not extract -- giving up this cycle" >&2
      rm -f "$live"; rm -rf "$live_extract"; return 0
    fi
    rm -f "$live"
    of_memory_union "$mem_dir" "$live_extract"
    rm -rf "$live_extract"

    printf '%s\n' "${of_state_epoch:-0}" > "$mem_dir/.memories_epoch"
    tar czf "$tarball" -C "$mem_dir" . || { echo "[of-memories] ERROR: re-tar after merge failed; this cycle's memories are lost" >&2; return 0; }

    gen="$(of_gcs_read_generation "$HERMES_STATE_BUCKET" "$HERMES_MEMORIES_OBJECT" "$tok")"
    if [[ -z "$gen" || "$gen" == "0" ]]; then
      echo "[of-memories] WARN: could not re-read the live generation -- giving up this cycle" >&2
      return 0
    fi
  done
}

# openfathom-meta ENG-103. Snapshots $HERMES_HOME/memories into its own tarball and
# uploads it to HERMES_MEMORIES_OBJECT via CAS, independent of of_state_snapshot.
#
# stage/tarball are mktemp'd fresh EVERY call, deliberately never a fixed path: unlike
# of_state_snapshot (which runs exactly once, from of_on_term or the normal-exit path,
# never both), this function can genuinely be IN FLIGHT TWICE AT ONCE. The periodic loop
# (Passo 3) calls it every HERMES_MEMORY_SYNC_INTERVAL_SECONDS; of_on_term's
# `kill -TERM "$of_memories_loop_pid"` does not (and, given the shutdown budget, should
# not) wait for that call to finish before running its own final flush -- and bash
# defers a pending trap until the loop's CURRENT foreground command (a curl, not
# specially interruptible like `wait`) returns. A fixed path would let one invocation's
# `rm -rf "$stage"` delete the directory the other is mid-`cp`/`tar` into.
of_memories_snapshot() {
  local home="${HERMES_HOME:-/opt/data}" mem_dir
  mem_dir="$home/memories"
  [[ -d "$mem_dir" ]] || { echo "[of-memories] no memories dir yet -- nothing to snapshot"; return 0; }

  local stage tarball tok
  stage="$(mktemp -d)"; tarball="$(mktemp --suffix=.tar.gz)"
  cp -a "$mem_dir/." "$stage/" 2>/dev/null || true
  # Copied, THEN pruned -- never delete inside $mem_dir itself, which memory_tool.py may
  # be actively writing to (live, concurrently, from Passo 3's periodic loop) while this
  # runs. Its own .lock/.mem_*.tmp are real only for the instant of one write.
  find "$stage" -name '*.lock' -delete 2>/dev/null || true
  find "$stage" -name '.mem_*.tmp' -delete 2>/dev/null || true

  printf '%s\n' "${of_state_epoch:-0}" > "$stage/.memories_epoch"
  tar czf "$tarball" -C "$stage" . || { echo "[of-memories] ERROR: tar failed; this cycle's memories are lost" >&2; rm -rf "$stage"; return 0; }
  [[ -s "$tarball" ]] || { echo "[of-memories] WARN: nothing to snapshot"; rm -rf "$stage" "$tarball"; return 0; }
  tok="$(of_metadata_token)" || { echo "[of-memories] ERROR: no metadata token; this cycle's memories are lost" >&2; rm -rf "$stage" "$tarball"; return 0; }

  of_memories_write_with_merge_retry "$stage" "$tarball" "$tok"
  rm -rf "$stage" "$tarball"
}

# openfathom-meta ENG-103, Passo 3. Periodic persistence for memories/ -- independent of
# the message snapshot, which still only runs on shutdown (Passo 1, unchanged). A crash
# (SIGKILL, not a graceful SIGTERM) loses at most one interval's worth of memories instead
# of everything since the last shutdown-triggered snapshot.
#
# ASYMMETRY, DELIBERATE: memories are written with the gateway STILL ALIVE (this loop);
# messages only after it dies (of_state_snapshot, called from of_on_term and the
# normal-exit path). A future reader must not "fix" this loop to run only after the
# gateway's own `wait` returns -- that would defeat the entire purpose of this step.
#
# `sleep "$interval" & wait "$!"` (not a bare `sleep "$interval"`) so a TERM/INT arriving
# mid-interval interrupts the WAIT immediately -- a foreground `sleep` would run to
# completion before bash even checks for a pending trap. Same pattern already used for
# `wait "${of_gateway_pid}"` below. `|| true` because an interrupted wait returns >128,
# which `set -e` would otherwise treat as fatal and kill the loop's own subshell.
of_memories_sync_loop() {
  local interval="${HERMES_MEMORY_SYNC_INTERVAL_SECONDS:-90}"
  trap 'exit 0' TERM INT
  while true; do
    sleep "$interval" & wait "$!" || true
    of_memories_snapshot || echo "[of-memories] WARN: periodic sync cycle failed" >&2
  done
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
# `hermes gateway run`).
#
# THE KEY IS THE FRONTMATTER NAME, NOT THE DIRECTORY NAME -- openfathom-meta ENG-88.
# A prior version of this comment claimed "the manifest keys are flat basenames -- so the
# match is on the SKILL DIRECTORY NAME", validated only against `apple-notes`/`arch-brainstorm`
# (a case where both happen to agree). That claim is false in general: tools/skills_sync.py
# indexes the manifest by the `name:` field of SKILL.md's YAML frontmatter
# (_read_skill_name), and upstream commit 503da4e30 (2026-07-23, "align skill directory
# names with frontmatter name") renamed 4 bundled directories to match their frontmatter --
# our image predates that commit, so those 4 (vllm, lm-evaluation-harness, audiocraft,
# segment-anything at the time) sat in the manifest under a DIFFERENT key than their
# on-disk directory name, the basename match always missed, and every boot re-deposited
# them as if the agent had written them: measured, 20 objects in skills-inbox/, 1 genuine.
# 14 more bundled/optional skills carry the same dir != frontmatter split today (all in
# optional-skills/, e.g. peft -> peft-fine-tuning) -- latent until one is hub-installed.
#
# So the match below tries BOTH the directory basename and the frontmatter `name:`
# against the manifest, mirroring upstream's own _read_skill_name (fallback = basename
# when frontmatter has no name field or the file can't be read) -- plus a second
# provenance table upstream also maintains and this function used to ignore entirely:
# ~/.hermes/skills/.hub/lock.json (tools/skill_usage.py::_read_hub_installed_names),
# which records skills installed via the Skills Hub rather than shipped in the image.
# Safe from name collisions for the same reason upstream's own lookup is: _create_skill
# refuses a name that already exists in any skills dir.
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
#
# Self-contained (no import of tools/skills_sync.py or tools/skill_usage.py, both outside
# the fork's 8-file scope -- ADR-002/035/050): re-derives the same frontmatter-name and
# hub-lock lookups those modules already do, read-only, without patching or depending on
# their internals. Prints one skill DIRECTORY PATH per line for every skill judged
# agent-written (i.e. NOT bundled/hub-installed); the caller stages exactly those.
of_skills_inbox_genuine_dirs() {
  local skills="$1" manifest="$2"
  python3 - "$skills" "$manifest" <<'PYEOF'
import json
import sys
from pathlib import Path

skills_root, manifest_path = Path(sys.argv[1]), Path(sys.argv[2])


def read_skill_name(skill_md, fallback):
    """Mirrors tools/skills_sync.py::_read_skill_name."""
    try:
        content = skill_md.read_text(encoding="utf-8", errors="replace")[:4000]
    except OSError:
        return fallback
    in_frontmatter = False
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped == "---":
            if in_frontmatter:
                break
            in_frontmatter = True
            continue
        if in_frontmatter and stripped.startswith("name:"):
            value = stripped.split(":", 1)[1].strip().strip("\"'")
            if value:
                return value
    return fallback


def read_manifest_keys(path):
    """Mirrors tools/skills_sync.py::_read_manifest (v1 and v2 formats)."""
    keys = set()
    if not path.exists():
        return keys
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        name = line.partition(":")[0].strip() if ":" in line else line
        if name:
            keys.add(name)
    return keys


def read_hub_names(root):
    """Mirrors tools/skill_usage.py::_read_hub_installed_names."""
    lock_path = root / ".hub" / "lock.json"
    if not lock_path.exists():
        return set()
    try:
        data = json.loads(lock_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return set()
    installed = data.get("installed") if isinstance(data, dict) else None
    if not isinstance(installed, dict):
        return set()
    return {str(k) for k in installed.keys()}


manifest_keys = read_manifest_keys(manifest_path)
hub_names = read_hub_names(skills_root)

for skill_md in skills_root.rglob("SKILL.md"):
    dir_path = skill_md.parent
    if dir_path == skills_root:
        # Same refusal as before: a SKILL.md at the root would stage the WHOLE tree.
        print(f"WARN: ignoring a SKILL.md at the root of {skills_root}", file=sys.stderr)
        continue
    dirname = dir_path.name
    frontmatter_name = read_skill_name(skill_md, dirname)
    if (
        dirname in manifest_keys
        or frontmatter_name in manifest_keys
        or dirname in hub_names
        or frontmatter_name in hub_names
    ):
        continue
    print(str(dir_path))
PYEOF
}

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

  local dir name
  while IFS= read -r dir; do
    name="$(basename "$dir")"
    cp -a "$dir" "$stage/$name" 2>/dev/null || echo "[of-inbox] WARN: could not stage $dir" >&2
  done < <(of_skills_inbox_genuine_dirs "$skills" "$manifest")

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
# ONLY lever for the agent's OWN spoken language -- the model's conversational output.
#
# CORRECTION (2026-07-24): the claim that used to sit here -- "display.language does
# not accept pt/pt-BR (config.py supports en/zh/ja/de/es/fr/tr/uk only)" -- is WRONG
# today. Verified directly against agent/i18n.py, not recited: SUPPORTED_LANGUAGES now
# includes "pt" (locales/pt.yaml, 402 lines, real catalog), and "pt-br"/"pt-pt" both
# alias to it. This drifted true to false silently after an upstream sync widened the
# language list; nobody re-checked the comment against the code since.
#
# It STILL does not cover everything, and that half of the old claim holds: i18n.py's
# own docstring scopes it to "the highest-impact static strings ... approval prompts,
# a handful of gateway slash command replies, restart-drain notices" -- confirmed by
# reading the call sites. Task-interruption notices and first-touch onboarding tips
# (gateway/run.py, agent/onboarding.py) are plain f-strings with no t() call at all;
# setting display.language does not touch them, and nothing short of an upstream i18n
# expansion (out of ADR-002 scope) will.
# openfathom-meta ENG-81 (skills half). Measured 2026-07-23: asked generically what
# skills it has, the Sonda invented plausible-sounding names instead of admitting it did
# not track that. The fix is not a hand-written list in SOUL.md (drifts the moment a skill
# is added or a toolset is disabled) and not a doc the Sonda might or might not read (the
# same failure mode, one hop removed) -- it is a block computed HERE, at boot, from the two
# facts this script already holds in this exact execution: which SKILL.md files
# of_skills_fetch actually populated into $of_skills_dir, and which toolsets
# of_disabled_toolsets (above) just turned off. Nothing to keep in sync; both are read live.
#
# Parses requires_toolsets with the SAME nesting rule openfathom-skills'
# scripts/lint_skills.py declared_toolsets() enforces at review time
# (metadata.hermes.requires_toolsets, not a top-level key) -- a skill CI already proved
# compliant is read here the same way, not by a second, looser parser that could disagree.
#
# Reads $of_skills_dir as a global (set, unquoted `local`, in the service) case body above,
# same pattern of_write_soul below already relies on) -- absent or missing dir (skills
# fetch was never configured, or failed) degrades to an empty block, not an error: Dogma 2.
of_soul_capabilities_block() {
  local dir="${of_skills_dir:-}"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "[of-soul-capabilities] no skills directory this boot -- SOUL.md gets no capabilities block" >&2
    return 0
  fi
  python3 - "$dir" "${of_disabled_toolsets[@]}" <<'PYEOF'
import os
import re
import sys

skills_dir = sys.argv[1]
disabled = set(sys.argv[2:])

REQ_KEY = "requires_toolsets"


def declared_toolsets(text):
    # Mirror of openfathom-skills scripts/lint_skills.py declared_toolsets(): same nesting
    # rule (metadata.hermes.requires_toolsets only), same reason a field elsewhere is read
    # by nobody (ENG-68). Returns None for missing/misplaced/malformed -- callers fail closed.
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end == -1:
        return None
    lines = text[4:end].splitlines()
    for i, line in enumerate(lines):
        m = re.match(rf"^(\s*){REQ_KEY}\s*:\s*(.*)$", line)
        if not m:
            continue
        indent, inline = len(m.group(1)), m.group(2).strip()
        want, cur = ["hermes", "metadata"], indent
        for j in range(i - 1, -1, -1):
            pm = re.match(r"^(\s*)([a-z_]+)\s*:", lines[j])
            if not pm or len(pm.group(1)) >= cur:
                continue
            if pm.group(2) != want[0]:
                return None
            want.pop(0)
            cur = len(pm.group(1))
            if not want:
                break
        if want:
            return None
        if inline:
            if not (inline.startswith("[") and inline.endswith("]")):
                return None
            body = inline[1:-1].strip()
            return [v.strip().strip("\"'") for v in body.split(",") if v.strip()]
        vals = []
        for j in range(i + 1, len(lines)):
            bm = re.match(r"^(\s*)-\s*(.+)$", lines[j])
            if bm and len(bm.group(1)) > indent:
                vals.append(bm.group(2).strip().strip("\"'"))
            elif lines[j].strip():
                break
        return vals
    return None


def declared_name(text, fallback):
    if not text.startswith("---\n"):
        return fallback
    end = text.find("\n---", 4)
    if end == -1:
        return fallback
    for line in text[4:end].splitlines():
        m = re.match(r"^name\s*:\s*(.+)$", line)
        if m:
            return m.group(1).strip().strip("\"'")
    return fallback


available, unavailable = [], []
for root, _, files in os.walk(skills_dir):
    if "SKILL.md" not in files:
        continue
    text = open(os.path.join(root, "SKILL.md"), encoding="utf-8").read()
    fallback = os.path.basename(root)
    name = declared_name(text, fallback)
    toolsets = declared_toolsets(text)
    if toolsets is None:
        # CI (lint_skills.py check 6) already refuses to merge a skill without this field
        # declared correctly, so this should never happen in a published tarball -- but
        # fail closed, not open: list it as unavailable rather than silently as safe.
        unavailable.append((name, ["<requires_toolsets não declarado>"]))
        continue
    missing = sorted(set(toolsets) & disabled)
    if missing:
        unavailable.append((name, missing))
    else:
        available.append(name)

available.sort()
unavailable.sort(key=lambda t: t[0])

lines = [
    "## Skills disponíveis agora (gerado no boot -- não afirme status além do que está aqui)",
    "",
    "Toolsets desligados neste ambiente: " + (", ".join(sorted(disabled)) or "nenhum") + ".",
    "",
    "Disponíveis:",
]
lines += [f"- {n}" for n in available] if available else ["- (nenhuma)"]
lines += ["", "Carregadas mas indisponíveis aqui (falta ferramenta desligada):"]
lines += [f"- {n} (precisa: {', '.join(m)})" for n, m in unavailable] if unavailable else ["- (nenhuma)"]

print("\n".join(lines))
PYEOF
}

of_write_soul() {
  [[ -n "${HERMES_SOUL:-}" ]] || return 0
  local home="${HERMES_HOME:-/opt/data}"
  mkdir -p "$home"
  local capabilities
  capabilities="$(of_soul_capabilities_block)"
  if [[ -n "$capabilities" ]]; then
    printf '%s\n\n%s\n' "${HERMES_SOUL}" "$capabilities" > "$home/SOUL.md"
  else
    printf '%s\n' "${HERMES_SOUL}" > "$home/SOUL.md"
  fi
  echo "[of-soul] wrote declared SOUL.md (${#HERMES_SOUL} chars, capabilities block: $([[ -n "$capabilities" ]] && echo yes || echo no)) to $home/SOUL.md"
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

    # openfathom-meta ENG-84. Two real production outages (2026-07-24, 12:23 and
    # 13:04) with HTTP 402 from OpenRouter -- "requested up to 64000 tokens, but can
    # only afford 6216/63067" -- because model.max_tokens was never set, so Hermes
    # used the model's 64k default. A realistic ceiling doesn't fix the cause (the
    # OpenRouter top-up friction ENG-83 targets), only the preflight-balance rejection
    # that turns it into a full request failure. 12000 is inside the ~8-16k band
    # ENG-84 sized as "enough for a chat reply" -- unconditional because there is no
    # deployment of this image where a bare chat reply needs the model's full 64k.
    hermes config set model.max_tokens 12000

    # openfathom-meta ENG-101. Never set, so production ran on the 5m default.
    # Measured from a real session's session_model_usage (2026-07-28):
    # cache_read 79.5% of input-side tokens, cache_write 20.5% -- and a 5m TTL
    # write costs 1.25x base vs 0.1x for a read, a 12.5x penalty on whatever
    # expires between Telegram turns. The write share, not the read share, is
    # what a longer TTL targets; 1h write costs 2x instead, but amortizes
    # across the paused-then-resumed conversation pattern this gateway sees.
    # Unconditional, same reasoning as model.max_tokens above -- no deployment
    # of this image benefits from the 5m default over 1h.
    hermes config set prompt_caching.cache_ttl 1h

    if [[ -n "${HERMES_TIMEZONE:-}" ]]; then
      hermes config set timezone "${HERMES_TIMEZONE}"
    fi

    # ENG-47 / language-protocol. Unconditional, not env-gated, same reasoning as
    # agent.reasoning_effort below -- there is no deployment of this image where
    # English static UI strings are wanted over Portuguese. Covers the curated subset
    # agent/i18n.py owns (approval prompts, some gateway slash replies, restart-drain
    # notices) -- see of_write_soul's comment above for what this does NOT cover
    # (task-interruption notices, onboarding tips: hardcoded English, no t() call,
    # unreachable from config). "pt", not "pt-br" -- SUPPORTED_LANGUAGES carries a
    # single Portuguese catalog and "pt-br"/"pt-pt" both alias to it (agent/i18n.py);
    # the canonical value avoids depending on alias resolution.
    hermes config set display.language pt

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
    # This is Hermes' own native fallback (hermes_cli/fallback_config.py), used here
    # for the first time.
    #
    # NOT vertex -- confirmed broken by a real smoke test (openfathom-meta, 2026-07-25):
    # a `vertex` fallback entry never activates. try_activate_fallback() (agent/
    # chat_completion_helpers.py) calls resolve_provider_client() (agent/
    # auxiliary_client.py), which resolves the provider via
    # `PROVIDER_REGISTRY.get(provider)` -- and that PROVIDER_REGISTRY
    # (hermes_cli/auth.py) is a DIFFERENT registry from the one
    # plugins/model-providers/vertex/__init__.py populates via
    # providers.register_provider() (which only feeds the PRIMARY-provider code
    # path, hermes_cli/runtime_provider.py). Confirmed live, inside a real
    # of-agent:cloudrun container, even with the vertex-provider plugin enabled and
    # the gateway restarted: `'vertex' in PROVIDER_REGISTRY` is False. The
    # `elif pconfig.auth_type == "vertex":` branch in resolve_provider_client
    # (auxiliary_client.py:5003) is dead code in hermes-agent 0.18.2 -- nothing
    # ever populates that registry key. Fixing it is out of scope: neither file
    # is one of the 8 this fork may touch (ADR-002/035/050).
    #
    # gemini (Google AI Studio), not vertex: `"gemini"` IS in
    # hermes_cli.auth.PROVIDER_REGISTRY (auth_type="api_key", confirmed live in the
    # same container), so it actually activates through the same
    # resolve_provider_client() that rejected vertex. Auth is a plain
    # GEMINI_API_KEY env var (plugins/model-providers/gemini/__init__.py:
    # env_vars=("GOOGLE_API_KEY", "GEMINI_API_KEY")) -- no entrypoint translation
    # needed, same class as ANTHROPIC_API_KEY/OPENROUTER_API_KEY above. Model slug
    # is bare `gemini-3.6-flash`, no `google/` prefix -- that prefix is specific to
    # Vertex's OpenAI-compatible path, not the AI Studio native endpoint
    # (generativelanguage.googleapis.com).
    #
    # A LIST value (even of one entry) -- `hermes config set` cannot write it; needs
    # the python heredoc, same reason agent.disabled_toolsets does.
    python3 - <<'PYEOF'
from hermes_cli.config import get_config_path, fast_safe_load, ensure_hermes_home, _set_nested
from utils import atomic_yaml_write
p = get_config_path()
cfg = (fast_safe_load(open(p)) or {}) if p.exists() else {}
_set_nested(cfg, "fallback_providers", [{"provider": "gemini", "model": "gemini-3.6-flash"}])
ensure_hermes_home()
atomic_yaml_write(p, cfg, sort_keys=False)
print(f"✓ Set fallback_providers = [gemini/gemini-3.6-flash] in {p}")
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
    # (amended by ADR-035 and ADR-050) puts outside the files this fork may touch --
    # the list is ALLOWED_FILES in scripts/validate-fork-scope.py, the only copy of it
    # CI reads. This is the only lever we have -- and it happens to be the intended
    # one, not a workaround: `none` is a documented value of this key.
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
    #
    # openfathom-meta ENG-81 (skills half): named once, not just inlined below, because
    # of_soul_capabilities_block (defined above, called from of_write_soul) needs the SAME
    # list to know which of a skill's declared requires_toolsets are actually off in this
    # boot. One array, read twice, instead of a second literal that could drift from this
    # one silently.
    of_disabled_toolsets=(terminal code_execution image_gen video_gen tts)
    python3 - "${of_disabled_toolsets[@]}" <<'PYEOF'
import sys
from hermes_cli.config import get_config_path, fast_safe_load, ensure_hermes_home, _set_nested
from utils import atomic_yaml_write
toolsets = sys.argv[1:]
p = get_config_path()
cfg = (fast_safe_load(open(p)) or {}) if p.exists() else {}
_set_nested(cfg, "agent.disabled_toolsets", toolsets)
ensure_hermes_home()
atomic_yaml_write(p, cfg, sort_keys=False)
print(f"✓ Set agent.disabled_toolsets = {toolsets} in {p}")
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
    # image's own skills/ directory. ADR-002 (amended by ADR-035/ADR-050) keeps our repo
    # to the ALLOWED_FILES allow-list, which no skill is on -- so our skills are
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
    HERMES_MEMORIES_OBJECT="${HERMES_MEMORIES_OBJECT:-memories.tar.gz}"
    of_memories_restore
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

    # openfathom-meta ENG-103, Passo 3. Started AFTER of_memories_restore has already run
    # (earlier in this same boot sequence) -- this background loop inherits
    # of_memories_generation at the moment of the fork below, so if that ordering is ever
    # reversed the loop would inherit 0 and its first periodic write would always 412.
    of_memories_sync_loop &
    of_memories_loop_pid=$!

    of_on_term() {
      trap - TERM INT
      kill -TERM "${of_gateway_pid}" 2>/dev/null || true
      wait "${of_gateway_pid}" 2>/dev/null || true
      kill -TERM "${of_memories_loop_pid:-}" 2>/dev/null || true
      of_state_snapshot
      # AFTER the snapshot, deliberately, and the ordering is the whole safety argument.
      # Cloud Run allocates ~10s of shutdown and the snapshot is sized to own it (see the
      # S6_CMD_RECEIVE_SIGNALS reasoning below). If the budget runs out, SIGKILL lands on
      # THIS call, not on the conversation state -- a lost skill deposit costs one
      # session's unreviewed drafts, a lost snapshot costs the user's real conversation.
      #
      # openfathom-meta ENG-103, Passo 3. Final flush, AFTER of_state_snapshot -- covers
      # the delta since the last periodic tick. Memories are small and cheap next to the
      # full state.db tarball, so this is deliberately the SECOND-to-last network call,
      # not competing with of_state_snapshot for the shutdown budget's early seconds.
      of_memories_snapshot
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
    kill -TERM "${of_memories_loop_pid:-}" 2>/dev/null || true
    of_state_snapshot
    of_memories_snapshot
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
