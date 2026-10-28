// l10n-allow-file: gallery fixtures (public-safe release notes), not shipped UI.
import { changelogPageEntry } from "../../gallery/format";
import { sampleNotes } from "./mockProvider";
import { realNightlies } from "./realNightlyFixtures";
import nightly3913596493801 from "./fixtures/nightly-3913596493801-span.json";
import realChanges from "./fixtures/real-pr-changes.json";
import type { ReleaseNotes } from "./types";
import { clipNotes, clipRoute } from "./clipFixtures";
import { journalNotes } from "./whatsNewFixtures";

/** Where build `index` of the 18 starts in realChanges: each takes (index % 5) + 1, none shared. */
const start = (index: number) => Array.from({ length: index }, (_, i) => (i % 5) + 1).reduce((a, b) => a + b, 0);

const manyNotes = Array.from({ length: 18 }, (_, index) => ({
  build: `37203579${String(6000 + index)}`,
  shortVersion: `1.0.${index + 1}-nightly`,
  date: `2026-09-${String(18 + (index % 12)).padStart(2, "0")}`,
  highlights:
    index % 3 === 0
      ? [
          {
            id: `highlight-${index}`,
            title: `A useful update ${index + 1}`,
            body: "A public-safe release note with enough text to exercise the notes column.",
          },
        ]
      : [],
  // Real landed pull requests, so each change shows its linked title and number.
  items: realChanges.slice(start(index), start(index) + (index % 5) + 1),
  changes: realChanges.slice(start(index), start(index) + (index % 5) + 1).map((c) => `${c.title} (#${c.pr})`),
}));

/** A real published reel (scripts/cmux-next/media/reel.py), so the gallery shows the card as it plays. */
const nightlyReel = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/3969193688601/reel.mp4";

export default changelogPageEntry({
  id: "pages.changelog",
  title: "Changelog",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: [
    "page:cmux.changelog",
    "pages/changelog/ChangelogPage.tsx",
    "pages/changelog/JournalPage.tsx",
    "pages/changelog/RailPage.tsx",
    "pages/changelog/DigestPage.tsx",
    "pages/changelog/ReleaseParts.tsx",
    "pages/changelog/SpanNews.tsx",
    "pages/changelog/clipFixtures.ts",
  ],
  variants: {
    "nightly-3913596493801": {
      note: "The update from 1.0.0-nightly.3911762409401 to 3913596493801 (2026-10-18): the ten signed notes of that span as published, perf-split commits, cut titles and bead ids included.",
      notes: nightly3913596493801 as ReleaseNotes[],
      route: "#/?from=1.0.0-nightly.3911762409401&to=1.0.0-nightly.3913596493801",
    },
    "nightly-update": {
      note: "Real nightly-next notes: opened after the update from 1.0.0-nightly.3797234815201 to 3832783556401. Highlights of the span first, then one section per day.",
      notes: realNightlies,
      route: "#/?from=1.0.0-nightly.3797234815201&to=1.0.0-nightly.3832783556401",
    },
    "nightly-unpublished": {
      note: "An update to a build whose notes were never published: Maintenance and fixes plus the offline line, then the days.",
      notes: realNightlies.slice(1),
      route: "#/?from=1.0.0-nightly.3797234815201&to=1.0.0-nightly.3821558930001",
    },
    "nightly-history": {
      note: "Opened from the Help menu (no update span): one section per day.",
      notes: realNightlies,
    },
    ledger: {
      note: "Ledger (default, u5099): conductor.build/changelog's layout. Each day's newest version as a small mono tag and its date sticky in the left margin; New / Improved / Fixed as headings over bullet lists.",
      notes: journalNotes,
    },
    "clips-alternate": {
      note: "What's New after an update, each change with its clip (Leo 2026-10-24: \"it's like you're not even showing anything properly off\"). Alternate: the clip beside its words, sides taking turns. Clips recorded on the fleet by whats-new-clips.py, at their own size.",
      notes: clipNotes,
      route: `#/?news=alternate&${clipRoute}`,
    },
    "clips-stack": {
      note: "The same update, Stack: one change after another, the clip on top and its caption under it.",
      notes: clipNotes,
      route: `#/?news=stack&${clipRoute}`,
    },
    "clips-grid": {
      note: "The same update, Grid (default): two-up glass cards, the clip on top.",
      notes: clipNotes,
      route: `#/?${clipRoute}`,
    },
    "clips-lead": {
      note: "The same update in the lead row the clips replaced (before): up to three changes side by side, each clip boxed to 16:10 and cut.",
      notes: clipNotes,
      route: `#/?news=lead&${clipRoute}`,
    },
    "ledger-update-span": {
      note: "Ledger opened by See What's New after an update from 1.0.0-nightly.410 to 413: Since your last update first, then the days with their margin tags.",
      notes: journalNotes,
      route: "#/?from=1.0.0-nightly.410&to=1.0.0-nightly.413",
    },
    "ledger-update-reel": {
      note: "The same update with a nightly reel: one video card (its first frame, a play button, its length and title) that plays in place. The reel is nightly 3969193's, as published.",
      notes: journalNotes.map((n, i) => (i === 0 ? { ...n, reel: nightlyReel } : n)),
      route: "#/?from=1.0.0-nightly.410&to=1.0.0-nightly.413",
    },
    journal: {
      note: "Design A (Debug Settings whatsNew.design = journal): four nightlies stacked; the lead change with light/dark media, grouped rows, folded commits.",
      notes: journalNotes,
      route: "#/?design=journal",
    },
    "journal-update-span": {
      note: "Design A opened by See What's New after an update from 1.0.0-nightly.410 to 413: those releases come first under Since your last update.",
      notes: journalNotes,
      route: "#/?design=journal&from=1.0.0-nightly.410&to=1.0.0-nightly.413",
    },
    rail: {
      note: "Design B (Debug Settings whatsNew.design = rail) on the same update span.",
      notes: journalNotes,
      route: "#/?design=rail&from=1.0.0-nightly.410&to=1.0.0-nightly.413",
    },
    digest: {
      note: "Design C (Debug Settings whatsNew.design = digest) on the same update span.",
      notes: journalNotes,
      route: "#/?design=digest&from=1.0.0-nightly.410&to=1.0.0-nightly.413",
    },
    current: {
      note: "The current build with a highlight action and a full change list.",
      notes: sampleNotes,
    },
    "many-builds": {
      note: "Eighteen release builds for a long, scrolling history.",
      notes: manyNotes,
    },
    "update-span": {
      note: "Opened after an update from 1.0.3 to 1.0.7: those four releases are marked, the newest is shown.",
      notes: manyNotes,
      route: "#/?from=1.0.3-nightly&to=1.0.7-nightly",
    },
    "updated-no-notes": {
      note: "Opened after an update whose versions have no notes: the page says which version it is now.",
      notes: manyNotes,
      route: "#/?from=1.0.18-nightly&to=1.0.19-nightly",
    },
    empty: {
      note: "No verified release notes yet.",
      notes: [],
    },
    missing: {
      note: "The selected build has no verified notes on this machine.",
      current: "unknown-build",
      notes: sampleNotes,
    },
    error: {
      note: "The signed changelog index cannot be reached.",
      mode: "error",
      error: { code: "cmux.protocol.transport", message: "Release notes are offline." },
      notes: sampleNotes,
    },
    loading: {
      note: "The signed release index is still loading.",
      mode: "loading",
      notes: sampleNotes,
    },
  },
});
