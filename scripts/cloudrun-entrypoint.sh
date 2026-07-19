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
      echo "[of-state] conflict snapshot parked at gs://${HERMES_STATE_BUCKET}/${conflict} -- BOTH states survive; a human decides which wins" >&2
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
    # aggregator slug -- a bare `google/gemini-2.5-flash` here would silently bill Gemini
    # through OpenRouter instead of running Haiku. These are scalar keys two levels deep
    # -- `hermes config set` writes them fine (unlike the LIST at agent.disabled_toolsets
    # below, which needs the python heredoc).
    if [[ -n "${HERMES_INFERENCE_PROVIDER:-}" ]]; then
      hermes config set auxiliary.compression.provider      "${HERMES_INFERENCE_PROVIDER}"
      hermes config set auxiliary.compression.model         anthropic/claude-haiku-4.5
      hermes config set auxiliary.title_generation.provider "${HERMES_INFERENCE_PROVIDER}"
      hermes config set auxiliary.title_generation.model    anthropic/claude-haiku-4.5
    fi

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
      exit 0
    }
    trap of_on_term TERM INT

    # Two waits: the first is interrupted by the trap (bash runs the handler and
    # `wait` returns >128); the second reaps `hermes` on the normal-exit path, where
    # no signal ever arrives and the gateway simply died on its own.
    wait "${of_gateway_pid}" || true
    of_state_snapshot
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
