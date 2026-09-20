# Claude Code Usage Monitor — Design

Date: 2026-09-20
Status: approved for planning
Distribution: to be released as a public repo under `arturl95` once built and tested

## Problem

Long-running Claude Code agents hit account usage limits mid-task, get
force-stopped, and lose all uncommitted progress. The user can see usage via
`/usage`, but agents cannot: nothing in an agent's tool surface exposes
remaining limit. Agents therefore cannot know to wrap up before being cut off.

## Findings that constrain the design

Verified against Claude Code 2.1.278 on this machine.

1. **`rate_limits` reaches exactly one component: the `statusLine` command.**
   Claude Code pipes a JSON object to the configured statusLine command on
   stdin containing:

   ```json
   "rate_limits": {
     "five_hour": { "used_percentage": number, "resets_at": unix_seconds },
     "seven_day": { "used_percentage": number, "resets_at": unix_seconds },
     "spend_limit": { "used_percentage": number, "resets_at": unix_seconds }
   }
   ```

   It is present only for subscription users, only after the first API
   response, and each window appears only while the API reports it and its
   `resets_at` has not passed. Hooks do **not** receive `rate_limits`.
   There is no `claude usage` subcommand. The statusLine is the only
   sanctioned live source.

2. **Live sessions are enumerable.** `~/.claude/sessions/<pid>.json` holds one
   record per live session: `pid`, `sessionId`, `cwd`, `name`, `status`
   (`busy|idle|shell`), and `messagingSocketPath` pointing at
   `/tmp/cc-socks/<pid>.sock`.

3. **Hooks can inject text into an agent's context.** `PreToolUse` accepts
   `hookSpecificOutput.additionalContext` and receives `session_id` on stdin.

4. **`SendMessage` already reaches peer sessions** over the supported API, so
   broadcasting needs no reverse-engineering of the socket protocol. It is a
   tool, not a CLI, so it can only be driven from inside a session.

5. **`flock` is not available** (macOS). Any design requiring write locking on
   a shared file would need a bespoke lock. `jq` 1.8.0 and `python3` 3.12 are
   available.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| What an agent does at threshold | Warn only; the agent decides how to respond | User's call. Agents are best placed to judge whether they are mid-edit or at a natural boundary. |
| Which agents are covered | Top-level sessions only | Subagents would require a different mechanism; not needed. |
| Delivery | `PreToolUse` hook (automatic) + `/usage-broadcast` skill (manual) | The hook is the documented, daemon-free path and fires exactly when an agent is about to spend more limit. The broadcast covers the "I looked at /usage myself and it's bad" case. |
| Unattended socket daemon | Rejected | Undocumented wire protocol; would break on Claude Code updates. The hook already delivers automatically. |
| Hook failure policy | Report loudly, always exit 0 | A `PreToolUse` hook exiting nonzero blocks the tool call. A monitoring script must never be able to halt the work it monitors. Directly-invoked scripts still fail hard. |
| Install target | `~/.claude/scripts/` | Lives where it runs; settings.json points straight at it. |
| Source of truth | A public git repo under `arturl95`, installed by script | The tool is to be released publicly, so the repo is canonical and `~/.claude/scripts/` holds installed copies. |

## Architecture

```
each session's statusLine
        │ writes
        v
~/.claude/usage-state/<pid>.json        (one file per session; no locking)
        │ read+merged by
        v
   claude-usage  <──── called by ────  usage-warn-hook.sh   (PreToolUse, automatic)
   (also run directly by agents)       /usage-broadcast     (skill, manual)
```

### Why one file per session rather than one shared file

A single shared state file has a correctness bug, not just a locking problem.
A session whose last API response was ten minutes ago still re-renders its
status line *now*. With a shared file it would stamp ten-minute-old
percentages with a fresh timestamp and clobber a newer session's accurate
reading — understating usage precisely when accuracy matters most.

Per-session files also sidestep the missing `flock`: each writer owns exactly
one path, so an atomic `write-tmp + mv` is sufficient and writers never
contend.

## Components

### 1. `~/.claude/scripts/usage-statusline.sh`

