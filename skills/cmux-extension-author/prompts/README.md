# Copy-paste prompts

Each page here is one common goal and a prompt for it. Paste the prompt (the `text` block) into
any coding agent that can run `cmux`, in an empty folder, and it ends with a working
customization: `cmux ext dev --once --json` exits 0 and the view shows the words the page names.
Change the words in the prompt to what you want; keep the steps.

`cmux customize prompts` lists them and `cmux customize prompts NAME` prints one. Each prompt
points its agent at `cmux customize docs SURFACE`, the reference for that surface with a working
example, written from this build's code.

How they are checked: `<!-- prompt-check: shows "WORDS" -->` (or `loads`) names what the
finished extension's first scene must show. `cmux-tui`'s `customize` tests check that every page
names a surface `cmux customize docs` has; the scheduled `customize-prompts-cold-model` workflow
pastes each prompt into a fresh model in an empty folder on a runner with no cmux and passes only
when `cmux ext dev --once --headless --json` exits 0 and shows the words
(`scripts/cmux-next/ext-recipe-cold-model.py --prompts`).
