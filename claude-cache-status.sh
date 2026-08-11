#!/bin/sh
# Prompt-cache countdown for the Claude Code status line.
#
# Shows how long the conversation's cached prefix stays warm, e.g. "cache 47m".
# Anthropic's prompt cache is refreshed for free on every use, and its lifetime
# is measured from the START of the last request that read or wrote it — so this
# is an idle timer, not a session budget. It resets to full every time you send
# anything. Hitting 0 means the next turn re-pays the cache-write premium on the
# whole prefix, which on a long session is the expensive part of the request.
#
# The TTL tier is detected, never assumed: the API default is 5 minutes, the
# 1-hour TTL is an opt-in at 2x the cache-write price, and Claude Code can drop
# from 1h to 5m if a session enters usage overage. Each response records which
# tier it wrote to under usage.cache_creation, and that is the only place the
# split appears — the status line's own JSON carries aggregate token counts
# only. Once established the tier is remembered for the session, so a turn that
# only reads cache does not lose it. If it has never been established the
# segment renders "cache ?" rather than guessing, because guessing 5m on a 1h
# session reports "cold" with 55 minutes left.
#
# WHAT THIS SCRIPT DOES AND DOES NOT DO
#   Reads:   the JSON Claude Code sends on stdin; the tail of the session
#            transcript named in that JSON; its own small state file.
#   Writes:  one state file per session under $XDG_CACHE_HOME (or ~/.cache),
#            holding three fields — tier, anchor timestamp, and a change token
#            derived from the transcript's mtime and size. No conversation
#            content. Files unused for 7 days are pruned. Nothing else is
#            written anywhere.
#   Sends:   nothing. There are no network calls of any kind.
#   Executes: jq, tail, stat, date, mkdir, mv, find, basename, tr. No eval, no
#            sudo, no dynamic command construction.
#   Extracts from the transcript: two timestamps and two integer token counts.
#            No message content, no prompts, no tool output. The only strings
#            this script can print are "cache <value>", "cache cold" and
#            "cache ?", each optionally followed by a dollar figure when
#            CLAUDE_CACHE_STATUS_PRICING is set.
#
# INSTALL
#   "statusLine": { "type": "command",
#                   "command": "/abs/path/to/claude-cache-status.sh",
#                   "refreshInterval": 30 }
#
#   refreshInterval IS REQUIRED. Status lines are otherwise event-driven, so the
#   countdown would freeze at the prompt — exactly when you'd be looking at it.
#
#   To merge into an existing status line, copy the marked COMPUTE and RENDER
#   blocks plus the helpers and colours they reference. If your script uses
#   `echo "$input" | jq` or `printf '%b'`, read the two notes on those below
#   before you do — both are latent bugs.
#
# Requires: jq >= 1.5 (for fromdateiso8601), and a POSIX shell. Verified under
# bash-as-sh and dash, on macOS (BSD stat) and with GNU stat fallback.
#
# NOTE ON ERROR HANDLING: deliberately no `set -e`. A status line that errors is
# worse than one that omits a segment, so every failure path degrades to
# printing nothing.
#
# SPDX-License-Identifier: MIT

input=$(cat)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Real ESC byte, produced once. The line is emitted with printf '%s', never
# '%b': '%b' interprets backslash sequences inside the values being printed,
# and a directory literally named 'x\033]0;title\007' is legal on macOS and
# Linux — under '%b' that becomes a real terminal escape.
_esc=$(printf '\033')

# 256-colour indices. Indices >= 16 are a fixed cube and greyscale ramp rather
# than palette entries, so they render identically under any terminal theme.
# The basic 8 colours (30-37) are theme-defined; BOLD is promoted to bright
# variants by iTerm2's "Use Bright Bold"; DIM renders as 50%-alpha faint text.
# All three are avoided.
C_RESET="${_esc}[0m"
C_OK="${_esc}[38;5;108m"    # sage green - over half the window left
C_WARN="${_esc}[38;5;179m"  # amber      - 15-50% left
C_CRIT="${_esc}[38;5;203m"  # red        - under 15% left, or cold
C_UNKNOWN="${_esc}[38;5;245m" # grey     - tier not yet established

