# OpenFathom delta — marcovillar-consultoria/openfathom-agent

This is a **minimal fork** of [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent), scoped per [ADR-002](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/ADR/002-fork-strategy-upstream-sync.md).

**Do not modify upstream files directly.** Allowed additions in this fork, per ADR-002:

- [`Dockerfile.cloudrun`](Dockerfile.cloudrun) — builds `FROM` the real upstream `Dockerfile` (tagged `of-agent:base`), adds only the entrypoint. Does not reinvent the s6-overlay/Node/Playwright build.
- [`scripts/cloudrun-entrypoint.sh`](scripts/cloudrun-entrypoint.sh) — `HERMES_MODE=service` runs `hermes gateway run` (Cloud Run Service, requires `API_SERVER_KEY`); `HERMES_MODE=job` runs `hermes -z "$HERMES_TASK"` (Cloud Run Job)
- [`docker-compose.cloudrun.yml`](docker-compose.cloudrun.yml) — local smoke-test harness for both modes (containers/ports prefixed `of-`/`OF_`)
- [`.github/workflows/of-upstream-sync.yml`](.github/workflows/of-upstream-sync.yml) — weekly rebase of `cloudrun` onto upstream `main`; opens a PR on success, an issue on conflict. Named `of-*`, not the `upstream-sync.yml` ADR-002 lists verbatim, so it can never collide with an upstream workflow of the same short name
- [`.github/workflows/of-build-image.yml`](.github/workflows/of-build-image.yml) — builds + pushes to Artifact Registry on push to `cloudrun`. **Not yet authenticating**: needs a WIF service account in `openfathom-infra` that doesn't exist yet (see openfathom-meta `docs/BACKLOG.md`, ENG-32)
- [`scripts/validate-fork-scope.py`](scripts/validate-fork-scope.py) — fails CI when a PR touches anything outside this list. Added by [ADR-035](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/ADR/035-validate-fork-scope-script.md), which amended ADR-002 to include it; this line was missing here until 2026-07-17
- `README.openfathom.md` (this file)

## Set your git author email before committing here

```bash
git config --local user.email "<id>+<username>@users.noreply.github.com"   # your GitHub noreply
```

**Per clone. It is not versioned, so a fresh clone loses it — and nothing warns you until CI is red.**

Two reasons, and the first one is not ours to argue with. Upstream's `contributor-check.yml` fails any PR whose author email is absent from `AUTHOR_MAP` in `scripts/release.py` — a file **outside** the allowed list above, so we cannot add ourselves to it. The check has its own escape hatch, and it is the supported one, not a trick:

```sh
if echo "$email" | grep -qP '\+.*@users\.noreply\.github\.com'; then
  continue  # GitHub noreply emails auto-resolve
fi
```

The second reason stands on its own: **this fork is public**, so a personal address in `%ae` is published in every commit, forever, to anyone. The GitHub noreply address still attributes the commit to the account — nothing is lost.

Existing history keeps whatever it was committed with. That is deliberate: rewriting a public fork's history is worse than the problem, and the check only looks at `merge-base..HEAD`, so old commits are never re-examined. **Found the hard way (2026-07-17):** PRs #4, #5 and #6 all merged with this check red, and it was reported as "pre-existing and unfixable" — it was neither.

Added in **OF-03** (2026-07-12), **built and run for real the same day** once Docker became available mid-session: `docker build -t of-agent:base .` (the real upstream Dockerfile, 3.79GB) then `docker build -f Dockerfile.cloudrun`, then both modes exercised against a running container — not just read. Two real bugs surfaced only by running it (both fixed, see the script's comments): the `job` mode's output path assumed a `/data` mount that doesn't exist by default, and `service` mode needed `HERMES_GATEWAY_NO_SUPERVISE=1` + `API_SERVER_KEY` — this image starts its gateway as an independent s6-supervised service at boot, so env vars exported later in this script don't reach it without that flag. `job` mode reached a real Gemini API call with a live key and got HTTP 404 (a model/provider question for OF-04 — the key's shape suggests Vertex AI, not the Generative Language API this fork's Gemini adapter targets); `service` mode's `/health` answered `{"status":"ok",...}` correctly. `hermes -z`'s output shape (JSON or free text) is still unconfirmed — the call failed before producing an answer to inspect.

Governance SSOT: `openfathom-meta`.