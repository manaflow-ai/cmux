// l10n-allow-file: gallery fixtures (public-safe release notes), not shipped UI.
import { changelogPageEntry } from "../../gallery/format";
import { sampleNotes } from "./mockProvider";

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
  changes: Array.from({ length: (index % 5) + 1 }, (_, change) => `sample change ${index + 1}.${change + 1}`),
}));

export default changelogPageEntry({
  id: "pages.changelog",
  title: "Changelog",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.changelog", "pages/changelog/ChangelogPage.tsx"],
  variants: {
    current: {
      note: "The current build with a highlight action and a full change list.",
      notes: sampleNotes,
    },
    "many-builds": {
      note: "Eighteen release builds for a long, scrolling history.",
      notes: manyNotes,
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
