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
  for fn in of_state_read_local_epoch of_state_tarball_epoch of_state_messages_superset of_state_try_promote of_state_merge_messages of_state_snapshot_upload of_state_snapshot of_state_sync_loop of_gcs_read_generation of_memory_union of_memories_tarball_epoch of_memories_restore of_memories_snapshot of_memories_write_with_merge_retry of_memories_sync_loop; do
    awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}' "$ENTRYPOINT" >> "$dest"
    echo >> "$dest"
  done
  grep -q "of_state_try_promote() {" "$dest" || { echo "FATAL: extraction failed" >&2; exit 1; }
  [[ -n "$mutation" ]] && sed -i "$mutation" "$dest"
  return 0
}

# extract_one_fn <dest> <fn-name> [sed-mutation] -- like extract_fns, but pulls a SINGLE
# named function. Needed when a mutation's pattern is not unique across the whole bundle
# (sed's occurrence flag counts per LINE, not per file, so it cannot target "the 2nd
# occurrence of this line anywhere in the file") -- source the normal bundle first for
# unmutated dependencies, then source this file's single function on top to override it.
extract_one_fn() {
  local dest="$1" fn="$2" mutation="${3:-}"
  awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}' "$ENTRYPOINT" > "$dest"
  grep -q "${fn}() {" "$dest" || { echo "FATAL: extraction of $fn failed" >&2; exit 1; }
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
# Queue of upload response codes, one per line, FIFO. A FILE, not a bash array: every
# `code="$(curl ...)"` call in the real code is a command substitution, which forks a
# SUBSHELL -- an array mutated inside curl() there would vanish the moment that subshell
# exits, and every upload would keep seeing the same first element forever (confirmed:
# the first version of this stub did exactly that, silently, and every "412 then 200"
# scenario looped on 412 no matter how the queue was primed). A file write is real I/O
# and survives the subshell. Empty/absent -> "200" (every existing test leaves this
# unset and sees no behaviour change).
UPLOAD_CODES_FILE="$WORK/upload_codes"
set_upload_codes() { printf '%s\n' "$@" > "$UPLOAD_CODES_FILE"; }

# openfathom-meta ENG-136. Opt-in emulation of the REAL compare-and-swap, for the one
# property a scripted code queue cannot express: whether a 412 happens is a CONSEQUENCE
# of the generation the caller sent, not of what the test primed. A queue that hands out
# `412 200 412 200` passes against code that lost the union and against code that kept
# it, because the second 412 arrives no matter what the caller did -- exactly the shape
# of test the ENG-133 post-mortem calls "passing by coincidence".
#
# File-backed for the same reason UPLOAD_CODES_FILE is: the real code calls curl inside
# `code="$(curl ...)"`, a command-substitution subshell, so any variable this stub writes
# there evaporates. Reads of LIVE/LIVE_GEN survive; writes do not.
#
# Off unless a test calls cas_enable, so every existing case keeps the queue semantics.
CAS_GEN_FILE="$WORK/cas_gen"
CAS_LIVE="$WORK/cas_live.tar.gz"
CAS_ENFORCED=""
cas_enable() { # cas_enable <current generation> <tarball the live object holds>
  CAS_ENFORCED=1
  printf '%s\n' "$1" > "$CAS_GEN_FILE"
  cp -f "$2" "$CAS_LIVE"
}
cas_generation() { cat "$CAS_GEN_FILE"; }

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
    local served="$LIVE"
    [[ -n "$CAS_ENFORCED" ]] && served="$CAS_LIVE"
    if [[ -n "$served" && -f "$served" ]]; then
      [[ -n "$out" ]] && cp -f "$served" "$out"; echo "200"
    else
      echo "404"
    fi
    return 0
  fi
  if [[ "$method" == "DELETE" ]]; then echo "204"; return 0; fi
  # ENG-136. A conditional write under CAS mode: 412 unless the caller's generation is
  # the one the object actually carries. On success the object MOVES -- new bytes, new
  # generation -- which is what makes a second tick's stale generation fail.
  if [[ -n "$CAS_ENFORCED" && "$url" == *"uploadType=media"* && "$url" == *"ifGenerationMatch="* ]]; then
    local want="${url##*ifGenerationMatch=}"; want="${want%%&*}"
    if [[ "$want" != "$(cat "$CAS_GEN_FILE")" ]]; then echo "412"; return 0; fi
    if [[ -n "$data" ]]; then cp -f "$data" "$UPLOADED"; cp -f "$data" "$CAS_LIVE"; fi
    printf '%s\n' "$(( $(cat "$CAS_GEN_FILE") + 1 ))" > "$CAS_GEN_FILE"
    echo "200"
    return 0
  fi
  if [[ "$url" == *"uploadType=media"* ]]; then
    [[ -n "$data" ]] && cp -f "$data" "$UPLOADED"
    if [[ -s "$UPLOAD_CODES_FILE" ]]; then
      head -n1 "$UPLOAD_CODES_FILE"
      tail -n +2 "$UPLOAD_CODES_FILE" > "$UPLOAD_CODES_FILE.tmp"
      mv "$UPLOAD_CODES_FILE.tmp" "$UPLOAD_CODES_FILE"
    else
      echo "200"
    fi
    return 0
  fi
  # Object metadata GET -> generation.
  if [[ -n "$CAS_ENFORCED" ]]; then
    printf '{"generation":"%s"}\n' "$(cat "$CAS_GEN_FILE")"
  else
    printf '{"generation":"%s"}\n' "$LIVE_GEN"
  fi
}

reset_stub() { : > "$CALLS"; rm -f "$UPLOADED"; LIVE=""; LIVE_GEN="42"; CAS_ENFORCED=""; : > "$UPLOAD_CODES_FILE"; }
promoted()  { [[ -f "$UPLOADED" ]] && echo yes || echo no; }
deleted()   { grep -q "^DELETE " "$CALLS" && echo yes || echo no; }

export HERMES_STATE_BUCKET="test-bucket"
export HERMES_STATE_OBJECT="gateway-state.tar.gz"
# Real script declares this `readonly` at file scope (deliberately not an env var --
# see the comment there); extract_fns only pulls FUNCTION BODIES, not that top-level
# declaration, so the harness must supply it before sourcing anything that reads it.
OF_STATE_MERGE_MAX_ATTEMPTS=3

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

echo "== case 7: reading the local epoch must SURVIVE \`set -e\` when the file is absent =="
# THE REGRESSION THIS FILE FAILED TO CATCH THE FIRST TIME. The inline version of this read
# was `cat file 2>/dev/null | tr -cd '0-9'`; with no file, under `set -euo pipefail`, the
# whole boot died between "restored snapshot" and the next line. Production revision
# 00033-lcr never listened on PORT. The suite was green because the read lived inside
# of_state_restore, which the harness did not extract -- the untested line is the one that
# broke. Every case below runs with `-e` ON, because that is the condition that kills.
EPOCH_HOME="$WORK/epoch-home"; rm -rf "$EPOCH_HOME"; mkdir -p "$EPOCH_HOME"
read_epoch() { ( set -euo pipefail; HERMES_HOME="$EPOCH_HOME" of_state_read_local_epoch ); }

check "absent file  -> 0, no abort" "0"  "$(read_epoch; echo)"

# Status captured on its OWN line, never as an `if`/`&&`/`||` condition. Bash disables
# `set -e` for any command being used as a test -- and that suppression reaches INSIDE
# nested subshells. The first version of this assertion was
#   ( set -euo pipefail; ... ) && ok ... || bad ...
# which passed unconditionally, proving nothing, while testing for a `set -e` abort.
run_epoch_under_e() {
  ( set -euo pipefail; HERMES_HOME="$EPOCH_HOME" of_state_read_local_epoch >/dev/null 2>&1 )
  printf '%s' "$?"
}
check "absent file does not abort under set -e (00033-lcr)" "0" "$(run_epoch_under_e)"

printf '12\n' > "$EPOCH_HOME/.state_epoch"
check "reads a real epoch"          "12" "$(read_epoch)"
: > "$EPOCH_HOME/.state_epoch"
check "empty file   -> 0"           "0"  "$(read_epoch)"
printf 'garbage\n' > "$EPOCH_HOME/.state_epoch"
check "non-numeric  -> 0"           "0"  "$(read_epoch)"
printf ' 4 2 \n' > "$EPOCH_HOME/.state_epoch"
check "strips noise -> digits only" "42" "$(read_epoch)"
rm -f "$EPOCH_HOME/.state_epoch"

# ---------------------------------------------------------------------------
# Memory comparison (openfathom-meta ENG-66). Before this, of_state_messages_superset
# decided every promotion on messages alone -- memories/ rode along in the same tarball
# with nothing checked, so a promotion could be a message-superset and a memory-SUBSET,
# silently. Fixture below builds a minimal, identical state.db on both sides (so the
# message half of the decision is a no-op) and varies only memories/MEMORY.md, split by
# tools/memory_tool.py's own ENTRY_DELIMITER ("\n§\n") -- entry granularity, not
# whole-file bytes, so append-only growth or reordering must not read as "changed".
# ---------------------------------------------------------------------------
mk_state_with_memory() { # mk_state_with_memory <out.tar.gz> <epoch> <memory-relpath> <entry> [entry ...]
  local out="$1" epoch="$2" mem_rel="$3"; shift 3
  local d; d="$(mktemp -d -p "$WORK")"
  printf '%s\n' "$epoch" > "$d/.state_epoch"
  python3 - "$d/state.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table messages (id integer primary key, session_id text, role text, "
            "content text, timestamp real)")
con.execute("insert into messages (id, session_id, role, content, timestamp) "
            "values (1, 's1', 'user', 'hello', 100)")
con.commit(); con.close()
PY
  mkdir -p "$d/memories/$(dirname "$mem_rel")"
  local content="" e
  for e in "$@"; do
    [[ -n "$content" ]] && content+=$'\n§\n'
    content+="$e"
  done
  printf '%s' "$content" > "$d/memories/$mem_rel"
  tar czf "$out" -C "$d" .
}

echo "== case 8: memory superset, messages equal -> PROMOTES =="
reset_stub
mk_state_with_memory "$MINE"   3 "MEMORY.md" "user prefers pt-BR" "runs make check before push"
mk_state_with_memory "$THEIRS" 3 "MEMORY.md" "user prefers pt-BR"
LIVE="$THEIRS"; of_state_epoch=3
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "promoted"                        "yes" "$(promoted)"
check "mentions memory entries in the summary" "1" "$(echo "$out" | grep -c 'memory entries')"

echo "== case 9: memory divergence, messages equal -> does NOT promote (the ENG-66 gap) =="
reset_stub
mk_state_with_memory "$MINE"   3 "MEMORY.md" "user prefers pt-BR"
mk_state_with_memory "$THEIRS" 3 "MEMORY.md" "user prefers pt-BR" "LIVE-ONLY memory entry"
LIVE="$THEIRS"; of_state_epoch=3
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "not promoted (messages alone would have said yes)" "no" "$(promoted)"
check "names memory as the reason"      "1"   "$(echo "$out" | grep -c 'memory entry/entries exist only in the live snapshot')"

