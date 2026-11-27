# Prompt: add a command to the Command Palette

One operation that runs from the Command Palette, as `cmux NAME ...` in a terminal, and as a tool
agents can call. Surface: `command` (`cmux customize docs command`).

<!-- prompt-check: command standup note -->

```text
Add a command to cmux called "Stand-up: Copy my note" that builds a stand-up note from a list
of what I did (an input `done`, a list of strings) and shows it in a toast, and returns the note.
In a terminal it runs as `cmux standup note`.

Do it as a cmux extension in this folder (it may be empty):
1. Run `cmux customize docs command` and read it whole. It is the reference for a command with a
   working example (cmux-app.json, catalog.json, src/main.ts); start from that example and change
   only what my ask needs. Keep the catalog's naming rules exactly as it says.
2. Run `cmux ext dev --once --json`. If it exits 3 (no cmux running), run
   `cmux ext dev --once --headless --json` instead. Fix every error it prints and run it again
   until it exits 0.
Then tell me in two sentences what you made and how I run it.
```
