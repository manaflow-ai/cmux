# Onboarding Import from Browsers: Express

Decided 2026-11-07 from a live picker prototype (emil-prototype run, four variants, real app icons,
nine browsers incl. a three-profile Chrome with a long profile name, Safari behind Full Disk Access,
Firefox behind a folder grant). Default picked by Chief for the user ("keep Express"); the user can
override with another variant name.

## Direction: Express (zero decisions by default)

- The body is one summary, centered: the checked browsers' real app icons (up to four, overlapping
  by 18 px, 56 pt), one sentence "Bring over your browsing from Google Chrome and Arc.", and the
  checked data kinds under it as one muted line ("Bookmarks · History · Open Tabs · Sign-ins").
- One primary action in the footer (Import), Skip beside it, Other Sources at the leading edge.
- Browsers that need a grant are asks in plain sight under the sentence: one row each, the app icon,
  "Safari needs Full Disk Access" and Open System Settings; "Firefox needs access to its folder"
  and Allow Access….
- The full list (profiles with their target menus, the kinds, Keep History in Sync) is one click
  away behind "Choose Browsers and Data…", and back with "Hide Details". Nothing in the list
  changed.
- Importing: the summary shows the browser and profile being read, a progress bar, and the counts
  so far. Finished: a success mark on the icon stack and the existing summary line.
- Detecting: three icon placeholders and "Looking for browsers…". None found: the existing line.

## Rejected

- **Current (grouped cards)**: one row per profile reads as a settings form; with nine browsers the
  list scrolls and the user disliked it on sight (Nov 7 screenshot).
- **Shelf (a toggle tile per browser)**: friendly with real icons, but profiles and data kinds sat
  in two lines under the grid that are easy to miss, and five tiles a line truncated
  "Google Chrome".
- **Stepper (one browser per screen)**: most control, but nine browsers means nine Import/Skip
  presses; slow for the common case of accepting defaults.
- The four earlier looks (plain, grouped, chips, tiles) and their gallery switch are deleted.