# NO_COLOR (https://no-color.org): any non-empty value disables styling.
if [ -n "${NO_COLOR:-}" ]; then
  C_RESET="" C_OK="" C_WARN="" C_CRIT="" C_UNKNOWN=""
fi

# Reject anything that is not a plain integer before it reaches arithmetic.
# Unvalidated shell arithmetic evaluates "abc" as 0 and overflows past 19
# digits, which renders confident nonsense instead of omitting the segment.
_is_int() {
  _v=${1#-}
  case "$_v" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#_v}" -le 11 ] || return 1
  return 0
}

# A change-detection token for a file: modification time plus size, as one
# opaque string. It is only ever compared for equality, never used in
# arithmetic, so it does not need to be numeric — which lets us ask for
# FRACTIONAL mtime. Whole-second mtime is not enough: two writes inside the
# same second that leave the file the same length are indistinguishable, and
# the stale state then gets served. BSD (macOS) first, GNU second, whole
# seconds only as a last resort.
_stat_token() {
  stat -f '%Fm-%z' "$1" 2>/dev/null ||
    stat -c '%.9Y-%s' "$1" 2>/dev/null ||
    stat -f '%m-%z' "$1" 2>/dev/null ||
    stat -c '%Y-%s' "$1" 2>/dev/null
}

# Validate a change token: digits, dots and dashes only, bounded length. It is
# interpolated into a state file we later parse, so it must not be able to
# introduce whitespace or newlines.
_is_token() {
  case "$1" in
    '' | *[!0-9.-]*) return 1 ;;
  esac
  [ "${#1}" -le 40 ] || return 1
  return 0
}

# Base INPUT price in whole cents per million tokens, by model id. Only input
# pricing matters here: the cache multipliers apply to input tokens.
#
# Deliberately conservative. A model that is not listed yields no price, and no
# price means no figure is shown — a wrong number is worse than no number.
# Supply your own with CLAUDE_CACHE_STATUS_PRICING=<dollars per million> for a
# model that is missing, or when your rates are not list rates.
_price_cents_per_mtok() {
  case "$1" in
    *fable-5* | *mythos-5*) echo 1000 ;;
    *opus-5* | *opus-4-8* | *opus-4-7* | *opus-4-6*) echo 500 ;;
    *sonnet-5* | *sonnet-4-6*) echo 300 ;;
    *haiku-4-5*) echo 100 ;;
    *) echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# COMPUTE  (needs $input; sets $cache_ttl, $cache_left, $cache_state,
