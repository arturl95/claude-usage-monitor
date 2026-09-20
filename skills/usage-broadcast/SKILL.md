---
name: usage-broadcast
description: Use when you want to tell every other running Claude Code session to wrap up and record its progress because account usage limits are close to being hit. Invoked as /usage-broadcast.
---

# Broadcast a usage wrap-up to every running session

Tell all other Claude Code sessions on this machine that account usage is
running out, so they can record their progress before being force-stopped.

Account usage limits are shared across every session. When one session
exhausts them, all of them stop.

## Steps

1. **Read the current usage.**

   ```bash
   ~/.claude/scripts/claude-usage --json
   ```

   If this exits non-zero, stop and report the error to the user verbatim. Do
   not broadcast a warning built on numbers you could not read. Exit code 4
   means no session has published recently; 6 means the status line is not
   installed.

2. **List the other sessions.** Call `ListAgents`. It returns every peer
   session by name. Skip any session the user told you to leave alone.

3. **Message each peer.** For every peer, call `SendMessage` with its name and
   a message along these lines, filled in with the real numbers:

   > Account usage is at 91% of the 5-hour limit, which resets at 14:20 (in 38
   > minutes). This limit is shared across all sessions, so you may be
   > force-stopped mid-task and lose unsaved progress. Please wrap up at a safe
   > point: record what you have done, what is in flight, and the next concrete
   > step somewhere durable, so this work can be resumed. You decide whether to
   > finish the current step first.

   Send to every peer, including ones marked idle — an idle session may be
   waiting on the user and will see the message when it resumes.

4. **Report back.** Tell the user the current percentages, the reset time, and
   which sessions you notified. If any `SendMessage` failed, say which and why.

## Notes

- This is advisory. Each session decides how to respond; nothing is forced.
- The automatic `PreToolUse` hook already warns each session once per window.
  Use this skill when you want to push the warning out immediately, for example
  after checking `/usage` yourself.
