#!/bin/sh
# Test suite for claude-cache-status.sh
#
#   sh tests/claude-cache-status.test.sh
#   SCRIPT=/path/to/x.sh sh tests/claude-cache-status.test.sh
#   SH=dash sh tests/claude-cache-status.test.sh
#
# SH is the shell the script under test is executed with, which is the thing
# portability claims are about. It is independent of the shell running this
# harness: `bash tests/...` with SH unset still exercises the script under sh.
#
# Fixtures are generated at run time rather than committed, because every
# meaningful case depends on a timestamp relative to now. No control characters
# are written literally into this file; they are produced via printf.

SCRIPT=${SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/claude-cache-status.sh}
SH=${SH:-sh}
command -v "$SH" >/dev/null 2>&1 || { echo "no such shell: $SH" >&2; exit 1; }
W=$(mktemp -d) || exit 1
export XDG_CACHE_HOME="$W/cache"
trap 'rm -rf "$W"' EXIT INT TERM

pass=0; fail=0
ESC=$(printf '\033')
strip() { sed "s/${ESC}\[[0-9;]*m//g"; }

iso_ago() {  # $1 = seconds ago -> ISO8601 with milliseconds
  _e=$(( $(date +%s) - $1 ))
  date -u -r "$_e" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null ||
    date -u -d "@$_e" +%Y-%m-%dT%H:%M:%S.000Z
}

# fixture <file> <secs-ago> <1h-tokens> <5m-tokens> [sidechain-last]
fixture() {
  _f=$1; _ts=$(iso_ago "$2")
  printf '{"type":"user","timestamp":"%s","message":{}}\n' "$_ts" > "$_f"
  if [ "$3" != "-" ]; then
    printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":%s}}}}\n' \
      "$_ts" "$3" "$4" >> "$_f"
  fi
  if [ "${5:-}" = "sidechain" ]; then
    printf '{"type":"assistant","timestamp":"%s","isSidechain":true,"message":{"usage":{"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":9999}}}}\n' \
      "$_ts" >> "$_f"
  fi
}

run() {  # run <transcript> <session> -> stripped output
  jq -nc --arg t "$1" --arg s "$2" '{transcript_path:$t,session_id:$s}' | "$SH" "$SCRIPT" 2>&1 | strip
}
run_raw() { jq -nc --arg t "$1" --arg s "$2" '{transcript_path:$t,session_id:$s}' | "$SH" "$SCRIPT" 2>&1; }

check() {  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass+1)); printf '  ok   %-46s %s\n' "$1" "$3"
  else
    fail=$((fail+1)); printf '  FAIL %-46s got [%s] want [%s]\n' "$1" "$3" "$2"
  fi
}
contains() {  # contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*) pass=$((pass+1)); printf '  ok   %-46s\n' "$1" ;;
    *) fail=$((fail+1)); printf '  FAIL %-46s [%s] lacks [%s]\n' "$1" "$3" "$2" ;;
  esac
}

# Any assertion on a rendered value that shows seconds is racing the wall clock:
# the fixture stamps a timestamp, and the script reads the clock again a moment
# later. When a second ticks over in between, the value is one lower and the
# check is wrong about nothing. Accept the next second down as well. Values that
# render only whole minutes are not affected and use plain check().
check_t() {  # check_t <label> <expected> <expected-one-second-later> <actual>
  if [ "$2" = "$4" ] || [ "$3" = "$4" ]; then
    pass=$((pass+1)); printf '  ok   %-46s %s\n' "$1" "$4"
  else
    fail=$((fail+1)); printf '  FAIL %-46s got [%s] want [%s] or [%s]\n' "$1" "$4" "$2" "$3"
  fi
}

echo "script: $SCRIPT"
echo "shell:  $SH ($("$SH" -c 'echo ${BASH_VERSION:-POSIX sh}' 2>/dev/null))"
echo

echo "-- syntax --------------------------------------------------------------"
for sh_bin in sh dash bash; do
  command -v "$sh_bin" >/dev/null 2>&1 || continue
  if "$sh_bin" -n "$SCRIPT" 2>/dev/null; then
    pass=$((pass+1)); printf '  ok   parses under %s\n' "$sh_bin"
  else
    fail=$((fail+1)); printf '  FAIL parses under %s\n' "$sh_bin"
  fi