#           and $cache_cents when pricing is opted in)
# ---------------------------------------------------------------------------
#
# One jq pass. printf '%s' rather than echo: echo mangles backslash escapes in
# dash and in bash with xpg_echo, which breaks the parse outright for any JSON
# containing one — and backslashes are legal in filenames, so it is reachable.
#
# The session key is restricted to [A-Za-z0-9_-] because it is interpolated
# into a file path; without that, a session_id containing ../ would escape the
# state directory. Control characters are stripped from the transcript path so
# nothing downstream can emit a raw escape sequence.
#
# [[:cntrl:]] is a POSIX class Oniguruma understands. Do NOT write it as
# "[\\u0000-\\u001f]": inside a jq string literal that is a literal backslash
# followed by "u0000", which becomes a class of the letters u/0/1/f and quietly
# corrupts ordinary values ("Opus" -> "ps", "/tmp/x" -> "//x").
ccs_fields=$(printf '%s' "$input" | jq -r '
    ((.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "") | .[0:64]),
    ((.transcript_path // "") | tostring | gsub("[[:cntrl:]]"; "")),
    ((.model.id // .model.display_name // "") | tostring | gsub("[^A-Za-z0-9._-]"; "")),
    ((.context_window.total_input_tokens // "") | tostring)
  ' 2>/dev/null)
{
  IFS= read -r ccs_session
  IFS= read -r ccs_transcript
  IFS= read -r ccs_model
  IFS= read -r ccs_ctx_tokens
} <<EOF
$ccs_fields
EOF

# Fall back to the transcript's own filename, which is the session UUID, when
# session_id is absent (older Claude Code builds).
if [ -z "$ccs_session" ] && [ -n "$ccs_transcript" ]; then
  ccs_session=$(basename "$ccs_transcript" .jsonl | tr -c 'A-Za-z0-9_-' '_')
fi

cache_ttl=""
cache_left=""
cache_state=""   # "" = nothing to show, "unknown" = session known, tier not
cache_cents=""   # cost at risk in whole cents, only when pricing is opted in

# -f is true only for regular files, so a fifo, device, or directory supplied
# as transcript_path short-circuits here and `tail` can never block.
if [ -n "$ccs_transcript" ] && [ -f "$ccs_transcript" ] && [ -n "$ccs_session" ]; then

  ccs_now=$(date +%s)
  ccs_token=$(_stat_token "$ccs_transcript")
  _is_token "$ccs_token" || ccs_token=""

  ccs_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-cache-status"
  ccs_state="$ccs_dir/$ccs_session"

  # --- try the cache -------------------------------------------------------
  # State line: "<tier> <anchor_epoch> <change_token>". Validated on read even
  # though we wrote it: a torn or hand-edited file must not reach arithmetic. A
  # hit means the transcript has not changed since we last parsed it, so the
  # anchor and tier are still current and there is no need to touch the
  # transcript at all — which is the common case, because refreshInterval
  # re-runs this script repeatedly while the session sits idle.
  ccs_tier=""
  ccs_anchor=""
  if [ -f "$ccs_state" ] && [ -n "$ccs_token" ]; then
    IFS=' ' read -r s_tier s_anchor s_token < "$ccs_state" 2>/dev/null
    if _is_int "$s_tier" && _is_int "$s_anchor" && _is_token "$s_token" &&
       [ "$s_tier" -gt 0 ]; then
      if [ "$s_token" = "$ccs_token" ]; then
        ccs_tier="$s_tier"      # full hit: tier and anchor both reusable
        ccs_anchor="$s_anchor"
      else
        ccs_tier_prev="$s_tier" # stale: keep the remembered tier as a fallback
      fi
    fi
  fi

  # --- parse the transcript only when it has changed -----------------------
  if [ -z "$ccs_anchor" ]; then
    # Two values: the newest non-sidechain user-side entry (the prompt or tool
    # result Claude Code appends immediately before firing a request — a closer
    # anchor than the assistant timestamp, which is response *end*), and the
    # tier from the most recent response that actually wrote to cache.
    # Sidechain turns are excluded: a subagent refreshes its own prefix, not
    # this conversation's. "-" marks an undeterminable tier so it can be
    # distinguished from a determinable one.
    ccs_raw=$(tail -n 200 "$ccs_transcript" 2>/dev/null | jq -rs '
      def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      [ .[] | select(.isSidechain != true) ] as $main
      | ([ $main[] | select(.type == "user") | .timestamp // empty | epoch ] | max) as $start
      | ([ $main[] | select(.type == "assistant")
             | .message.usage.cache_creation // empty
             | select(((.ephemeral_1h_input_tokens // 0) + (.ephemeral_5m_input_tokens // 0)) > 0) ]
         | last) as $cc
      # Each request writes exactly one tier, and the tier can change mid-session
      # (an account entering usage overage drops from 1h to 5m). The most recent
      # write is therefore the operative tier. A tier change is accompanied by a
      # full re-write at cache_read 0, so it is never missed.
      #
      # If a single write ever reports BOTH tiers, the shorter one wins: part of
      # the prefix dies in 5 minutes, and over-reporting warmth is the dangerous
      # direction. Not observed in practice, but free to be safe about.
      | (if $cc == null then "-"
         elif (($cc.ephemeral_5m_input_tokens // 0) > 0) then "300"
         else "3600" end) as $ttl
      | if $start == null then empty else "\($ttl) \(($start | floor))" end
    ' 2>/dev/null)
    IFS=' ' read -r r_tier r_anchor <<EOF
$ccs_raw
EOF

    if _is_int "$r_anchor"; then
      ccs_anchor="$r_anchor"
      if _is_int "$r_tier" && [ "$r_tier" -gt 0 ]; then
        ccs_tier="$r_tier"
      elif _is_int "${ccs_tier_prev:-}" ; then
        # No cache write in this window, but we established the tier earlier in
        # this session. Remembering it is what lets us avoid defaulting to 5m.
        ccs_tier="$ccs_tier_prev"
      fi
    fi

    # --- persist, best effort -------------------------------------------
    # Written only when the transcript changed (roughly once per turn), never
    # on an idle render. Atomic rename so a concurrent reader cannot see a
    # torn line. Every failure here is ignored: the state file is an
    # optimisation, not a dependency.
    if [ -n "$ccs_tier" ] && [ -n "$ccs_anchor" ] && [ -n "$ccs_token" ]; then
      if mkdir -p "$ccs_dir" 2>/dev/null; then
        ccs_tmp="$ccs_state.$$"
        if printf '%s %s %s\n' "$ccs_tier" "$ccs_anchor" "$ccs_token" >"$ccs_tmp" 2>/dev/null; then
          mv -f "$ccs_tmp" "$ccs_state" 2>/dev/null || rm -f "$ccs_tmp" 2>/dev/null
        else
          rm -f "$ccs_tmp" 2>/dev/null
        fi
        # Prune abandoned sessions. Guarded so an empty variable can never
        # turn this into a find over the filesystem root.
        case "$ccs_dir" in
          */claude-cache-status) find "$ccs_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null ;;
        esac
      fi
    fi
  fi

  # --- remaining ------------------------------------------------------------
  if _is_int "$ccs_tier" && _is_int "$ccs_anchor" && [ "$ccs_tier" -gt 0 ] && _is_int "$ccs_now"; then
    cache_ttl="$ccs_tier"
    cache_left=$(( ccs_tier - (ccs_now - ccs_anchor) ))

    # ---- cost at risk (opt-in) ------------------------------------------
    # What expiry costs: you write the prefix again instead of reading it.
    # Cache pricing is a multiple of the normal input price — reads 0.1x,
    # 5-minute writes 1.25x, 1-hour writes 2x — so the loss is the gap:
    #   5m tier: 1.25 - 0.1 = 1.15x     1h tier: 2.0 - 0.1 = 1.9x
    # At Opus's $5/Mtok that is $5.75/Mtok on the short tier and $9.50 on the
    # long one. The multiplier depends on the tier, which is why this is worth
    # doing here and hard to do without tier detection.
    #
    # Opt-in, because on a Pro or Max subscription you are not billed per token
    # and the figure would imply a cost you will never see. Nothing in the
    # status line input says which billing you are on, so the opt-in IS the
    # signal. All arithmetic is integer cents; no shell float rounding.
    if [ -n "${CLAUDE_CACHE_STATUS_PRICING:-}" ] && _is_int "$ccs_ctx_tokens" &&
       [ "$ccs_ctx_tokens" -gt 0 ]; then
      case "$CLAUDE_CACHE_STATUS_PRICING" in
        api) ccs_price=$(_price_cents_per_mtok "$ccs_model") ;;
        *.*) # dollars per million, one or two decimal places
          ccs_p_whole=${CLAUDE_CACHE_STATUS_PRICING%%.*}
          ccs_p_frac=${CLAUDE_CACHE_STATUS_PRICING#*.}00
          _is_int "$ccs_p_whole" && _is_int "${ccs_p_frac%"${ccs_p_frac#??}"}" &&
            ccs_price=$(( ccs_p_whole * 100 + ${ccs_p_frac%"${ccs_p_frac#??}"} )) ;;
        *) _is_int "$CLAUDE_CACHE_STATUS_PRICING" &&
             ccs_price=$(( CLAUDE_CACHE_STATUS_PRICING * 100 )) ;;
      esac

      if _is_int "${ccs_price:-}" && [ "$ccs_price" -gt 0 ]; then
        # 190 = 1.9x for the 1h tier, 115 = 1.15x for the 5m tier
        if [ "$ccs_tier" -ge 3600 ]; then ccs_mult=190; else ccs_mult=115; fi
        # Divide the token count first so the product cannot overflow a 32-bit
        # shell: (tokens/1000) * cents_per_mtok / 1000 == tokens * cents / 1e6
        ccs_loss=$(( ccs_price * ccs_mult / 100 ))
        cache_cents=$(( (ccs_ctx_tokens / 1000) * ccs_loss / 1000 ))
      fi
    fi

  elif _is_int "$ccs_anchor"; then
    # The session is real and we know when it last spoke, but no cache write has
    # been seen, so the tier is unknown. Distinct from "not a Claude session".
    cache_state="unknown"
  fi
fi
# ---- end COMPUTE ----------------------------------------------------------

line=""

# ---------------------------------------------------------------------------
# RENDER  (needs $cache_ttl, $cache_left, $cache_state, the C_* colours)
# ---------------------------------------------------------------------------
if [ "$cache_state" = "unknown" ]; then
  # An anchor exists but no cache write has been seen, so the tier is unknown
  # and no honest countdown is possible. Say so rather than printing nothing:
  # in a status line, silence is indistinguishable from a broken script.
  line="${C_UNKNOWN}cache ?${C_RESET}"

elif [ -n "$cache_left" ] && [ -n "$cache_ttl" ]; then
  # Clamp: clock skew, or an anchor from a request still in flight, can read as
  # more than a full TTL.
  [ "$cache_left" -gt "$cache_ttl" ] && cache_left="$cache_ttl"

  if [ "$cache_left" -le 0 ]; then
    cache_color="$C_CRIT"
    cache_text="cache cold"
  else
    # Granularity adapts to how much is left. Seconds are noise for most of an
    # hour-long window, but they are the only thing that matters in the last
    # minutes — and a number that never visibly moves is indistinguishable from
    # a frozen one. Because the switch points are absolute, the 5m tier gets
    # M:SS from the start, which is what it needs.
    if [ "$cache_left" -ge 600 ]; then
      cache_text="cache $(( cache_left / 60 ))m"
    elif [ "$cache_left" -ge 60 ]; then
      cache_text="cache $(( cache_left / 60 )):$(printf '%02d' "$(( cache_left % 60 ))")"
    else
      cache_text="cache ${cache_left}s"
    fi

    # Colour bands are fractions of the DETECTED tier, so the same colour means
    # the same urgency whether the window is 5 minutes or an hour. Absolute
    # thresholds cannot do this: "red under 300s" is the entire 5m window and
    # only the last 8% of the 1h one. The 60s floor keeps the short tier from
    # going red too late (15% of 300s is only 45s).
    cache_pct=$(( cache_left * 100 / cache_ttl ))
    if [ "$cache_left" -lt 60 ] || [ "$cache_pct" -lt 15 ]; then
      cache_color="$C_CRIT"
    elif [ "$cache_pct" -lt 50 ]; then
      cache_color="$C_WARN"
    else
      cache_color="$C_OK"
    fi
  fi

  # Cost at risk, when priced. Suppressed below a dime: at the start of a
  # session the figure is pennies and reads as noise.
  if _is_int "${cache_cents:-}" && [ "$cache_cents" -ge 10 ]; then
    cache_text="$cache_text \$$(( cache_cents / 100 )).$(printf '%02d' "$(( cache_cents % 100 ))")"
  fi

  line="${cache_color}${cache_text}${C_RESET}"
fi
# ---- end RENDER ----------------------------------------------------------

# '%s', never '%b' — see the _esc note above.
printf '%s\n' "$line"