echo "== case 10: same entries, different order/whitespace -> still PROMOTES (entry-level, not whole-file)=="
reset_stub
mk_state_with_memory "$MINE"   3 "MEMORY.md" "  runs make check before push  " "user prefers pt-BR"
mk_state_with_memory "$THEIRS" 3 "MEMORY.md" "user prefers pt-BR" "runs make check before push"
LIVE="$THEIRS"; of_state_epoch=3
out="$(run_promote "$MINE")"; echo "$out" | sed 's/^/    | /'
check "promoted despite reordering/whitespace" "yes" "$(promoted)"

setup_memory_would_be_lost() {
  mk_state_with_memory "$MINE"   3 "MEMORY.md" "only-mine"
  mk_state_with_memory "$THEIRS" 3 "MEMORY.md" "only-mine" "LIVE-ONLY, would be lost"
  LIVE="$THEIRS"; of_state_epoch=3
}
echo "== MUTANT: memory comparison removed (the pre-ENG-66 behaviour) =="
mutant "memory check removed" \
  's|missing_mem = theirs_mem - mine_mem|missing_mem = set()|' \
  setup_memory_would_be_lost "yes" "missing_mem = set()"

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

# The regression mutant: restore the exact line that took production down, and prove the
# suite now refuses it. Without this, "we fixed it" rests on my word.
echo "== MUTANT: the 00033-lcr line, restored =="
# The mutation must be an ASSIGNMENT, exactly as the original was. A first attempt wrote
# `printf "%s" "$(cat ... | tr ...)"` and the mutant SURVIVED -- because a command
# substitution inside an argument does not trip `set -e`: printf itself succeeds. Only a
# plain assignment inherits the substitution's exit status. Getting this wrong would have
# shipped a regression test that could never fail.
extract_fns "$WORK/regress.sh" \
  's|^  local f="${HERMES_HOME:-/opt/data}/.state_epoch" v=""$|  of_state_epoch="$(cat "${HERMES_HOME:-/opt/data}/.state_epoch" 2>/dev/null \| tr -cd "0-9")"; printf "%s" "${of_state_epoch:-0}"; return|'
if grep -q 'cat "${HERMES_HOME' "$WORK/regress.sh"; then
  ( # shellcheck disable=SC1090
    source "$WORK/regress.sh"
    rm -f "$EPOCH_HOME/.state_epoch"
    # Same trap as above: the status must be captured on its own line. Wrapping this in
    # `if ( ... )` suppresses `set -e` inside the subshell and the mutant survives every
    # time -- which is exactly what happened on the first attempt.
    ( set -euo pipefail; HERMES_HOME="$EPOCH_HOME" of_state_read_local_epoch >/dev/null 2>&1 )
    rc=$?
    [[ "$rc" -eq 0 ]] && echo SURVIVED > "$WORK/regress.verdict" || echo KILLED > "$WORK/regress.verdict"
  )
  if [[ "$(cat "$WORK/regress.verdict")" == "KILLED" ]]; then
    ok "the original inline read still dies under set -e -- the guard is real"
  else
    bad "the original inline read no longer fails: this test proves nothing"
  fi
else
  bad "regression mutation did not apply"
fi

# ---------------------------------------------------------------------------
# of_state_merge_messages (openfathom-meta ENG-103) -- retry-with-merge for the CAS of
# messages. Unlike of_state_messages_superset (read-only comparison), this one WRITES:
# it copies rows that exist only in the live tarball into the destination db, so a
# retry of the conditional upload has a chance to succeed instead of parking on the
# first genuine divergence.
#
# hermes_state.py declares `messages.session_id TEXT NOT NULL REFERENCES sessions(id)`
# and opens the connection with `PRAGMA foreign_keys=ON` (hermes_state.py:1995) -- a
# message copied in without its session row violates the FK. The fixtures below build
# a real `sessions` table (mk_state()/mk_state_with_memory() above deliberately do not,
# and must keep not doing so -- changing them would ripple into every existing test).
# ---------------------------------------------------------------------------
mk_full_db() { # mk_full_db <out.db> <sessions:"id1,id2,..."> <id:session:role:ts:content> ...
  local out="$1" sessions_csv="$2"; shift 2
  python3 - "$out" "$sessions_csv" "$@" <<'PY'
import sqlite3, sys
db, sessions_csv = sys.argv[1], sys.argv[2]
specs = sys.argv[3:]
con = sqlite3.connect(db)
con.execute("PRAGMA foreign_keys=ON")
con.execute("create table sessions (id text primary key, title text)")
con.execute(
    "create table messages (id integer primary key, "
    "session_id text not null references sessions(id), role text, content text, "
    "timestamp real)"
)
for sid in [s for s in sessions_csv.split(",") if s]:
    con.execute("insert into sessions (id, title) values (?, ?)", (sid, "session " + sid))
for spec in specs:
    mid, sess, role, ts, content = spec.split(":", 4)
    con.execute(
        "insert into messages (id, session_id, role, content, timestamp) "
        "values (?,?,?,?,?)", (int(mid), sess, role, content, float(ts)))
con.commit(); con.close()
PY
}
mk_full_state() { # mk_full_state <out.tar.gz> <epoch> <sessions csv> <msg specs...>
  local out="$1" epoch="$2" sessions_csv="$3"; shift 3
  local d; d="$(mktemp -d -p "$WORK")"
  printf '%s\n' "$epoch" > "$d/.state_epoch"
  mk_full_db "$d/state.db" "$sessions_csv" "$@"
  tar czf "$out" -C "$d" .
}