done

echo
echo "-- tier detection ------------------------------------------------------"
fixture "$W/h1.jsonl"    30 5000 0;    check "1h tier, 30s elapsed"   "cache 59m"  "$(run "$W/h1.jsonl" s1)"
fixture "$W/m5.jsonl"    30 0 5000;    check_t "5m tier, 30s elapsed"   "cache 4:30" "cache 4:29" "$(run "$W/m5.jsonl" s2)"
fixture "$W/mixed.jsonl" 30 5000 1200; check_t "mixed write -> shorter" "cache 4:30" "cache 4:29" "$(run "$W/mixed.jsonl" s3)"

echo
echo "-- adaptive granularity ------------------------------------------------"
fixture "$W/g1.jsonl" 30   5000 0; check "1h, 59m left  -> coarse minutes" "cache 59m"  "$(run "$W/g1.jsonl" g1)"
fixture "$W/g2.jsonl" 3000 5000 0; check_t "1h, 10m left  -> coarse minutes" "cache 10m"  "cache 9:59"  "$(run "$W/g2.jsonl" g2)"
fixture "$W/g3.jsonl" 3100 5000 0; check_t "1h, 8m left   -> M:SS"           "cache 8:20" "cache 8:19" "$(run "$W/g3.jsonl" g3)"
fixture "$W/g4.jsonl" 3570 5000 0; check_t "1h, 30s left  -> seconds"        "cache 30s"  "cache 29s"  "$(run "$W/g4.jsonl" g4)"
fixture "$W/g5.jsonl" 7200 5000 0; check "1h, expired   -> cold"           "cache cold" "$(run "$W/g5.jsonl" g5)"
fixture "$W/g6.jsonl" 30   0 5000; check_t "5m, 4:30 left -> M:SS"           "cache 4:30" "cache 4:29" "$(run "$W/g6.jsonl" g6)"
fixture "$W/g7.jsonl" 250  0 5000; check_t "5m, 50s left  -> seconds"        "cache 50s"  "cache 49s"  "$(run "$W/g7.jsonl" g7)"

echo
echo "-- colour bands are fractions of the detected tier ---------------------"
band() { # band <label> <secs-ago> <1h> <5m> <expected-index>
  fixture "$W/c.jsonl" "$2" "$3" "$4"
  rm -f "$XDG_CACHE_HOME/claude-cache-status/cb"
  _o=$(run_raw "$W/c.jsonl" cb)
  _i=$(printf '%s' "$_o" | sed 's/.*38;5;\([0-9]*\)m.*/\1/')
  check "$1" "$5" "$_i"
}
band "1h  59m left -> green  108" 30   5000 0 108
band "1h  25m left -> amber  179" 2100 5000 0 179
band "1h   5m left -> red    203" 3300 5000 0 203
band "5m  4:30     -> green  108" 30   0 5000 108
band "5m  2:00     -> amber  179" 180  0 5000 179
band "5m  0:45     -> red    203" 255  0 5000 203

echo
echo "-- explicit unknown state ----------------------------------------------"
fixture "$W/u1.jsonl" 30 - -;      check "no cache write, no memory -> unknown" "cache ?" "$(run "$W/u1.jsonl" u1)"
fixture "$W/u2.jsonl" 30 0 0;      check "zero-token write        -> unknown"   "cache ?" "$(run "$W/u2.jsonl" u2)"

echo
echo "-- tier memory ---------------------------------------------------------"
fixture "$W/mem.jsonl" 30 5000 0
check "v1 establishes 1h" "cache 59m" "$(run "$W/mem.jsonl" mem)"
sleep 1
fixture "$W/mem.jsonl" 30 0 0
check "v2 has no write, keeps 1h" "cache 59m" "$(run "$W/mem.jsonl" mem)"

echo
echo "-- sidechain exclusion -------------------------------------------------"
fixture "$W/sc.jsonl" 30 5000 0 sidechain
check "subagent 5m write ignored" "cache 59m" "$(run "$W/sc.jsonl" sc)"

