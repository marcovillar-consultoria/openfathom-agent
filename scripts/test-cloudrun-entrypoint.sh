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
# chmod first: the ENG-338 cases leave read-only trees under $WORK.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

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
  for fn in of_state_read_local_epoch of_state_tarball_epoch of_state_messages_superset of_state_try_promote of_state_merge_messages of_state_snapshot_upload of_state_snapshot of_state_sync_loop of_gcs_read_generation of_memory_union of_memories_tarball_epoch of_memories_restore of_memories_snapshot of_memories_write_with_merge_retry of_memories_sync_loop of_safe_extract of_state_restore_failed of_memories_forget_generation of_state_restore; do
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
    # ENG-373: LIVE="HTTP<code>" serves that code (a 5xx after the generation was read).
    if [[ "$served" == HTTP* ]]; then echo "${served#HTTP}"; return 0; fi
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
# Wait for the cycles, never a fixed `sleep 0.9`: that failed 5 runs in 10 on a loaded
# machine (openfathom-meta ENG-313, 2026-11-02). What this case protects is that the loop
# ticks AGAIN on its own, not how fast; a loop that ticks once and stops still fails here,
# after the deadline.
cycles=0
for _ in $(seq 1 200); do   # up to ~20s
  cycles="$(grep -c 'snapshot uploaded to gs://test-bucket/memories.tar.gz' "$LOOP_LOG")"
  [[ "$cycles" -ge 2 ]] && break
  sleep 0.1
done
kill -TERM "$loop_pid" 2>/dev/null || true
wait "$loop_pid" 2>/dev/null || true
check "the loop ticks again on its own (>=2 cycles within ~20s)" "1" "$([[ "$cycles" -ge 2 ]] && echo 1 || echo 0)"

echo "== case: of_memories_sync_loop -- an entry written mid-session survives a HARD kill (SIGKILL, never of_on_term) =="
reset_stub
MEM_HOME8="$WORK/mem-home8"; rm -rf "$MEM_HOME8"; mkdir -p "$MEM_HOME8/memories"
mk_mem_file "$MEM_HOME8/memories" "MEMORY.md" "entry written before boot"
export HERMES_HOME="$MEM_HOME8"
export HERMES_MEMORIES_OBJECT="memories.tar.gz"
export HERMES_MEMORY_SYNC_INTERVAL_SECONDS="0.2"
of_memories_generation=1; of_state_epoch=0
LOOP8_LOG="$WORK/loop8-cycles.log"
( of_memories_sync_loop > "$LOOP8_LOG" 2>&1 ) &
loop8_pid=$!
# Wait for the EFFECT, never a fixed sleep: two `sleep 0.3` here flapped on a loaded
# machine (openfathom-meta ENG-313), the same shape the state-sync crash case below
# already fixed on 2026-08-21. First, the loop has demonstrably ticked once.
for _ in $(seq 1 200); do   # up to ~20s
  [[ "$(grep -c 'snapshot uploaded to' "$LOOP8_LOG")" -ge 1 ]] && break
  sleep 0.1
done
mk_mem_file "$MEM_HOME8/memories" "MEMORY.md" "entry written before boot" "entry written mid-session, never gracefully shut down"
# Then, a later tick carried the new entry to GCS. Each branch records WHY it has not
# succeeded yet, so a regression does not read like a slow runner.
mem8_rows=""
mem8_diag="no attempt completed"
for _ in $(seq 1 200); do   # up to ~20s
  if [[ ! -s "$UPLOADED" ]]; then
    mem8_diag="no tarball uploaded yet"; sleep 0.1; continue
  fi
  rm -rf "$WORK/crash-extract8"; mkdir -p "$WORK/crash-extract8"
  if ! tar_err="$(tar xzf "$UPLOADED" -C "$WORK/crash-extract8" 2>&1)"; then
    mem8_diag="tar failed: $tar_err"; sleep 0.1; continue
  fi
  mem8_rows="$(mem_file_entries "$WORK/crash-extract8/MEMORY.md" | grep -c '^entry written mid-session, never gracefully shut down$')"
  [[ "$mem8_rows" == "1" ]] && { mem8_diag="ok"; break; }
  mem8_diag="tarball reached, but it holds $mem8_rows matching entr(y/ies)"
  sleep 0.1
done
kill -9 "$loop8_pid" 2>/dev/null || true   # SIGKILL -- of_on_term, of_state_snapshot, of_memories_snapshot's final flush NEVER run
wait "$loop8_pid" 2>/dev/null || true
[[ "$mem8_rows" == "1" ]] || echo "  diag: $mem8_diag"
check "the mid-session entry reached GCS through a periodic tick, with no graceful shutdown at all" \
  "1" "$mem8_rows"

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
# of_plugins_fetch's "loaded" line calls of_make_read_only (ENG-338); define it too.
awk '/^of_make_read_only\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" >> "$PLUG_FN"
# ... and the pin check (ENG-373).
awk '/^of_verify_sha256\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT" >> "$PLUG_FN"
grep -q "of_verify_sha256() {" "$PLUG_FN" || { echo "FATAL: of_verify_sha256 extraction failed" >&2; exit 1; }
grep -q "of_make_read_only() {" "$PLUG_FN" || { echo "FATAL: of_make_read_only extraction failed" >&2; exit 1; }
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
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
# ENG-373: a fetch now loads only the tarball its pin names, so each case pins the one it serves.
export HERMES_PLUGINS_SHA256="$(sha_of "$PLUG_OK")"

reset_stub; LIVE="$PLUG_OK"
of_plugins_fetch "$PDIR" >/dev/null 2>&1; rc=$?
check "valid plugin tarball -> fetch ok"       "0"   "$rc"
check "plugin.yaml landed in dest"             "yes" "$([[ -f "$PDIR/delegation-tasks/plugin.yaml" ]] && echo yes || echo no)"

reset_stub; LIVE="$PLUG_NO"; HERMES_PLUGINS_SHA256="$(sha_of "$PLUG_NO")"
of_plugins_fetch "$PDIR" 2>"$WORK/plug-no.err" >/dev/null; rc=$?
check "tarball with no plugin.yaml -> refuses" "1"   "$rc"
check "... for the manifest, not the pin"      "1"   "$(grep -c 'no plugin.yaml' "$WORK/plug-no.err")"
HERMES_PLUGINS_SHA256="$(sha_of "$PLUG_OK")"

reset_stub; LIVE=""   # HTTP 404 from the stub
of_plugins_fetch "$PDIR" >/dev/null 2>&1; rc=$?
check "404 -> refuses (publish step skipped)"  "1"   "$rc"

# ---------------------------------------------------------------------------
# openfathom-meta ENG-338 (b): a delivered plugin or skill tree is left read-only, so
# the gateway's write_file (same `hermes` user) cannot rewrite code a forced plugin
# rediscovery would import. Three properties, for both fetch functions: nothing under
# dest is writable and neither a file nor a new directory can be created there; a
# second fetch over the read-only tree (a container restart over a surviving
# $HERMES_HOME) still replaces it; and the "loaded" line says "(read-only)" only
# because that held. The a-w and the find mutants run in-harness below ("mutants:
# ENG-338/361"); dropping either `chmod -R u+w` before `rm -rf` was run by hand on
# 2026-11-06 and turns "second fetch over the read-only tree" red.
# Root ignores file modes, so under root these cases would prove nothing: fail loud.
# ---------------------------------------------------------------------------
echo "== case: ENG-338 -- delivered trees are read-only =="
RO_FN="$WORK/ro.sh"
for fn in of_skills_fetch; do
  awk "/^${fn}\\(\\) \\{/{p=1} p{print} p&&/^\\}\$/{exit}" "$ENTRYPOINT" >> "$RO_FN"
  grep -q "${fn}() {" "$RO_FN" || { echo "FATAL: ${fn} extraction failed" >&2; exit 1; }
done
# shellcheck disable=SC1090
source "$RO_FN"
export HERMES_SKILLS_OBJECT="skills.tar.gz" HERMES_STATE_BUCKET="${HERMES_STATE_BUCKET:-test-bucket}"
mk_skill_tarball() { # <out> -- a tarball of_skills_fetch accepts: one SKILL.md
  local out="$1" d; d="$(mktemp -d -p "$WORK")"
  mkdir -p "$d/daily-briefing"
  printf -- '---\nname: daily-briefing\n---\n' > "$d/daily-briefing/SKILL.md"
  tar czf "$out" -C "$d" .
}
SKILL_OK="$WORK/skill-ok.tar.gz"; mk_skill_tarball "$SKILL_OK"
export HERMES_SKILLS_SHA256="$(sha_of "$SKILL_OK")"

if [[ "$(id -u)" -eq 0 ]]; then
  bad "ENG-338 cases run as root, which ignores file modes -- they cannot prove read-only here"
else
  for spec in "of_plugins_fetch|$PLUG_OK|$WORK/ro-plugins|delegation-tasks/plugin.yaml" \
              "of_skills_fetch|$SKILL_OK|$WORK/ro-skills|daily-briefing/SKILL.md"; do
    IFS='|' read -r fn tb dest leaf <<< "$spec"
    reset_stub; LIVE="$tb"
    out="$("$fn" "$dest" 2>/dev/null)"; rc=$?
    check "$fn: fetch ok"                                     "0"   "$rc"
    check "$fn: loaded line says (read-only)"                 "yes" "$([[ "$out" == *"(read-only)"* ]] && echo yes || echo no)"
    check "$fn: nothing under dest is writable"               ""    "$(find "$dest" -perm /222 -print -quit)"
    check "$fn: overwriting a delivered file is refused"      "no"  "$( (printf x > "$dest/$leaf") 2>/dev/null && echo yes || echo no)"
    check "$fn: a new directory in dest is refused"           "no"  "$(mkdir "$dest/injected" 2>/dev/null && echo yes || echo no)"
    reset_stub; LIVE="$tb"
    "$fn" "$dest" >/dev/null 2>&1; rc=$?
    check "$fn: second fetch over the read-only tree ok"      "0"   "$rc"
    check "$fn: second fetch left the delivered file"         "yes" "$([[ -f "$dest/$leaf" ]] && echo yes || echo no)"
  done
  # The line must not outrun the chmod: with chmod neutralised, the tree stays
  # writable, and the helper must WARN and print no "(read-only)".
  NOCHMOD="$WORK/still-writable"; mkdir -p "$NOCHMOD/p"; : > "$NOCHMOD/p/plugin.yaml"
  chmod() { :; }
  ro_out="$(of_make_read_only "$NOCHMOD" of-plugins 2>"$WORK/ro-warn")"
  unset -f chmod
  check "chmod failing: no (read-only) claimed"               ""    "$ro_out"
  check "chmod failing: WARN names the writable path"         "yes" "$(grep -q 'still writable' "$WORK/ro-warn" && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# openfathom-meta ENG-361: $HERMES_HOME/scripts is created empty and read-only on the