echo "== case: of_state_merge_messages copies a missing message AND its session row (FK) =="
DEST_DB="$WORK/merge-dest.db"
mk_full_db "$DEST_DB" "s1" "1:s1:user:100:hello"
LIVE_MERGE_TB="$WORK/merge-live.tar.gz"
mk_full_state "$LIVE_MERGE_TB" 3 "s1,s2" "1:s1:user:100:hello" "2:s2:user:200:only-in-live"
merge_out="$(of_state_merge_messages "$DEST_DB" "$LIVE_MERGE_TB" 2>&1)"; merge_rc=$?
echo "$merge_out" | sed 's/^/    | /'
check "merge succeeds (exit 0)" "0" "$merge_rc"
check "session s2 copied" "1" "$(python3 -c "
import sqlite3
con = sqlite3.connect('$DEST_DB')
con.execute('PRAGMA foreign_keys=ON')
print(con.execute(\"select count(*) from sessions where id='s2'\").fetchone()[0])
")"
check "message only-in-live copied, readable under foreign_keys=ON" "1" "$(python3 -c "
import sqlite3
con = sqlite3.connect('$DEST_DB')
con.execute('PRAGMA foreign_keys=ON')
print(con.execute(\"select count(*) from messages where content='only-in-live'\").fetchone()[0])
")"
check "no duplicate of the message both sides already shared" "1" "$(python3 -c "
import sqlite3
con = sqlite3.connect('$DEST_DB')
print(con.execute(\"select count(*) from messages where content='hello'\").fetchone()[0])
")"

echo "== case: of_state_merge_messages -- schema too divergent (live has no content column) -> fails closed =="
DEST_DB2="$WORK/merge-dest2.db"
mk_full_db "$DEST_DB2" "s1" "1:s1:user:100:hello"
LIVE_TB2="$WORK/merge-live2.tar.gz"
d2="$(mktemp -d -p "$WORK")"
printf '3\n' > "$d2/.state_epoch"
python3 - "$d2/state.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table sessions (id text primary key, title text)")
con.execute("insert into sessions (id, title) values ('s2', 'session s2')")
# Deliberately missing `content` -- the shape of a schema too far apart to merge safely.
con.execute(
    "create table messages (id integer primary key, "
    "session_id text not null references sessions(id), role text, timestamp real)")
con.execute(
    "insert into messages (id, session_id, role, timestamp) values (2, 's2', 'user', 200)")
con.commit(); con.close()
PY
tar czf "$LIVE_TB2" -C "$d2" .
merge_out2="$(of_state_merge_messages "$DEST_DB2" "$LIVE_TB2" 2>&1)"; merge_rc2=$?
echo "$merge_out2" | sed 's/^/    | /'
check "merge fails closed on divergent schema (exit 4)" "4" "$merge_rc2"
check "names the missing column in the error" "1" "$(echo "$merge_out2" | grep -c 'content')"
check "dest untouched by a failed merge" "1" "$(python3 -c "
import sqlite3
con = sqlite3.connect('$DEST_DB2')
print(con.execute(\"select count(*) from messages\").fetchone()[0])
")"

echo "== MUTANT: of_state_merge_messages -- sessions copy removed =="
# Comments out the sessions INSERT via a SQL line-comment appended to the mutated string
# (the two f-string pieces concatenate into ONE line, so `--` blanks both the neutered
# insert AND the select that used to follow it). The FK (PRAGMA foreign_keys=ON) then
# refuses the message insert that references the now-missing session -- an unhandled
# IntegrityError, not a graceful non-zero: the mutant is killed by the merge CRASHING,
# which is still "did not succeed", the only thing the assertion below requires.
DEST_DB3="$WORK/merge-dest3.db"
mk_full_db "$DEST_DB3" "s1" "1:s1:user:100:hello"
LIVE_TB3="$WORK/merge-live3.tar.gz"
mk_full_state "$LIVE_TB3" 3 "s1,s2" "1:s1:user:100:hello" "2:s2:user:200:only-in-live"
extract_fns "$WORK/merge-mut1.sh" \
  's|insert or ignore into sessions ({sess_col_list}) |select 1 as noop where 0=1 -- |'
if grep -q 'select 1 as noop where 0=1' "$WORK/merge-mut1.sh"; then
  ( # shellcheck disable=SC1090
    source "$WORK/merge-mut1.sh"
    of_state_merge_messages "$DEST_DB3" "$LIVE_TB3" >/dev/null 2>&1
    echo "$?" > "$WORK/merge-mut1.rc"
  )
  mut1_rc="$(cat "$WORK/merge-mut1.rc")"
  check "sessions copy removed -- merge no longer succeeds (proves the FK copy is load-bearing)" \
    "1" "$([[ "$mut1_rc" != "0" ]] && echo 1 || echo 0)"
else
  bad "sessions-copy mutation did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== MUTANT: of_state_merge_messages -- schema-divergence guard removed =="
# Without the guard, a message missing a REQUIRED column (here: content) is not refused --
# it is merged anyway, silently dropping the column. That is the SPECIFIC wrong behaviour:
# not a crash, a quiet loss of message content.
extract_fns "$WORK/merge-mut2.sh" \
  's|if not REQUIRED.issubset(set(common_msg)):|if False:|'
if grep -q 'if False:' "$WORK/merge-mut2.sh"; then
  DEST_DB4="$WORK/merge-dest4.db"
  mk_full_db "$DEST_DB4" "s1" "1:s1:user:100:hello"
  d4="$(mktemp -d -p "$WORK")"
  printf '3\n' > "$d4/.state_epoch"
  python3 - "$d4/state.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table sessions (id text primary key, title text)")
con.execute("insert into sessions (id, title) values ('s2', 'session s2')")
con.execute(
    "create table messages (id integer primary key, "
    "session_id text not null references sessions(id), role text, timestamp real)")
con.execute(
    "insert into messages (id, session_id, role, timestamp) values (2, 's2', 'user', 200)")
con.commit(); con.close()
PY
  LIVE_TB4="$WORK/merge-live4.tar.gz"
  tar czf "$LIVE_TB4" -C "$d4" .
  ( # shellcheck disable=SC1090
    source "$WORK/merge-mut2.sh"
    of_state_merge_messages "$DEST_DB4" "$LIVE_TB4" >/dev/null 2>&1
    echo "$?" > "$WORK/merge-mut2.rc"
  )
  mut2_rc="$(cat "$WORK/merge-mut2.rc")"
  check "guard removed -- schema mismatch no longer fails closed (exit 4)" \
    "1" "$([[ "$mut2_rc" != "4" ]] && echo 1 || echo 0)"
else
  bad "schema-guard mutation did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# of_state_snapshot_upload (openfathom-meta ENG-103) -- the retry-with-merge loop that
# replaces of_state_snapshot's old inline "try once, park on 412" upload block. On a 412
# it downloads the live object, merges (of_state_merge_messages) and retries the
# conditional upload, up to OF_STATE_MERGE_MAX_ATTEMPTS times, before falling back to
# the existing park + of_state_try_promote path.
# ---------------------------------------------------------------------------
mk_upload_stage() { # mk_upload_stage <stage-dir> <epoch> <sessions csv> <msg specs...>
  local stage="$1" epoch="$2" sessions_csv="$3"; shift 3
  mkdir -p "$stage"
  mk_full_db "$stage/state.db" "$sessions_csv" "$@"
  printf '%s\n' "$epoch" > "$stage/.state_epoch"
}

echo "== case: of_state_snapshot_upload -- resolves on the 2nd attempt via merge, no park =="
reset_stub
STAGE1="$WORK/upload-stage1"; rm -rf "$STAGE1"
mk_upload_stage "$STAGE1" 3 "s1" "1:s1:user:100:hello"
TARBALL1="$WORK/upload-tb1.tar.gz"
tar czf "$TARBALL1" -C "$STAGE1" .
LIVE_FOR_RETRY="$WORK/upload-live1.tar.gz"
mk_full_state "$LIVE_FOR_RETRY" 3 "s1,s2" "1:s1:user:100:hello" "2:s2:user:200:only-in-live"
LIVE="$LIVE_FOR_RETRY"; set_upload_codes 412 200; of_state_generation=42; of_state_epoch=3
out="$(of_state_snapshot_upload "$STAGE1" "$TARBALL1" "stub-token" 2>&1)"; echo "$out" | sed 's/^/    | /'
check "no conflict object was ever uploaded" "0" "$(grep -c 'name=.*conflict-' "$CALLS")"
check "exactly 2 main-upload attempts happened" "2" "$(grep -c 'uploadType=media&name=gateway-state.tar.gz' "$CALLS")"
mkdir -p "$WORK/uploaded-extract1"; tar xzf "$UPLOADED" -C "$WORK/uploaded-extract1"
check "the merged message reached the uploaded tarball" "1" "$(python3 -c "
import sqlite3
con = sqlite3.connect('$WORK/uploaded-extract1/state.db')
print(con.execute(\"select count(*) from messages where content='only-in-live'\").fetchone()[0])
")"

echo "== case: of_state_snapshot_upload -- teto de tentativas esgotado -> parks =="
reset_stub
STAGE2="$WORK/upload-stage2"; rm -rf "$STAGE2"
mk_upload_stage "$STAGE2" 3 "s1" "1:s1:user:100:hello"
TARBALL2="$WORK/upload-tb2.tar.gz"
tar czf "$TARBALL2" -C "$STAGE2" .
LIVE="$LIVE_FOR_RETRY"; set_upload_codes 412 412 412; of_state_generation=42; of_state_epoch=3
out="$(of_state_snapshot_upload "$STAGE2" "$TARBALL2" "stub-token" 2>&1)"; echo "$out" | sed 's/^/    | /'
check "exactly 3 retry-loop attempts happened (the configured ceiling)" \
  "3" "$(echo "$out" | grep -cE 'restored \(attempt [0-9]+/3|still conflicting after 3 attempt')"
check "exactly 1 conflict object was parked" "1" "$(grep -c 'name=.*conflict-' "$CALLS")"
check "says still conflicting" "1" "$(echo "$out" | grep -c 'still conflicting after 3 attempt')"

echo "== case: of_state_snapshot_upload -- live epoch newer mid-retry -> aborts WITHOUT merging, parks =="
reset_stub
STAGE3="$WORK/upload-stage3"; rm -rf "$STAGE3"
mk_upload_stage "$STAGE3" 3 "s1" "1:s1:user:100:hello"
TARBALL3="$WORK/upload-tb3.tar.gz"
tar czf "$TARBALL3" -C "$STAGE3" .
LIVE_RESET_TB="$WORK/upload-live-reset.tar.gz"
mk_full_state "$LIVE_RESET_TB" 9 "s1" "1:s1:user:100:hello"   # epoch 9: a deliberate reset
LIVE="$LIVE_RESET_TB"; set_upload_codes 412; of_state_generation=42; of_state_epoch=3
out="$(of_state_snapshot_upload "$STAGE3" "$TARBALL3" "stub-token" 2>&1)"; echo "$out" | sed 's/^/    | /'
check "only 1 main-upload attempt -- the epoch guard aborted the retry, not the ceiling" \
  "1" "$(grep -c 'uploadType=media&name=gateway-state.tar.gz' "$CALLS")"
check "no merge was attempted" "0" "$(echo "$out" | grep -c 'merged.*message')"
check "names the deliberate reset (the retry loop's own guard, not just try_promote's)" \
  "1" "$(echo "$out" | grep -c 'deliberate reset happened, NOT merging')"
check "park succeeds (only 1 queued 412 -- the queue is empty by the time the park upload runs)" \
  "1" "$(echo "$out" | grep -c 'conflict snapshot parked at')"

echo "== MUTANT: of_state_snapshot_upload -- retry removed (parks on the FIRST 412, like before ENG-103) =="
extract_fns "$WORK/upload-mut.sh" \
  's|if \[\[ "\$attempt" -ge "\$max_attempts" \]\]; then|if true; then|'
if grep -q 'if true; then' "$WORK/upload-mut.sh"; then
  reset_stub
  STAGE4="$WORK/upload-stage4"; rm -rf "$STAGE4"
  mk_upload_stage "$STAGE4" 3 "s1" "1:s1:user:100:hello"
  TARBALL4="$WORK/upload-tb4.tar.gz"
  tar czf "$TARBALL4" -C "$STAGE4" .
  LIVE="$LIVE_FOR_RETRY"; set_upload_codes 412 200; of_state_generation=42; of_state_epoch=3
  ( # shellcheck disable=SC1090
    source "$WORK/upload-mut.sh"
    of_state_snapshot_upload "$STAGE4" "$TARBALL4" "stub-token" >/dev/null 2>&1
  )
  check "retry removed -- now parks after just 1 attempt (proves the retry is load-bearing)" \
    "1" "$(grep -c 'name=.*conflict-' "$CALLS")"
  check "retry removed -- never reaches the 2nd main-upload attempt" \
    "1" "$(grep -c 'uploadType=media&name=gateway-state.tar.gz' "$CALLS")"
else
  bad "retry-removal mutation did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# of_memory_union / of_memories_restore / of_memories_snapshot / of_memories_write_with_
# merge_retry (openfathom-meta ENG-103) -- memories move into their own CAS unit,
# independent of state.db's. Merge for memories is ALWAYS union-by-entry (never "genuine
# divergence" -- text union is safe and commutative by construction), gated by the same
# epoch guard ADR-049 already uses for messages, so a deliberate removal of a memory
# entry cannot be resurrected by a stale instance's own periodic sync.
# ---------------------------------------------------------------------------
DELIM_PY='"\n§\n"'  # tools/memory_tool.py::ENTRY_DELIMITER == "\n§\n"

mk_mem_file() { # mk_mem_file <root_dir> <relpath> <entry> [entry ...]
  local root="$1" rel="$2"; shift 2
  mkdir -p "$root/$(dirname "$rel")"
  python3 - "$root/$rel" "$@" <<PY
import sys
path = sys.argv[1]
entries = sys.argv[2:]
DELIM = $DELIM_PY
with open(path, "w", encoding="utf-8") as fh:
    fh.write(DELIM.join(entries))
PY
}

mem_file_entries() { # mem_file_entries <path> -- one parsed entry per line
  python3 - "$1" <<PY
import sys
path = sys.argv[1]
DELIM = $DELIM_PY
try:
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
except FileNotFoundError:
    raw = ""
for e in [e.strip() for e in raw.split(DELIM) if e.strip()]:
    print(e)
PY
}

mk_memories_tarball() { # mk_memories_tarball <out.tar.gz> <epoch> <relpath> <entry> [entry ...]
  local out="$1" epoch="$2" rel="$3"; shift 3
  local d; d="$(mktemp -d -p "$WORK")"
  printf '%s\n' "$epoch" > "$d/.memories_epoch"
  mk_mem_file "$d" "$rel" "$@"
  tar czf "$out" -C "$d" .
}

echo "== case: of_memory_union -- adds src-only entries, keeps dest's own =="
UDEST1="$WORK/union-dest1"; USRC1="$WORK/union-src1"; rm -rf "$UDEST1" "$USRC1"
mk_mem_file "$UDEST1" "MEMORY.md" "user prefers pt-BR"
mk_mem_file "$USRC1" "MEMORY.md" "user prefers pt-BR" "runs make check before push"
of_memory_union "$UDEST1" "$USRC1" >/dev/null 2>&1
check "dest gained the src-only entry" "1" "$(mem_file_entries "$UDEST1/MEMORY.md" | grep -c '^runs make check before push$')"
check "dest kept its own entry" "1" "$(mem_file_entries "$UDEST1/MEMORY.md" | grep -c '^user prefers pt-BR$')"
check "no duplicate of the shared entry" "1" "$(mem_file_entries "$UDEST1/MEMORY.md" | grep -c '^user prefers pt-BR$')"

echo "== case: of_memory_union -- commutative, order of application does not change the resulting set =="
UA="$WORK/union-a"; UB="$WORK/union-b"; rm -rf "$UA" "$UB"
mk_mem_file "$UA" "USER.md" "goal: ship OF-09"
mk_mem_file "$UB" "USER.md" "prefers dd/mm/yyyy dates"
COPY_A_UNION_B="$WORK/union-a-then-b"; rm -rf "$COPY_A_UNION_B"; cp -a "$UA" "$COPY_A_UNION_B"
of_memory_union "$COPY_A_UNION_B" "$UB" >/dev/null 2>&1
COPY_B_UNION_A="$WORK/union-b-then-a"; rm -rf "$COPY_B_UNION_A"; cp -a "$UB" "$COPY_B_UNION_A"
of_memory_union "$COPY_B_UNION_A" "$UA" >/dev/null 2>&1
SET1="$(mem_file_entries "$COPY_A_UNION_B/USER.md" | sort)"
SET2="$(mem_file_entries "$COPY_B_UNION_A/USER.md" | sort)"
check "union(A,B) and union(B,A) reach the same entry set" "1" "$([[ "$SET1" == "$SET2" ]] && echo 1 || echo 0)"
check "the resulting set has exactly 2 entries" "2" "$(mem_file_entries "$COPY_A_UNION_B/USER.md" | wc -l | tr -d ' ')"

echo "== case: of_memory_union -- .lock and .mem_*.tmp in src are ignored, .memories_epoch never merged as prose =="
UDEST2="$WORK/union-dest2"; USRC2="$WORK/union-src2"; rm -rf "$UDEST2" "$USRC2"
mkdir -p "$UDEST2" "$USRC2"
mk_mem_file "$USRC2" "MEMORY.md" "real entry"
printf 'garbage-mid-write' > "$USRC2/MEMORY.md.lock"
printf 'garbage-tmp' > "$USRC2/.mem_abc123.tmp"
printf '7\n' > "$USRC2/.memories_epoch"
of_memory_union "$UDEST2" "$USRC2" >/dev/null 2>&1
check "real entry copied" "1" "$(mem_file_entries "$UDEST2/MEMORY.md" | grep -c '^real entry$')"
check ".lock NOT copied into dest" "0" "$(find "$UDEST2" -name '*.lock' | wc -l | tr -d ' ')"
check ".mem_*.tmp NOT copied into dest" "0" "$(find "$UDEST2" -name '.mem_*.tmp' | wc -l | tr -d ' ')"
check ".memories_epoch NOT treated as a mergeable entry file" "0" "$([[ -e "$UDEST2/.memories_epoch" ]] && echo 1 || echo 0)"

echo "== MUTANT: of_memory_union -- union becomes substitution (dest_entries no longer kept) =="
extract_fns "$WORK/union-mut.sh" \
  's|merged = dest_entries + added|merged = added|'
if grep -q 'merged = added' "$WORK/union-mut.sh"; then
  UDEST3="$WORK/union-dest3"; USRC3="$WORK/union-src3"; rm -rf "$UDEST3" "$USRC3"
  mk_mem_file "$UDEST3" "MEMORY.md" "dest-only entry"
  mk_mem_file "$USRC3" "MEMORY.md" "src-only entry"
  (
    # shellcheck disable=SC1090
    source "$WORK/union-mut.sh"
    of_memory_union "$UDEST3" "$USRC3" >/dev/null 2>&1
  )
  check "substitution mutant -- dest-only entry LOST (proves union, not overwrite, is load-bearing)" \
    "0" "$(mem_file_entries "$UDEST3/MEMORY.md" | grep -c '^dest-only entry$')"
else
  bad "union-substitution mutation did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== case: of_memories_snapshot -- writes to its OWN object, never touches HERMES_STATE_OBJECT =="
reset_stub
MEM_HOME="$WORK/mem-home1"; rm -rf "$MEM_HOME"; mkdir -p "$MEM_HOME/memories"
mk_mem_file "$MEM_HOME/memories" "MEMORY.md" "user prefers pt-BR"
export HERMES_HOME="$MEM_HOME"
export HERMES_MEMORIES_OBJECT="memories.tar.gz"
of_memories_generation=42; of_state_epoch=3
out="$(of_memories_snapshot 2>&1)"; echo "$out" | sed 's/^/    | /'
check "uploaded to the memories object" "1" "$(grep -c 'uploadType=media&name=memories.tar.gz' "$CALLS")"
check "never touched the messages object" "0" "$(grep -c 'name=gateway-state.tar.gz' "$CALLS")"

echo "== case: of_memories_restore -- unions the live memories object into a fresh boot =="
reset_stub
MEM_HOME2="$WORK/mem-home2"; rm -rf "$MEM_HOME2"; mkdir -p "$MEM_HOME2/memories"
mk_mem_file "$MEM_HOME2/memories" "MEMORY.md" "carried over from a legacy combined tarball"
LIVE_MEM_TB="$WORK/live-memories.tar.gz"
mk_memories_tarball "$LIVE_MEM_TB" 3 "MEMORY.md" "user prefers pt-BR"
export HERMES_HOME="$MEM_HOME2"
LIVE="$LIVE_MEM_TB"
of_state_epoch=3   # ENG-104: same epoch as the tarball -- the honest boot, guard stays quiet
of_memories_restore >/dev/null 2>&1
check "kept what was already on disk" "1" "$(mem_file_entries "$MEM_HOME2/memories/MEMORY.md" | grep -c '^carried over from a legacy combined tarball$')"
check "merged in the entry from the memories object" "1" "$(mem_file_entries "$MEM_HOME2/memories/MEMORY.md" | grep -c '^user prefers pt-BR$')"

echo "== case: of_memories_write_with_merge_retry -- epoch guard aborts a resurrection attempt, does not merge =="
reset_stub
MEM_HOME3="$WORK/mem-home3"; rm -rf "$MEM_HOME3"; mkdir -p "$MEM_HOME3"
mk_mem_file "$MEM_HOME3" "MEMORY.md" "entry deliberately removed elsewhere"
LIVE_MEM_RESET="$WORK/live-memories-reset.tar.gz"
mk_memories_tarball "$LIVE_MEM_RESET" 9 "MEMORY.md"   # epoch 9: deliberate reset, entry gone
LIVE="$LIVE_MEM_RESET"; set_upload_codes 412 200; of_memories_generation=42; of_state_epoch=3
TARBALL_MEM3="$WORK/mem-tb3.tar.gz"; tar czf "$TARBALL_MEM3" -C "$MEM_HOME3" .
out="$(of_memories_write_with_merge_retry "$MEM_HOME3" "$TARBALL_MEM3" "stub-token" 2>&1)"; echo "$out" | sed 's/^/    | /'
check "only 1 upload attempt -- the epoch guard aborted, not the retry ceiling" \
  "1" "$(grep -c 'uploadType=media&name=memories.tar.gz' "$CALLS")"
check "names the deliberate reset" "1" "$(echo "$out" | grep -c 'deliberate reset happened, NOT merging')"
check "the removed entry was not resurrected onto the union target" "1" "$(mem_file_entries "$MEM_HOME3/MEMORY.md" | grep -c '^entry deliberately removed elsewhere$')"

echo "== MUTANT: of_memories_write_with_merge_retry -- epoch guard removed, resurrection succeeds =="
extract_one_fn "$WORK/mem-epoch-mut.sh" of_memories_write_with_merge_retry \
  's|if \[\[ "\${of_state_epoch:-0}" -lt "\$live_epoch" \]\]; then|if false; then|'
if grep -q 'if false; then' "$WORK/mem-epoch-mut.sh"; then
  reset_stub
  MEM_HOME4="$WORK/mem-home4"; rm -rf "$MEM_HOME4"; mkdir -p "$MEM_HOME4"
  mk_mem_file "$MEM_HOME4" "MEMORY.md" "entry deliberately removed elsewhere"
  LIVE="$LIVE_MEM_RESET"; set_upload_codes 412 200; of_memories_generation=42; of_state_epoch=3
  TARBALL_MEM4="$WORK/mem-tb4.tar.gz"; tar czf "$TARBALL_MEM4" -C "$MEM_HOME4" .
  (
    # shellcheck disable=SC1090
    source "$FN"
    # shellcheck disable=SC1090
    source "$WORK/mem-epoch-mut.sh"
    of_memories_write_with_merge_retry "$MEM_HOME4" "$TARBALL_MEM4" "stub-token" >/dev/null 2>&1
  )
  check "guard removed -- 2nd attempt now happens (the merge was NOT skipped)" \
    "2" "$(grep -c 'uploadType=media&name=memories.tar.gz' "$CALLS")"
  check "guard removed -- the deliberately-removed entry got resurrected onto the union target" \
    "1" "$(mem_file_entries "$MEM_HOME4/MEMORY.md" | grep -c '^entry deliberately removed elsewhere$')"
else
  bad "epoch-guard mutation did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# openfathom-meta ENG-104. The RESTORE end of the same round trip. The write path above
# refuses when the LIVE object is newer than us; this refuses when the DOWNLOADED tarball
# predates the epoch we just restored. Without it, a reset per
# openfathom-runbooks/docs/deploy/reset-gateway-state.md removed nothing: the operator
# curated the state, bumped .state_epoch, and the very next boot unioned every deleted
# memory straight back in from the untouched memories object.
# ---------------------------------------------------------------------------
echo "== case: of_memories_restore -- epoch guard refuses a tarball written before a deliberate reset =="
reset_stub
MEM_HOME7="$WORK/mem-home7"; rm -rf "$MEM_HOME7"; mkdir -p "$MEM_HOME7/memories"
mk_mem_file "$MEM_HOME7/memories" "USER.md" "the one entry the operator chose to keep"
LIVE_MEM_STALE="$WORK/live-memories-stale.tar.gz"
mk_memories_tarball "$LIVE_MEM_STALE" 3 "USER.md" "deliberately deleted in the reset"
export HERMES_HOME="$MEM_HOME7"
LIVE="$LIVE_MEM_STALE"
of_state_epoch=4   # the reset bumped .state_epoch to 4; the memories object is still at 3
out="$(of_memories_restore 2>&1)"; echo "$out" | sed 's/^/    | /'
check "names the deliberate reset instead of merging silently" \
  "1" "$(echo "$out" | grep -c 'predates ours')"
check "the deleted entry was NOT resurrected" \
  "0" "$(mem_file_entries "$MEM_HOME7/memories/USER.md" | grep -c '^deliberately deleted in the reset$')"
check "the curated entry survived untouched" \
  "1" "$(mem_file_entries "$MEM_HOME7/memories/USER.md" | grep -c '^the one entry the operator chose to keep$')"

echo "== case: of_memories_restore -- a tarball NEWER than ours still merges (guard is one-directional) =="
reset_stub
MEM_HOME8="$WORK/mem-home8"; rm -rf "$MEM_HOME8"; mkdir -p "$MEM_HOME8/memories"
mk_mem_file "$MEM_HOME8/memories" "USER.md" "on disk already"
LIVE_MEM_NEWER="$WORK/live-memories-newer.tar.gz"
mk_memories_tarball "$LIVE_MEM_NEWER" 7 "USER.md" "written after a reset we have not seen"
export HERMES_HOME="$MEM_HOME8"
LIVE="$LIVE_MEM_NEWER"
of_state_epoch=4
of_memories_restore >/dev/null 2>&1
check "a newer tarball is merged, not refused -- only the STALE direction is a resurrection" \
  "1" "$(mem_file_entries "$MEM_HOME8/memories/USER.md" | grep -c '^written after a reset we have not seen$')"

echo "== MUTANT: of_memories_restore -- restore epoch guard removed, the reset is undone at boot =="
extract_one_fn "$WORK/mem-restore-epoch-mut.sh" of_memories_restore \
  's|if \[\[ "\$tar_epoch" -lt "\${of_state_epoch:-0}" \]\]; then|if false; then|'
if grep -q 'if false; then' "$WORK/mem-restore-epoch-mut.sh"; then
  reset_stub
  MEM_HOME9="$WORK/mem-home9"; rm -rf "$MEM_HOME9"; mkdir -p "$MEM_HOME9/memories"
  mk_mem_file "$MEM_HOME9/memories" "USER.md" "the one entry the operator chose to keep"
  LIVE="$LIVE_MEM_STALE"
  export HERMES_HOME="$MEM_HOME9"
  of_state_epoch=4
  (
    # shellcheck disable=SC1090
    source "$FN"
    # shellcheck disable=SC1090
    source "$WORK/mem-restore-epoch-mut.sh"
    of_memories_restore >/dev/null 2>&1
  )
  check "guard removed -- the deleted entry comes back at boot (this is the ENG-104 defect)" \
    "1" "$(mem_file_entries "$MEM_HOME9/memories/USER.md" | grep -c '^deliberately deleted in the reset$')"
else
  bad "restore epoch-guard mutation did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== case: of_memories_write_with_merge_retry -- generation carries forward after a successful write =="
# Without this, the NEXT periodic tick (Passo 3) would still target the generation this
# instance restored with -- which the GCS object has already moved past -- and every
# single subsequent cycle would spuriously 412 into a merge it never needed.
reset_stub
MEM_HOME5="$WORK/mem-home5"; rm -rf "$MEM_HOME5"; mkdir -p "$MEM_HOME5"
mk_mem_file "$MEM_HOME5" "MEMORY.md" "entry"
TARBALL_MEM5="$WORK/mem-tb5.tar.gz"; tar czf "$TARBALL_MEM5" -C "$MEM_HOME5" .
of_memories_generation=1; LIVE_GEN="77"
of_memories_write_with_merge_retry "$MEM_HOME5" "$TARBALL_MEM5" "stub-token" >/dev/null 2>&1
check "of_memories_generation updated to the freshly-read generation after a successful write" \
  "77" "$of_memories_generation"

echo "== MUTANT: of_memories_write_with_merge_retry -- generation no longer updated after a successful write =="
extract_one_fn "$WORK/mem-gen-mut.sh" of_memories_write_with_merge_retry \
  's|of_memories_generation="\$(of_gcs_read_generation.*)"|: # NEUTERED|'
if grep -q ': # NEUTERED' "$WORK/mem-gen-mut.sh"; then
  reset_stub
  MEM_HOME6="$WORK/mem-home6"; rm -rf "$MEM_HOME6"; mkdir -p "$MEM_HOME6"
  mk_mem_file "$MEM_HOME6" "MEMORY.md" "entry"
  TARBALL_MEM6="$WORK/mem-tb6.tar.gz"; tar czf "$TARBALL_MEM6" -C "$MEM_HOME6" .
  of_memories_generation=1; LIVE_GEN="77"
  (
    # shellcheck disable=SC1090
    source "$FN"
    # shellcheck disable=SC1090
    source "$WORK/mem-gen-mut.sh"
    of_memories_write_with_merge_retry "$MEM_HOME6" "$TARBALL_MEM6" "stub-token" >/dev/null 2>&1
    echo "$of_memories_generation" > "$WORK/mem-gen-mut.out"
  )
  check "generation-update removed -- stays stale at the pre-write value (proves the re-read is load-bearing)" \
    "1" "$(cat "$WORK/mem-gen-mut.out")"
else
  bad "generation-update mutation did not apply -- a mutant that does not mutate proves nothing"
fi
unset HERMES_HOME HERMES_MEMORIES_OBJECT

# ---------------------------------------------------------------------------
# of_memories_sync_loop (openfathom-meta ENG-103, Passo 3) -- periodic persistence so a
# crash (SIGKILL, not graceful SIGTERM) loses at most one interval's worth of memories
# instead of everything since the last shutdown-triggered snapshot.
# ---------------------------------------------------------------------------
echo "== case: of_memories_sync_loop -- runs at least 2 cycles with a short interval =="
reset_stub
MEM_HOME7="$WORK/mem-home7"; rm -rf "$MEM_HOME7"; mkdir -p "$MEM_HOME7/memories"
mk_mem_file "$MEM_HOME7/memories" "MEMORY.md" "entry"
export HERMES_HOME="$MEM_HOME7"
export HERMES_MEMORIES_OBJECT="memories.tar.gz"
export HERMES_MEMORY_SYNC_INTERVAL_SECONDS="0.2"
of_memories_generation=1; of_state_epoch=0
LOOP_LOG="$WORK/loop-cycles.log"
( of_memories_sync_loop > "$LOOP_LOG" 2>&1 ) &
loop_pid=$!
sleep 0.9
kill -TERM "$loop_pid" 2>/dev/null || true
wait "$loop_pid" 2>/dev/null || true
cycles="$(grep -c 'snapshot uploaded to gs://test-bucket/memories.tar.gz' "$LOOP_LOG")"
check "at least 2 sync cycles ran in ~0.9s at a 0.2s interval" "1" "$([[ "$cycles" -ge 2 ]] && echo 1 || echo 0)"

echo "== case: of_memories_sync_loop -- an entry written mid-session survives a HARD kill (SIGKILL, never of_on_term) =="
reset_stub
MEM_HOME8="$WORK/mem-home8"; rm -rf "$MEM_HOME8"; mkdir -p "$MEM_HOME8/memories"
mk_mem_file "$MEM_HOME8/memories" "MEMORY.md" "entry written before boot"
export HERMES_HOME="$MEM_HOME8"
export HERMES_MEMORIES_OBJECT="memories.tar.gz"
export HERMES_MEMORY_SYNC_INTERVAL_SECONDS="0.2"
of_memories_generation=1; of_state_epoch=0
( of_memories_sync_loop > /dev/null 2>&1 ) &
loop8_pid=$!
sleep 0.3   # let >=1 tick complete
mk_mem_file "$MEM_HOME8/memories" "MEMORY.md" "entry written before boot" "entry written mid-session, never gracefully shut down"
sleep 0.3   # let a tick pick up the new entry
kill -9 "$loop8_pid" 2>/dev/null || true   # SIGKILL -- of_on_term, of_state_snapshot, of_memories_snapshot's final flush NEVER run
wait "$loop8_pid" 2>/dev/null || true
mkdir -p "$WORK/crash-extract8"; tar xzf "$UPLOADED" -C "$WORK/crash-extract8" 2>/dev/null
check "the mid-session entry reached GCS through a periodic tick, with no graceful shutdown at all" \
  "1" "$(mem_file_entries "$WORK/crash-extract8/MEMORY.md" | grep -c '^entry written mid-session, never gracefully shut down$')"

echo "== case: of_memories_sync_loop -- TERM interrupts immediately, does not wait out the interval =="
reset_stub
export HERMES_MEMORY_SYNC_INTERVAL_SECONDS="5"
of_memories_generation=1; of_state_epoch=0
( of_memories_sync_loop > /dev/null 2>&1 ) &
loop_pid=$!
sleep 0.2   # let it enter its sleep phase
before="$SECONDS"
kill -TERM "$loop_pid" 2>/dev/null || true
wait "$loop_pid" 2>/dev/null || true
elapsed=$((SECONDS - before))
check "TERM was honored well under the 5s interval" "1" "$([[ "$elapsed" -le 1 ]] && echo 1 || echo 0)"

# No mutant for the TERM/INT trap itself: measured directly (a probe outside this
# harness, not kept here) -- bash's DEFAULT disposition for an untrapped SIGTERM already
# terminates a process blocked in `wait` immediately, so removing the trap does not
# change the elapsed-time behaviour the two scenarios above check, and asserting
# otherwise would be exactly the "differs for a reason unrelated to the rule under test"
# failure this file's own header warns against. The trap's real value is a clean exit
# code (0, not 143) and no stray "Terminated" message -- neither observable here, since
# the caller (of_on_term) never `wait`s on this pid or inspects its exit status. Kept in
# production code as defensive style, consistent with the of_gateway_pid trap pattern.
unset HERMES_MEMORY_SYNC_INTERVAL_SECONDS

# ---------------------------------------------------------------------------
# of_plugins_fetch (ADR-052) -- same fail-loud contract as of_skills_fetch: it
# must REFUSE a tarball that would leave $HERMES_HOME/plugins/ without a plugin.yaml,
# so the caller never enables a plugin that is not on disk (the of-skills SKILL.md
# guard, one level over). Extracted from the shipped script; curl/of_metadata_token
# are already stubbed at the top.
# ---------------------------------------------------------------------------
echo "== case: of_plugins_fetch =="
PLUG_FN="$WORK/plug.sh"
awk '/^of_plugins_fetch\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" > "$PLUG_FN"
grep -q "of_plugins_fetch() {" "$PLUG_FN" || { echo "FATAL: of_plugins_fetch extraction failed" >&2; exit 1; }
# shellcheck disable=SC1090
source "$PLUG_FN"
export HERMES_PLUGINS_OBJECT="plugins.tar.gz"

mk_plugin_tarball() { # <out> -- a tarball Hermes would load: delegation-tasks/plugin.yaml
  local out="$1" d; d="$(mktemp -d -p "$WORK")"
  mkdir -p "$d/delegation-tasks"
  printf 'name: delegation-tasks\n' > "$d/delegation-tasks/plugin.yaml"
  tar czf "$out" -C "$d" .
}
mk_no_manifest_tarball() { # <out> -- non-empty, but no plugin.yaml anywhere
  local out="$1" d; d="$(mktemp -d -p "$WORK")"
  printf 'x\n' > "$d/readme.txt"
  tar czf "$out" -C "$d" .
}

PLUG_OK="$WORK/plug-ok.tar.gz"; mk_plugin_tarball "$PLUG_OK"
PLUG_NO="$WORK/plug-no.tar.gz"; mk_no_manifest_tarball "$PLUG_NO"
PDIR="$WORK/plugdest"

reset_stub; LIVE="$PLUG_OK"
of_plugins_fetch "$PDIR" >/dev/null 2>&1; rc=$?
check "valid plugin tarball -> fetch ok"       "0"   "$rc"
check "plugin.yaml landed in dest"             "yes" "$([[ -f "$PDIR/delegation-tasks/plugin.yaml" ]] && echo yes || echo no)"

reset_stub; LIVE="$PLUG_NO"
of_plugins_fetch "$PDIR" >/dev/null 2>&1; rc=$?
check "tarball with no plugin.yaml -> refuses" "1"   "$rc"

reset_stub; LIVE=""   # HTTP 404 from the stub
of_plugins_fetch "$PDIR" >/dev/null 2>&1; rc=$?
check "404 -> refuses (publish step skipped)"  "1"   "$rc"

echo "== structural: the plugin is enabled ONLY after a successful fetch =="
# A failed fetch must not leave plugins.enabled pointing at a plugin not on disk. Assert
# on the source that the enable write sits after the of_plugins_fetch guard.
fetch_guard="$(grep -n 'if of_plugins_fetch "\$of_plugins_dir"; then' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
enable_write="$(grep -n '_set_nested(cfg, "plugins.enabled"' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
if [[ -n "$fetch_guard" && -n "$enable_write" && "$enable_write" -gt "$fetch_guard" ]]; then
  ok "plugins.enabled write (line $enable_write) is inside the of_plugins_fetch guard (line $fetch_guard)"
else
  bad "plugin enable is not provably after the fetch guard (guard=$fetch_guard enable=$enable_write)"
fi
check "approvals.mode pinned to manual (the gate bypasses under off)" \
  "1" "$(grep -c '_set_nested(cfg, "approvals.mode", "manual")' "$ENTRYPOINT")"
# The enable must be DYNAMIC -- enumerate the delivered dir, not a hardcoded plugin name --
# so a second plugin (get_current_time) is enabled by a re-published tarball, no fork change.
check "plugin enable enumerates the delivered dir (not a hardcoded name)" \
  "1" "$(grep -c 'os.listdir(plugins_dir)' "$ENTRYPOINT")"

echo "== MUTANT: of_plugins_fetch without the plugin.yaml guard =="
awk '/^of_plugins_fetch\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" \
  | sed 's|if \[\[ "$n" -eq 0 \]\]; then|if false; then|' > "$WORK/plug-mut.sh"
if grep -q "if false; then" "$WORK/plug-mut.sh"; then
  reset_stub; LIVE="$PLUG_NO"
  # Guarded version refused PLUG_NO with rc 1 above; with the guard gone it accepts the
  # manifest-less tarball (rc 0) -- the fail-open the guard exists to stop.
  mrc="$( source "$WORK/plug-mut.sh"; of_plugins_fetch "$WORK/pm" >/dev/null 2>&1; echo "$?" )"
  check "guard removed -> empty tarball accepted (rc 0); the guard is load-bearing" "0" "$mrc"
else
  bad "plugin mutant did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# openfathom-meta ENG-83: fallback_providers config + the aux-model hardcoding
# bug it exposed. Structural checks (grep on the shipped script), same style as
# approvals.mode/plugins.enabled above -- these blocks call into hermes_cli
# internals not importable in this bash-only test job, so the check proves the
# CORRECT call is present rather than executing it.
# ---------------------------------------------------------------------------
echo "== structural: ENG-83 fallback_providers + aux model =="
# NOT vertex: a real smoke test (openfathom-meta, 2026-07-25) proved a vertex
# fallback entry never activates (PROVIDER_REGISTRY mismatch, see the entrypoint
# comment above this line's target) -- gemini is the entry that actually works.
check "fallback_providers set to gemini/gemini-3.6-flash" \
  "1" "$(grep -c '_set_nested(cfg, "fallback_providers", \[{"provider": "gemini", "model": "gemini-3.6-flash"}\])' "$ENTRYPOINT")"
# The regression this guards: the aux model was hardcoded to the OpenRouter
# routing slug (anthropic/claude-haiku-4.5), silently wrong the moment
# HERMES_INFERENCE_PROVIDER stops being openrouter. Asserting the hardcoded
# slug is GONE, not just that the new line exists, is what makes this a
# regression test rather than an addition test.
check "aux compression model no longer hardcoded to the OpenRouter slug" \
  "0" "$(grep -c 'auxiliary.compression.model         anthropic/claude-haiku-4.5' "$ENTRYPOINT")"
check "aux compression model follows HERMES_INFERENCE_MODEL" \
  "1" "$(grep -c 'hermes config set auxiliary.compression.model         "\${HERMES_INFERENCE_MODEL}"' "$ENTRYPOINT")"
check "aux title_generation model follows HERMES_INFERENCE_MODEL" \
  "1" "$(grep -c 'hermes config set auxiliary.title_generation.model    "\${HERMES_INFERENCE_MODEL}"' "$ENTRYPOINT")"

# openfathom-meta ENG-47: display.language pt, and the stale comment claiming pt is
# unsupported is gone. Both checked because the second is the actual regression this
# guards against -- a comment that drifted true-to-false silently once already.
check "display.language set to pt" \
  "1" "$(grep -c 'hermes config set display.language pt' "$ENTRYPOINT")"
check "stale 'display.language does not accept pt' claim is gone" \
  "0" "$(grep -c 'display.language does not accept pt' "$ENTRYPOINT")"

# openfathom-meta ENG-84: model.max_tokens ceiling, so an unbounded 64k default
# request never again triggers OpenRouter's HTTP 402 preflight-balance rejection.
# Structural check, same reasoning as ENG-83 above -- hermes_cli internals aren't
# importable in this bash-only test job.
check "model.max_tokens set to a realistic ceiling, unconditionally" \
  "1" "$(grep -c 'hermes config set model.max_tokens 12000' "$ENTRYPOINT")"

# openfathom-meta ENG-101: prompt_caching.cache_ttl 1h, so a >5-minute pause between
# Telegram turns no longer forces a 1.25x cache write where a 0.1x cache read would do.
# Structural check, same reasoning as model.max_tokens above.
check "prompt_caching.cache_ttl set to 1h, unconditionally" \
  "1" "$(grep -c 'hermes config set prompt_caching.cache_ttl 1h' "$ENTRYPOINT")"

# ---------------------------------------------------------------------------
# of_skill_usage_report (openfathom-meta ADR-053) -- derives the skill_invocations
# log-based metric from the .usage.json sidecar Hermes already writes natively.
# Extracted standalone, same style as of_plugins_fetch above (it is not part of
# the state-promotion cluster extract_fns pulls). No network stub needed: this
# function never touches curl/of_metadata_token, only stdout.
# ---------------------------------------------------------------------------
echo "== case: of_skill_usage_report =="
USAGE_FN="$WORK/usage.sh"
awk '/^of_skill_usage_report\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" > "$USAGE_FN"
grep -q "of_skill_usage_report() {" "$USAGE_FN" || { echo "FATAL: of_skill_usage_report extraction failed" >&2; exit 1; }
# shellcheck disable=SC1090
source "$USAGE_FN"

USAGE_HOME="$WORK/usage-home"
run_usage_report() { ( set -euo pipefail; HERMES_HOME="$USAGE_HOME" of_skill_usage_report ); }

mk_usage_json() { # mk_usage_json <raw-json-body>
  rm -rf "$USAGE_HOME"; mkdir -p "$USAGE_HOME/skills"
  printf '%s' "$1" > "$USAGE_HOME/skills/.usage.json"
}

mk_usage_json '{"arch-brainstorm": {"use_count": 3}, "unused-skill": {"use_count": 0}}'
out="$(run_usage_report)"; echo "$out" | sed 's/^/    | /'
check "one line per use (used skill)"      "3" "$(grep -c '^\[of-skill-usage\] skill=arch-brainstorm ' <<<"$out")"
check "zero lines for an unused skill"     "0" "$(grep -c 'unused-skill' <<<"$out")"
check "occurrence numbering, first line"   "1" "$(grep -c '^\[of-skill-usage\] skill=arch-brainstorm occurrence=1/3$' <<<"$out")"
check "occurrence numbering, last line"    "1" "$(grep -c '^\[of-skill-usage\] skill=arch-brainstorm occurrence=3/3$' <<<"$out")"

rm -rf "$USAGE_HOME"
out="$(run_usage_report)"; echo "$out" | sed 's/^/    | /'
check "missing .usage.json -> no crash, says so" "1" "$(grep -c 'no .usage.json this session' <<<"$out")"

mk_usage_json 'not valid json{{{'
out="$( ( set -euo pipefail; HERMES_HOME="$USAGE_HOME" of_skill_usage_report ) 2>&1 )"; echo "$out" | sed 's/^/    | /'
check "corrupt .usage.json -> WARN, does not abort under set -e" \
  "1" "$(grep -c 'WARN: could not parse' <<<"$out")"

# A skill name is a directory basename Hermes itself created, but an autogenerated
# skill's name traces back to model output on untrusted input (Dogma 5 / ADR-029).
# `\n` here is a real JSON escape -- the loaded Python string contains an actual
# newline, which is exactly what a name-based log-injection attempt would look like:
# an attacker-controlled skill name trying to forge an extra, unrelated log line.
mk_usage_json '{"evil\nname": {"use_count": 1}, "fine-name": {"use_count": 1}}'
out="$(run_usage_report)"; echo "$out" | sed 's/^/    | /'
check "name failing the character class is skipped, not printed" \
  "0" "$(grep -c 'evil' <<<"$out")"
check "a well-formed name alongside it still prints" \
  "1" "$(grep -c '^\[of-skill-usage\] skill=fine-name occurrence=1/1$' <<<"$out")"

echo "== MUTANT: of_skill_usage_report without the name character-class guard =="
awk '/^of_skill_usage_report\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" \
  | sed 's|not NAME_RE.match(name)|False|' > "$WORK/usage-mut.sh"
if grep -q 'or False:' "$WORK/usage-mut.sh"; then
  mk_usage_json '{"evil\nname": {"use_count": 1}}'
  mut_out="$( ( set -euo pipefail
    # shellcheck disable=SC1090
    source "$WORK/usage-mut.sh"
    HERMES_HOME="$USAGE_HOME" of_skill_usage_report
  ) )"
  check "guard removed -> the malicious name now reaches stdout (proves the guard is load-bearing)" \
    "1" "$(grep -c 'evil' <<<"$mut_out")"
else
  bad "usage-report mutant did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# openfathom-meta ENG-81 (skills half) -- of_soul_capabilities_block. Boot-computed
# capabilities summary appended to SOUL.md instead of a hand-written list that drifts
# (or a doc the Sonda might never read). Extracted standalone, same style as
# of_skill_usage_report above. Parses requires_toolsets with the same nesting rule
# openfathom-skills' lint_skills.py declared_toolsets() enforces at review time.
# ---------------------------------------------------------------------------
echo "== case: of_soul_capabilities_block =="
CAPS_FN="$WORK/caps.sh"
awk '/^of_soul_capabilities_block\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" > "$CAPS_FN"
grep -q "of_soul_capabilities_block() {" "$CAPS_FN" || { echo "FATAL: of_soul_capabilities_block extraction failed" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CAPS_FN"

of_disabled_toolsets=(terminal code_execution image_gen video_gen tts)

mk_skill() { # mk_skill <dir> <name> <toolsets-yaml-inline-list>
  local dir="$1" name="$2" toolsets="$3"
  mkdir -p "$dir"
  cat > "$dir/SKILL.md" <<EOF
---
name: $name
metadata:
  hermes:
    requires_toolsets: $toolsets
---
body
EOF
}

CAPS_HOME="$WORK/caps-skills"
rm -rf "$CAPS_HOME"; mkdir -p "$CAPS_HOME/shared" "$CAPS_HOME/academic"
mk_skill "$CAPS_HOME/shared/citation-format" "citation-format" "[]"
mk_skill "$CAPS_HOME/academic/pr-triage" "pr-triage" "[terminal]"

run_caps() { ( set -euo pipefail; of_skills_dir="$CAPS_HOME" of_soul_capabilities_block ); }

out="$(run_caps)"; echo "$out" | sed 's/^/    | /'
check "header present" \
  "1" "$(grep -c '^## Skills disponíveis agora' <<<"$out")"
check "toolset-free skill listed as available" \
  "1" "$(grep -c '^- citation-format$' <<<"$out")"
check "toolset-requiring skill listed as unavailable, with reason" \
  "1" "$(grep -c '^- pr-triage (precisa: terminal)$' <<<"$out")"
check "unavailable skill NOT also listed under Disponíveis" \
  "0" "$(awk '/^Disponíveis:/{f=1;next}/^$/{f=0}f' <<<"$out" | grep -c '^- pr-triage$')"

echo "== case: of_soul_capabilities_block with no skills directory this boot =="
run_caps_absent() { ( set -euo pipefail; of_skills_dir="$WORK/does-not-exist" of_soul_capabilities_block ); }
check "no dir -> empty block (Dogma 2: degrade, don't error)" "" "$(run_caps_absent)"

echo "== MUTANT: of_soul_capabilities_block without the disabled-toolset intersection guard =="
sed 's|missing = sorted(set(toolsets) & disabled)|missing = []|' "$CAPS_FN" > "$WORK/caps-mut.sh"
if grep -q 'missing = \[\]' "$WORK/caps-mut.sh"; then
  mut_out="$( ( set -euo pipefail
    # shellcheck disable=SC1090
    source "$WORK/caps-mut.sh"
    of_disabled_toolsets=(terminal code_execution image_gen video_gen tts)
    of_skills_dir="$CAPS_HOME" of_soul_capabilities_block
  ) )"
  check "guard removed -> a skill needing a disabled toolset now leaks into Disponíveis (proves the guard is load-bearing)" \
    "1" "$(awk '/^Disponíveis:/{f=1;next}/^Carregadas/{f=0}f' <<<"$mut_out" | grep -c '^- pr-triage$')"
else
  bad "capabilities mutant did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# of_skills_inbox_genuine_dirs (openfathom-meta ENG-88) -- the Dogma 5 review-queue
# discriminator. Extracted standalone, same style as of_skill_usage_report above.
# Regression target: a skill's on-disk DIRECTORY NAME can differ from the `name:`
# in its own SKILL.md frontmatter (upstream renamed 4 bundled skills this way on
# 2026-07-23, commit 503da4e30) -- the OLD basename-only match against
# .bundled_manifest (keyed by frontmatter name) missed all four, every boot,
# depositing them into skills-inbox/ as if the agent had written them (measured:
# 20 objects, 1 genuine). No network stub needed: this function never touches
# curl/of_metadata_token, only stdout/stderr.
# ---------------------------------------------------------------------------
echo "== case: of_skills_inbox_genuine_dirs =="
INBOX_FN="$WORK/inbox.sh"
awk '/^of_skills_inbox_genuine_dirs\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" > "$INBOX_FN"
grep -q "of_skills_inbox_genuine_dirs() {" "$INBOX_FN" || { echo "FATAL: of_skills_inbox_genuine_dirs extraction failed" >&2; exit 1; }
# shellcheck disable=SC1090
source "$INBOX_FN"

INBOX_SKILLS="$WORK/inbox-skills"
mk_inbox_skill() { # mk_inbox_skill <relative-dir-under-skills> <frontmatter-name>
  local rel="$1" fmname="$2"
  local dir="$INBOX_SKILLS/skills/$rel"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: "test"\n---\nbody\n' "$fmname" > "$dir/SKILL.md"
}

rm -rf "$INBOX_SKILLS"; mkdir -p "$INBOX_SKILLS/skills"
# Bundled, dir name MATCHES frontmatter -- the convenient case the old comment
# validated against ("apple-notes").
mk_inbox_skill "apple/apple-notes" "apple-notes"
# Bundled, dir name DIFFERS from frontmatter -- the ENG-88 shape (vllm on disk,
# "serving-llms-vllm" in the manifest, the real pre-503da4e30 pair).
mk_inbox_skill "mlops/vllm" "serving-llms-vllm"
# Installed via the Skills Hub, not in .bundled_manifest at all, but IS in
# .hub/lock.json -- a second provenance table the old code never consulted.
mk_inbox_skill "optional-skills-installed/peft" "peft-fine-tuning"
mkdir -p "$INBOX_SKILLS/skills/.hub"
printf '{"installed": {"peft-fine-tuning": {"install_path": "optional-skills-installed/peft"}}}\n' \
  > "$INBOX_SKILLS/skills/.hub/lock.json"
# The one that should actually be flagged: not in the manifest, not in the hub
# lock, under either name.
mk_inbox_skill "machine-written-genuine" "machine-written-genuine"

INBOX_MANIFEST="$INBOX_SKILLS/skills/.bundled_manifest"
printf 'apple-notes:aaa\nserving-llms-vllm:bbb\n' > "$INBOX_MANIFEST"

out="$(of_skills_inbox_genuine_dirs "$INBOX_SKILLS/skills" "$INBOX_MANIFEST" 2>"$WORK/inbox.stderr")"
echo "$out" | sed 's/^/    | /'
check "bundled, dir name == frontmatter -> NOT flagged" \
  "0" "$(grep -c '/apple/apple-notes$' <<<"$out")"
check "bundled, dir name != frontmatter -> NOT flagged (the ENG-88 regression)" \
  "0" "$(grep -c '/mlops/vllm$' <<<"$out")"
check "hub-installed skill -> NOT flagged" \
  "0" "$(grep -c '/optional-skills-installed/peft$' <<<"$out")"
check "genuine agent-written skill -> IS flagged" \
  "1" "$(grep -c '/machine-written-genuine$' <<<"$out")"
check "exactly one path flagged total" \
  "1" "$(grep -c . <<<"$out")"

echo "== case: of_skills_inbox_genuine_dirs -- SKILL.md at the root of skills/ =="
rm -rf "$WORK/inbox-root"; mkdir -p "$WORK/inbox-root/skills"
printf -- '---\nname: root-skill\n---\nbody\n' > "$WORK/inbox-root/skills/SKILL.md"
: > "$WORK/inbox-root/manifest"
root_out="$(of_skills_inbox_genuine_dirs "$WORK/inbox-root/skills" "$WORK/inbox-root/manifest" 2>"$WORK/inbox-root.stderr")"
check "root SKILL.md -> not staged (would sweep the whole tree)" "" "$root_out"
check "root SKILL.md -> warns on stderr, not stdout" \
  "1" "$(grep -c 'ignoring a SKILL.md at the root' "$WORK/inbox-root.stderr")"

echo "== MUTANT: of_skills_inbox_genuine_dirs without the frontmatter-name fallback =="
# Reverts the match to basename-only against the manifest -- the exact bug measured
# in production (ENG-88): a bundled skill whose directory name differs from its
# frontmatter name is then indistinguishable from one the agent wrote.
sed 's/frontmatter_name = read_skill_name(skill_md, dirname)/frontmatter_name = dirname/' \
  "$INBOX_FN" > "$WORK/inbox-mut.sh"
if grep -q 'frontmatter_name = dirname$' "$WORK/inbox-mut.sh"; then
  mut_out="$( ( source "$WORK/inbox-mut.sh"
    of_skills_inbox_genuine_dirs "$INBOX_SKILLS/skills" "$INBOX_MANIFEST" 2>/dev/null ) )"
  check "guard removed -> the dir!=frontmatter bundled skill now leaks as genuine (proves the fix is load-bearing)" \
    "1" "$(grep -c '/mlops/vllm$' <<<"$mut_out")"
else
  bad "inbox mutant did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# of_state_sync_loop (openfathom-meta ENG-132) -- periodic persistence for MESSAGES,
# closing the asymmetry of_memories_sync_loop's own comment declared deliberate. The
# production fact that forced it: on 2026-08-01 the live state object was stamped
# 2026-07-30T09:19:06Z, eleven seconds after the CURRENT revision went ready -- the
# outgoing revision's goodbye -- so two days of turns existed nowhere but the instance.
# ---------------------------------------------------------------------------
mk_state_home() { # mk_state_home <dir> <epoch> <msg specs...>
  local home="$1" epoch="$2"; shift 2
  rm -rf "$home"; mkdir -p "$home"
  printf '%s\n' "$epoch" > "$home/.state_epoch"
  python3 - "$home/state.db" "$@" <<'PY'
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
}

echo "== case: of_state_snapshot_upload -- carries the new generation forward after a 200 =="
reset_stub
STAGE_G="$WORK/upload-stage-gen"; rm -rf "$STAGE_G"
mk_upload_stage "$STAGE_G" 3 "s1" "1:s1:user:100:hello"
TARBALL_G="$WORK/upload-tb-gen.tar.gz"
tar czf "$TARBALL_G" -C "$STAGE_G" .
LIVE_GEN="99"; of_state_generation=42; of_state_epoch=3
of_state_snapshot_upload "$STAGE_G" "$TARBALL_G" "stub-token" >/dev/null 2>&1
check "of_state_generation advanced to the live generation, not left at boot's" \
  "99" "${of_state_generation}"

# ---------------------------------------------------------------------------
# openfathom-meta ENG-136. The case above is the UNCONTENDED path and stays true. This
# one is the contended path, and it is where carrying the generation forward destroys
# data: of_state_merge_messages writes the union into the mktemp'd STAGING copy, never
# into $HERMES_HOME, so the union exists only in the object just written. Advance the
# generation and the next tick re-stages from $HERMES_HOME, matches the CAS, gets a 200
# instead of a 412, and overwrites the union with the smaller local state.
#
# Production, 2026-08-01: 18:09:34Z wrote 3 sessions / 135 messages after a merge;
# 19:09:35Z wrote 2 sessions / 46 messages, and session 20260730_071029_cc5c4281 stayed
# gone for 20 consecutive hourly ticks. Two ticks is the smallest thing that reproduces
# it, and one tick can never show it -- which is why every ENG-132 test passed.
# ---------------------------------------------------------------------------
e136_object_has() { # e136_object_has <content> -> 1 if present in the live object
  local d; d="$(mktemp -d -p "$WORK")"
  tar xzf "$CAS_LIVE" -C "$d" 2>/dev/null
  python3 - "$d/state.db" "$1" <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1])
    print(con.execute("select count(*) from messages where content = ?", (sys.argv[2],)).fetchone()[0])
except Exception:
    print(-1)
PY
}

echo "== case: ENG-136 -- a merged union survives the NEXT tick =="
reset_stub
E136_HOME="$WORK/eng136-home"; rm -rf "$E136_HOME"; mkdir -p "$E136_HOME"
printf '3\n' > "$E136_HOME/.state_epoch"
mk_full_db "$E136_HOME/state.db" "s1" "1:s1:user:100:local-only"
export HERMES_HOME="$E136_HOME"
E136_LIVE="$WORK/eng136-live.tar.gz"
mk_full_state "$E136_LIVE" 3 "s1,s2" "1:s1:user:100:local-only" "2:s2:user:200:only-in-the-object"
# Generation 77 in the object, 42 in this instance: the boot race of of-09.md section 11,
# which is what puts turns in the object that were never in $HERMES_HOME.
cas_enable 77 "$E136_LIVE"
of_state_generation=42; of_state_epoch=3
of_state_snapshot >/dev/null 2>&1
check "tick 1 -- the 412 merged, and the union reached the object" \
  "1" "$(e136_object_has 'only-in-the-object')"
check "tick 1 -- the generation was NOT carried forward past a merge" \
  "42" "${of_state_generation}"
of_state_snapshot >/dev/null 2>&1
check "tick 2 -- the union SURVIVED (this is the whole item: 89 real messages did not)" \
  "1" "$(e136_object_has 'only-in-the-object')"
check "tick 2 -- and the instance's own state is still there, so nothing was traded away" \
  "1" "$(e136_object_has 'local-only')"

echo "== MUTANT: ENG-136 -- the merge is not recorded, so the generation advances anyway =="
# Exactly the code that ran in production between 2026-08-01 and this fix: the write-back
# is unconditional because nothing ever tells it a merge happened. Tick 2 then CASes
# successfully and the union is gone -- silently, with a 200 and a cheerful log line.
extract_fns "$WORK/e136-mut.sh" '/^    merged=1$/d'
if ! grep -q '^    merged=1$' "$WORK/e136-mut.sh" && bash -n "$WORK/e136-mut.sh" 2>/dev/null; then
  reset_stub
  E136M_HOME="$WORK/eng136-mut-home"; rm -rf "$E136M_HOME"; mkdir -p "$E136M_HOME"
  printf '3\n' > "$E136M_HOME/.state_epoch"
  mk_full_db "$E136M_HOME/state.db" "s1" "1:s1:user:100:local-only"
  export HERMES_HOME="$E136M_HOME"
  E136M_LIVE="$WORK/eng136-mut-live.tar.gz"
  mk_full_state "$E136M_LIVE" 3 "s1,s2" "1:s1:user:100:local-only" "2:s2:user:200:only-in-the-object"
  cas_enable 77 "$E136M_LIVE"
  ( # shellcheck disable=SC1090
    source "$WORK/e136-mut.sh"
    of_state_generation=42; of_state_epoch=3
    of_state_snapshot >/dev/null 2>&1
    of_state_snapshot >/dev/null 2>&1 )
  check "merge flag removed -> tick 2 destroyed the union (proves the fix is load-bearing)" \
    "0" "$(e136_object_has 'only-in-the-object')"
else
  bad "ENG-136 mutant did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== case: of_state_snapshot -- a fresh staging dir per call, never a shared fixed path =="
reset_stub
SNAP_HOME="$WORK/snap-home"; mk_state_home "$SNAP_HOME" 3 "1:s1:user:100:hello"
export HERMES_HOME="$SNAP_HOME"
MKTEMP_LOG="$WORK/mktemp-calls.log"; : > "$MKTEMP_LOG"
# Wrap mktemp so the test can see WHETHER a per-call path was allocated at all. A fixed
# path is invisible to any assertion on the uploaded bytes -- the damage it does needs two
# invocations overlapping in time, which a unit test cannot schedule deterministically.
# What IS deterministic, and is the property the fix actually adds, is that each call
# allocates its own.
mktemp() { local p; p="$(command mktemp "$@")"; echo "$p" >> "$MKTEMP_LOG"; echo "$p"; }
of_state_generation=0; of_state_epoch=3
of_state_snapshot >/dev/null 2>&1
of_state_snapshot >/dev/null 2>&1
unset -f mktemp
check "two calls allocated 4 temp paths (a stage + a tarball each)" \
  "4" "$(wc -l < "$MKTEMP_LOG")"
check "every allocated path is distinct -- no call reuses another's" \
  "4" "$(sort -u "$MKTEMP_LOG" | wc -l)"

echo "== case: of_state_sync_loop -- runs at least 2 cycles with a short interval =="
reset_stub
SYNC_HOME="$WORK/sync-home"; mk_state_home "$SYNC_HOME" 3 "1:s1:user:100:hello"
export HERMES_HOME="$SYNC_HOME"
export HERMES_STATE_SYNC_INTERVAL_SECONDS="0.2"
of_state_generation=0; of_state_epoch=3
STATE_LOOP_LOG="$WORK/state-loop.log"
( of_state_sync_loop > "$STATE_LOOP_LOG" 2>&1 ) &
state_loop_pid=$!
sleep 0.9
kill -TERM "$state_loop_pid" 2>/dev/null || true
wait "$state_loop_pid" 2>/dev/null || true
state_cycles="$(grep -c 'snapshot uploaded to gs://test-bucket/gateway-state.tar.gz' "$STATE_LOOP_LOG")"
check "at least 2 state sync cycles ran in ~0.9s at a 0.2s interval" \
  "1" "$([[ "$state_cycles" -ge 2 ]] && echo 1 || echo 0)"

echo "== case: of_state_sync_loop -- a turn written mid-session survives a HARD kill (SIGKILL) =="
reset_stub
CRASH_HOME="$WORK/crash-home"; mk_state_home "$CRASH_HOME" 3 "1:s1:user:100:before boot"
export HERMES_HOME="$CRASH_HOME"
export HERMES_STATE_SYNC_INTERVAL_SECONDS="0.2"
of_state_generation=0; of_state_epoch=3
( of_state_sync_loop > /dev/null 2>&1 ) &
crash_loop_pid=$!
sleep 0.3
python3 - "$CRASH_HOME/state.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("insert into messages (id, session_id, role, content, timestamp) "
            "values (2, 's1', 'user', 'mid-session, never gracefully shut down', 200.0)")