echo
echo "-- NO_COLOR ------------------------------------------------------------"
fixture "$W/nc.jsonl" 30 5000 0
_o=$(NO_COLOR=1 jq -nc --arg t "$W/nc.jsonl" --arg s nc '{transcript_path:$t,session_id:$s}' | NO_COLOR=1 "$SH" "$SCRIPT")
case "$_o" in
  *"$ESC"*) fail=$((fail+1)); printf '  FAIL %-46s escapes still present\n' "NO_COLOR=1 emits no escapes" ;;
  *) pass=$((pass+1)); printf '  ok   %-46s %s\n' "NO_COLOR=1 emits no escapes" "$_o" ;;
esac

echo
echo "-- malformed and hostile input all fail safe ---------------------------"
printf '{"type":"user","timestamp":"not-a-date","message":{}}\n' > "$W/bad.jsonl"
: > "$W/empty.jsonl"
printf 'not json\n' > "$W/garbage.jsonl"
printf '{"type":"user","timestamp":"%s","message":{}}\n{"type":"assistant","timestamp":"%s","message":{"usage":{"cache_creation":{"ephemeral_1h_input_tokens":"9e99","ephemeral_5m_input_tokens":-5}}}}\n' \
  "$(iso_ago 30)" "$(iso_ago 30)" > "$W/hostile.jsonl"
mkfifo "$W/fifo.jsonl" 2>/dev/null
for n in bad empty garbage hostile fifo; do
  ( run "$W/$n.jsonl" "z$n" > "$W/o" 2>&1 ) & _bg=$!
  _i=0; while kill -0 $_bg 2>/dev/null && [ $_i -lt 6 ]; do sleep 0.5; _i=$((_i+1)); done
  if kill -0 $_bg 2>/dev/null; then kill $_bg 2>/dev/null; check "$n" "<no hang>" "HUNG"
  else check "$n omits cleanly" "" "$(cat "$W/o")"; fi
done
check "missing file"      "" "$(run /nope/missing.jsonl zm)"
check "directory as path" "" "$(run "$W" zd)"
check "no transcript field" "" "$(printf '{}' | "$SH" "$SCRIPT" 2>&1 | strip)"
_o=$(jq -nc --arg t '/tmp/back\slash' '{transcript_path:$t,session_id:"zb"}' | "$SH" "$SCRIPT" 2>&1 | strip)
check "backslash in JSON parses" "" "$_o"

echo
echo "-- state file integrity ------------------------------------------------"
fixture "$W/st.jsonl" 30 5000 0
run "$W/st.jsonl" st >/dev/null
_sf="$XDG_CACHE_HOME/claude-cache-status/st"
contains "state file written" "3600" "$(cat "$_sf" 2>/dev/null)"
for bad in "abc def ghi" "" "99999999999999999999 1 1" "3600 1" "3600 1 1 extra"; do
  printf '%s\n' "$bad" > "$_sf"
  check "corrupt state recomputes [$bad]" "cache 59m" "$(run "$W/st.jsonl" st)"
done

echo
echo "-- path traversal in session_id ----------------------------------------"
fixture "$W/pt.jsonl" 30 5000 0
run "$W/pt.jsonl" '../../../../tmp/ESCAPED' >/dev/null
if [ -e /tmp/ESCAPED ]; then
  fail=$((fail+1)); printf '  FAIL %-46s escaped the state dir\n' "session_id traversal neutralised"
else
  pass=$((pass+1)); printf '  ok   %-46s\n' "session_id traversal neutralised"
fi

echo
echo "-- control characters cannot reach the output --------------------------"
_o=$(jq -nc --arg t "$W/h1.jsonl" --arg s nc2 --arg esc "$(printf '\033')" \
  '{transcript_path:($t + $esc + "]0;x"),session_id:$s}' | "$SH" "$SCRIPT" 2>&1)
case "$_o" in
  *"]0;x"*) fail=$((fail+1)); printf '  FAIL %-46s escape reached output\n' "ESC in transcript_path stripped" ;;
  *) pass=$((pass+1)); printf '  ok   %-46s\n' "ESC in transcript_path stripped" ;;
esac

echo
echo "-- cost at risk (opt-in) -----------------------------------------------"
# loss per Mtok = base_input_price x (write_multiplier - 0.1x read)
#   1h tier: 1.9x   5m tier: 1.15x
priced() {  # priced <transcript> <session> <model-id> <ctx-tokens> [pricing-env]
  jq -nc --arg t "$1" --arg s "$2" --arg m "$3" --argjson n "$4" \
    '{transcript_path:$t,session_id:$s,model:{id:$m},context_window:{total_input_tokens:$n}}' \
    | CLAUDE_CACHE_STATUS_PRICING="${5:-api}" "$SH" "$SCRIPT" 2>&1 | strip
}
fixture "$W/p1h.jsonl" 30 5000 0
fixture "$W/p5m.jsonl" 30 0 5000