# service path, before either gateway start, so write_file cannot place a script that a
# cron job (cronjob_manage script=, no_agent=True) would run with bash. Structural: the
# line sits inside `service)` and above the first `exec hermes gateway run`. Functional:
# the two lines, run as written in the entrypoint, leave a directory where neither a file
# nor a subdirectory can be created.
# ---------------------------------------------------------------------------
echo "== case: ENG-361 -- \$HERMES_HOME/scripts is read-only before the gateway starts =="
scripts_fence() { # <entrypoint> -> "ok" when the of-scripts line is at the top level of service), above the first gateway exec
  local f="$1" svc line ex depth
  svc="$(grep -n '^  service)$' "$f" | head -1 | cut -d: -f1)"
  line="$(grep -n 'of_make_read_only "\${HERMES_HOME:-/opt/data}/scripts" of-scripts' "$f" | head -1 | cut -d: -f1)"
  ex="$(grep -nE '^ +exec hermes gateway run$' "$f" | head -1 | cut -d: -f1)"
  # if/fi depth between `service)` and the line: 0 means no optional block (skills,
  # plugins, bucket) can skip it. Counts shell keywords only, at line start.
  depth="$(awk -v a="$svc" -v b="$line" -v q="'" '
    NR<=a || NR>=b { next }
    hd != "" { if ($0 == hd) hd = ""; next }                 # inside a heredoc body (embedded Python)
    { if ($0 ~ /^[[:space:]]*if[[:space:]]/) d++; if ($0 ~ /^[[:space:]]*fi([[:space:];]|$)/) d-- }
    match($0, "<<-?" q "?[A-Z_]+" q "?") { w = substr($0, RSTART, RLENGTH); gsub("[<" q "-]", "", w); hd = w }
    END { print d+0 }' "$f")"
  [[ -n "$svc" && -n "$line" && -n "$ex" && "$line" -gt "$svc" && "$line" -lt "$ex" && "$depth" == 0 ]] && echo ok || echo "no (service=$svc line=$line exec=$ex depth=$depth)"
}
check "scripts dir made read-only inside service), before the first gateway exec" "ok" "$(scripts_fence "$ENTRYPOINT")"
scripts_lines() { # <entrypoint> -> the two shipped lines (mkdir + of_make_read_only), verbatim
  grep -E '^    mkdir -p "\$\{HERMES_HOME:-/opt/data\}/scripts"|^    echo "\[of-scripts\]' "$1"
}
check "the two shipped scripts lines were found" "2" "$(scripts_lines "$ENTRYPOINT" | wc -l)"
if [[ "$(id -u)" -ne 0 ]]; then
  SH_HOME="$WORK/scripts-home"; mkdir -p "$SH_HOME"
  sc_out="$( ( HERMES_HOME="$SH_HOME"; eval "$(scripts_lines "$ENTRYPOINT")" ) 2>&1)"
  check "scripts line says (read-only)"                     "yes" "$([[ "$sc_out" == *"/scripts (read-only)"* ]] && echo yes || echo no)"
  check "a script cannot be written into scripts/"          "no"  "$( (printf 'id\n' > "$SH_HOME/scripts/p.sh") 2>/dev/null && echo yes || echo no)"
  check "a subdirectory cannot be created in scripts/"      "no"  "$(mkdir "$SH_HOME/scripts/gmail-triage" 2>/dev/null && echo yes || echo no)"
fi

