#!/usr/bin/env bash
# OpenFathom delta -- allowed by ADR-002 as amended by ADR-050 (which added this file to
# the allow-list; ADR-035 added the previous one).
#
# Regression test for the state-snapshot logic in scripts/cloudrun-entrypoint.sh.
#
# WHY THIS FILE EXISTS. The entrypoint decides whether the user's conversation is written
# or parked. It had no versioned test: the harness that proved the ADR-048 skill deposit
# lived in a scratch directory and died with the session that wrote it, which makes it a
# demonstration, not a test. ADR-050 admits this file so that stops being true.
#
# HOW IT AVOIDS LYING. The functions under test are EXTRACTED from the real script rather
# than copied here, so the test cannot drift from the shipped code -- the classic failure
# of shell tests. Network is stubbed at the `curl` boundary.
#
# EVERY MUTANT MUST DIE FOR THE RIGHT REASON. That distinction is not pedantry: the
# ADR-048 harness first "killed" a mutant on an empty tarball, i.e. for a reason unrelated
# to the rule under test, and reported a live rule as validated. Each mutant below
# therefore asserts the SPECIFIC wrong behaviour it should produce, not merely "differs".
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/cloudrun-entrypoint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -r "$ENTRYPOINT" ]] || { echo "FATAL: cannot read $ENTRYPOINT" >&2; exit 1; }

pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }

# ---------------------------------------------------------------------------
# Extract the functions under test straight out of the shipped script.
# ---------------------------------------------------------------------------
extract_fns() { # extract_fns <dest> [sed-mutation]
  local dest="$1" mutation="${2:-}"
  : > "$dest"
  local fn
  for fn in of_state_tarball_epoch of_state_messages_superset of_state_try_promote; do
    awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}' "$ENTRYPOINT" >> "$dest"
    echo >> "$dest"
  done
  grep -q "of_state_try_promote() {" "$dest" || { echo "FATAL: extraction failed" >&2; exit 1; }
  [[ -n "$mutation" ]] && sed -i "$mutation" "$dest"
  return 0
}

# ---------------------------------------------------------------------------
# Fixtures: build a state tarball with a given epoch and message list.
# ---------------------------------------------------------------------------
mk_state() { # mk_state <out.tar.gz> <epoch> <id:session:role:ts:content> ...
  local out="$1" epoch="$2"; shift 2
  local d; d="$(mktemp -d -p "$WORK")"
  [[ "$epoch" == "none" ]] || printf '%s\n' "$epoch" > "$d/.state_epoch"
  if [[ "${1:-}" != "nodb" ]]; then
    python3 - "$d/state.db" "$@" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table messages (id integer primary key, session_id text, role text, "
            "content text, timestamp real)")
for spec in sys.argv[2:]:
    mid, sess, role, ts, content = spec.split(":", 4)
    con.execute("insert into messages (id, session_id, role, content, timestamp) "
                "values (?,?,?,?,?)", (int(mid), sess, role, content, float(ts)))
con.commit(); con.close()
PY
  fi
  tar czf "$out" -C "$d" .
}

# ---------------------------------------------------------------------------
# Network stub. Dispatches on the URL; records every call so a test can assert
# that a request was NOT made, which is how the happy path is verified.
# ---------------------------------------------------------------------------
CALLS="$WORK/calls.log"
LIVE=""          # tarball served for ?alt=media; empty => HTTP 404
LIVE_GEN="42"    # generation reported by the metadata GET
UPLOADED="$WORK/uploaded.tar.gz"

of_metadata_token() { echo "stub-token"; }

curl() {
  local url="" out="" data="" method="GET" a prev=""
  for a in "$@"; do
    case "$prev" in -o) out="$a" ;; -X) method="$a" ;; esac
    case "$a" in
      https://*) url="$a" ;;
      --data-binary) ;;
      @*) data="${a#@}" ;;
    esac
    prev="$a"
  done
  echo "${method} ${url}" >> "$CALLS"

  if [[ "$url" == *"?alt=media"* ]]; then
    if [[ -n "$LIVE" && -f "$LIVE" ]]; then
      [[ -n "$out" ]] && cp -f "$LIVE" "$out"; echo "200"
    else
      echo "404"
    fi
    return 0
  fi
  if [[ "$method" == "DELETE" ]]; then echo "204"; return 0; fi
  if [[ "$url" == *"uploadType=media"* ]]; then
    [[ -n "$data" ]] && cp -f "$data" "$UPLOADED"
    echo "200"; return 0
  fi
  # Object metadata GET -> generation.
  printf '{"generation":"%s"}\n' "$LIVE_GEN"
}

