# OpenFathom delta — marcovillar-consultoria/openfathom-agent

This is a **minimal fork** of [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent), scoped per [ADR-002](https://github.com/marcovillar-consultoria/openfathom-meta) (governance SSOT — content migration pending).

**Do not modify upstream files directly.** Allowed additions in this fork, per ADR-002:

- `Dockerfile.cloudrun`
- `scripts/cloudrun-entrypoint.sh`
- `docker-compose.cloudrun.yml`
- `.github/workflows/upstream-sync.yml`
- `.github/workflows/build-image.yml`
- `README.openfathom.md` (this file)

None of these exist yet — this repo is currently bootstrap-only (OF-01).
The actual Cloud Run packaging work is scheduled for **OF-03 — Agent fork**.

Governance SSOT: `openfathom-meta` (pending migration from
`aequitas-mas/tmp/openfathom/`).