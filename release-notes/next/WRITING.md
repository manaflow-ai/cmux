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
docs: https://cmux.com/docs/next/agents   (optional)

cmux finds your Claude Code, Codex and other agent chats on this Mac and lists them in All
chats at the bottom of the sidebar. Open one to resume it.
```

- **Title.** What people can do now, or what works now. Start with the thing ("Every chat on your
  Mac, in one place", "⇧⌘N opens a new window"). At most 60 characters, no final period.
- **Body.** One or two whole sentences, at most 240 characters. Say where to find it (the menu,
  the setting, the shortcut). Benefit first, then the detail.
- **Fixed entries** say what works now, not what was broken inside: "Restart to Update works after
  a background download", not "Fix race in installer".
- **Docs link.** Link a page that exists: a cmux-next page is `https://cmux.com/docs/next/<slug>`, with
  a slug from `web/data/next-docs/pages.ts` (agents, cli, settings, ...), or a page under
  `web/app/[locale]/(landing)/docs/`. The validator checks only that it is an https URL.
- **No internal words.** No bead ids, PR numbers, commit hashes, branch, lane or crate names, and no
  work-stream codes ("P0 RESIZE KEYS K4", "REOPEN-F7", "part 1 of 2"; `validate.py` rejects them). Use
  the names people see in the app.
- **The body adds to the title.** Never the title again, never the rest of its sentence ("And name the
  check that refuses it"), never "Fixes and improvements".
- **Never a commit subject.** "fix(sidebar): …" and "sidebar: …" are rejected.
- **One change, one file.** Join small related changes into one entry, as Conductor does
  ("Sidebar sections collapse, and clearer feature errors").
- **A picture for each New entry people can see.** Stable and RC releases require one for every New
  entry, in light and dark. Nightlies show a picture when it is there.

## A gallery picture, and a before and after

Leo, 2026-10-20: "tho i think vids and before/afters for our techincal stuff is p important... we
want things to be PRETTY!!!!" When the change shows in a webview gallery entry, name the state that
shows it, and for an Improved entry the state it replaced:

```
title: The Updated card stays glass while open
category: improved
gallery: pages.changelog.update-surfaces/card-preview-over-rows
before: pages.changelog.update-surfaces/card-preview-over-rows-solid
```

Each value is `ENTRY/VARIANT`, as the gallery names them. Keep the before state as a variant of
your gallery when you change a look (`-solid`, `-old`), so it can still render after the change.
When the file merges, `whats-new-gallery.yml` renders both in the dark default theme and puts them
on pr-media after the privacy check (`scripts/cmux-next/media/whats-new-gallery.py`). The next
nightly shows the picture beside the entry, with the before after it. A clip wins over both.

With no `gallery:` line, a New or Improved entry still gets a picture when its commit changed a
`*.gallery.ts` file: the first variant the commit added, else the one whose lines it changed most.
An Improved entry with no `before:` line gets the same state rendered at the commit before it, so a
look you changed in place still has its before. Name the states when the pick would be wrong (for
example when the commit touched several entries).
NOW's `whats_new` line (cmuxterm-hq goal whats-new-pretty) counts the New and Improved entries of the
last ten nightlies that went out without a picture, or without a before and after.

## A clip for each change people can see

Leo, 2026-10-24: "I also think the What's New video is kind of, uh, it's like you're not even showing
anything properly off. It's just sort of weird." Each New or Improved change people can see gets a
3 to 8 second loop of the feature being used, cropped to where it happens. What's New shows it
uncut beside its caption. The clip is recorded on the fleet from a spec, so the next release's clips
come out the same way:

1. Write `release-notes/next/clips/<highlight id>.json` (the format is in the docstring of
   `scripts/cmux-next/media/whats-new-clips.py`):
   - `caption`: one sentence of what you can now do.
   - `steps`: capture steps that set the scene, then the steps that perform the feature, marked
     `"clip": true`.
   - `crop`: the part of the window where it happens, as fractions.
   - Use made-up names, no real chats and no other products' names.
2. Record it: `CMUX_HQ=<cmuxterm-hq checkout> scripts/cmux-next/media/whats-new-clips.py record <id>
   --sha <commit>` (a commit that has the feature; the tip of feat-cmux-next). The fleet builds the app and a capture mini drives it, so nothing runs on your
   Mac. Read every frame of the WebP it writes. A clip that shows no change is refused.
3. Publish it: `whats-new-clips.py publish <id> <file>.webp`. This uploads it to pr-media (after
   the privacy check) and writes the highlight's `clip:` line, which the signed notes carry. A clip
   added within a week of its highlight comes again with the next nightly.

`whats-new-clips.py check` (CI) holds every spec and `clip:` line to that shape.

## Release title

A nightly's title is its first New entry's title, "and N more" when it has more. Order the
highlight files so that the best change comes first.

## Checks

`scripts/whats-new/validate.py` runs on every digest and is the release gate. It rejects internal
names, commit-style text, summaries that are not whole sentences, and text that is too long. A
highlight file that fails is left out of the nightly and reported. Stable and RC releases also need
every language and every picture.