Configured as `statusLine.command` in `~/.claude/settings.json`.

- Reads the statusLine JSON from stdin.
- Writes `~/.claude/usage-state/<pid>.json` atomically (`mktemp` in the same
  directory, then `mv`).
- Prints the status line text: `5h:62% 7d:41%`.
- If `rate_limits` is absent, writes **no** state file and leaves any existing
  one untouched. It never writes zeros or placeholder values.
- If `jq` is missing or the input is unparseable, prints
  `usage-monitor: <reason>` as the status line itself. This is maximally
  visible and cannot break anything.
- Prunes `<pid>.json` files whose pid has no corresponding
  `~/.claude/sessions/<pid>.json`, and `warned/` latch files older than 8 days.

State file schema:

```json
{
  "pid": 12345,
  "session_id": "<session-uuid>",
  "written_at": 1789914370,
  "five_hour": { "used_percentage": 62.4, "resets_at": 1789920000 },
  "seven_day": { "used_percentage": 41.0, "resets_at": 1790400000 }
}
```

`five_hour` and `seven_day` are each optional and present only when the API
reported that window.

### 2. `~/.claude/scripts/claude-usage`

The on-demand checker, and the **single** implementation of the read/merge
logic. The hook and the broadcast skill call it rather than reimplementing it.

Interface:

- `claude-usage` → `5h: 91% (resets 14:20, in 38m)   7d: 44%`
- `claude-usage --json` → the merged state as JSON
- `claude-usage --check` → exit 0 below threshold, exit 3 at or above
- Missing or stale state → exit 4, clear message on stderr, no output on stdout

Merge algorithm:

1. Read every `~/.claude/usage-state/*.json`.
2. Drop any file where `now - written_at > USAGE_FRESH_SECONDS`.
3. For each tier (`five_hour`, `seven_day`) independently:
   a. Among remaining files that carry that tier, take the maximum
      `resets_at`. This survives a window rollover, where some sessions still
      report the old window.
   b. Among files sharing that maximum `resets_at`, take the maximum
      `used_percentage`.
4. If no tier yielded data, the state is stale or missing — fail.

Taking the maximum is deliberate: usage only increases within a window, so the
highest recent report is the best available estimate of current truth, and for
an alarm the safe direction to err is high.

Configuration, with defaults defined once at the top of this script and
overridable by environment variable:

- `USAGE_WARN_PCT` (default `90`)
- `USAGE_FRESH_SECONDS` (default `300`)

### 3. `~/.claude/scripts/usage-warn-hook.sh`

Registered as a `PreToolUse` hook with matcher `*`.

- Reads hook JSON on stdin; uses `session_id`.
- Calls `claude-usage --json`.
- At or above `USAGE_WARN_PCT` on either tier, emits:

  ```json
  {"hookSpecificOutput": {
     "hookEventName": "PreToolUse",
     "additionalContext": "Claude usage is at 91% of the 5-hour window (resets 14:20, in 38 min). You may be force-stopped before this task finishes. Consider wrapping up now: write down what is done, what is in flight, and the next concrete step, so a fresh session can pick this up."
  }}
  ```

- **Latching.** A latch file `warned/<session_id>__<tier>__<resets_at>` ensures
  each session is warned once per tier per window. Without this the hook would
  inject on every tool call and flood the context. Because the latch key
  includes `resets_at`, a new window naturally re-arms the warning.
- **Failure handling.** Any internal error is logged to
  `~/.claude/usage-state/monitor.log` and surfaced once per session per hour as
  `additionalContext` reading `usage monitor is broken: <reason>`. The hook
  **always exits 0**.
- Stale state is treated as a breakage, not as "below threshold". It is
  reported, never silently ignored.

### 4. `~/.claude/skills/usage-broadcast/SKILL.md`

A personal skill, invocable as `/usage-broadcast`. Instructs the session to:

1. Run `claude-usage --json`; abort and report if the state is stale.
2. Call `ListAgents` to enumerate peer sessions.
3. `SendMessage` each peer with the current numbers, the reset time, and a
   wrap-up instruction.
4. Report which sessions were notified.