# default off: no env var means no figure at all
_o=$(jq -nc --arg t "$W/p1h.jsonl" --arg s pd --arg m claude-opus-5 \
  '{transcript_path:$t,session_id:$s,model:{id:$m},context_window:{total_input_tokens:700000}}' \
  | "$SH" "$SCRIPT" 2>&1 | strip)
check "off by default (no env var)"        "cache 59m"        "$_o"

check "1h Opus   700K -> 0.7 x \$9.50"    "cache 59m \$6.65"  "$(priced "$W/p1h.jsonl" p1 claude-opus-5     700000)"
check_t "5m Opus 700K -> 0.7 x \$5.75"   "cache 4:30 \$4.02" "cache 4:29 \$4.02" "$(priced "$W/p5m.jsonl" p2 claude-opus-5     700000)"
check "1h Sonnet 5   700K -> 0.7 x \$3.80" "cache 59m \$2.66" "$(priced "$W/p1h.jsonl" p3 claude-sonnet-5   700000)"
# Sonnet 5 is $2/Mtok and Sonnet 4.6 is $3. They shared a price table entry
# until they did not; pin both so the split cannot silently collapse again.
check "1h Sonnet 4.6 700K -> 0.7 x \$5.70" "cache 59m \$3.99" "$(priced "$W/p1h.jsonl" p3b claude-sonnet-4-6 700000)"
# Opus 4.5 and Sonnet 4.5 carry dated snapshot ids, unlike everything newer;
# these also pin that the table's substring match works on the dated form.
check "1h Sonnet 4.5 700K -> 0.7 x \$5.70" "cache 59m \$3.99" "$(priced "$W/p1h.jsonl" p3c claude-sonnet-4-5-20250929 700000)"
check "1h Opus 4.5  700K -> 0.7 x \$9.50"  "cache 59m \$6.65" "$(priced "$W/p1h.jsonl" p3d claude-opus-4-5-20251101  700000)"
check "1h Haiku  700K -> 0.7 x \$1.90"    "cache 59m \$1.33"  "$(priced "$W/p1h.jsonl" p4 claude-haiku-4-5  700000)"
check "1h Fable  700K -> 0.7 x \$19.00"   "cache 59m \$13.30" "$(priced "$W/p1h.jsonl" p5 claude-fable-5    700000)"
check "1h Fable    1M -> no overflow"     "cache 59m \$19.00" "$(priced "$W/p1h.jsonl" p6 claude-fable-5   1000000)"
check "unknown model  -> no figure"       "cache 59m"         "$(priced "$W/p1h.jsonl" p7 claude-future-9   700000)"
check "tiny context   -> under a dime"    "cache 59m"         "$(priced "$W/p1h.jsonl" p8 claude-opus-5       5000)"
check "zero context   -> no figure"       "cache 59m"         "$(priced "$W/p1h.jsonl" p9 claude-opus-5          0)"
check "explicit price 5"                  "cache 59m \$6.65"  "$(priced "$W/p1h.jsonl" pa claude-future-9   700000 5)"
check "explicit price 12.50"              "cache 59m \$16.62" "$(priced "$W/p1h.jsonl" pb claude-future-9   700000 12.50)"
check "garbage price   -> no figure"      "cache 59m"         "$(priced "$W/p1h.jsonl" pc claude-opus-5     700000 garbage)"
check "price 0         -> no figure"      "cache 59m"         "$(priced "$W/p1h.jsonl" pd2 claude-opus-5    700000 0)"
check "negative price  -> no figure"      "cache 59m"         "$(priced "$W/p1h.jsonl" pe claude-opus-5     700000 -5)"
# Cold still shows the figure, and should: once expired it is no longer "at
# risk", it is what the next message costs extra. That is the moment it matters.
fixture "$W/pcold.jsonl" 7200 5000 0
check "cold prices the next turn"         "cache cold \$6.65" "$(priced "$W/pcold.jsonl" pf claude-opus-5   700000)"

echo
echo "========================================================================"
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
