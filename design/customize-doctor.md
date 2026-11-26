# Customize doctor

Leo, 2026-11-19: "cmux for themes customizations and whatnot if there's errant files etc that affect
customizations it should be able to automatically tell the user and inform them". Later: "as in like
random json that is affecthing things outside of typically expected settings too", "make sure you can
recover and stuff. for all customizations", and on pane dividers he could not see: "i thought we turned
those on by default and htat i was following them by default? where's it all at?"

`cmux customize doctor` (cmux-customize `library/doctor.rs`) finds everything: layers still on, a web-dev
overlay, files that do not load, skipped files and keys, overridden values, leftovers, unknown keys,
wrong folders, layers pinning code the app has, files outside the usual settings that still change cmux
(`override`). It words each finding and its fixes and plans one way back (`recover`). Swift and web
only show the report. Your own values are not findings (Leo, 2026-11-25, on "You are not following the
default for sidebar.priorityView.shown and 49 more": "what is this and why is it so ugly"), and only
warnings, which break something now, are problems: the count, the line and the toast are the warnings;
info findings (an unknown key, a stray file) are listed under them, never counted or toasted.

## Start and end states

The start state is the ordinary app: no card, no notice. When the report has a warning that is not
dismissed, Personalization draws **Customization Problems** above the Customization Library, and one
quiet line says so. The end state is the start state: when the last warning is fixed or dismissed, the
card and the line leave together in one frame. Nothing changes on its own: every fix and Recover… run
only on a click. Remove, Restore and Recover ask first,
inline, Cancel focused, and say what is kept. A dismissed finding stays, muted, until it changes.

## The notice: two treatments

Web gallery `pages.settings-customize-doctor`, variants `treatment-banner` and `treatment-inline`.
Choosing one is one line (`customizeDoctor.ts` `treatment`).

- **inline** (shipped): the count and the line in the card's own header, nothing else. Quiet and never
  in the way; outside Settings the native toast on launch (`customize.doctorNotice`, default on) is
  what tells the person.
- **banner**: ui/Notice's warning banner with Review (and Recover…) across the top of the Settings
  column. Nobody misses it, but a warning stays until resolved, so a finding the person chose to leave
  (an `info` leftover) pushes every Settings page down until they dismiss it, and it competes with the
  read-only and try-on bars that sit in the same place.

A third, **chip** (a dot and the line at the bottom of the Settings sidebar, shipped first in #50458),
was removed on 2026-11-23: Lawrence, on "29 things change your customization: aws-…" under the
categories, "remove this thing". The sidebar holds only the search field and the categories.

## The card

One row per finding: a 6 px dot (attention for `warning`, faint for `info`; never a red slab), the
title, the detail, the place, the fixes in the CLI's order as ghost buttons, and Dismiss. Warnings
first, then info, dismissed last. Recover… is a subtle button on the help row while `recover` is not
null; its question shows the CLI's `said`, as does the answer line under the list; a refusal shows
the CLI's own words ("Not changed: …"). No animation of its own; held buttons change only their fill.

## Page op

`cmux.settings.customize.library` `{verb, id?, fix?}`: `doctor`, `doctor-fix` {id, fix: off, remove,
restore}, `doctor-dismiss` {id}, `doctor-open` {id} (the host opens the path),
`doctor-recover`; all but `doctor` need a gesture. Link: `?focus=card.customizeDoctor` (`.recover`).