## Settings changes

`~/.claude/settings.json` gains a `statusLine` block and a `hooks.PreToolUse`
entry. The user currently has **no** `statusLine` configured, so this adds a
status line to their terminal that was not there before; it displays the usage
percentages, which is useful in its own right given the problem being solved.

The file is backed up before editing and the edit is surgical — the existing
`permissions`, `enabledPlugins`, `autoMode`, and other keys are preserved
untouched.

`permissions.allow` gains `Bash(claude-usage:*)` so agents can run the checker
without a permission prompt.

## Distribution

The tool is to be published as a public repository under `arturl95` after it is
built and verified working locally. This adds requirements the local-only
version would not have.

### Repository contents

- `scripts/` — the three scripts, canonical copies
- `skills/usage-broadcast/SKILL.md`
- `install.sh` — copies scripts into the Claude config dir and patches settings
- `tests/` — the test suite described below, runnable by a contributor
- `README.md` — what it does, why `statusLine` is the only usage source, install, configuration, uninstall
- `LICENSE` — MIT

### Portability requirements beyond the local build

- **Respect `CLAUDE_CONFIG_DIR`.** Scripts must resolve the config directory
  from `CLAUDE_CONFIG_DIR` when set, falling back to `~/.claude` only when it
  is not. Hardcoding `~/.claude` would break for anyone who has moved it.
- **Never clobber an existing status line.** The author has none configured, but
  most users will. If `statusLine` is already set, `install.sh` must refuse,
  print the exact snippet to merge by hand, and exit nonzero. Silently
  replacing someone's status line is unacceptable.
- **Same for hooks.** Append to any existing `PreToolUse` array rather than
  replacing it.
- **Back up `settings.json`** before any modification, and report the backup path.
- **Provide `uninstall.sh`** that reverses both the file copies and the settings
  changes.
- **No personal data anywhere in the repo.** No real session IDs, pids,
  usernames, absolute home-directory paths, project names, or any content
  from the author's settings file. The spec's own examples are already
  placeholders; the same rule applies to the README, tests, and fixtures.
- **`bash` 3.2 compatible.** macOS ships bash 3.2; the scripts must not rely on
  bash 4+ features such as associative arrays.

## Testing

Both scripts are pure stdin-to-stdout, so the bulk of the behaviour is testable
without a live session.

`usage-statusline.sh`, fed canned statusLine JSON:
- full `rate_limits` → correct state file, correct status line text
- `rate_limits` absent → no state file written, existing file untouched
- only `five_hour` present → state file omits `seven_day`
- malformed input → visible `usage-monitor:` status line, exit 0
- dead-pid state files and old latch files are pruned

`claude-usage`, fed canned state directories:
- fresh single session → correct merged values
- multiple sessions disagreeing → maximum wins
- mid-rollover, sessions reporting different `resets_at` → newest window wins
- all files stale → exit 4
- empty or missing directory → exit 4
- `--check` exit codes on both sides of the threshold

`usage-warn-hook.sh`:
- above threshold, no latch → emits `additionalContext`, creates latch
- above threshold, latch present → emits nothing
- new `resets_at` → re-arms and warns again
- `claude-usage` failing → emits breakage context, exit 0
- every error path → exit 0, verified explicitly

`install.sh`, against canned settings files:
- no existing `statusLine` → installs cleanly, backup created
- existing `statusLine` → refuses, exits nonzero, prints the manual snippet
- existing `PreToolUse` hooks → appended to, not replaced
- `CLAUDE_CONFIG_DIR` set → installs there, not into `~/.claude`
- `uninstall.sh` restores the pre-install state

One integration check that cannot be done offline: configure the status line,
render a live session, and confirm `~/.claude/usage-state/<pid>.json` appears
and is populated with real `rate_limits`. This validates the single assumption
the whole design rests on.

## Out of scope

- Subagents spawned via the Agent tool.
- Automatic checkpointing, WIP commits, or handoff-file generation.
- An unattended socket-broadcast daemon.
- Background (`claude --bg`) sessions, which may not render a status line and
  so may consume state without publishing it.