reset_stub() { : > "$CALLS"; rm -f "$UPLOADED"; LIVE=""; LIVE_GEN="42"; }
promoted()  { [[ -f "$UPLOADED" ]] && echo yes || echo no; }
deleted()   { grep -q "^DELETE " "$CALLS" && echo yes || echo no; }

export HERMES_STATE_BUCKET="test-bucket"
export HERMES_STATE_OBJECT="gateway-state.tar.gz"

# `set -e` is ON in the real entrypoint. Each scenario runs the function with -e enabled
# so an unguarded non-zero -- which would abort the real shutdown path mid-way -- shows up
# here as a missing side effect rather than passing silently.
run_promote() { ( set -e; of_state_try_promote "$1" "conflict-x.tar.gz" "stub-token" ) 2>&1; }

FN="$WORK/fns.sh"
extract_fns "$FN"
# shellcheck disable=SC1090
source "$FN"

MINE="$WORK/mine.tar.gz"; THEIRS="$WORK/theirs.tar.gz"

echo "== case 1: superset, same epoch -> PROMOTES and removes the conflict =="
reset_stub
mk_state "$MINE"   3 1:s1:user:100:hello 2:s1:assistant:101:hi 3:s1:user:102:extra
mk_state "$THEIRS" 3 1:s1:user:100:hello 2:s1:assistant:101:hi
LIVE="$THEIRS"; of_state_epoch=3
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "promoted"            "yes" "$(promoted)"
check "conflict removed"    "yes" "$(deleted)"
check "says PROMOTED"       "1"   "$(echo "$out" | grep -c 'PROMOTED this state')"

echo "== case 2: genuine divergence -> does NOT promote, conflict stays =="
reset_stub
mk_state "$MINE"   3 1:s1:user:100:hello 2:s1:assistant:101:hi
mk_state "$THEIRS" 3 1:s1:user:100:hello 9:s2:user:200:only-in-live
LIVE="$THEIRS"; of_state_epoch=3
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "not promoted"        "no"  "$(promoted)"
check "conflict kept"       "no"  "$(deleted)"
check "names the reason"    "1"   "$(echo "$out" | grep -c 'NOT a superset')"

echo "== case 3: live object gone (404) -> does NOT promote (deliberate deletion) =="
reset_stub
mk_state "$MINE" 3 1:s1:user:100:hello
LIVE=""; of_state_epoch=3
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "not promoted"        "no"  "$(promoted)"
check "names the reason"    "1"   "$(echo "$out" | grep -c 'deleted deliberately')"

echo "== case 4: live epoch is NEWER -> does NOT promote (protects a reset) =="
reset_stub
mk_state "$MINE"   3 1:s1:user:100:hello 2:s1:user:101:more
mk_state "$THEIRS" 4          # curated reset tarball: newer epoch, no messages at all
LIVE="$THEIRS"; of_state_epoch=3
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "not promoted"        "no"  "$(promoted)"
check "names the reason"    "1"   "$(echo "$out" | grep -c 'deliberate reset')"

echo "== case 5: live has NO state.db -> fails closed even if the epoch guard is bypassed =="
reset_stub
mk_state "$MINE"   9 1:s1:user:100:hello
mk_state "$THEIRS" 0 nodb
LIVE="$THEIRS"; of_state_epoch=9
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "not promoted"        "no"  "$(promoted)"

echo "== case 6: epoch parsing =="
mk_state "$WORK/e1.tar.gz" 7 1:s:u:1:x
mk_state "$WORK/e2.tar.gz" none 1:s:u:1:x
check "reads the epoch"     "7"   "$(of_state_tarball_epoch "$WORK/e1.tar.gz")"
check "absent epoch  -> 0"  "0"   "$(of_state_tarball_epoch "$WORK/e2.tar.gz")"
check "garbage file  -> 0"  "0"   "$(of_state_tarball_epoch /dev/null)"

