#!/usr/bin/env python3
# OpenFathom delta — allowed by ADR-002 (amended by ADR-035 to add this file
# itself to the allow-list; the original ADR-002 named this check in its
# Consequences section but never listed it as a permitted file — that gap
# is what ADR-035 closes).
#
# Runs on every PR into `cloudrun` (see of-build-image.yml) and fails if the
# PR touches any file outside the fork's declared scope. Without this, only
# PR-review discipline protects the allow-list — the mitigation ADR-002 names
# but that, until now, was never wired into CI.
#
# The count is deliberately NOT written out in prose here: this comment said
# "7-file" while ALLOWED_FILES below already held 8 (ADR-050 added the
# entrypoint test). `len(ALLOWED_FILES)` is the only count that cannot drift.

import os
import subprocess
import sys

ALLOWED_FILES = frozenset(
    {
        "Dockerfile.cloudrun",
        "scripts/cloudrun-entrypoint.sh",
        "docker-compose.cloudrun.yml",
        ".github/workflows/of-upstream-sync.yml",
        ".github/workflows/of-build-image.yml",
        "README.openfathom.md",
        "scripts/validate-fork-scope.py",
        # Added by ADR-050. The entrypoint grew to 740 lines of production-only edge cases
        # with no versioned test; the harness that proved ADR-048 died with its session.
        "scripts/test-cloudrun-entrypoint.sh",
    }
)


# WHY THE COMPARISON IS AGAINST UPSTREAM, NOT AGAINST THE PR's BASE.
#
# This check used to diff `origin/<base>...HEAD` -- "what did this PR change?".
# That reading made the check STRUCTURALLY FAIL the one mechanism ADR-002 exists
# to enable: the weekly upstream sync. Measured 2026-07-25 on the first real sync
# (PR #34, `cloudrun` 2824 commits behind): the rebase carried the whole upstream
# delta, so the PR "changed" thousands of core files and the check reported every
# one of them as a scope violation. The fork-scope guard made fork-scope
# maintenance unmergeable.
#
# The invariant ADR-002 actually states is not about a PR. It is about the FORK:
# *we differ from upstream in these files and no others*. So that is what gets
# measured -- `upstream/main...HEAD`, three dots, i.e. from the merge-base
# forward. Three dots and not two: between syncs upstream moves ahead of us, and
# a two-dot tree diff would report every commit we have not pulled yet as if we
# had deleted it.
#
# This is also STRICTER than what it replaces. The old form only saw the current
# PR, so drift that accumulated across several merged PRs was invisible to it;
# this form re-checks the whole fork surface on every run.
UPSTREAM_REF = os.environ.get("OF_UPSTREAM_REF", "upstream/main")


def _rev_exists(ref: str) -> bool:
    return subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
        capture_output=True,
        text=True,
    ).returncode == 0


def changed_files(upstream_ref: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{upstream_ref}...HEAD"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def main() -> int:
    upstream_ref = sys.argv[1] if len(sys.argv) > 1 else UPSTREAM_REF
    # FAIL CLOSED. Without the upstream ref this check has no ground truth, and a
    # guard that goes quiet when it loses its reference is worse than no guard --
    # it reports OK forever while nobody is watching the allow-list.
    if not _rev_exists(upstream_ref):
        print(
            f"validate-fork-scope: cannot resolve '{upstream_ref}' -- this check has lost "
            f"its ground truth and is comparing against nothing. The workflow must fetch "
            f"the upstream remote before running it (see of-build-image.yml), or pass a "
            f"resolvable ref as argv[1].",
            file=sys.stderr,
        )
        return 1
    files = changed_files(upstream_ref)
    violations = sorted(f for f in files if f not in ALLOWED_FILES)

    if violations:
        print(
            "validate-fork-scope: this PR touches file(s) outside ADR-002's allowed scope:",
            file=sys.stderr,
        )
        for f in violations:
            print(f"  - {f}", file=sys.stderr)
        print(
            "\nADR-002 (openfathom-meta, amended by ADR-035 and ADR-050) "
            f"restricts this fork to these {len(ALLOWED_FILES)} files:",
            file=sys.stderr,
        )
        for f in sorted(ALLOWED_FILES):
            print(f"  - {f}", file=sys.stderr)
        print(
            "\nA change to core hermes-agent code must be proposed to upstream first "
            "(ADR-002). A change to the allow-list itself needs an ADR amendment.",
            file=sys.stderr,
        )
        return 1

    print(
        f"validate-fork-scope: OK ({len(files)} file(s) differ from {upstream_ref}, "
        f"all within ADR-002 scope)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
