// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { ReleaseNotes } from "./types";
function fixture(count: number): BridgePageVariant {
  const notes: ReleaseNotes = {
    build: "100",
    shortVersion: "0.40.0",
    date: "2026-10-01",
    highlights: Array.from({ length: count }, (_, i) => ({
      id: `highlight-${i}`,
      title: `Workspace update ${i + 1}`,
      body: "Sample release notes describing improvements to workspace navigation and terminal sessions. ".repeat(
        count > 4 ? 12 : 1,
      ),
    })),
    changes: ["Improved keyboard navigation.", "Restored the selected workspace after reopening."],
  };
  return {
    replies: {
      "cmux.changelog.list": {
        current: count ? "100" : "",
        builds: Array.from({ length: count }, (_, i) => ({
          build: String(100 - i),
          shortVersion: `0.40.${i}`,
          date: "2026-10-01",
          highlights: count,
        })),
      },
      "cmux.changelog.get": notes,
    },
  };
}
export default bridgePageEntry({
  id: "pages.changelog",
  title: "Changelog",
  area: "Pages",
  page: "changelog",
  covers: ["page:cmux.changelog", "pages/changelog/ChangelogPage.tsx"],
  variants: {
    empty: fixture(0),
    loaded: fixture(4),
    "long-content": fixture(40),
    error: {
      ...fixture(0),
      failures: {
        "cmux.changelog.list": { code: "cmux.page.failed", message: "Sample owner is unavailable. Try again." },
      },
    },
    loading: { ...fixture(0), pending: ["cmux.changelog.list"] },
  },
});
