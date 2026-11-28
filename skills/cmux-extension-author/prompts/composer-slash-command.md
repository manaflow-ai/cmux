# Prompt: add a slash command to the agent chat

A `/` command in the agent chat composer. Surface: `composer-command`
(`cmux customize docs composer-command`).

<!-- prompt-check: composer /review -->

```text
Add a slash command to cmux's agent chat composer: typing `/review` offers "Review my changes",
and picking it puts this into the composer: "Review the changes on this branch: what could
break, what is missing a test, and what you would rename."

Do it as a cmux extension in this folder (it may be empty):
1. Run `cmux customize docs composer-command` and read it whole. It is the reference for a
   composer slash command with a working example; start from that example and change only what my
   ask needs.
2. Run `cmux ext dev --once --json`. If it exits 3 (no cmux running), run
   `cmux ext dev --once --headless --json` instead. Fix every error it prints and run it again
   until it exits 0.
Then tell me in two sentences what you made and how I use it.
```