echo "== structural: promotion is wired AFTER the conflict is parked =="
# The ordering is the entire safety argument -- any interruption must leave the state
# parked exactly as before. A unit test cannot observe ordering inside of_state_snapshot,
# so assert it on the source: the call must sit inside the branch that confirms the park
# succeeded (HTTP 200), never before it.
park_line="$(grep -n 'conflict snapshot parked at' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
prom_line="$(grep -n '^ *of_state_try_promote "\$tarball"' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
if [[ -n "$park_line" && -n "$prom_line" && "$prom_line" -gt "$park_line" ]]; then
  ok "promotion call (line $prom_line) comes after the park confirmation (line $park_line)"
else
  bad "promotion is not provably after the park confirmation (park=$park_line promote=$prom_line)"
fi

# ---------------------------------------------------------------------------
# Mutants. Each asserts the SPECIFIC wrong behaviour, never just "differs".
# ---------------------------------------------------------------------------
echo "== MUTANTS =="

mutant() { # mutant <label> <sed-expr> <setup-fn> <expect-promoted>
  local label="$1" expr="$2" setup="$3" want="$4"
  extract_fns "$WORK/mut.sh" "$expr"
  if ! grep -q "$5" "$WORK/mut.sh"; then
    bad "$label: the mutation did not apply -- a mutant that does not mutate proves nothing"
    return
  fi
  ( # shellcheck disable=SC1090
    source "$WORK/mut.sh"
    reset_stub; $setup
    run_promote "$MINE" >/dev/null 2>&1
    [[ "$(promoted)" == "$want" ]] && echo MUTANT_KILLED > "$WORK/verdict" || echo MUTANT_SURVIVED > "$WORK/verdict"
  )
  if [[ "$(cat "$WORK/verdict")" == "MUTANT_KILLED" ]]; then
    ok "$label -- killed (it promoted when it must not)"
  else
    bad "$label -- SURVIVED: the guard it removes is not being exercised"
  fi
}

setup_divergent_same_ids() {
  # Same `id` values on both sides, DIFFERENT content: comparing by id reports a bogus
  # subset, comparing by content correctly refuses. This is the exact shape that four real
  # production snapshots had on 2026-07-20.
  mk_state "$MINE"   3 1:s1:user:100:hello 2:s1:assistant:101:mine-only
  mk_state "$THEIRS" 3 1:s1:user:100:hello 2:s1:assistant:101:LIVE-ONLY-DIFFERENT
  LIVE="$THEIRS"; of_state_epoch=3
}
# The mutation swaps `content` for the id, keeping every column a usable string. A cruder
# mutation (selecting `id` four times) made the comparison CRASH instead of answering
# wrongly -- and a mutant that dies of a traceback proves nothing about the guard, which
# is the precise trap this file's header warns about.
mutant "compare by id instead of content" \
  's|select session_id, role, content, timestamp from messages|select session_id, role, cast(id as text), timestamp from messages|' \
  setup_divergent_same_ids "yes" "cast(id as text)"

setup_reset_in_progress() {
  mk_state "$MINE"   3 1:s1:user:100:hello 2:s1:user:101:more
  mk_state "$THEIRS" 9   # a curated reset: newer epoch
  LIVE="$THEIRS"; of_state_epoch=3
}
mutant "epoch guard removed" \
  's|if \[\[ "${of_state_epoch:-0}" -lt "$live_epoch" \]\]; then|if false; then|' \
  setup_reset_in_progress "yes" "if false; then"

setup_missing_db() {
  mk_state "$MINE"   3 1:s1:user:100:hello
  mk_state "$THEIRS" 3 nodb
  LIVE="$THEIRS"; of_state_epoch=3
}
# Mutating the `is None` check alone only produces a TypeError. Mutating what keys()
# RETURNS is the faithful version: "a tarball with no state.db has an empty message set"
# is exactly the plausible-looking bug the guard exists to stop, and it promotes over a
# deliberately emptied state because everything is a superset of nothing.
mutant "empty-live guard removed (subset-of-nothing)" \
  's|^            return None$|            return set()|' \
  setup_missing_db "yes" "return set()"

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
