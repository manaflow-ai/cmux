// l10n-allow-file: gallery fixtures (section titles, rows and paths), not shipped UI.
// The pinned summary's custom sections (PINNED-SUMMARY S1) through the same card: a section from the
// user's config, one from the chat's agent (its links ask before they open), and a failed provider.
// Drawn by SummaryStage until the host sends sections in the snapshot.
import { componentEntry } from "../../../gallery/format";
import { CWD } from "../../../gallery/fixtures/acpmux";
import type { SummaryCardProps } from "./PinnedSummaryCard";
import { work } from "./PinnedSummaryCard.gallery";

const sectionsBase: SummaryCardProps = { rows: work, project: "atlas-web", folder: CWD };

export default componentEntry<SummaryCardProps>({
  id: "agent-pane.pinned-summary-sections",
  title: "Pinned summary: custom sections",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 560, normal: 1100, wide: 1280 },
  pane: true,
  covers: ["agent-session/acpmux/summary/CustomSection.tsx#CustomSection"],
  load: () => import("./SummaryStage").then((module) => module.SummaryStage),
  variants: {
    "user-section": {
      note: "A section from the user's config: CI runs as links, a deploy with a badge, a log file in the chat folder.",
      props: {
        ...sectionsBase,
        sections: [
          {
            id: "ci",
            title: "CI",
            source: "user",
            rows: [
              { title: "test (linux)", state: "ok", href: "https://ci.example.test/runs/41" },
              { title: "test (macos)", state: "running", href: "https://ci.example.test/runs/42" },
              { title: "lint", state: "error", subtitle: "2 errors", href: "https://ci.example.test/runs/43" },
              { title: "staging deploy", badge: "v1.42", state: "warn" },
              { title: "build log", href: `${CWD}/build.log` },
            ],
          },
        ],
      },
    },
    "agent-section": {
      note: "A section the chat's agent wrote: its link asks before it opens (click a row); its path opens directly.",
      props: {
        ...sectionsBase,
        sections: [
          {
            id: "agent-checks",
            title: "Checks",
            source: "agent",
            rows: [
              { title: "Benchmarks", subtitle: "p50 8.2 ms", href: "https://bench.example.test/run/9" },
              { title: "<b>HTML stays text</b>" },
              { title: "Report", href: `${CWD}/bench/report.md` },
            ],
          },
        ],
      },
      play: async (ctx) => {
        await ctx.click({ selector: '[data-summary-url="https://bench.example.test/run/9"]' });
        await ctx.waitFor(() => ctx.document.querySelector("[data-summary-confirm]"));
      },
    },
    "failed-provider": {
      note: "A provider that failed shows one row with its reason; the rest of the card is unaffected.",
      props: {
        ...sectionsBase,
        sections: [{ id: "deploys", title: "Deploys", source: "user", error: "command exited 2: not logged in" }],
      },
    },
  },
});
