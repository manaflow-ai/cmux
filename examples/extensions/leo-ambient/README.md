# Ambient

What your agents and machines are doing, at a glance:

- **Usage rings**: one pair per provider (Claude, Codex, ...). The outer ring is the 5-hour
  window and the inner ring is the week. Each ring turns amber at 60% and red at 85%. Under the
  rings you see the last 24 hours' tokens and dollars and when the window resets.
- **Checks**: the checks on your open pull requests. Any red reads as red, then running, then all
  green. The ones to look at come first; click one to open it.
- **Machines**: how busy each of your machines is (load against its budget) and how many agents
  run on it.

It shows up in two places, and you choose both yourself:

- **New Tab page**: Settings > Tabs > New Tab App > Ambient (`cmux settings set tabs.newTabApp local/leo-ambient`).
- **Widget**: Edit Widgets > Add Widget > Ambient, in small, medium or large. Tap the tile's title
  to switch between usage, checks and machines.

Nothing in cmux turns it on, and installing it changes no default look. In Settings > Apps >
Ambient you can turn off Checks, which stops every GitHub read, or Machines.

```sh
cmux ext dev examples/extensions/leo-ambient
```

The data comes from three `cmux.watch` sources. They are cached, and every mount shares them:
`chat.list` (usage and limits), `github.changes` (checks) and `fleet.hosts` (machines). The
extension runs no timer of its own.
