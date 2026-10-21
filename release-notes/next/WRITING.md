# Writing What's New entries

What's New, the Update Ready popover and the "cmux Updated!" card show only curated entries:
one file per change in `release-notes/next/highlights/`, added in the same commit as the change.
Each nightly's digest (`scripts/whats-new/digest.py`) is the highlight files that its commit range
added. Commit titles never appear as features: they show only in the folded "All changes" list
under a release. A nightly with no highlight file says "Maintenance and fixes".

The bar is conductor.build/changelog: grouped by release, short lines written by a person, a
picture for each feature people can see, and clear New, Improved and Fixed groups. The design is
ours: the What's New Ledger page, the update card and its popover.

## One file per change

```
title: Every chat on your Mac, in one place
category: new                       (new | improved | fixed | security)
docs: https://cmux.com/docs/agents        (optional)

cmux finds your Claude Code, Codex and other agent chats on this Mac and lists them in All
chats at the bottom of the sidebar. Open one to resume it.
```

- **Title.** What people can do now, or what works now. Start with the thing ("Every chat on your
  Mac, in one place", "⇧⌘N opens a new window"). At most 60 characters, no final period.
- **Body.** One or two whole sentences, at most 240 characters. Say where to find it (the menu,
  the setting, the shortcut). Benefit first, then the detail.
- **Fixed entries** say what works now, not what was broken inside: "Restart to Update works after
  a background download", not "Fix race in installer".
- **No internal words.** No bead ids, PR numbers, commit hashes, branch, lane or crate names. Use the
  names people see in the app.
- **Never a commit subject.** "fix(sidebar): …" and "sidebar: …" are rejected.
- **One change, one file.** Join small related changes into one entry, as Conductor does
  ("Sidebar sections collapse, and clearer feature errors").
- **A picture for each New entry people can see.** Stable and RC releases require one for every New
  entry, in light and dark. Nightlies show a picture when it is there.

## Release title

A nightly's title is its first New entry's title, "and N more" when it has more. Order the
highlight files so that the best change comes first.

## Checks

`scripts/whats-new/validate.py` runs on every digest and is the release gate. It rejects internal
names, commit-style text, summaries that are not whole sentences, and text that is too long. A
highlight file that fails is left out of the nightly and reported. Stable and RC releases also need
every language and every picture.
