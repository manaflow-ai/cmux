// l10n-allow-file: gallery-only sample labels, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { FleetSagaPill } from "./FleetSagaPill";

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-header-live-tree" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]'));
  await ctx.waitFor(() => ctx.document.querySelector('[role="status"]')?.textContent !== "…");
  await ctx.click({ selector: '[role="dialog"] button' });
  await ctx.waitFor(() => ctx.document.querySelector('[role="status"]')?.textContent !== "…");
};

type Props = { unavailable?: boolean; sagas?: { id: string; status: string; step: string }[] };

function FleetSagaGallery({ unavailable, sagas = [] }: Props) {
  return (
    <div className="acpmux-shell" style={{ minHeight: 180 }}>
      <header className="acpmux-header">
        <div className="acpmux-header-status-slot">Agent session</div>
        <div className="acpmux-handoff-header-tools acpmux-header-tools">
          <FleetSagaPill readStatus={async () => ({ available: !unavailable, sagas })} />
        </div>
      </header>
      <main style={{ padding: "calc(var(--ds-space-4) + var(--ds-space-1))", color: "var(--agent-muted)" }}>
        The default pane is unchanged until Labs enables this marker.
      </main>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.fleet-saga-pill",
  title: "Fleet saga marker",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-header-live-tree" }],
  covers: ["agent-session/acpmux/header/FleetSagaPill.tsx#FleetSagaPill"],
  styles: () => Promise.all([import("../styles.css"), import("./header.css")]),
  load: async () => FleetSagaGallery,
  variants: {
    "open-operations": {
      props: {
        sagas: [
          { id: "deploy-api", status: "running", step: "install" },
          { id: "sync-docs", status: "paused", step: "verify" },
        ],
      },
      play: open,
      note: "Open local operations show only their id, status and current step.",
    },
    unavailable: {
      props: { unavailable: true },
      play: open,
      note: "A missing local saga directory leaves the read-only marker visible with a clear fallback.",
    },
    empty: {
      props: { sagas: [] },
      play: open,
      note: "A readable directory with no unfinished operations reports the empty state.",
    },
  },
});