con.commit(); con.close()
PY
sleep 0.3
kill -9 "$crash_loop_pid" 2>/dev/null || true   # of_on_term and its final flush NEVER run
wait "$crash_loop_pid" 2>/dev/null || true
mkdir -p "$WORK/state-crash-extract"; tar xzf "$UPLOADED" -C "$WORK/state-crash-extract" 2>/dev/null
check "the mid-session turn reached GCS through a periodic tick, with no graceful shutdown at all" \
  "1" "$(python3 -c "
import sqlite3
con = sqlite3.connect('$WORK/state-crash-extract/state.db')
print(con.execute(\"select count(*) from messages where content='mid-session, never gracefully shut down'\").fetchone()[0])
" 2>/dev/null)"

echo "== case: of_state_sync_loop -- TERM interrupts immediately, does not wait out the interval =="
reset_stub
export HERMES_STATE_SYNC_INTERVAL_SECONDS="5"
of_state_generation=0; of_state_epoch=3
( of_state_sync_loop > /dev/null 2>&1 ) &
term_loop_pid=$!
sleep 0.2
term_start="$(date +%s%N)"
kill -TERM "$term_loop_pid" 2>/dev/null || true
wait "$term_loop_pid" 2>/dev/null || true
term_ms=$(( ( $(date +%s%N) - term_start ) / 1000000 ))
check "TERM returned in well under the 5s interval (bare \`sleep\` would have run to completion)" \
  "1" "$([[ "$term_ms" -lt 2000 ]] && echo 1 || echo 0)"

echo "== MUTANT: of_state_snapshot_upload without the generation write-back =="
# Reverts to the pre-ENG-132 behaviour: gen read once at boot and never advanced. Every
# periodic tick after the first would then CAS against a generation the object has moved
# past, 412, and pay a full download+merge+re-tar of a multi-megabyte tarball forever.
# ENG-136 made the write-back conditional, so the mutation deletes the whole `if` block
# (3 lines) rather than the assignment alone -- deleting the assignment on its own leaves
# a dangling `fi` and the mutant dies of a SYNTAX error, which proves nothing about the
# behaviour under test. A mutant that fails to parse is not a mutant.
extract_one_fn "$WORK/gen-mut.sh" of_state_snapshot_upload \
  '/if \[\[ "\$merged" -eq 0 \]\]; then/,+2d'
if ! grep -q 'of_state_generation="\$(of_gcs_read_generation' "$WORK/gen-mut.sh" \
   && bash -n "$WORK/gen-mut.sh" 2>/dev/null; then
  reset_stub
  STAGE_M="$WORK/upload-stage-mut"; rm -rf "$STAGE_M"
  mk_upload_stage "$STAGE_M" 3 "s1" "1:s1:user:100:hello"
  TARBALL_M="$WORK/upload-tb-mut.tar.gz"
  tar czf "$TARBALL_M" -C "$STAGE_M" .
  LIVE_GEN="99"; of_state_epoch=3
  mut_gen="$( ( # shellcheck disable=SC1090
    source "$WORK/gen-mut.sh"
    of_state_generation=42
    of_state_snapshot_upload "$STAGE_M" "$TARBALL_M" "stub-token" >/dev/null 2>&1
    echo "$of_state_generation" ) )"
  check "write-back removed -> the generation is stuck at boot's 42 (proves the fix is load-bearing)" \
    "42" "$mut_gen"
