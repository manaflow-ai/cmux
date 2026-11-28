# Prompt: make my sidebar show X

A section of your own in the sidebar. Surface: `section` (`cmux customize docs section`).
For a number or list that changes by itself (a clock, a count of workspaces), the surface is
`live-section`.

<!-- prompt-check: shows "Write the spec" -->

```text
Make my cmux sidebar show a section called "Focus" that lists these three things, in this order:
"Write the spec", "Review the open pull requests", "Reply to the design thread". Clicking one
shows a toast with its text.

Do it as a cmux extension in this folder (it may be empty):
1. Run `cmux customize docs section` and read it whole. It is the reference for a sidebar section
   with a working example; start from that example and change only what my ask needs.
2. Write the files it names (cmux-app.json and src/main.ts). Use the kit it shows (Row, VStack,
   signal); no sizes or colors of your own.
3. Run `cmux ext dev --once --json`. If it exits 3 (no cmux running), run
   `cmux ext dev --once --headless --json` instead. Fix every error it prints and run it again
   until it exits 0 and its "scene" shows "Write the spec".
Then tell me in two sentences what you made and where I see it.
```
