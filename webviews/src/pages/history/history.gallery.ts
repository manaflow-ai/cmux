// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { HistoryEntry } from "./types";
import { minutesAgo } from "../../gallery/clock";
function fixture(count: number): BridgePageVariant {
  const kinds = ["page", "location", "closed", "command", "agent"] as const;
  const entries: HistoryEntry[] = Array.from({ length: count }, (_, i) => ({
    id: `page:gallery:${i}`,
    kind: kinds[i % kinds.length]!,
    at_ms: minutesAgo(i * 10 + 1),
    title:
      count > 4
        ? `Workspace ${i + 1}: investigation of a long-running integration and release verification`
        : ["Documentation", "Project directory", "Closed workspace", "Run checks"][i]!,
    detail: `/home/sample/projects/gallery/${"nested/".repeat(count > 4 ? 8 : 1)}module-${i}`,
    available: i % 6 !== 5,
    machine: "Sample workstation",
    command: "bun run check",
    exit_code: 0,
    url: "https://example.org/docs",
    closed_kind: "workspace",
    session_id: `sample-${i}`,
  }));
  return { streams: ["cmux.history.changed"], replies: { "cmux.history.entries.list": { entries, revision: 1 } } };
}
export default bridgePageEntry({
  id: "pages.history",
  title: "History",
  area: "Pages",
  page: "history",
  covers: ["page:cmux.history", "pages/history/HistoryPage.tsx", "pages/history/KindIcon.tsx"],
  variants: {
    empty: fixture(0),
    loaded: fixture(4),
    "long-content": fixture(40),
    error: {
      ...fixture(0),
      failures: {
        "cmux.history.entries.list": { code: "cmux.page.failed", message: "Sample owner is unavailable. Try again." },
      },
    },
    loading: { ...fixture(0), pending: ["cmux.history.entries.list"] },
  },
});
