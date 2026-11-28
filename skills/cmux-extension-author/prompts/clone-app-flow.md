# Prompt: clone this app's flow

A pane (a tab of your own) that walks through another app's flow: a list, a detail, back.
Surface: `pane` (`cmux customize docs pane`).

<!-- prompt-check: shows "Welcome to cmux" -->

```text
Clone the flow of a mail app's inbox as a cmux pane called "Inbox": a list of messages, and
picking one opens it (its subject, sender and body) with a "Back" button to the list. Start with
three made-up messages; the first one's subject is "Welcome to cmux".

Do it as a cmux extension in this folder (it may be empty):
1. Run `cmux customize docs pane` and read it whole. It is the reference for a pane with a
   working example; start from that example and change only what my ask needs.
2. Keep which screen is showing in a `signal` (the list, or the message picked) and draw the
   screen from it; use the kit's views (VStack, Row, Text, Button, Panel), no sizes or colors of
   your own.
3. Run `cmux ext dev --once --json`. If it exits 3 (no cmux running), run
   `cmux ext dev --once --headless --json` instead. Fix every error it prints and run it again
   until it exits 0 and its "scene" shows "Welcome to cmux".
Then tell me in two sentences what you made and how I open it (the Command Palette, by its title).
```
