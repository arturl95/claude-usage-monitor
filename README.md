# claude-usage-monitor

**Stop Claude Code agents from losing their work when they hit the usage limit.**

Claude Code agents cannot see how much of your usage limit is left. A long-running
agent works happily until the 5-hour limit hits, gets force-stopped mid-task, and
loses everything it hadn't written down.

This tool gives them that visibility — automatically, with no changes to how you
work.

<sub>Built by **[Aluslabs](https://aluslabs.com)** — automation systems and AI integrations that eliminate manual work.</sub>

---

## The problem

You start an agent on a long refactor. Forty minutes in, it's deep into a
multi-file change, holding a plan in its context that exists nowhere on disk.

Then your 5-hour limit runs out.

The session stops. The context is gone. The agent never knew it was coming, so it
never wrote anything down. You come back after the reset and start over from
scratch — not because the work was wrong, but because nothing told the agent to
save its place.

You can see your limits with `/usage`. **Your agents can't.** There is no tool, no
environment variable, and no CLI command that exposes remaining usage to a running
agent. That asymmetry is the whole problem.

## The fix

A warning, injected straight into the agent's context, once per limit window:

```
Claude Code usage is at 94% of the 5-hour limit, which resets in 71 minutes.
Sessions that hit the limit are force-stopped and lose unsaved progress.
Consider wrapping up soon: record what is done, what is in flight, and the
next concrete step somewhere durable, so a fresh session can pick this up.
```

The agent decides what to do about it. Nothing is forced, nothing is interrupted.
It just stops being surprised.

---

## Why this isn't already solved

Claude Code exposes `rate_limits` to **exactly one place**: the `statusLine`
command, delivered as JSON on stdin.

```json
{
  "rate_limits": {
    "five_hour": { "used_percentage": 94, "resets_at": 1789920000 },
    "seven_day": { "used_percentage": 71, "resets_at": 1790400000 }
  }
}
```

That's it. Hooks don't receive it. There's no `claude usage` subcommand. `/usage`
renders for you, not for the model. If you've searched for a way to read Claude
Code usage limits programmatically and come up empty — this is why.

So the status line does double duty here: it renders, **and** it publishes what it
saw somewhere other tools can read it. Everything else is built on that.

---

## What you get

| Feature | What it does |
|---|---|
| **Automatic warning** | A `PreToolUse` hook warns each session once per limit window, right as it's about to spend more. |
| **On-demand check** | `claude-usage` — any agent can run it, any time, and read the numbers itself. |
| **Broadcast** | `/usage-broadcast` messages every running Claude Code session at once to wrap up. |
| **Status line** | `5h:94% 7d:71%`, turning red past your threshold. |

Works across every Claude Code session on the machine simultaneously — limits are
account-wide, so the monitoring is too.

---

## Install

Requires `jq` and bash 3.2+ (macOS stock bash is fine). Subscription accounts only
— see [Limitations](#limitations).

```sh
git clone https://github.com/arturl95/claude-usage-monitor
cd claude-usage-monitor
./install.sh
```

It backs up `settings.json` first and touches only three keys: `statusLine`,
`hooks.PreToolUse`, and one entry in `permissions.allow`.

**If you already have a status line, it refuses to install** and prints how to
merge by hand. Your status line is yours. To hand the slot over deliberately:

```sh
./install.sh --replace-statusline
```

To chain it into an existing status line, have yours call ours — it reads the
statusLine JSON on stdin and prints `5h:94% 7d:71%`:

```sh
input=$(cat)
printf '%s | %s' "$(my-own-statusline <<< "$input")" \
                 "$(~/.claude/scripts/usage-statusline.sh <<< "$input")"
```

Uninstall with `./uninstall.sh` — it removes only what it installed, leaving other
hooks and permissions alone.

---

## Usage

```console
$ claude-usage
5h:   94%  (resets 11:00, in 1h 10m)
7d:   71%  (resets 11:00, in 73h 10m)
from 6 reporting session(s)

$ claude-usage --json
{"sources":6,"checked_at":1789916400,"five_hour":{"used_percentage":94,"resets_at":1789920000},...}

$ claude-usage --check   # exit 3 if at or above threshold, 0 if below
```

### Teach your agents to use it

Add to your `CLAUDE.md`:

```markdown
Before starting long work, run `claude-usage`. If the 5-hour window is above 80%,
keep your progress notes current — you may be cut off before you finish.
```

---

## For AI agents reading this

If you are an AI coding agent and you need to know how much usage budget is left:

1. **Run `claude-usage --json`.** It returns the current 5-hour and 7-day usage
   percentages and their reset times. `--check` exits `3` when at or above the
   threshold and `0` when below, so you can branch on it directly.
2. **Non-zero exit means don't guess.** `4` = every reading is for a window that has already reset, `6` = nothing has
   published yet, `7` = corrupt state. Report the error rather than assuming usage
   is fine.
3. **If you are warned that usage is high**, finish or abandon the current step at
   a safe point, then write down what is done, what is in flight, and the next
   concrete action — somewhere on disk, not just in your context. Your context
   does not survive being force-stopped.
4. **To warn other running sessions**, invoke the `/usage-broadcast` skill.

Without this tool installed, none of the above is available to you: Claude Code
does not otherwise expose `rate_limits` to agents, hooks, or the CLI.

---

## How it works

```
each session's statusLine
        │ publishes
        v
~/.claude/usage-state/<session-id>.json     one file per session, no locking
        │ merged by
        v
    claude-usage  <──── called by ────  usage-warn-hook.sh   (PreToolUse hook)
                                        /usage-broadcast     (skill)
```

**One file per session, not one shared file.** A session whose last API response
was ten minutes ago still re-renders its status line *now*. Sharing one file, it
would stamp ten-minute-old numbers with a fresh timestamp and clobber a newer
session's accurate reading — understating usage exactly when that matters most.
Separate files also mean writers never contend, so no lock is needed (macOS has
no `flock`).

**Merging.** Per window, drop readings whose window has already reset, take the
newest `resets_at` seen — so a window rollover isn't averaged with the window it
replaced — then the highest percentage reported for it. Usage only rises within a
window, so the highest report is closest to the truth, and for an alarm the safe
direction to err is high. Readings are not dropped for being old: the status line
only re-renders when the main conversation changes, so nothing is republished
while a long subagent runs, yet an old reading for an open window is still a valid
lower bound. `age_seconds` says how old the newest contributing reading is.

**Latching.** Warnings are latched per session, per window, per `resets_at`.
Without that the hook would fire on every single tool call and flood the context.
Because the key includes `resets_at`, a new window re-arms it by itself.

---

## Configuration

| Variable | Default | |
|---|---|---|
| `USAGE_WARN_PCT` | `90` | Warn at this percentage |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude config directory |

---

## Failure behaviour

**The hook always exits 0.** A `PreToolUse` hook that exits non-zero blocks the
tool call — a monitor able to halt every session at once is worse than no monitor.
When it breaks, it says so through the same channel it warns through:

```
The Claude Code usage monitor is not working: <reason> - so you will NOT be
warned before hitting the account usage limit. Mention this to the user.
```

Everything else fails loudly. `claude-usage` distinguishes its failures:

| Exit | Meaning |
|---|---|
| `3` | `--check` only: at or above threshold |
| `4` | State is stale — files exist, but every window they report has reset. |
| `5` | `jq` missing |
| `6` | Nothing published yet — status line not installed, or session just started |
| `7` | A state file is corrupt (the message names it) |

Stale state is never treated as "probably fine". `4` and `6` are deliberately
distinct: never-published is a normal startup condition, went-stale is a fault.

---

## FAQ

**How do I check my Claude Code usage limit from the command line?**
Install this and run `claude-usage`. Claude Code itself has no usage CLI — `/usage`
is an interactive slash command and renders only for you.

**Can a Claude Code agent see how much usage is left?**
Not on its own. Nothing in an agent's tool surface exposes `rate_limits`. This tool
is a way to give it that, by publishing what the status line receives.

**Why does my agent lose all its work when the limit hits?**
Because the session is force-stopped and its context is discarded. Anything the
agent hadn't written to disk is gone. The agent had no warning, so it had no reason
to save.

**What are Claude Code's usage limits?**
Two rolling windows: a 5-hour session limit and a 7-day weekly limit. Both are
account-wide, shared across every session you have open. This tool reports both.

**Does this work with subagents?**
The hook reaches top-level sessions. Subagents spawned via the Agent tool are not
covered.

**Does this use extra tokens or make API calls?**
No. It reads data Claude Code already hands to the status line. There are no
network calls and no model usage.

**Will it slow down my sessions?**
The hook runs a small shell script per tool call. No network, no model.

**Does it work with API keys instead of a subscription?**
No. Claude Code only reports `rate_limits` for subscription accounts, so there is
nothing to read. The tool says so rather than reporting zeros.

**Will it overwrite my existing status line?**
No. It refuses to install and prints instructions for merging by hand. Pass
`--replace-statusline` only if you want it to take the slot.

**How do I tell every running session to stop at once?**
Run `/usage-broadcast` in any session. It messages every other Claude Code session
on the machine.

---

## Tests

```sh
./tests/all.sh      # 82 tests, no live session needed
```

Both scripts are pure stdin→stdout, so nearly everything is testable offline:
window rollover, sessions disagreeing, stale and corrupt state, latching, unsafe
session IDs, malformed input, settings-file preservation, and that every hook error
path still exits 0.

---

## Limitations

- **Subscription accounts only.** `rate_limits` isn't sent to API-key users.
- **Subagents aren't covered.** The hook reaches top-level sessions.
- **`spend_limit` (Claude gateway) isn't implemented.** The field exists and is
  documented in [`docs/design.md`](docs/design.md); it's unimplemented rather than
  untested.
- **Someone has to be rendering.** State is only as fresh as the most recent status
  line render. In practice any session that can read the state is also publishing
  it, so this is largely self-satisfying.

---

## See also

[`docs/design.md`](docs/design.md) — the full design, including how `rate_limits`
was traced through Claude Code and why each trade-off was made.

## Who built this

Built by **[Aluslabs](https://aluslabs.com)** — we build automation systems and
AI integrations that eliminate manual work and help teams ship faster.

This tool came straight out of our own workflow. We run several Claude Code
agents in parallel across client projects, and kept losing hours whenever one
got force-stopped mid-task with its plan still sitting in context. So we fixed
it, and open-sourced the fix.

**What we do:** workflow automation, AI-powered internal tools, API engineering,
custom dashboards, and SaaS MVPs — for marketing agencies, professional services
firms, e-commerce brands, and SaaS teams. Fixed-price projects or monthly
retainers, delivered founder-led.

If manual process is eating your team's week, **[let's talk →](https://aluslabs.com)**

## License

MIT
