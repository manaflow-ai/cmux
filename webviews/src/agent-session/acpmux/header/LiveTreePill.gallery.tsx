// l10n-allow-file: gallery-only sample labels, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { LiveTreePill } from "./LiveTreePill";

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-header-live-tree" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]'));
  await ctx.waitFor(() => ctx.document.querySelector('[role="status"]')?.textContent !== "…");
  await ctx.click({ selector: '[role="dialog"] button' });
  await ctx.waitFor(() => ctx.document.querySelector('[role="status"]')?.textContent !== "…");
};

type Props = { cwd?: string; unavailable?: boolean; failed?: boolean };

function LiveTreeGallery({ cwd, unavailable, failed }: Props) {
  return (
    <div className="acpmux-shell" style={{ minHeight: 180 }}>
      <header className="acpmux-header">
        <div className="acpmux-header-status-slot">Agent session</div>
        <div className="acpmux-handoff-header-tools acpmux-header-tools">
          <LiveTreePill
            cwd={cwd}
            readStatus={async () => ({
              available: !unavailable,
              updated: 1000,
              lanes: [
                { name: "rust", verdict: failed ? "failed" : "passed" },
                { name: "webviews", verdict: "passed" },
                { name: "swift", verdict: "unknown" },
              ],
            })}
          />
        </div>
      </header>
      <main style={{ padding: "calc(var(--ds-space-4) + var(--ds-space-1))", color: "var(--agent-muted)" }}>
        The default pane is unchanged until Labs enables this marker.
      </main>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.live-tree-pill",
  title: "Live tree marker",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-header-live-tree" }],
  covers: ["agent-session/acpmux/header/LiveTreePill.tsx#LiveTreePill"],
  styles: () => Promise.all([import("../styles.css"), import("./header.css")]),
  load: async () => LiveTreeGallery,
  variants: {
    "local-path": {
      props: { cwd: "/work/livetree/tree" },
      play: open,
      note: "The first live-tree slice shows the shared path and Rust, Webviews and Swift lanes.",
    },
    "long-path": {
      props: { cwd: "/work/livetree/tree/a-very-long-project-name/feature/live-tree", failed: true },
      play: open,
      note: "Long working paths wrap inside the popover without changing the header geometry.",
    },
    "missing-path": {
      props: { unavailable: true },
      play: open,
      note: "A missing chat working path gets a readable fallback while the experiment remains visible.",
    },
  },
});
