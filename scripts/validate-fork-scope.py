#!/usr/bin/env python3
# OpenFathom delta — allowed by ADR-002 (amended by ADR-035 to add this file
# itself to the allow-list; the original ADR-002 named this check in its
# Consequences section but never listed it as a permitted file — that gap
# is what ADR-035 closes).
#
# Runs on every PR into `cloudrun` (see of-build-image.yml) and fails if the
# PR touches any file outside the fork's declared scope. Without this, only
# PR-review discipline protects the 7-file allow-list — the mitigation
# ADR-002 names but that, until now, was never wired into CI.

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
    }
)


def changed_files(base_ref: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"origin/{base_ref}...HEAD"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def main() -> int:
    base_ref = os.environ.get("GITHUB_BASE_REF") or (
        sys.argv[1] if len(sys.argv) > 1 else "cloudrun"
    )
    files = changed_files(base_ref)
    violations = sorted(f for f in files if f not in ALLOWED_FILES)

    if violations:
        print(
            "validate-fork-scope: this PR touches file(s) outside ADR-002's allowed scope:",
            file=sys.stderr,
        )
        for f in violations:
            print(f"  - {f}", file=sys.stderr)
        print(
            "\nADR-002 (openfathom-meta, amended by ADR-035) restricts this fork to:",
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

    print(f"validate-fork-scope: OK ({len(files)} file(s) changed, all within ADR-002 scope)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
