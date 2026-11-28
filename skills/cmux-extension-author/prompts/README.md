# Copy-paste prompts

Each page here is one common goal and a prompt for it. Paste the prompt (the `text` block) into
any coding agent that can run `cmux`, in an empty folder, and it ends with a working
customization: `cmux ext dev --once --json` exits 0 and the extension draws the expected view or provides the requested command.
Change the words in the prompt to what you want; keep the steps.

`cmux customize prompts` lists them and `cmux customize prompts NAME` prints one. Each prompt
points its agent at `cmux customize docs SURFACE`, the reference for that surface with a working
example, written from this build's code.

The scheduled `customize-prompts-cold-model` workflow pastes each prompt into a fresh model in an
empty folder and runs `cmux ext dev --once --headless --json`. Each page declares what the checker
verifies after the build:

- `shows "WORDS"` checks the first scene for the requested text.
- `command standup note` checks the palette and CLI registration, runs the handler with sample
  work items, and checks its toast and returned note.
- `composer /review` checks the slash command's menu description and the text it inserts.

Run `python3 scripts/cmux-next/ext-recipe-cold-model.py --prompts --headless` to exercise the same checks.
