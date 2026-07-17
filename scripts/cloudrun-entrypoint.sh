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
#   PORT            injected by Cloud Run; only consulted in service mode
set -euo pipefail

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
    exec hermes gateway run
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
