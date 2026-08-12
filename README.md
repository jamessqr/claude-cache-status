# claude-cache-status

[![tests](https://github.com/jamessqr/claude-cache-status/actions/workflows/test.yml/badge.svg)](https://github.com/jamessqr/claude-cache-status/actions/workflows/test.yml)

A status line segment for [Claude Code](https://code.claude.com) that shows how
long your prompt cache stays warm.

```
dev@host  ~/code/app  main ±  |  Opus  ▓▓▓▓░░░░▏░ 42%  cache 47m
                                                       ─────────
```

POSIX shell and `jq`. No daemon, no background process, no configuration.

## The problem

Anthropic caches your conversation prefix server-side. A cache read costs about
a tenth of what re-processing the same tokens costs, and the cache is refreshed
for free every time you use it. Walk away for long enough and it expires — your
next message silently re-pays the full write price on the entire conversation.
On a large session that is the most expensive request you will make all day.

Nothing in Claude Code tells you how long you have. This does.

## The catch nobody handles well

There are two cache lifetimes. The API default is **5 minutes**; there is an
opt-in **1-hour** tier that costs 2× on writes. Claude Code chooses, and it does
not tell you which one you got.

Guessing is not a small error. Assume 5 minutes on a 1-hour session and you will
be told the cache is dead with 55 minutes still on the clock. Assume 1 hour on a
5-minute session and you will be told you have 50 minutes of warmth that does not
exist.

Worse, **the tier can change mid-session.** Here is a real transcript switching
from the 5-minute tier to the 1-hour tier, paying a full 728,000-token re-write
to do it:

```
20:23:40   5m   write 986       read 727254
20:24:12   1h   write 728046    read 0        <- tier change, total cache loss
20:24:26   1h   write 980       read 728046
```

So a hardcoded constant is not merely a bad default — it can be wrong for a
session it was right about ten minutes earlier.

This reads the tier out of your transcript, per session, and keeps reading it.

## Install

Requires `jq` 1.5 or newer (`brew install jq` / `apt install jq`).

```sh
curl -fsSL https://raw.githubusercontent.com/jamessqr/claude-cache-status/v1.0.0/claude-cache-status.sh \
  -o ~/.claude/claude-cache-status.sh
chmod +x ~/.claude/claude-cache-status.sh
```

Then add this to `~/.claude/settings.json`, verbatim — there is nothing to
substitute:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/claude-cache-status.sh",
    "refreshInterval": 30
  }
}
```

**`refreshInterval` is required.** Status lines are event-driven: without it the
countdown freezes while you sit at the prompt, which is exactly when you are
looking at it. `30` suits the 1-hour tier. Use `1`–`5` if you want a live
seconds readout — the warm path costs about 11 ms, so a 1 Hz refresh is safe.

The URL is pinned to a release tag, so the bytes you audit are the bytes you
run. There is deliberately no `curl | sh` installer: this reads your session
transcripts, and piping it straight into a shell is the one arrangement that
guarantees nobody read it first. See [Security and
privacy](#security-and-privacy) for what it does and does not touch.

To read it in a checkout, or to run the tests, clone instead — the script has no
dependencies on the rest of the repo and works from anywhere you point at it:

```sh
git clone https://github.com/jamessqr/claude-cache-status
```

Already have a status line? See [Adding this to an existing status
line](#adding-this-to-an-existing-status-line).

## What you see

| Display | Meaning |
|---|---|
| `cache 47m` (green) | More than half the window remaining |
| `cache 22m` (amber) | 15–50% remaining |
| `cache 6:30` (red) | Under 15% remaining |
| `cache 42s` (red) | Final minute |
| `cache cold` (red) | Expired — your next turn re-pays the write |
| `cache ?` (grey) | Session is live but no cache write has been seen yet, so the tier is unknown |
| *(nothing)* | Not a Claude Code session, or no transcript available |

With pricing enabled (below), each of those gains a figure: `cache 47m $6.65`.

Two deliberate choices there.

**Precision follows urgency.** Minutes above ten, `M:SS` below, seconds in the
last minute. Seconds are noise for most of an hour, and they are the only thing
that matters at the end — and a number that never visibly changes is
indistinguishable from a frozen one. Because the switch points are absolute, the
5-minute tier gets `M:SS` from the start, which is what it needs.

**Colour is a fraction of the detected tier, never an absolute time.** Green
above 50%, amber 15–50%, red below, with a hard 60-second floor. This is the
whole reason detecting the tier is worth doing: "red under 5 minutes" is the
*entire* 5-minute window and only the last 8% of the 1-hour one. The same colour
means the same urgency on either.

## How it works

Two values are needed: which tier, and when the last request started.

**The tier** comes from the most recent response that wrote to cache, via
`usage.cache_creation.ephemeral_1h_input_tokens` versus
`ephemeral_5m_input_tokens`. Each request writes exactly one tier, so the newest
write is the operative one. If a single write ever reports both, the shorter
wins — part of that prefix dies in five minutes, and over-reporting warmth is the
dangerous direction.

**The anchor** is the newest user-side transcript entry: your prompt, or a tool
result. Claude Code appends those immediately before firing a request, which
makes them a close proxy for request *start* — and the cache lifetime is measured
from the start of the request, not the end of the response. Anchoring on the
assistant entry instead would overstate remaining time by the whole streaming
duration of a long turn.

Subagent turns are excluded. A subagent runs against its own cache prefix, so its
activity must not refresh the main conversation's countdown.

### Two behaviours that matter more than the detection itself

**The tier is remembered per session.** A cache-read-only turn writes nothing, so
the tier is momentarily invisible in the transcript. Rather than falling back to
a guess, the established tier persists for the session. A tier change is never
missed, because it arrives with an unmissable full re-write at `read 0`.

**When the tier has never been established, it says so.** No cache write seen
means no honest countdown is possible, so it renders `cache ?` instead of
inventing a number. Silence would be worse — in a status line, silence is
indistinguishable from a crashed script.

### Cost at risk (opt-in)

Set `CLAUDE_CACHE_STATUS_PRICING=api` and the segment also shows what expiry
costs you: `cache 47m $6.65`.

The arithmetic is short. Cache pricing is a multiple of the normal input price:
reads are 0.1x, five-minute writes 1.25x, one-hour writes 2x. Expiry means you
write instead of read, so the loss is the gap between them:

| Tier | Loss per million tokens |
|---|---|
| 5-minute | (1.25 − 0.1) = **1.15x** input price |
| 1-hour | (2 − 0.1) = **1.9x** input price |

At Opus's $5 per million that is $5.75/M on the short tier and **$9.50/M on the
long one**. A 700,000-token conversation on the 1-hour tier has $6.65 riding on
it. The multiplier depends on the tier, which is why a tool that hardcodes one
cannot get this right — hardcoding 1.25x understates a 1-hour session by 65%.

Once the cache is cold the figure stays, because it is then no longer a risk: it
is what your next message costs extra.

**Why opt-in.** On a Pro or Max subscription you are not billed per token, so a
dollar figure would imply a cost you will never see. Nothing in the status line
input reveals which billing you are on, so the opt-in is the signal.

The price table covers Fable 5, Mythos 5, Opus 5 / 4.8 / 4.7 / 4.6, Sonnet 5 /
4.6 and Haiku 4.5 at list input rates. An unrecognised model shows no figure
rather than a guess. To price a model that is missing, or if your rates are not
list rates, give the number instead of `api`:

```sh
CLAUDE_CACHE_STATUS_PRICING=5      # $5.00 per million input tokens
CLAUDE_CACHE_STATUS_PRICING=12.50
```

Not modelled: the 1.1x data-residency multiplier that applies when inference is
pinned to a single region, and the 1.1x premium on regional endpoints under
Bedrock and Google Cloud. Both err toward understating, never overstating.
Figures under ten cents are suppressed as noise.

### Render cost

The transcript is parsed only when it has changed, tracked by a small per-session
state file keyed on the transcript's modification time and size. The mtime is
read at **fractional** precision deliberately: whole seconds cannot distinguish
two writes in the same second that leave the file the same length, and stale
state would then be served.

Idle re-renders — the common case under `refreshInterval` — reuse the cached
anchor and never touch the transcript. Measured on an M4 Max against a 78 MB
transcript:

| | CPU per render |
|---|---|
| Cold (transcript parsed) | 0.070 s |
| Warm (state reused) | 0.011 s |

## Configuration

There is no config file. Three environment knobs:

- **`CLAUDE_CACHE_STATUS_PRICING`** — unset (default) shows no dollar figure.
  `api` uses the built-in price table; a number is treated as dollars per
  million input tokens. See [Cost at risk](#cost-at-risk-opt-in).
- **`NO_COLOR`** — any non-empty value disables all styling
  ([no-color.org](https://no-color.org)).
- **`XDG_CACHE_HOME`** — where the state file lives (default `~/.cache`).

To change the colours, edit the three `C_*` lines at the top of the script. They
are 256-colour indices; anything ≥ 16 renders identically under every terminal
theme, unlike the basic 8 colours, `BOLD` (which iTerm2 promotes to bright
variants by default) and `DIM` (drawn as 50%-alpha faint text).

## Adding this to an existing status line

The script is marked with two blocks, `---- COMPUTE ----` and
`---- RENDER ----`. Copy both into your own script along with the `_esc`,
`_is_int`, `_stat_token` and `_is_token` helpers and the `C_*` colours. COMPUTE
goes after the line where you read stdin into `$input`; RENDER goes wherever the
segment belongs.

Two things to fix in your own script while you are there, if they apply:

- **`echo "$input" | jq`** corrupts any JSON containing a backslash under `dash`
  and under `bash` with `xpg_echo`. Backslashes are legal in filenames, so this
  is reachable. Use `printf '%s'`.
- **`printf '%b'`** interprets backslash sequences *inside the values you print*.
  A directory literally named `x\033]0;title\007` is legal, and `%b` turns it
  into a real terminal escape that rewrites your title bar. Use `printf '%s'` and
  build colours from a real `ESC` byte.

## Security and privacy

This reads your session transcripts, so it should be read before it is run. It is
short enough to audit in one sitting.

| | |
|---|---|
| **Reads** | stdin JSON from Claude Code; the last 200 lines of the transcript it names; its own state file |
| **Writes** | one state file per session under `$XDG_CACHE_HOME`, holding three integers. No conversation content. Pruned after 7 days |
| **Sends** | nothing. There are no network calls — `grep -E 'curl\|wget\|nc \|ssh' claude-cache-status.sh` comes back empty |
| **Runs** | `jq`, `tail`, `stat`, `date`, `mkdir`, `mv`, `find`, `basename`, `tr`. No `eval`, no `sudo`, no constructed commands |

From the transcript it extracts two timestamps and two integer token counts. No
message content, no prompts, no tool output. The only string it can print is
`cache <value>`.

Properties worth stating explicitly:

- The session key is restricted to `[A-Za-z0-9_-]` before it reaches a file path,
  so a `session_id` containing `../` cannot escape the state directory.
- Control characters are stripped from JSON-sourced values, so a filename holding
  a real `ESC` byte cannot emit an escape sequence.
- Every integer is validated before arithmetic, including values read back from
  the state file. Unvalidated shell arithmetic evaluates `"abc"` as `0` and
  overflows past 19 digits.
- The transcript read is gated on `[ -f ]`, true only for regular files, so a
  fifo, device, or directory supplied as `transcript_path` can never make `tail`
  block and hang the status line.
- The state file is written by atomic rename, so a concurrent reader cannot see a
  torn line.
- There is no `set -e`, deliberately. A status line that errors is worse than one
  that omits a segment, so malformed input, a missing file, an unwritable cache
  directory, the wrong `jq` version and unparseable timestamps all end in the
  segment simply not appearing.

## Limitations

- **It depends on transcript fields that are not a documented contract** —
  `.type`, `.isSidechain` and `.message.usage.cache_creation`. The status line
  *input* schema is documented and stable; the transcript JSONL shape is not. If
  a Claude Code release renames those, the segment vanishes silently and needs a
  fix. This is unavoidable for tier detection: the 1h/5m split appears nowhere
  else, and the status line's own JSON carries only aggregate cache counts. The
  state cache limits it to roughly one read per turn rather than one per render.
- **A conversation can hold up to four cache breakpoints**, each with its own
  lifetime. This reports one number, tracking the prefix every request reads.
- **`/compact` destroys the prefix.** For the window between compaction and your
  next request, the countdown still refers to a prefix that no longer exists. It
  corrects itself on the following turn.
- **Timing is approximate.** The anchor is a proxy for request start, and the
  display only moves as often as `refreshInterval`.
- **One input is unbounded.** A transcript consisting of a single enormous line
  is handed to `jq` whole, because `tail -n 200` has nothing to trim. Real
  transcripts are many small lines. A byte cap is not implemented because slicing
  mid-line would break the parse and disable the feature more often than the case
  it guards.

## Development

```sh
sh tests/claude-cache-status.test.sh          # script under /bin/sh
SH=dash sh tests/claude-cache-status.test.sh  # script under a named shell
```

`SH` selects the shell the *script* is executed with, which is what the
portability claim is about. It is independent of the shell running the harness.

59 checks: tier detection on both tiers and on a mixed write, every display
granularity boundary, all six colour bands, tier memory across a write-free
window, subagent exclusion, `NO_COLOR`, corrupt state files, path traversal via
`session_id`, control-character stripping, nine malformed or hostile inputs
verified to omit the segment without hanging, and every pricing path — each
model in the table hand-checked against the arithmetic, unknown models and
garbage prices producing no figure, and a 1M-token context confirming the
integer maths cannot overflow. Fixtures are generated at run time
because every meaningful case is relative to the current time.

CI runs the suite on every push across six combinations: `sh`, `dash` and `bash`
on Linux, and `sh`, `bash` and `zsh` on macOS. That spread is deliberate — it
covers GNU against BSD `stat` and `date`, and bash 5 against the bash 3.2 that
ships on macOS, which is where portability bugs in a script like this surface.

## Prior art

Several projects address this, with different tradeoffs. Worth reading before
choosing:

- **[KatsuJinCode/claude-cache-countdown](https://github.com/KatsuJinCode/claude-cache-countdown)**
  — the most featured. A standalone Python ticker with escalating audible alerts,
  multi-session tracking, a dollars-at-risk readout, and four display backends.
  Its TTL is a CLI flag defaulting to 295 s, and its clock starts at the `Stop`
  hook, i.e. after the response finished streaming.
- **[joeyda3rd/claude-cache-timer](https://github.com/joeyda3rd/claude-cache-timer)**
  — closest in spirit: a hook stamps an expiry, the status line counts down.
  ~30 lines. TTL hardcoded to 3600 with instructions to hand-edit two files for
  the other tier.
- **[fifthadj/claude-cache-keepalive](https://github.com/fifthadj/claude-cache-keepalive)**
  — the other project doing genuine tier detection from `cache_creation`, and
  additionally a PTY-host keepalive that injects a cheap request to hold the
  cache open. If you would rather prevent expiry than watch it, start here.
- **[cnighswonger/claude-code-coffee](https://github.com/cnighswonger/claude-code-coffee)**
  — infers the tier from quota state rather than from cache writes, and sets a
  cron cadence accordingly.
- **[she-llac/claude-counter](https://github.com/she-llac/claude-counter)** — by
  far the most popular cache timer, but a browser extension for claude.ai rather
  than the CLI. It cannot detect the tier: the endpoint it intercepts returns no
  usage data.
- **[jesserobbins gist](https://gist.github.com/jesserobbins/ff344a13f3b90cddb8e6b1e19e7e604e)**
  — the smallest version of the idea, in about 20 lines.

What is different here: the tier is detected rather than configured, remembered
across turns that write nothing, and reported as unknown rather than guessed when
it has never been seen; and the countdown is anchored to request start rather
than response end. The cost figure follows from the same detection: because the
write multiplier differs by tier, knowing the tier is what makes the number
correct.

## Licence

MIT. Unofficial and not affiliated with Anthropic.
