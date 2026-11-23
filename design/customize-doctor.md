# Customize doctor

Leo, 2026-11-19: "cmux for themes customizations and whatnot if there's errant files etc that affect
customizations it should be able to automatically tell the user and inform them". Later: "as in like
random json that is affecthing things outside of typically expected settings too", "make sure you can
recover and stuff. for all customizations", and on pane dividers he could not see: "i thought we turned
those on by default and htat i was following them by default? where's it all at?"

`cmux customize doctor` (cmux-customize `library/doctor.rs`) finds everything: layers still on, a web-dev
overlay, files that do not load, skipped files and keys, overridden values, leftovers, unknown keys,
wrong folders, layers pinning code the app has, files outside the usual settings that still change cmux
(`override`), and settings that hide something the default shows (`not-default`: Leo's
`appearance.surfaces.splitDivider.opacity` = 0, "Follow default"). It words each finding and its fixes
and plans one way back (`recover`). Swift and web only show the report.

## Start and end states

The start state is the ordinary app: no card, no notice. When the report has a finding that is not
dismissed, Personalization draws **Customization Problems** above the Customization Library, and one
quiet line says so. The end state is the start state: when the last finding is fixed or dismissed, the
card and the line leave together in one frame. Nothing changes on its own: every fix and Recover… run
only on a click (Follow default keeps a copy of the settings file). Remove, Restore and Recover ask first,
inline, Cancel focused, and say what is kept. A dismissed finding stays, muted, until it changes.

## The notice: three treatments

Web gallery `pages.settings-customize-doctor`, variants `treatment-chip`, `treatment-banner` and
`treatment-inline`. Choosing one is one line (`customizeDoctor.ts` `treatment`).

- **chip** (shipped): a dot and the CLI's line at the bottom of the Settings sidebar, with Recover… beside
  it while there is a way back; a click opens the card. It is the app-health footer's pattern: the words
  show without a hover, at the edge where status already lives, on every Settings page, and it moves no
  content (only the section list above it gets one line shorter and scrolls). Its cost: it is small, and
  a person reading the column may not look at the sidebar's foot.
- **banner**: ui/Notice's warning banner with Review (and Recover…) across the top of the Settings
  column. Nobody misses it, but a warning stays until resolved, so a finding the person chose to leave
  (an `info` leftover) pushes every Settings page down until they dismiss it, and it competes with the
  read-only and try-on bars that sit in the same place.
- **inline**: the count and the line in the card's own header, nothing else. Quietest, and never in the
  way, but it only shows once the person is already on Personalization, so it does not "tell the user":
  it is the B-treatment problem from design/app-health.md (you must go there to see the words).

**Recommended: chip.** It is the only treatment that tells the person on every Settings page without
taking room from the page's content, it reuses a pattern already chosen for the same job (a small mark
and words that open into labelled detail), and the native toast on launch covers the "automatically"
half outside Settings (`customize.doctorNotice`, default on).

## The card

One row per finding: a 6 px dot (attention for `warning`, faint for `info`; never a red slab), the
title, the detail, the place, the fixes in the CLI's order as ghost buttons, and Dismiss. Warnings
first, then info, dismissed last. Recover… is a subtle button on the help row while `recover` is not
null; its question shows the CLI's `said`, as does the answer line under the list; a refusal shows
the CLI's own words ("Not changed: …"). No animation of its own; held buttons change only their fill.

## Page op

`cmux.settings.customize.library` `{verb, id?, fix?}`: `doctor`, `doctor-fix` {id, fix: off, remove,
restore, follow-default}, `doctor-dismiss` {id}, `doctor-open` {id} (the host opens the path),
`doctor-recover`; all but `doctor` need a gesture. Link: `?focus=card.customizeDoctor` (`.recover`).
