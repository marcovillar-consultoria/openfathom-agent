# OpenFathom delta — marcovillar-consultoria/openfathom-agent

This is a **minimal fork** of [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent), scoped per [ADR-002](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/ADR/002-fork-strategy-upstream-sync.md).

**Do not modify upstream files directly.** Allowed additions in this fork, per ADR-002:

- [`Dockerfile.cloudrun`](Dockerfile.cloudrun) — builds `FROM` the real upstream `Dockerfile` (tagged `of-agent:base`), adds only the entrypoint. Does not reinvent the s6-overlay/Node/Playwright build.
- [`scripts/cloudrun-entrypoint.sh`](scripts/cloudrun-entrypoint.sh) — `HERMES_MODE=service` runs `hermes gateway run` (Cloud Run Service, requires `API_SERVER_KEY`); `HERMES_MODE=job` runs `hermes -z "$HERMES_TASK"` (Cloud Run Job). It also writes into `config.yaml` at boot: the Vertex/ADC LLM provider ([ENG-41](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/BACKLOG.md)), `agent.reasoning_effort none` (stops the reasoning leak, [ENG-49](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/BACKLOG.md)), and `agent.disabled_toolsets = [terminal, code_execution]` — which **closes the unsandboxed-RCE vector** ([ADR-043](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/ADR/043-context-b-execution-gateway-orchestrates-local-claude-executes.md) / [ENG-51](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/BACKLOG.md)) — and snapshots SQLite state on `SIGTERM` ([ADR-041](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/ADR/041-gateway-state-snapshot-not-fuse-mount.md))
- [`docker-compose.cloudrun.yml`](docker-compose.cloudrun.yml) — local smoke-test harness for both modes (containers/ports prefixed `of-`/`OF_`)
- [`.github/workflows/of-upstream-sync.yml`](.github/workflows/of-upstream-sync.yml) — weekly rebase of `cloudrun` onto upstream `main`; opens a PR on success, an issue on conflict. Named `of-*`, not the `upstream-sync.yml` ADR-002 lists verbatim, so it can never collide with an upstream workflow of the same short name
- [`.github/workflows/of-build-image.yml`](.github/workflows/of-build-image.yml) — builds + pushes to Artifact Registry on push to `cloudrun`, tag `v<hermes>-of-<sha>`. **Authenticating and publishing** since OF-09 via the WIF service account in `openfathom-infra` (ENG-32 resolved) — these are the images production runs (pinned by digest in the infra `terraform.tfvars`)
- [`scripts/validate-fork-scope.py`](scripts/validate-fork-scope.py) — fails CI when a PR touches anything outside this list. Added by [ADR-035](https://github.com/marcovillar-consultoria/openfathom-meta/blob/main/docs/ADR/035-validate-fork-scope-script.md), which amended ADR-002 to include it; this line was missing here until 2026-07-17
- `README.openfathom.md` (this file)

## Set your git author email before committing here

Two places, and the `git config` half alone is NOT enough — see the merge-commit trap below.

```bash
git config --local user.email "<id>+<username>@users.noreply.github.com"   # your GitHub noreply
```

Then, on **github.com → Settings → Emails → check "Keep my email addresses private."** This makes GitHub use your `...@users.noreply.github.com` as the author of everything the **web UI** creates — most importantly **merge commits from the green Merge button**, which `git config --local` cannot touch because that button runs on GitHub's servers, not your machine. Without this, every merge is authored with your account's public email and lands right back in `merge-base..HEAD`.

**Found the hard way (2026-07-17):** the merge commit of PR #7 — the very PR that fixed the author email — was itself authored `marco@marcovillar.com` by the Merge button, and re-red the check on PR #8. The `git config` fix is per-clone and covers only commits you make locally; the Settings fix is per-account and covers the merges. You need both.

**Per clone. It is not versioned, so a fresh clone loses it — and nothing warns you until CI is red.**

Two reasons, and the first one is not ours to argue with. Upstream's `contributor-check.yml` fails any PR whose author email is absent from `AUTHOR_MAP` in `scripts/release.py` — a file **outside** the allowed list above, so we cannot add ourselves to it. The check has its own escape hatch, and it is the supported one, not a trick:

```sh
if echo "$email" | grep -qP '\+.*@users\.noreply\.github\.com'; then
  continue  # GitHub noreply emails auto-resolve
fi
```

The second reason stands on its own: **this fork is public**, so a personal address in `%ae` is published in every commit, forever, to anyone. The GitHub noreply address still attributes the commit to the account — nothing is lost.

The check does NOT ignore old history. It computes `MERGE_BASE=$(git merge-base origin/main HEAD)`, so `merge-base..HEAD` is **every `cloudrun` commit since the fork from `main`** — each author email must be noreply (or in `AUTHOR_MAP`), not just the ones a PR adds. **Found the hard way (2026-07-17):** first, PRs #4–6 merged red and it was called "pre-existing and unfixable" — it was neither, noreply auto-resolves. Then a later PR (#10) failed *again* on six OLD commits authored `marco@marcovillar.com` (from before the noreply switch), which recur in `merge-base..HEAD` on every PR. An earlier version of this note claimed "old commits are never re-examined" — **that was wrong**, and it cost a red CI to learn.

The fix was to **rewrite the `cloudrun` history to noreply** (`git filter-branch` swapping author *and* committer email, content-identical, verified before force-push). That was the right call, not the wrong one: the earlier "rewriting a public fork's history is worse than the problem" stance missed two things — the personal email was **publicly leaked** in those commits on this public fork (the exact harm the noreply switch exists to prevent), *and* they recur in every PR's `merge-base..HEAD`, keeping the check red until fixed. If a personal email ever reappears in `cloudrun` history, rewrite it again.

Added in **OF-03** (2026-07-12), **built and run for real the same day** once Docker became available mid-session: `docker build -t of-agent:base .` (the real upstream Dockerfile, 3.79GB) then `docker build -f Dockerfile.cloudrun`, then both modes exercised against a running container — not just read. Two real bugs surfaced only by running it (both fixed, see the script's comments): the `job` mode's output path assumed a `/data` mount that doesn't exist by default, and `service` mode needed `HERMES_GATEWAY_NO_SUPERVISE=1` + `API_SERVER_KEY` — this image starts its gateway as an independent s6-supervised service at boot, so env vars exported later in this script don't reach it without that flag. `job` mode reached a real Gemini API call with a live key and got HTTP 404 (a model/provider question for OF-04 — the key's shape suggests Vertex AI, not the Generative Language API this fork's Gemini adapter targets); `service` mode's `/health` answered `{"status":"ok",...}` correctly. `hermes -z`'s output shape (JSON or free text) is still unconfirmed — the call failed before producing an answer to inspect.

Governance SSOT: `openfathom-meta`.