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
  for fn in of_state_read_local_epoch of_state_tarball_epoch of_state_messages_superset of_state_try_promote; do
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
check "fallback_providers set to vertex/google/gemini-3.6-flash" \
  "1" "$(grep -c '_set_nested(cfg, "fallback_providers", \[{"provider": "vertex", "model": "google/gemini-3.6-flash"}\])' "$ENTRYPOINT")"
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

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