# In-harness mutants (so CI re-proves them, not a hand run): each mutated copy of the
# entrypoint must turn the guarded property red. A mutation that does not change the
# text proves nothing, so that is a failure too. ENG-332 first, then ENG-338, ENG-361.
echo "== mutants: ENG-332/338/361 =="
ro_mutant() { # <label> <sed-expr> <probe-fn>
  local label="$1" expr="$2" probe="$3" m="$WORK/ro-mutant.sh"
  sed -e "$expr" "$ENTRYPOINT" > "$m"
  if cmp -s "$m" "$ENTRYPOINT"; then bad "$label: the mutation did not apply -- a mutant that does not mutate proves nothing"; return; fi
  if [[ "$($probe "$m")" == "survived" ]]; then bad "$label -- SURVIVED"; else ok "$label -- killed"; fi
}
# ENG-332: the boot line that proves the on-demand-install policy from the log (the VM
# has no ingress). Same fence: top level of service), above the first gateway exec.
lazy_fence() {
  local f="$1" svc line ex
  svc="$(grep -n '^  service)$' "$f" | head -1 | cut -d: -f1)"
  line="$(grep -n 'echo "\[of-lazy\] HERMES_DISABLE_LAZY_INSTALLS=' "$f" | head -1 | cut -d: -f1)"
  ex="$(grep -nE '^ +exec hermes gateway run$' "$f" | head -1 | cut -d: -f1)"
  [[ -n "$svc" && -n "$line" && -n "$ex" && "$line" -gt "$svc" && "$line" -lt "$ex" ]] && echo ok || echo "no (service=$svc line=$line exec=$ex)"
}
check "[of-lazy] boot line inside service), before the first gateway exec (ENG-332)" "ok" "$(lazy_fence "$ENTRYPOINT")"
probe_lazy() { [[ "$(lazy_fence "$1")" == ok ]] && echo survived || echo killed; }
ro_mutant "[of-lazy] boot line removed (ENG-332)" '/echo "\[of-lazy\] HERMES_DISABLE_LAZY_INSTALLS=/d' probe_lazy
# ENG-338 (b): the read-only helper.
probe_ro_helper() { # <entrypoint> -> "survived" if its of_make_read_only still yields a read-only tree that it reports as such
  local f="$1" d; d="$(mktemp -d -p "$WORK")"; mkdir -p "$d/p"; : > "$d/p/plugin.yaml"
  local out; out="$( ( eval "$(awk '/^of_make_read_only\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$f")"; of_make_read_only "$d" t ) 2>/dev/null)"
  [[ -z "$(find "$d" -perm /222 -print -quit)" && "$out" == " (read-only)" ]] && echo survived || echo killed
}
probe_ro_claim() { # <entrypoint> -> "survived" if, with chmod neutralised, the helper still WARNs and claims nothing
  local f="$1" d; d="$(mktemp -d -p "$WORK")"; : > "$d/plugin.yaml"
  local out; out="$( ( eval "$(awk '/^of_make_read_only\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$f")"; chmod() { :; }; of_make_read_only "$d" t ) 2>"$d.warn")"
  [[ -z "$out" ]] && grep -q 'still writable' "$d.warn" && echo survived || echo killed
}
if [[ "$(id -u)" -ne 0 ]]; then
  ro_mutant "of_make_read_only without chmod -R a-w" 's/^  chmod -R a-w "\$dest" 2>\/dev\/null || true$/  :/' probe_ro_helper
  ro_mutant "(read-only) claimed without the find" 's/^  w="\$(find "\$dest" -perm \/222 -print -quit 2>\/dev\/null)"$/  w=""/' probe_ro_claim
fi
# ENG-361: the scripts lock.
probe_scripts() { # <entrypoint> -> "survived" if the scripts fence still holds
  [[ "$(scripts_fence "$1")" == ok ]] && echo survived || echo killed
}
ro_mutant "scripts dir left writable (ENG-361 line removed)" '/of_make_read_only "\${HERMES_HOME:-\/opt\/data}\/scripts" of-scripts/d' probe_scripts
ro_mutant "scripts lock moved inside the optional plugins block (ENG-361)" '/^    mkdir -p "\${HERMES_HOME:-\/opt\/data}\/scripts"/i\
    if [[ -n "${HERMES_PLUGINS_OBJECT:-}" ]]; then
/of_make_read_only "\${HERMES_HOME:-\/opt\/data}\/scripts" of-scripts/a\
    fi' probe_scripts

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
  # ENG-373: pinned to the tarball it serves, so the pin is not what refuses it.
  mrc="$( source "$WORK/plug-mut.sh"; HERMES_PLUGINS_SHA256="$(sha_of "$PLUG_NO")"; of_plugins_fetch "$WORK/pm" >/dev/null 2>&1; echo "$?" )"
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

# openfathom-meta ENG-316: the entrypoint no longer writes model.max_tokens -- no code
# reads the key since upstream fd3565deec. A TEXT check, and only that: it proves the
# line is gone from the file, not what Hermes does with its output cap. It replaces a
# case that grepped the line in, which proved the line written and never the line read.
check "model.max_tokens is not written by the entrypoint (ENG-316)" \
  "0" "$(grep -c 'hermes config set model.max_tokens' "$ENTRYPOINT")"

# openfathom-meta ENG-101: prompt_caching.cache_ttl 1h, so a >5-minute pause between
# Telegram turns no longer forces a 1.25x cache write where a 0.1x cache read would do.
# Structural check, same reasoning as ENG-83 above -- hermes_cli internals aren't
# importable in this bash-only test job.
check "prompt_caching.cache_ttl set to 1h, unconditionally" \
  "1" "$(grep -c 'hermes config set prompt_caching.cache_ttl 1h' "$ENTRYPOINT")"

# openfathom-meta ENG-283: per-message timestamps, so the model sees the current date
# in every turn instead of the session's frozen "Conversation started:" line.
# Structural check, same reasoning as ENG-83 above -- hermes_cli internals aren't
# importable in this bash-only test job.
check "gateway.message_timestamps.enabled set to true, unconditionally" \
  "1" "$(grep -c 'hermes config set gateway.message_timestamps.enabled true' "$ENTRYPOINT")"

# openfathom-meta OF-10 task [2]: the API server binds loopback only. On the VM the
# container shares the host's network stack, so a 0.0.0.0 bind put an endpoint that
# dispatches agent work on the VM's NIC. Structural check, same reasoning as above; the
# second line catches a revert that keeps the new line around but re-adds the old one.
check "API server bound to 127.0.0.1" \
  "1" "$(grep -c '^    export API_SERVER_HOST="127.0.0.1"$' "$ENTRYPOINT")"
check "API server never bound to 0.0.0.0" \
  "0" "$(grep -c '^ *export API_SERVER_HOST="0.0.0.0"' "$ENTRYPOINT")"

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

# ENG-332: the documents line needs the delivered document-reader plugin.
CAPS_PLUGINS="$WORK/caps-plugins"; mkdir -p "$CAPS_PLUGINS/document-reader"
printf 'name: document-reader\n' > "$CAPS_PLUGINS/document-reader/plugin.yaml"
run_caps() { ( set -euo pipefail; of_skills_dir="$CAPS_HOME" of_plugins_dir="$CAPS_PLUGINS" of_soul_capabilities_block ); }
run_caps_no_plugins() { ( set -euo pipefail; of_skills_dir="$CAPS_HOME" of_plugins_dir="$WORK/no-plugins" of_soul_capabilities_block ); }

out="$(run_caps)"; echo "$out" | sed 's/^/    | /'
check "header present" \
  "1" "$(grep -c '^## Skills disponíveis agora' <<<"$out")"
# openfathom-meta ENG-332: read_file no longer converts PDF in this image while its
# core schema still says it does; the block is where the Sonda learns the real route.
check "documents are routed to extract_document_text (ENG-332)" \
  "1" "$(grep -c '^Documentos anexados .*extract_document_text' <<<"$out")"
check "no document-reader delivered -> no documents line (the block claims no tool it lacks)" \
  "0" "$(run_caps_no_plugins | grep -c '^Documentos anexados')"
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
# Wait for the EFFECT (two cycles logged), never for a fixed slice of wall clock.
# The old form slept 0.9s and asked how much work fitted inside it, which measures
# the runner's scheduler as much as it measures the loop -- and it turned CI red
# twice on 2026-08-21 while the loop itself was fine, blocking an image build both
# times (openfathom-meta ENG-174). The ceiling below is deliberately generous: a
# slow runner must come out SLOW here, never RED. What still fails, and must, is a
# loop that does not iterate -- the ceiling then expires with cycles still at 0/1.
state_cycles=0
for _ in $(seq 1 200); do   # up to ~20s, 100x the 0.2s interval
  state_cycles="$(grep -c 'snapshot uploaded to gs://test-bucket/gateway-state.tar.gz' "$STATE_LOOP_LOG")"
  [[ "$state_cycles" -ge 2 ]] && break
  sleep 0.1
done
kill -TERM "$state_loop_pid" 2>/dev/null || true
wait "$state_loop_pid" 2>/dev/null || true
[[ "$state_cycles" -ge 2 ]] || echo "  diag: only $state_cycles cycle(s) logged before the 20s ceiling"
check "at least 2 state sync cycles ran at a 0.2s interval (waited up to 20s)" \
  "1" "$([[ "$state_cycles" -ge 2 ]] && echo 1 || echo 0)"

echo "== case: of_state_sync_loop -- a turn written mid-session survives a HARD kill (SIGKILL) =="
reset_stub
CRASH_HOME="$WORK/crash-home"; mk_state_home "$CRASH_HOME" 3 "1:s1:user:100:before boot"
export HERMES_HOME="$CRASH_HOME"
export HERMES_STATE_SYNC_INTERVAL_SECONDS="0.2"
of_state_generation=0; of_state_epoch=3
CRASH_LOOP_LOG="$WORK/crash-loop.log"
( of_state_sync_loop > "$CRASH_LOOP_LOG" 2>&1 ) &
crash_loop_pid=$!
# Wait until the loop has demonstrably ticked once before writing the mid-session
# turn. "sleep 0.3 and hope" is half of why this case flapped on 2026-08-21.
for _ in $(seq 1 200); do
  [[ "$(grep -c 'snapshot uploaded to' "$CRASH_LOOP_LOG")" -ge 1 ]] && break
  sleep 0.1
done
python3 - "$CRASH_HOME/state.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("insert into messages (id, session_id, role, content, timestamp) "
            "values (2, 's1', 'user', 'mid-session, never gracefully shut down', 200.0)")
con.commit(); con.close()
PY
# Now wait for the EFFECT, and do NOT swallow the errors on the way to it. With
# `2>/dev/null` on both the extract and the query, three different worlds printed
# the same empty string -- "no tarball was ever uploaded", "the query blew up" and
# "the tick simply has not run yet" -- so a real regression in the periodic merge
# was indistinguishable from a slow runner. That is exactly the failure mode
# openfathom-meta ENG-136 cost us: 89 real messages lost, no error in any log.
# Each branch below records WHY it has not succeeded yet.
crash_rows=""
crash_diag="no attempt completed"
for _ in $(seq 1 200); do   # up to ~20s
  if [[ ! -s "$UPLOADED" ]]; then
    crash_diag="no tarball uploaded yet"; sleep 0.1; continue
  fi
  rm -rf "$WORK/state-crash-extract"; mkdir -p "$WORK/state-crash-extract"
  if ! tar_err="$(tar xzf "$UPLOADED" -C "$WORK/state-crash-extract" 2>&1)"; then
    crash_diag="tar failed: $tar_err"; sleep 0.1; continue
  fi
  if ! crash_rows="$(python3 -c "
import sqlite3
con = sqlite3.connect('$WORK/state-crash-extract/state.db')
print(con.execute(\"select count(*) from messages where content='mid-session, never gracefully shut down'\").fetchone()[0])
" 2>&1)"; then
    crash_diag="query failed: $crash_rows"; crash_rows=""; sleep 0.1; continue
  fi
  [[ "$crash_rows" == "1" ]] && { crash_diag="ok"; break; }
  crash_diag="tarball reached, but it holds $crash_rows matching row(s)"
  sleep 0.1
done
kill -9 "$crash_loop_pid" 2>/dev/null || true   # of_on_term and its final flush NEVER run
wait "$crash_loop_pid" 2>/dev/null || true
[[ "$crash_rows" == "1" ]] || echo "  diag: $crash_diag"
check "the mid-session turn reached GCS through a periodic tick, with no graceful shutdown at all" \
  "1" "$crash_rows"

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
  's|stage="\$(mktemp -d)"; tarball="\$(mktemp --suffix=.tar.gz)"|stage="/tmp/of-state-stage-mut"; tarball="/tmp/of-state-snap-mut.tar.gz"; rm -rf "$stage" "$tarball"; mkdir -p "$stage"|'  # no-tmp: ok — the mutant restores the pre-ENG-132 fixed path on purpose
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

# ---------------------------------------------------------------------------
# of_reconcile_api_server_key (openfathom-meta ENG-167) -- the upstream sync of
# 2026-08-17 made docker/stage2-hook.sh generate an API_SERVER_KEY into
# $HERMES_HOME/.env, and env_loader.load_hermes_dotenv() loads that file with
# override=True. Without this reconcile the gateway runs on a container-generated key
# while Secret Manager holds a different one -- silently, because the gateway still boots.
# ---------------------------------------------------------------------------
echo "== case: of_reconcile_api_server_key =="
RECON_FN="$WORK/recon.sh"
extract_one_fn "$RECON_FN" of_reconcile_api_server_key
# shellcheck disable=SC1090
source "$RECON_FN"

mk_env_file() { # <dir> <line>...
  local d="$1"; shift; mkdir -p "$d"
  : > "$d/.env"; local l
  for l in "$@"; do printf '%s\n' "$l" >> "$d/.env"; done
  chmod 600 "$d/.env"
}
env_key() { grep '^API_SERVER_KEY=' "$1/.env" | sed 's/^API_SERVER_KEY=//'; }

# The generated-key case: exactly what the new stage2 block leaves behind.
RH1="$WORK/recon1"
mk_env_file "$RH1" "ANTHROPIC_API_KEY=sk-from-dotenv" "API_SERVER_KEY=deadbeefgenerated0123456789abcdef"
HERMES_HOME="$RH1" API_SERVER_KEY="canonical-from-container-env-0000" of_reconcile_api_server_key >/dev/null 2>&1
check "generated key replaced by the container's env var" \
  "canonical-from-container-env-0000" "$(env_key "$RH1")"
check "exactly ONE assignment remains (dotenv keeps the last -- a leftover would shadow us)" \
  "1" "$(grep -c '^API_SERVER_KEY=' "$RH1/.env")"
check "unrelated lines survive untouched" \
  "1" "$(grep -c '^ANTHROPIC_API_KEY=sk-from-dotenv$' "$RH1/.env")"
check "mode stayed 0600 (cat > preserves it; mv would not)" \
  "600" "$(stat -c '%a' "$RH1/.env")"

# Two assignments: generator ran, then someone appended. dotenv honors the LAST one, so
# leaving either behind is a live defect.
RH2="$WORK/recon2"
mk_env_file "$RH2" "API_SERVER_KEY=first-value-000000000" "OTHER=x" "API_SERVER_KEY=second-value-00000000"
HERMES_HOME="$RH2" API_SERVER_KEY="canonical-000000000000" of_reconcile_api_server_key >/dev/null 2>&1
check "both stale assignments dropped, ours is the only one" \
  "1" "$(grep -c '^API_SERVER_KEY=' "$RH2/.env")"
check "the surviving value is ours, not the file's last one" \
  "canonical-000000000000" "$(env_key "$RH2")"

# Steady state must be silent AND must not rewrite: a boot line that says "nothing to do"
# every time is the noise that trains people to skip boot logs.
RH3="$WORK/recon3"
mk_env_file "$RH3" "API_SERVER_KEY=already-identical-00000"
out3="$(HERMES_HOME="$RH3" API_SERVER_KEY="already-identical-00000" of_reconcile_api_server_key 2>&1)"
check "already-identical -> says nothing" "0" "$(printf '%s' "$out3" | grep -c .)"

# No .env at all (job mode, or an image that never seeded one) -> no-op, no error.
RH4="$WORK/recon4"; mkdir -p "$RH4"
HERMES_HOME="$RH4" API_SERVER_KEY="whatever-0000000000000" of_reconcile_api_server_key >/dev/null 2>&1
check "no .env -> no file created (we reconcile, we do not seed)" "0" "$([[ -f "$RH4/.env" ]] && echo 1 || echo 0)"

# A .env whose ONLY line is the key: `grep -v` legitimately exits 1 on empty output, and
# without the `|| true` the function would abort under `set -e` before appending.
RH5="$WORK/recon5"
mk_env_file "$RH5" "API_SERVER_KEY=the-only-line-00000000"
( set -e; HERMES_HOME="$RH5" API_SERVER_KEY="canonical-solo-0000000" of_reconcile_api_server_key >/dev/null 2>&1 )
check "single-line .env still reconciled (grep -v exiting 1 does not abort us)" \
  "canonical-solo-0000000" "$(env_key "$RH5")"

echo "== MUTANT: of_reconcile_api_server_key -- stale assignments no longer dropped =="
# Reverts to a bare append. dotenv keeps the LAST occurrence, so appending after the
# generated line looks correct and IS correct by luck of ordering -- but the file then
# carries two, and any later append (operator, or a second boot of a future generator)
# silently wins. Asserts the specific wrong state, not merely "differs".
extract_one_fn "$WORK/recon-mut.sh" of_reconcile_api_server_key \
  "s|grep -v '\\^API_SERVER_KEY=' \"\\\$env_file\" > \"\\\$tmp\" |cat \"\$env_file\" > \"\$tmp\" |"
if grep -q 'cat "$env_file" > "$tmp"' "$WORK/recon-mut.sh"; then
  RHM="$WORK/recon-mut-home"
  mk_env_file "$RHM" "API_SERVER_KEY=generated-stale-000000"
  ( # shellcheck disable=SC1090
    source "$WORK/recon-mut.sh"
    HERMES_HOME="$RHM" API_SERVER_KEY="canonical-000000000000" of_reconcile_api_server_key >/dev/null 2>&1 )
  check "filter removed -> the stale generated assignment is still in the file (2 lines)" \
    "2" "$(grep -c '^API_SERVER_KEY=' "$RHM/.env")"
  check "filter removed -> the generated value survives alongside ours" \
    "1" "$(grep -c '^API_SERVER_KEY=generated-stale-000000$' "$RHM/.env")"
else
  bad "reconcile filter mutation did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== MUTANT: of_reconcile_api_server_key -- never called at all (the pre-ENG-167 state) =="
# The regression itself: with the reconcile absent, the .env keeps the generated key and
# dotenv's override=True hands it to the gateway. Simulated by simply not calling it.
RHN="$WORK/recon-none"
mk_env_file "$RHN" "API_SERVER_KEY=generated-by-stage2-00"
check "no reconcile -> the container-generated key is what dotenv would load" \
  "generated-by-stage2-00" "$(env_key "$RHN")"
unset HERMES_HOME

# ---------------------------------------------------------------------------
# openfathom-meta ENG-167 -- the guard above was INERT until 2026-08-24. It is LIVE now,
# and this case exists so that state cannot change again in silence, in either direction.
#
# WHAT WAS MEASURED, 2026-08-17. The reconcile shipped believing the generated key was the
# NORMAL case. It was not: the boot of revision hermes-gateway-00071-7wm showed neither
# `[stage2] Generated API_SERVER_KEY` nor `[of-apikey] reconciled` -- both absent, with the
# filter proven against a case it had to catch (the same query returned the `[of-state]`
# lines). The chain never started because /opt/hermes/.env.example DID NOT EXIST in the
# image: .dockerignore excluded it, so upstream's `seed_one ".env" ".env.example"` failed
# its own `[ -f ]`, no $HERMES_HOME/.env was ever born, and stage2's generator block --
# guarded by `[ -f "$HERMES_HOME/.env" ]` -- never fired.
#
# WHAT CHANGED, 2026-08-24, and this case is what caught it. The upstream sync
# `sync/upstream-20260824` (upstream/main@6ed8bcee8) re-included the template ON PURPOSE:
#
#     .env
#     .env.*
#    +# ...but keep the template: docker/stage2-hook.sh seeds $HERMES_HOME/.env from
#    +# /opt/hermes/.env.example on first boot (OOF-285 -- excluding it silently broke
#    +# first-boot .env seeding and the API_SERVER_KEY generation that depends on it).
#    +!.env.example
#     @@
#    -.env.example
#
# Upstream fixed THEIR side of the same mechanism and, in doing so, armed OUR chain. This
# assertion failed on that sync -- expected [disarmed-excluded], got [armed] -- which is
# exactly the future the 2026-08-17 version of this comment was written to catch, and the
# `!` re-inclusion mutant below had already named the shape of it.
#
# SO THE RECONCILE IS NO LONGER A CONTINGENCY: it is now the live path, exercised on every
# boot, and ENG-167's exit criterion (`[of-apikey] reconciled` in the boot log) became
# satisfiable for the first time. The risk that remains is the MIRROR of the old one -- a
# future sync silently disarming the chain again, which would make the reconcile inert and
# the exit criterion unsatisfiable once more, with nothing announcing it. THAT is what this
# checks now. The verdict flipped; the reason for watching did not.
#
# WHY IT IS NOT A CHECK IN openfathom-meta: the fact lives in THIS repo, in a file
# (.dockerignore) the fork is forbidden to edit (ADR-002/035/050 -- 8 files, this test is
# one, .dockerignore is not). Reading it is not editing it.
# ---------------------------------------------------------------------------
echo "== case: ENG-167 -- is the .env.example trigger still disarmed? =="
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Four verdicts, not two, because the two DISARMED reasons are different futures: upstream
# deleting .env.example and upstream un-ignoring it both change this line, and collapsing
# them would hide which one moved. Docker resolves .dockerignore by LAST match wins, with
# `!` re-including -- so a negation added after an exclusion arms the trigger just as
# surely as deleting the exclusion, and this walks the file in order to catch that.
eng167_trigger_state() { # <repo-root> -> no-dockerignore|disarmed-absent|disarmed-excluded|armed
  local root="$1" di="$1/.dockerignore" line verdict="included"
  # FAIL CLOSED. A guard that goes quiet when its source of truth disappears is worse than
  # no guard: the CI stays green while nothing is being watched.
  [[ -r "$di" ]] || { echo "no-dockerignore"; return 0; }
  [[ -f "$root/.env.example" ]] || { echo "disarmed-absent"; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == '!'* ]]; then
      # shellcheck disable=SC2053
      [[ ".env.example" == ${line#!} ]] && verdict="included"
    else
      # shellcheck disable=SC2053
      [[ ".env.example" == $line ]] && verdict="excluded"
    fi
  done < "$di"
  [[ "$verdict" == "excluded" ]] && echo "disarmed-excluded" || echo "armed"
}

check "the trigger is ARMED -- upstream re-included the template on 2026-08-24" \
  "armed" "$(eng167_trigger_state "$REPO_ROOT")"

# POSITIVE CONTROL, and it INVERTED with the verdict above on 2026-08-24. The control must
# always prove the query can return something OTHER than what the live assertion expects --
# otherwise a function hardwired to the expected value passes that line forever. While the
# live verdict was "disarmed-excluded" this fixture proved the function could say "armed";
# now that the live verdict IS "armed", it has to prove the opposite. Leaving the old
# control in place would have made the pair tautological. Same edge openfathom-meta ENG-123
# pays for repeatedly.
E167_POS="$WORK/eng167-excluded"; mkdir -p "$E167_POS"; touch "$E167_POS/.env.example"
printf 'node_modules\n*.pyc\n.env.example\n' > "$E167_POS/.dockerignore"
check "control -- a .dockerignore that DOES exclude it still reads as disarmed" \
  "disarmed-excluded" "$(eng167_trigger_state "$E167_POS")"

echo "== MUTANT: ENG-167 -- upstream re-includes .env.example with a negation =="
# The subtle arming, and the reason this walks the file instead of grepping for the
# pattern: both exclusion lines survive, so a grep-based guard would still report them and
# stay green while the file is back in the build context.
E167_NEG="$WORK/eng167-negated"; mkdir -p "$E167_NEG"; touch "$E167_NEG/.env.example"
printf '.env\n.env.*\n.env.example\n!.env.example\n' > "$E167_NEG/.dockerignore"
check "a later '!' re-inclusion arms the trigger, and the guard says so" \
  "armed" "$(eng167_trigger_state "$E167_NEG")"

echo "== MUTANT: ENG-167 -- the exclusions are dropped from .dockerignore =="
# The blunt arming: a sync rewrites .dockerignore without the .env rules. This fixture is
# synthetic on purpose, so it keeps documenting that the `.env.*` glob ALONE disarms the
# file and that losing only one exclusion line is NOT enough to arm it -- a fact that
# outlives the real file's layout. (Before 2026-08-24 the live file carried two exclusions,
# `.env.*` and a by-name `.env.example`; the sync dropped the by-name line and added a `!`
# re-inclusion instead. Line numbers are deliberately not cited here -- they rot.)
E167_ONE="$WORK/eng167-glob-only"; mkdir -p "$E167_ONE"; touch "$E167_ONE/.env.example"
printf '.env\n.env.*\n' > "$E167_ONE/.dockerignore"
check "the glob alone still disarms it -- dropping the by-name line is not enough" \
  "disarmed-excluded" "$(eng167_trigger_state "$E167_ONE")"
E167_NONE="$WORK/eng167-no-rules"; mkdir -p "$E167_NONE"; touch "$E167_NONE/.env.example"
printf '.git\n__pycache__\n' > "$E167_NONE/.dockerignore"
check "dropping BOTH arms it, and the guard fires" \
  "armed" "$(eng167_trigger_state "$E167_NONE")"

echo "== MUTANT: ENG-167 -- the source of truth disappears entirely =="
# openfathom-meta AGENTS.md: "Um check que perdeu a fonte de verdade tem de gritar, não
# emudecer." Without .dockerignore there is no way to know what reaches the build context,
# and reporting "disarmed" there would be a lie told with a green CI.
E167_GONE="$WORK/eng167-no-di"; mkdir -p "$E167_GONE"; touch "$E167_GONE/.env.example"
check "no .dockerignore -> shouts instead of vouching for a state it cannot see" \
  "no-dockerignore" "$(eng167_trigger_state "$E167_GONE")"

# ---------------------------------------------------------------------------
# of_metadata_token (openfathom-meta ENG-244, ADR-067 Decision 3) -- the token path off
# GCP. metadata.google.internal does not resolve outside GCP, so on the Hetzner VPS (and
# in the local Phase 1 rehearsal that precedes the migration) every caller of this function
# loses its token at once. That produces the rehearsal's own negative signals -- zero
# skills, a lost first turn -- which would read as a refutation of ADR-067 while only
# measuring the absence of the metadata server.
#
# WHAT THIS CASE CAN AND CANNOT PROVE. It proves the BRANCH SELECTION: which source is
# consulted, in which order, and what happens when neither answers. It does NOT prove that
# google-auth imports inside the image or that a real service-account key mints a real
# token -- the python3 heredoc is stubbed, because google-auth is not installed on a dev
# box or on this runner. That is the boundary of what a fake can assert; only the rehearsal
# closes it, and the entrypoint comment says so too.
#
# Everything here runs in subshells: sourcing the real function at top level would clobber
# the `of_metadata_token() { echo "stub-token"; }` stub the rest of this file depends on.
# ---------------------------------------------------------------------------
echo "== case: of_metadata_token -- GOOGLE_APPLICATION_CREDENTIALS fallback =="

MDT_FN="$WORK/mdt.sh"
extract_one_fn "$MDT_FN" of_metadata_token

MDT_CALLS="$WORK/mdt-calls"
MDT_SA="$WORK/sa-key.json"
printf '{"type":"service_account","client_email":"x@y.iam.gserviceaccount.com"}\n' > "$MDT_SA"

# curl stands in for the metadata server, switchable by MDT_MD. python3 is stubbed ONLY on
# the heredoc form (`python3 - <file>`, the fallback); the `-c` form that parses the
# metadata JSON keeps running for real, so the happy path is not faked into passing.
mdt_env() {
  curl() {
    echo "CURL" >> "$MDT_CALLS"
    case "$MDT_MD" in
      up)    printf '{"access_token":"token-from-metadata"}\n'; return 0 ;;
      empty) printf '{"expires_in":3599}\n'; return 0 ;;          # 200, but no token in it
      *)     return 7 ;;                                          # curl: could not connect
    esac
  }
  python3() {
    if [[ "${1:-}" == "-" ]]; then
      echo "FALLBACK ${2:-}" >> "$MDT_CALLS"
      cat > /dev/null
      printf 'token-from-sa-key\n'
      return 0
    fi
    command python3 "$@"
  }
}

mdt_run() { # mdt_run <fn-file> <metadata-state: up|empty|down> <GOOGLE_APPLICATION_CREDENTIALS or "">
  : > "$MDT_CALLS"
  local t; t="$(mktemp -d -p "$WORK")"   # a fresh TMPDIR = a fresh container, so the
  ( # shellcheck disable=SC1090          # once-per-container announcement starts unfired
    source "$1"
    MDT_MD="$2"
    mdt_env
    export TMPDIR="$t"
    if [[ -n "$3" ]]; then export GOOGLE_APPLICATION_CREDENTIALS="$3"; else unset GOOGLE_APPLICATION_CREDENTIALS; fi
    of_metadata_token 2>/dev/null || echo "__NONZERO__"
  )
}

# Two consecutive calls inside ONE container (one TMPDIR), counting the announcements. The
# sync loops call of_metadata_token on a timer, so "announces" and "announces every time"
# are different behaviours and only one of them is wanted.
mdt_twice() { # mdt_twice <fn-file> <metadata-state> <GOOGLE_APPLICATION_CREDENTIALS>
  local t; t="$(mktemp -d -p "$WORK")"
  ( # shellcheck disable=SC1090
    source "$1"
    MDT_MD="$2"
    mdt_env
    export TMPDIR="$t"
    export GOOGLE_APPLICATION_CREDENTIALS="$3"
    of_metadata_token >/dev/null
    of_metadata_token >/dev/null
  ) 2>&1 | grep -c 'metadata server unreachable'
}

# Order, and it is the case that protects production: with the metadata server answering,
# the fallback must not be consulted AT ALL -- even with a key sitting right there.
check "metadata server answering -> its token is the one returned" \
  "token-from-metadata" "$(mdt_run "$MDT_FN" up "$MDT_SA")"
check "metadata server answering -> the key file is never read (fallback not consulted)" \
  "0" "$(grep -c '^FALLBACK' "$MDT_CALLS")"

check "metadata server unreachable + key present -> the fallback mints the token" \
  "token-from-sa-key" "$(mdt_run "$MDT_FN" down "$MDT_SA")"
check "the fallback is handed exactly the path GOOGLE_APPLICATION_CREDENTIALS names" \
  "FALLBACK $MDT_SA" "$(grep '^FALLBACK' "$MDT_CALLS")"
check "the metadata server is still TRIED first, not skipped" \
  "1" "$(grep -c '^CURL' "$MDT_CALLS")"

# A 200 that carries no access_token is not success. Before this change the python3 -c would
# raise and the function returned empty-but-zero-ish through the pipe; now it must fall back.
check "metadata answers 200 without an access_token -> falls back rather than returning empty" \
  "token-from-sa-key" "$(mdt_run "$MDT_FN" empty "$MDT_SA")"

# No key, no token: all seven callers branch on a non-zero return, so this must stay
# non-zero rather than print an empty string and look like success.
check "metadata unreachable and no key configured -> non-zero, nothing on stdout" \
  "__NONZERO__" "$(mdt_run "$MDT_FN" down "")"
check "metadata unreachable and the key path does not exist -> non-zero, not a crash" \
  "__NONZERO__" "$(mdt_run "$MDT_FN" down "$WORK/no-such-key.json")"

# Falling back must be VISIBLE. Inside GCP it means the metadata server broke and the key is
# covering for it, which is a degradation that would otherwise boot green and say nothing.
check "falling back announces itself EXACTLY once across two calls in one container" \
  "1" "$(mdt_twice "$MDT_FN" down "$MDT_SA")"
check "the metadata server answering announces nothing -- silence is the healthy path" \
  "0" "$(mdt_twice "$MDT_FN" up "$MDT_SA")"

echo "== MUTANT: of_metadata_token -- the announcement fires on every call =="
# The noise failure, which is how a real signal stops being read. Asserts the specific wrong
# count (2 for two calls), not merely "differs".
extract_one_fn "$WORK/mdt-noisy.sh" of_metadata_token \
  's|if \[\[ ! -e "$announced" \]\]; then|if true; then|'
if grep -q 'if true; then' "$WORK/mdt-noisy.sh"; then
  check "guard removed -> both calls announce, which is the line people learn to skip" \
    "2" "$(mdt_twice "$WORK/mdt-noisy.sh" down "$MDT_SA")"
else
  bad "announcement-guard mutation did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== MUTANT: of_metadata_token -- the fallback is removed (the pre-ENG-244 state) =="
# The regression this change exists to prevent: off GCP there is no second source, so the
# rehearsal produces its own negative signals and ADR-067 Decision 3 looks refuted.
extract_one_fn "$WORK/mdt-nofb.sh" of_metadata_token \
  's|^  \[\[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}".*|  return 1|'
if grep -q '^  return 1$' "$WORK/mdt-nofb.sh"; then
  check "fallback removed -> no token at all, even with a valid key present" \
    "__NONZERO__" "$(mdt_run "$WORK/mdt-nofb.sh" down "$MDT_SA")"
  check "fallback removed -> the key file is never consulted" \
    "0" "$(grep -c '^FALLBACK' "$MDT_CALLS")"
else
  bad "fallback-removal mutation did not apply -- a mutant that does not mutate proves nothing"
fi

echo "== MUTANT: of_metadata_token -- the metadata token is discarded, so the key wins =="
# The inverse defect, and the one that would hurt PRODUCTION rather than the rehearsal:
# preferring the long-lived key over the metadata server. The Worker Pool would start
# authenticating with a key it does not need, and nothing in a boot log would say so.
extract_one_fn "$WORK/mdt-order.sh" of_metadata_token \
  's|if \[\[ -n "$tok" \]\]; then|if [[ -n "" ]]; then|'
if grep -q 'if \[\[ -n "" \]\]; then' "$WORK/mdt-order.sh"; then
  check "metadata result ignored -> the key's token is returned although the server answered" \
    "token-from-sa-key" "$(mdt_run "$WORK/mdt-order.sh" up "$MDT_SA")"
  check "metadata result ignored -> the fallback ran on a boot that never needed it" \
    "1" "$(grep -c '^FALLBACK' "$MDT_CALLS")"
else
  bad "token-order mutation did not apply -- a mutant that does not mutate proves nothing"
fi

# ---------------------------------------------------------------------------
# openfathom-meta ENG-171: of_configure_openrouter_route. The shell half is EXECUTED here
# (python3 is replaced by a recorder, since hermes_cli is not importable in this job): the
# provider gate and the six guards, each with its mutant. The python half -- what lands in
# config.yaml -- is proven by running the published image, not by this file.
# ---------------------------------------------------------------------------
echo "== case: ENG-171 openrouter route =="
OR_CALLS="$WORK/or-calls"; OR_ERR="$WORK/or-err"
or_run() { # or_run <fn-file> [VAR=value ...] -> prints "rc=<n>"; python3 argv in $OR_CALLS, stderr in $OR_ERR
  local fn_file="$1"; shift
  : > "$OR_CALLS"
  ( set +e
    python3() { echo "PY $*" >> "$OR_CALLS"; cat > /dev/null; return 0; }
    # shellcheck disable=SC1090
    source "$fn_file"
    export HERMES_INFERENCE_PROVIDER=openrouter HERMES_OPENROUTER_ONLY=together \
      HERMES_INFERENCE_MODEL=z-ai/glm-5.3 HERMES_OPENROUTER_REASONING_EFFORT=low \
      HERMES_VISION_PROVIDER=anthropic HERMES_VISION_MODEL=claude-sonnet-5 \
      HERMES_AUX_PROVIDER=anthropic HERMES_AUX_MODEL=claude-sonnet-5 ANTHROPIC_API_KEY=sk-ant-test
    local kv; for kv in "$@"; do export "$kv"; done
    of_configure_openrouter_route 2> "$OR_ERR"
    echo "rc=$?" )
}
extract_one_fn "$WORK/or.sh" of_configure_openrouter_route
check "anthropic provider -> no-op, rc 0" "rc=0" "$(or_run "$WORK/or.sh" HERMES_INFERENCE_PROVIDER=anthropic)"
check "anthropic provider -> config untouched (python never runs)" "0" "$(grep -c '^PY' "$OR_CALLS")"
check "openrouter with every pin -> writes" "rc=0" "$(or_run "$WORK/or.sh")"
check "openrouter with every pin -> python gets hosts, model, effort, vision and aux pins" \
  "PY - together z-ai/glm-5.3 low anthropic claude-sonnet-5 anthropic claude-sonnet-5" "$(cat "$OR_CALLS")"
# One row per guard: the env that trips it, and the return code that names it.
OR_GUARDS=(
  "1|HERMES_OPENROUTER_ONLY=|no host list"
  "1|HERMES_OPENROUTER_ONLY= , |only separators"
  "2|HERMES_VISION_MODEL=|no vision model"
  "2|HERMES_VISION_PROVIDER=|no vision provider"
  "3|HERMES_AUX_MODEL=|no aux model"
  "4|HERMES_OPENROUTER_REASONING_EFFORT=|no effort"
  "5|ANTHROPIC_API_KEY=|anthropic pins without the anthropic key"
  "6|HERMES_VISION_PROVIDER=openrouter|vision on the chain that cannot see"
)
for row in "${OR_GUARDS[@]}"; do
  IFS='|' read -r rc env label <<< "$row"
  check "openrouter, $label -> refuses to boot (rc $rc)" "rc=$rc" "$(or_run "$WORK/or.sh" "$env")"
  check "openrouter, $label -> nothing written" "0" "$(grep -c '^PY' "$OR_CALLS")"
  check "openrouter, $label -> says why, on stderr" "1" "$(grep -c '^FATAL: HERMES_INFERENCE_PROVIDER=openrouter' "$OR_ERR")"
done

for rc in 1 2 3 4 5 6; do
  echo "== MUTANT: ENG-171 guard $rc removed =="
  extract_one_fn "$WORK/or-m$rc.sh" of_configure_openrouter_route "s/^    return $rc\$/    :/"
  if grep -q "^    return $rc\$" "$WORK/or-m$rc.sh"; then
    bad "guard $rc mutation did not apply -- a mutant that does not mutate proves nothing"; continue
  fi
  env=$(printf '%s\n' "${OR_GUARDS[@]}" | awk -F'|' -v r="$rc" '$1==r {print $2; exit}')
  check "guard $rc removed -> the case it exists for boots ($env)" "rc=0" "$(or_run "$WORK/or-m$rc.sh" "$env")"
done

echo "== MUTANT: ENG-171 provider gate removed =="
extract_one_fn "$WORK/or-nogate.sh" of_configure_openrouter_route 's/ || return 0$/ || true/'
if grep -q '|| true$' "$WORK/or-nogate.sh"; then
  or_run "$WORK/or-nogate.sh" HERMES_INFERENCE_PROVIDER=anthropic > /dev/null
  check "gate removed -> an anthropic deployment gets OpenRouter routing written" \
    "1" "$(grep -c '^PY' "$OR_CALLS")"
else
  bad "provider gate mutation did not apply -- a mutant that does not mutate proves nothing"
fi

# Text, not execution: these prove the lines exist in the shipped script, not that hermes_cli
# writes them -- that is proven by running the published image (openfathom-meta ENG-171).
echo "== structural: ENG-171 what the python half writes, and when it runs =="
check "routing pins the hosts and refuses data collection" \
  "1" "$(grep -c '_set_nested(cfg, "provider_routing", {"only": only, "data_collection": "deny"})' "$ENTRYPOINT")"
check "the effort override is keyed by the model, not global" \
  "1" "$(grep -c '_set_nested(cfg, "agent.reasoning_overrides", {model: effort})' "$ENTRYPOINT")"
check "telegram never shows the reasoning a mandatory-reasoning model produces" \
  "1" "$(grep -c '_set_nested(cfg, "display.platforms.telegram.show_reasoning", False)' "$ENTRYPOINT")"
check "compression and title_generation move to the aux pin" \
  "1" "$(grep -c 'for task in ("compression", "title_generation"):' "$ENTRYPOINT")"
none_line=$(grep -n '^    of_configure_reasoning_effort$' "$ENTRYPOINT" | cut -d: -f1)
aux_line=$(grep -n '^      hermes config set auxiliary.title_generation.model ' "$ENTRYPOINT" | cut -d: -f1)
call_line=$(grep -n '^    of_configure_openrouter_route$' "$ENTRYPOINT" | cut -d: -f1)
check "the route is configured after the global reasoning effort" \
  "1" "$([[ -n "$none_line" && -n "$call_line" && "$call_line" -gt "$none_line" ]] && echo 1 || echo 0)"
check "the route is configured after the ENG-83 aux block it overrides" \
  "1" "$([[ -n "$aux_line" && -n "$call_line" && "$call_line" -gt "$aux_line" ]] && echo 1 || echo 0)"

# openfathom-meta ENG-349: build-check cuts of_configure_compression out of the file and runs
# it alone, so it proves the WRITER and never that the service block CALLS it -- deleting the
# call would leave every job green. A text check on the call site, between the two writers
# it sits with. Mutant: the call line removed.
cc_line=$(grep -n '^    of_configure_compression$' "$ENTRYPOINT" | cut -d: -f1)
check "the service block calls of_configure_compression exactly once (ENG-349)" \
  "1" "$(grep -c '^    of_configure_compression$' "$ENTRYPOINT")"
check "the compression writer is called next to the other config writers (ENG-349)" \
  "1" "$([[ -n "$cc_line" && -n "$none_line" && -n "$call_line" && "$cc_line" -gt "$none_line" && "$cc_line" -lt "$call_line" ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# openfathom-meta ENG-171: of_configure_reasoning_effort. All of it is python, so this file
# can only prove the text; the build-check job of of-build-image.yml runs it inside the
# built image and asserts what the resolver reads (the proof that executes).
# ---------------------------------------------------------------------------
echo "== structural: ENG-171 the effort is a string, and the display flag is pinned =="
check "the old null-writing line is gone" \
  "0" "$(grep -c '^    hermes config set agent.reasoning_effort none$' "$ENTRYPOINT")"
check "the effort is written as the string medium" \
  "1" "$(grep -c '_set_nested(cfg, "agent.reasoning_effort", "medium")' "$ENTRYPOINT")"
check "the Gemini fallback is not pinned off (its native adapter separates reasoning)" \
  "0" "$(grep -c 'gemini-3.6-flash"\] = "none"' "$ENTRYPOINT")"

# ---------------------------------------------------------------------------
# openfathom-meta ENG-373 and ENG-362. Three properties, each with its input domain and
# its mutants (the plan's item-30 list, one case or refusal per line):
#   1. the pin -- a skills/plugins tarball loads only when its sha256 is the pinned one;
#   2. the restore -- a snapshot lands only the paths of_state_snapshot writes, as regular
#      files and directories, and a restore that fails forgets the generation it read, so
#      the first upload merges into the live snapshot instead of replacing it;
#   3. the lock -- hooks/ and profiles/ are read-only before of_state_restore runs.
# ---------------------------------------------------------------------------
echo "== case: ENG-373 -- the pin =="
PIN_DEST="$WORK/pin-dest"
pin_fetch() { # <pin> <served> -> "rc|stderr"; dest holds a marker the refusal must not touch
  chmod -R u+w "$PIN_DEST" 2>/dev/null; rm -rf "$PIN_DEST"; mkdir -p "$PIN_DEST"; : > "$PIN_DEST/marker"
  reset_stub; LIVE="$2"
  local out rc; out="$( (HERMES_PLUGINS_SHA256="$1"; of_plugins_fetch "$PIN_DEST" 2>&1 >/dev/null) )"; rc=$?
  printf '%s|%s' "$rc" "$out"
}
OK_SHA="$(sha_of "$PLUG_OK")"
PLUG_TRUNC="$WORK/plug-trunc.tar.gz"; head -c 40 "$PLUG_OK" > "$PLUG_TRUNC"
r="$(pin_fetch "" "$PLUG_OK")"
check "pin unset -> refused"                       "1"   "${r%%|*}"
check "... says unset, names the variable"         "1"   "$(grep -c 'HERMES_PLUGINS_SHA256 is unset' <<< "${r#*|}")"
check "... and touched nothing in dest"            "yes" "$([[ -f "$PIN_DEST/marker" ]] && echo yes || echo no)"
r="$(pin_fetch "abc123" "$PLUG_OK")"
check "pin malformed -> refused"                   "1"   "${r%%|*}"
check "... as not a sha256"                        "1"   "$(grep -c 'is not a sha256' <<< "${r#*|}")"
r="$(pin_fetch "${OK_SHA:0:32} ${OK_SHA:32}" "$PLUG_OK")"
check "pin with an inner space -> refused"         "1"   "${r%%|*}"
r="$(pin_fetch "$(sha_of "$PLUG_NO")" "$PLUG_OK")"
check "the right hash of ANOTHER tarball -> refused" "1" "${r%%|*}"
check "... as a mismatch"                          "1"   "$(grep -c 'sha256 mismatch' <<< "${r#*|}")"
r="$(pin_fetch "$OK_SHA" "$PLUG_TRUNC")"
check "a truncated tarball under the full pin -> refused" "1" "${r%%|*}"
r="$(pin_fetch "$OK_SHA" "")"
check "download fails (404) -> refused, as before" "1"   "${r%%|*}"
r="$(pin_fetch "$(printf '  %s\n' "${OK_SHA^^}")" "$PLUG_OK")"
check "surrounding whitespace, a newline and upper-case hex -> loads" "0" "${r%%|*}"
reset_stub; LIVE="$PLUG_OK"
pin_line="$( (HERMES_PLUGINS_SHA256="$OK_SHA"; of_plugins_fetch "$PIN_DEST" 2>/dev/null) )"
check "the loaded line prints the verified digest" "yes" "$([[ "$pin_line" == *"(sha256 ${OK_SHA})"* ]] && echo yes || echo no)"
reset_stub; LIVE="$SKILL_OK"
out="$( (HERMES_SKILLS_SHA256="$(sha_of "$PLUG_OK")"; of_skills_fetch "$WORK/pin-skills" 2>&1 >/dev/null) )"; rc=$?
check "of_skills_fetch: a mismatched pin -> refused" "1" "$rc"
check "... with its own tag and variable"          "1"   "$(grep -c '\[of-skills\] ERROR: sha256 mismatch' <<< "$out")"

echo "== case: ENG-373 -- the restore lands only state =="
# The honest snapshot, as of_state_snapshot writes it, plus every member the domain list
# names. Built in Python because tar(1) will not write an absolute name or a hardlink to
# order, and the point is to hand the extractor what an attacker would.
mk_restore_tarball() { # <out> <honest|evil>
  python3 - "$1" "$2" <<'PY'
import io, sys, tarfile, time
out, kind = sys.argv[1], sys.argv[2]
def add(tf, name, data=b"x", **kw):
    ti = tarfile.TarInfo(name); ti.mtime = int(time.time())
    for k, v in kw.items(): setattr(ti, k, v)
    if ti.type in (tarfile.REGTYPE, tarfile.AREGTYPE):
        ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
    else:
        tf.addfile(ti)
with tarfile.open(out, "w:gz") as tf:
    add(tf, "./.state_epoch", b"3\n")
    add(tf, "./state.db", b"honest-db")
    add(tf, "./plans", type=tarfile.DIRTYPE, mode=0o755)
    add(tf, "./plans/p.md", b"plan")
    add(tf, "./pairing/telegram.json", b"{}")
    add(tf, "./cron/jobs.json", b"[]")
    if kind == "evil":
        add(tf, "./config.yaml", b"agent: {disabled_toolsets: []}\n")
        add(tf, "./.env", b"TELEGRAM_ALLOWED_USERS=*\n")
        add(tf, "./skills/x/SKILL.md", b"evil")
        add(tf, "skills/y/SKILL.md", b"evil")
        add(tf, "./openfathom-skills/x/SKILL.md", b"evil")
        add(tf, "./hooks/h/handler.py", b"raise SystemExit")
        add(tf, "./profiles/p/SOUL.md", b"evil")
        add(tf, "./scripts/p.sh", b"id")
        add(tf, "./plans/l", type=tarfile.SYMTYPE, linkname="/etc/passwd")
        add(tf, "./pairing/h", type=tarfile.LNKTYPE, linkname="./state.db")
        add(tf, "./foo", type=tarfile.SYMTYPE, linkname="plugins")
        add(tf, "./foo/x", b"evil")
        add(tf, "../x", b"evil")
        add(tf, "/etc/x", b"evil")
PY
}
RS_HONEST="$WORK/rs-honest.tar.gz"; mk_restore_tarball "$RS_HONEST" honest
RS_EVIL="$WORK/rs-evil.tar.gz";     mk_restore_tarball "$RS_EVIL" evil
rs_home() { # fresh $HERMES_HOME holding the config the boot already wrote
  RS_HOME="$WORK/rs-home-$1"; chmod -R u+w "$RS_HOME" 2>/dev/null; rm -rf "$RS_HOME"; mkdir -p "$RS_HOME"
  printf 'SAFE\n' > "$RS_HOME/config.yaml"; export HERMES_HOME="$RS_HOME"
}
rs_home honest; reset_stub; LIVE="$RS_HONEST"; LIVE_GEN="42"; of_state_generation=""
of_state_restore > "$WORK/rs-honest.out" 2>&1; out="$(cat "$WORK/rs-honest.out")"   # not $(...): the generation must reach this shell
check "honest snapshot: every member extracted, none refused" "1" "$(grep -c 'restore: 5 extracted, 0 refused' <<< "$out")"
check "honest snapshot: state.db, plans, pairing and cron landed" "4" \
  "$(for f in state.db plans/p.md pairing/telegram.json cron/jobs.json; do [[ -f "$RS_HOME/$f" ]] && echo y; done | wc -l)"
check "honest snapshot: the generation read is kept"  "42"  "$of_state_generation"
check "honest snapshot: the epoch is read"            "3"   "$of_state_epoch"
rs_home evil; reset_stub; LIVE="$RS_EVIL"; LIVE_GEN="42"
out="$(of_state_restore 2>&1)"
check "evil snapshot: the 5 state members land, all 14 others are refused" "1" "$(grep -c 'restore: 5 extracted, 14 refused' <<< "$out")"
check "evil snapshot: config.yaml the boot wrote is untouched" "SAFE" "$(cat "$RS_HOME/config.yaml")"
for f in .env skills openfathom-skills hooks profiles scripts foo plans/l pairing/h; do
  check "evil snapshot: $f is not on disk" "no" "$([[ -e "$RS_HOME/$f" || -L "$RS_HOME/$f" ]] && echo yes || echo no)"
done
check "evil snapshot: nothing escaped the home (../x)" "no" "$([[ -e "$(dirname "$RS_HOME")/x" ]] && echo yes || echo no)"
check "evil snapshot: each refusal is named"     "14"  "$(grep -c 'refused archive member' <<< "$out")"
# A link already on disk is not a door either: cron -> outside, and a member under cron/.
rs_home link; mkdir -p "$WORK/rs-outside"; ln -s "$WORK/rs-outside" "$RS_HOME/cron"
reset_stub; LIVE="$RS_HONEST"
out="$(of_state_restore 2>&1)"
check "a member through a link on disk is refused" "1" "$(grep -c "refused archive member './cron/jobs.json'" <<< "$out")"
check "... and nothing was written outside"       "no" "$([[ -e "$WORK/rs-outside/jobs.json" ]] && echo yes || echo no)"

echo "== case: ENG-373 -- a failed restore forgets the generation =="
RS_GARBAGE="$WORK/rs-garbage.tar.gz"; printf 'not a tarball\n' > "$RS_GARBAGE"
RS_TRUNC="$WORK/rs-trunc.tar.gz"; head -c 60 "$RS_EVIL" > "$RS_TRUNC"
for spec in "garbage|$RS_GARBAGE" "truncated|$RS_TRUNC" "HTTP 500 after the generation|HTTP500"; do
  IFS='|' read -r label served <<< "$spec"
  rs_home fail; reset_stub; LIVE="$served"; LIVE_GEN="42"; of_state_generation=""
  of_state_restore > "$WORK/rs-fail.out" 2>&1; out="$(cat "$WORK/rs-fail.out")"
  check "$label: generation forced to 0 (not 42)"  "0" "$of_state_generation"
  check "$label: epoch forced to 0"               "0" "$of_state_epoch"
  check "$label: says why, at ERROR"              "1" "$(grep -c '\[of-state\] ERROR: restore failed' <<< "$out")"
done
# What a failed restore must do with the first upload, in production's shape: the live
# object at epoch 2 (read from the bucket on 2026-11-09), real compare-and-swap. The live
# snapshot must come out byte for byte the same, and this boot's turn must survive in the
# parked conflict object. Two failures: an archive that does not open at all, and one that
# breaks AFTER landing .state_epoch -- where reading the epoch back would make the 412 path
# merge and upload this boot's incomplete plans/, pairing/ and cron/ over the live ones.
RS_PARTIAL="$WORK/rs-partial.tar.gz"
python3 - "$RS_PARTIAL" <<'PY'
import io, os, sys, tarfile
full = sys.argv[1] + ".full"
with tarfile.open(full, "w:gz") as tf:
    for name, data in ((".state_epoch", b"2\n"), ("state.db", os.urandom(200_000))):
        ti = tarfile.TarInfo("./" + name); ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
raw = open(full, "rb").read()
open(sys.argv[1], "wb").write(raw[: len(raw) // 2])
PY
rs_park_case() { # <fns-file or ""> <served restore tarball> -> "<live unchanged>,<turn parked>"
  RSC_HOME="$WORK/rsc-home"; chmod -R u+w "$RSC_HOME" 2>/dev/null; rm -rf "$RSC_HOME"; mkdir -p "$RSC_HOME"
  export HERMES_HOME="$RSC_HOME"
  RSC_LIVE="$WORK/rsc-live.tar.gz"; RSC_ORIG="$WORK/rsc-live-orig.tar.gz"
  mk_full_state "$RSC_LIVE" 2 "s0" "7:s0:user:50:history-in-the-object"; cp -f "$RSC_LIVE" "$RSC_ORIG"
  ( [[ -n "$1" ]] && source "$1"
    reset_stub; LIVE="$2"; LIVE_GEN="42"; of_state_generation=""; of_state_epoch=""; of_state_restore_failed=""
    of_state_restore >/dev/null 2>&1
    rm -f "$RSC_HOME/state.db"; mk_full_db "$RSC_HOME/state.db" "s1" "1:s1:user:100:said-this-boot"
    cas_enable 42 "$RSC_LIVE"
    of_state_snapshot >/dev/null 2>&1 )
  local parked=0 d; d="$(mktemp -d -p "$WORK")"
  if [[ -f "$UPLOADED" ]] && grep -q 'conflict-' "$CALLS"; then
    tar xzf "$UPLOADED" -C "$d" 2>/dev/null
    parked="$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from messages where content=?",("said-this-boot",)).fetchone()[0])' "$d/state.db" 2>/dev/null || echo 0)"
  fi
  printf '%s,%s' "$(cmp -s "$CAS_LIVE" "$RSC_ORIG" && echo same || echo changed)" "$parked"
}
check "unreadable snapshot + one upload: the live object is untouched, this boot's turn is parked" "same,1" "$(rs_park_case "" "$RS_GARBAGE")"
check "partial snapshot that landed .state_epoch: still parked, never merged" "same,1" "$(rs_park_case "" "$RS_PARTIAL")"
echo "== case: ENG-373 -- the memories restore follows the same rule =="
export HERMES_MEMORIES_OBJECT="memories.tar.gz"
rs_home mem; reset_stub; LIVE="$RS_GARBAGE"; LIVE_GEN="42"; of_memories_generation=""
of_memories_restore >/dev/null 2>&1
check "memories: an unreadable tarball forgets the generation" "0" "$of_memories_generation"
MEM_LINK="$WORK/mem-link.tar.gz"
python3 - "$MEM_LINK" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    ti = tarfile.TarInfo("./MEMORY.md"); ti.type = tarfile.SYMTYPE; ti.linkname = "/etc/hostname"; tf.addfile(ti)
    ti = tarfile.TarInfo("./USER.md"); data = b"likes tea"; ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
PY
rs_home memlink; reset_stub; LIVE="$MEM_LINK"; LIVE_GEN="42"; of_state_epoch=0
out="$(of_memories_restore 2>&1)"
check "memories: a link member is refused, the regular file is merged" "1" "$(grep -c '(1 extracted, 1 refused)' <<< "$out")"
check "memories: the link target was not read into MEMORY.md" "no" "$([[ -s "$RS_HOME/memories/MEMORY.md" ]] && echo yes || echo no)"

echo "== case: ENG-373 -- the memories MERGE path extracts like the restore =="
# A planted memories.tar.gz moves the object's generation, so the next memories tick gets a
# 412 and downloads it: that download must not follow a link either, or of_memory_union
# reads whatever it points at (the review named /proc/self/environ) into the memories.
printf 'SECRET-FROM-OUTSIDE\n' > "$WORK/outside-secret.txt"
MEM_412="$WORK/mem-412.tar.gz"
python3 - "$MEM_412" "$WORK/outside-secret.txt" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    ti = tarfile.TarInfo("./MEMORY.md"); ti.type = tarfile.SYMTYPE; ti.linkname = sys.argv[2]; tf.addfile(ti)
PY
mem412_case() { # <fns-file or ""> -> "leaked" if the outside file reached the memories
  local h="$WORK/mem412-home"; chmod -R u+w "$h" 2>/dev/null; rm -rf "$h"; mkdir -p "$h/memories"
  printf 'likes tea' > "$h/memories/USER.md"
  ( [[ -n "$1" ]] && source "$1"
    export HERMES_HOME="$h"; reset_stub; cas_enable 77 "$MEM_412"
    of_memories_generation=42; of_state_epoch=0
    of_memories_snapshot >/dev/null 2>&1 )
  # The 412 path unions into the tarball it re-uploads, not into memories/ on disk: the
  # leak, if any, is in the object the next boot restores.
  local d; d="$(mktemp -d -p "$WORK")"; tar xzf "$CAS_LIVE" -C "$d" 2>/dev/null
  grep -rqs 'SECRET-FROM-OUTSIDE' "$h/memories" "$d" && echo leaked || echo clean
}
check "a link planted in the live memories is not followed on the 412 merge" "clean" "$(mem412_case "")"
probe_mem412() { # survived = the merge path still does not follow the link
  local fl; fl="$(fns_of "$1" of_safe_extract of_memory_union of_memories_tarball_epoch of_memories_snapshot of_memories_write_with_merge_retry of_gcs_read_generation)"
  [[ "$(mem412_case "$fl")" == clean ]] && echo survived || echo killed
}
rs_home memhttp; reset_stub; LIVE="HTTP500"; LIVE_GEN="42"; of_memories_generation=""
of_memories_restore >/dev/null 2>&1
check "memories: an HTTP 500 after the generation forgets it" "0" "$of_memories_generation"

echo "== case: ENG-373 -- a real snapshot round-trips through the allow-list =="
# Not a hand-picked member list: what of_state_snapshot itself writes from a populated
# home, restored with the allow-list. Anything it writes that the list refuses is lost
# state at every boot.
RT_HOME="$WORK/rt-home"; rm -rf "$RT_HOME"; mkdir -p "$RT_HOME"/{plans,pairing,cron}
mk_full_db "$RT_HOME/state.db" "s1" "1:s1:user:100:round-trip"
printf 'plan\n' > "$RT_HOME/plans/p.md"; printf '{}\n' > "$RT_HOME/pairing/telegram.json"; printf '[]\n' > "$RT_HOME/cron/jobs.json"
printf 'soul\n' > "$RT_HOME/SOUL.md"   # not state: of_state_snapshot leaves it out by design
export HERMES_HOME="$RT_HOME"; reset_stub; of_state_generation=0; of_state_epoch=2
of_state_snapshot >/dev/null 2>&1
RT_TARBALL="$WORK/rt-uploaded.tar.gz"; cp -f "$UPLOADED" "$RT_TARBALL"   # reset_stub deletes $UPLOADED
rs_home roundtrip; reset_stub; LIVE="$RT_TARBALL"; LIVE_GEN="42"; of_state_restore_failed=""
of_state_restore > "$WORK/rt.out" 2>&1
check "round trip: everything the snapshot wrote is restored, nothing refused" "1" "$(grep -c 'restore: 5 extracted, 0 refused' "$WORK/rt.out")"
check "round trip: the turn is back"  "1" "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from messages where content=?",("round-trip",)).fetchone()[0])' "$RS_HOME/state.db" 2>/dev/null)"
check "round trip: the epoch is back" "2" "$of_state_epoch"

echo "== case: ENG-373 -- a bad header after the first member is a failed restore =="
RS_TAILJUNK="$WORK/rs-tailjunk.tar.gz"
python3 - "$RS_TAILJUNK" <<'PY'
import gzip, io, os, sys, tarfile
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as tf:
    for name, data in ((".state_epoch", b"2\n"), ("state.db", b"db")):
        ti = tarfile.TarInfo("./" + name); ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
raw = buf.getvalue()
first = 512 + 512          # header + one padded data block of the first member
bad = raw[:first] + os.urandom(512) + raw[first:]
open(sys.argv[1], "wb").write(gzip.compress(bad))
PY
rs_home tailjunk; reset_stub; LIVE="$RS_TAILJUNK"; LIVE_GEN="42"; of_state_restore_failed=""
of_state_restore >/dev/null 2>&1
check "garbage after the first member: the restore fails instead of passing as partial" "0" "$of_state_generation"
probe_tailjunk() { # survived = the junk still fails the restore
  local fl; fl="$(fns_of "$1" of_safe_extract of_state_restore_failed of_state_restore of_state_read_local_epoch)"
  local g; g="$( source "$fl"; rs_home mtj; reset_stub; LIVE="$RS_TAILJUNK"; LIVE_GEN="42"; of_state_restore_failed=""; of_state_restore >/dev/null 2>&1; echo "$of_state_generation" )"
  [[ "$g" == 0 ]] && echo survived || echo killed
}

echo "== case: ENG-362 -- hooks/ and profiles/ are locked before the restore =="
lock_fence() { # <entrypoint> -> ok when the hooks/profiles lock is top-level in service), above of_state_restore
  local f="$1" svc line rs depth
  svc="$(grep -n '^  service)$' "$f" | head -1 | cut -d: -f1)"
  line="$(grep -n '^    for of_d in hooks profiles; do$' "$f" | head -1 | cut -d: -f1)"
  rs="$(grep -n '^    of_state_restore$' "$f" | head -1 | cut -d: -f1)"
  depth="$(awk -v a="$svc" -v b="$line" -v q="'" '
    NR<=a || NR>=b { next }
    hd != "" { if ($0 == hd) hd = ""; next }
    { if ($0 ~ /^[[:space:]]*if[[:space:]]/) d++; if ($0 ~ /^[[:space:]]*fi([[:space:];]|$)/) d-- }
    match($0, "<<-?" q "?[A-Z_]+" q "?") { w = substr($0, RSTART, RLENGTH); gsub("[<" q "-]", "", w); hd = w }
    END { print d+0 }' "$f")"
  [[ -n "$svc" && -n "$line" && -n "$rs" && "$line" -gt "$svc" && "$line" -lt "$rs" && "$depth" == 0 ]] && echo ok || echo "no (service=$svc lock=$line restore=$rs depth=$depth)"
}
check "hooks/profiles lock inside service), above of_state_restore" "ok" "$(lock_fence "$ENTRYPOINT")"
lock_block() { awk '/^    for of_d in hooks profiles; do$/{p=1} p{print} p&&/^    done$/{exit}' "$1"; }
if [[ "$(id -u)" -ne 0 ]]; then
  LK_HOME="$WORK/lock-home"; mkdir -p "$LK_HOME"
  lk_out="$( ( HERMES_HOME="$LK_HOME"; eval "$(awk '/^of_make_read_only\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT")"; eval "$(lock_block "$ENTRYPOINT")" ) 2>&1)"
  for d in hooks profiles; do
    check "$d: the line says (read-only)"         "yes" "$([[ "$lk_out" == *"/$d (read-only)"* ]] && echo yes || echo no)"
    check "$d: is empty"                          "0"   "$(find "$LK_HOME/$d" -mindepth 1 | wc -l)"
    check "$d: a file cannot be written"          "no"  "$( (printf x > "$LK_HOME/$d/handler.py") 2>/dev/null && echo yes || echo no)"
    check "$d: a subdirectory cannot be created"  "no"  "$(mkdir "$LK_HOME/$d/x" 2>/dev/null && echo yes || echo no)"
  done
  LK2="$WORK/lock-home2"; mkdir -p "$LK2/hooks/left"
  lk_out="$( ( HERMES_HOME="$LK2"; eval "$(awk '/^of_make_read_only\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ENTRYPOINT")"; eval "$(lock_block "$ENTRYPOINT")" ) 2>&1)"
  check "a non-empty hooks/ is named, not silently locked" "1" "$(grep -c 'already holds 1 entr' <<< "$lk_out")"
fi

echo "== mutants: ENG-373/362 =="
m373() { # <label> <sed-expr> <probe-fn> -- probe gets the mutated entrypoint; "survived" fails the run
  local label="$1" expr="$2" probe="$3" m="$WORK/m373.sh"
  sed -e "$expr" "$ENTRYPOINT" > "$m"
  if cmp -s "$m" "$ENTRYPOINT"; then bad "$label: the mutation did not apply -- a mutant that does not mutate proves nothing"; return; fi
  if [[ "$($probe "$m")" == "survived" ]]; then bad "$label -- SURVIVED"; else ok "$label -- killed"; fi
}
fns_of() { # <entrypoint> <fn>... -> a file with those functions, as extract_fns does
  local f="$1" o; o="$(mktemp -p "$WORK")"; shift
  for fn in "$@"; do awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}' "$f" >> "$o"; echo >> "$o"; done
  echo "$o"
}
probe_pin_mismatch() { # survived = a mismatched pin still loads
  local fl; fl="$(fns_of "$1" of_verify_sha256 of_plugins_fetch of_make_read_only)"
  local rc; rc="$( source "$fl"; reset_stub; LIVE="$PLUG_OK"; HERMES_PLUGINS_SHA256="$(sha_of "$PLUG_NO")"; of_plugins_fetch "$WORK/m-pin" >/dev/null 2>&1; echo $? )"
  [[ "$rc" == 1 ]] && echo survived || echo killed
}
probe_pin_unset() { # survived = an unset pin still loads
  local fl; fl="$(fns_of "$1" of_verify_sha256 of_plugins_fetch of_make_read_only)"
  local rc; rc="$( source "$fl"; reset_stub; LIVE="$PLUG_OK"; HERMES_PLUGINS_SHA256=""; of_plugins_fetch "$WORK/m-pin2" >/dev/null 2>&1; echo $? )"
  [[ "$rc" == 1 ]] && echo survived || echo killed
}
m373 "the mismatch comparison removed" 's/^  if \[\[ "\$got" != "\$want" \]\]; then$/  if false; then/' probe_pin_mismatch
m373 "of_plugins_fetch no longer calls the pin check" 's/sha="\$(of_verify_sha256 "\$tarball" "\${HERMES_PLUGINS_SHA256:-}" of-plugins HERMES_PLUGINS_SHA256)"/sha=skipped/' probe_pin_mismatch
m373 "an unset pin read as no check" '/is unset -- refusing to load an unpinned tarball/{n;s/return 1/return 0/}' probe_pin_unset
probe_restore_evil() { # survived = config.yaml from the snapshot replaced the boot's
  local fl; fl="$(fns_of "$1" of_safe_extract of_state_restore_failed of_state_restore of_state_read_local_epoch)"
  rs_home mut
  ( source "$fl"; reset_stub; LIVE="$RS_EVIL"; of_state_restore >/dev/null 2>&1 )
  [[ "$(cat "$RS_HOME/config.yaml")" == SAFE && ! -e "$RS_HOME/skills" && ! -e "$RS_HOME/.env" ]] && echo survived || echo killed
}
probe_restore_link() { # survived = a member was written through a link on disk
  local fl; fl="$(fns_of "$1" of_safe_extract of_state_restore_failed of_state_restore of_state_read_local_epoch)"
  rs_home mutlink; rm -rf "$WORK/rs-out2"; mkdir -p "$WORK/rs-out2"; ln -s "$WORK/rs-out2" "$RS_HOME/cron"
  ( source "$fl"; reset_stub; LIVE="$RS_HONEST"; of_state_restore >/dev/null 2>&1 )
  [[ -e "$WORK/rs-out2/jobs.json" ]] && echo killed || echo survived
}
m373 "the state allow-list off" 's/^    if mode != "state":$/    if True:/' probe_restore_evil
# Links that resolve INSIDE the archive: with the type check gone they would land as copies
# (a link that points outside the archive only crashes the extractor, which proves nothing).
RS_LINKS="$WORK/rs-links.tar.gz"
python3 - "$RS_LINKS" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    ti = tarfile.TarInfo("./state.db"); d = b"db"; ti.size = len(d); tf.addfile(ti, io.BytesIO(d))
    ti = tarfile.TarInfo("./pairing/h"); ti.type = tarfile.LNKTYPE; ti.linkname = "./state.db"; tf.addfile(ti)
    ti = tarfile.TarInfo("./plans/s"); ti.type = tarfile.SYMTYPE; ti.linkname = "../state.db"; tf.addfile(ti)
PY
probe_restore_links() { # survived = neither link member landed
  local fl; fl="$(fns_of "$1" of_safe_extract of_state_restore_failed of_state_restore of_state_read_local_epoch)"
  rs_home mutlinks
  ( source "$fl"; reset_stub; LIVE="$RS_LINKS"; of_state_restore >/dev/null 2>&1 )
  [[ ! -e "$RS_HOME/pairing/h" && ! -e "$RS_HOME/plans/s" ]] && echo survived || echo killed
}
rs_home links; reset_stub; LIVE="$RS_LINKS"
check "in-archive hardlink and symlink are refused" "1" "$(of_state_restore 2>&1 | grep -c 'restore: 1 extracted, 2 refused')"
check "probe_restore_links holds on the shipped entrypoint" "survived" "$(probe_restore_links "$ENTRYPOINT")"
m373 "links and hardlinks accepted" 's/and (m.isfile() or m.isdir()) and allowed/and allowed/' probe_restore_links
m373 "writing through a link on disk allowed" 's/                  and not through_link(parts))$/                  )/' probe_restore_link
m373 "the restore back to tar xzf" 's/^  if counts="\$(of_safe_extract "\$tarball" "\${HERMES_HOME:-\/opt\/data}" of-state state)"; then$/  if counts="$(tar xzf "$tarball" -C "${HERMES_HOME:-\/opt\/data}" 2>\/dev\/null \&\& echo 0)"; then/' probe_restore_evil
probe_forget() { # survived = the live snapshot survives a failed restore (unreadable archive)
  local fl; fl="$(fns_of "$1" of_state_read_local_epoch of_state_tarball_epoch of_state_messages_superset of_state_try_promote of_state_merge_messages of_state_snapshot_upload of_state_snapshot of_gcs_read_generation of_safe_extract of_state_restore_failed of_state_restore)"
  [[ "$(rs_park_case "$fl" "$RS_GARBAGE")" == "same,1" ]] && echo survived || echo killed
}
probe_partial() { # survived = the live snapshot survives a partial restore that landed .state_epoch
  local fl; fl="$(fns_of "$1" of_state_read_local_epoch of_state_tarball_epoch of_state_messages_superset of_state_try_promote of_state_merge_messages of_state_snapshot_upload of_state_snapshot of_gcs_read_generation of_safe_extract of_state_restore_failed of_state_restore)"
  [[ "$(rs_park_case "$fl" "$RS_PARTIAL")" == "same,1" ]] && echo survived || echo killed
}
m373 "the memories merge path back to tar xzf" 's/^    if ! of_safe_extract "\$live" "\$live_extract" of-memories files >\/dev\/null; then$/    if ! tar xzf "$live" -C "$live_extract" 2>\/dev\/null; then/' probe_mem412
m373 "the end-of-archive check removed" 's/^        if tf.fileobj.read().strip(b"\\0"):$/        if False:/' probe_tailjunk
m373 "an unreadable snapshot keeps the generation (the old line 330)" '/^    echo "\[of-state\] WARN: snapshot present but did not extract; starting with empty state" >&2$/{n;/of_state_restore_failed/d}' probe_forget
m373 "a failed restore reads the epoch back from what it half-extracted" 's/^  \[\[ -n "\${of_state_restore_failed:-}" \]\] || of_state_epoch=/  of_state_epoch=/' probe_partial
probe_lock() { [[ "$(lock_fence "$1")" == ok ]] && echo survived || echo killed; }
# Each probe must say "survived" on the SHIPPED entrypoint -- a probe that reports
# "killed" for everything kills every mutant and proves nothing (the first draft of these
# probes had their polarity inverted, and every mutant "survived" for that reason).
for pr in probe_pin_mismatch probe_pin_unset probe_restore_evil probe_restore_link probe_forget probe_partial probe_mem412 probe_tailjunk; do
  check "$pr holds on the shipped entrypoint" "survived" "$($pr "$ENTRYPOINT")"
done
check "probe_lock holds on the shipped entrypoint" "survived" "$(probe_lock "$ENTRYPOINT")"
m373 "the hooks/profiles lock removed (ENG-362)" '/^    for of_d in hooks profiles; do$/,/^    done$/d' probe_lock
m373_file() { # <label> <mutated file> <probe> -- for mutations sed cannot express
  local label="$1" m="$2" probe="$3"
  if cmp -s "$m" "$ENTRYPOINT"; then bad "$label: the mutation did not apply -- a mutant that does not mutate proves nothing"; return; fi
  if [[ "$($probe "$m")" == "survived" ]]; then bad "$label -- SURVIVED"; else ok "$label -- killed"; fi
}
python3 - "$ENTRYPOINT" "$WORK/m-lock-moved.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index("    for of_d in hooks profiles; do\n"); b = s.index("    done\n", a) + len("    done\n")
block, s = s[a:b], s[:a] + s[b:]
r = s.index("\n    of_state_restore\n") + len("\n    of_state_restore\n")
open(sys.argv[2], "w").write(s[:r] + block + s[r:])
PY
m373_file "the lock moved below of_state_restore (ENG-362)" "$WORK/m-lock-moved.sh" probe_lock

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
