# Prompt: make my New Tab page my own

A whole New Tab page of your own, over the composer. Surface: `newtab`
(`cmux customize docs newtab`). For one small tile on the built-in page instead, the surface is
`widget`.

<!-- prompt-check: shows "Good morning" -->

```text
Make my cmux New Tab page my own: a heading "Good morning", under it today's three priorities
("Ship the release", "Review the design", "Plan next week") as rows, and a button "Start the day"
that shows a toast "Let's go".

Do it as a cmux extension in this folder (it may be empty):
1. Run `cmux customize docs newtab` and read it whole. It is the reference for a New Tab page
   with a working example; start from that example and change only what my ask needs.
2. Use the kit it shows; no sizes or colors of your own.
3. Run `cmux ext dev --once --json`. If it exits 3 (no cmux running), run
   `cmux ext dev --once --headless --json` instead. Fix every error it prints and run it again
   until it exits 0 and its "scene" shows "Good morning".
Then tell me in two sentences what you made, and the one setting that picks it
(the docs page names it).
```