else
  bad "generation mutant did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== MUTANT: of_state_snapshot back on the shared fixed staging path =="
# Reverts to the pre-ENG-132 `stage=/tmp/of-state-stage`, safe only while this function
# ran exactly once per process. With of_state_sync_loop alive it no longer does, and the
# `rm -rf "$stage"` of one invocation deletes what the other is mid-tar into.
extract_one_fn "$WORK/stage-mut.sh" of_state_snapshot \
  's|stage="\$(mktemp -d)"; tarball="\$(mktemp --suffix=.tar.gz)"|stage="/tmp/of-state-stage-mut"; tarball="/tmp/of-state-snap-mut.tar.gz"; rm -rf "$stage" "$tarball"; mkdir -p "$stage"|'
if grep -q '/tmp/of-state-stage-mut' "$WORK/stage-mut.sh"; then
  reset_stub
  MUT_HOME="$WORK/stage-mut-home"; mk_state_home "$MUT_HOME" 3 "1:s1:user:100:hello"
  export HERMES_HOME="$MUT_HOME"
  MUT_MKTEMP_LOG="$WORK/mktemp-mut.log"; : > "$MUT_MKTEMP_LOG"
  mut_paths="$( ( # shellcheck disable=SC1090
    source "$WORK/stage-mut.sh"
    mktemp() { local p; p="$(command mktemp "$@")"; echo "$p" >> "$MUT_MKTEMP_LOG"; echo "$p"; }
    of_state_generation=0; of_state_epoch=3
    of_state_snapshot >/dev/null 2>&1
    of_state_snapshot >/dev/null 2>&1
    wc -l < "$MUT_MKTEMP_LOG" ) )"
  check "fixed path restored -> both calls share one staging dir, 0 per-call allocations (proves the fix is load-bearing)" \
    "0" "$(echo "$mut_paths" | tr -d ' ')"
else
  bad "staging-path mutant did not apply -- a mutant that does not mutate proves nothing"
fi

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
