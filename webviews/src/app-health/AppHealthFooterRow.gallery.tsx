// l10n-allow-file: gallery fixtures, not shipped UI.
// App health at the sidebar's bottom-left, in the footer row it shares with the profile avatar, the spaces
// strip, the update button and Search (design/app-health.md). Leo, 2026-11-11: "the agent pane: slow
// indicator on the bottom left is uselsss and layout shifts the space. it's bad".
//
// Each variant draws the row twice, at rest and with the indicator showing, so a move is visible at a
// glance: `before` is how it shipped (the line sat in the row after the avatar and pushed the strip and the
// update button along); `overlay` (shipped now) floats the line on its own chip above the row; `badge` is a
// dot on the avatar's corner, its line the tooltip; `hidden` shows nothing (the popover still opens from
// the "Restoring sessions…" card's Details). In every variant but `before`, the row's boxes are identical in
// both copies. The states are the same five in each: a page that is only slow (the case Leo saw: nothing
// shows now), one not responding, one the app is repairing, one whose repairs ran out, and a queued action.
import { componentEntry } from "../gallery/format";
import type { ComponentVariant } from "../gallery/format";
import type { HealthPart, HealthSnapshot } from "./types";

type Placement = "before" | "overlay" | "badge" | "hidden";
type Props = { snapshot: HealthSnapshot; placement: Placement };

function part(state: HealthPart["state"], detail: string, action: HealthPart["action"] = "none"): HealthPart {
  return {
    id: "page:42",
    kind: "page",
    label: "Agent chat",
    state,
    sinceMs: 1_000,
    detail,
    action,
    attempt: state === "failed" ? 3 : state === "repairing" ? 1 : 0,
    maxAttempts: 3,
    nextAtMs: null,
    canRepair: state !== "slow",
  };
}

const STATES: Record<string, { note: string; snapshot: HealthSnapshot }> = {
  "1-slow": {
    note: "The page is late on its heartbeat (a busy Mac): it still answers, so the line says nothing now. `before` shows what Leo saw.",
    snapshot: { worst: "slow", parts: [part("slow", "Not answering for 6 s.")], receipts: [] },
  },
  "2-not-responding": {
    note: "Stuck for 10 s: names the part; the click opens Repair now.",
    snapshot: { worst: "stuck", parts: [part("stuck", "Not answering for 12 s.", "reloadPage")], receipts: [] },
  },
  "3-repairing": {
    note: "The app reloads it on its own, keeping the draft.",
    snapshot: {
      worst: "repairing",
      parts: [
        part("repairing", "Not answering for 12 s. Reloading it (attempt 1 of 3); your draft is kept.", "reloadPage"),
      ],
      receipts: [],
    },
  },
  "4-needs-repair": {
    note: "Its repairs ran out: the person's one Repair now.",
    snapshot: {
      worst: "failed",
      parts: [part("failed", "Reloaded 3 times in 10 minutes and still not answering.", "reloadPage")],
      receipts: [],
    },
  },
  "5-queued-close": {
    note: "Every part healthy, a tab close queued until the link is back.",
    snapshot: {
      worst: "healthy",
      parts: [],
      receipts: [],
      pending: [{ id: "intent-7", label: "close Background task", sinceMs: 7_000 }],
    },
  },
};

const PLACEMENTS: Record<Placement, string> = {
  before: "Before (#39112): the line in the row after the avatar; the strip and the update button move.",
  overlay: "Shipped: the line on its own chip above the row; the row never moves.",
  badge: "A dot on the avatar's corner, the line its tooltip; the row never moves.",
  hidden: "Hidden entirely; the popover opens from the Restoring sessions card's Details.",
};

const variants: Record<string, ComponentVariant<Props>> = {};
for (const [placement, lead] of Object.entries(PLACEMENTS) as [Placement, string][])
  for (const [state, { note, snapshot }] of Object.entries(STATES))
    variants[`${placement}-${state}`] = { props: { snapshot, placement }, note: `${lead} ${note}` };

export default componentEntry<Props>({
  id: "ui.app-health.footer-row",
  title: "App health at the sidebar's bottom-left",
  area: "Pages",
  height: 220,
  widths: { narrow: 240, normal: 260, wide: 320 },
  covers: ["app-health/model.ts#indicatorHeadline", "app-health/AppHealth.tsx#AppHealthIndicator"],
  keywords: ["health", "slow", "stuck", "footer", "sidebar", "layout shift", "spaces", "status"],
  load: async () => {
    const [{ AppHealthDot }, { indicatorHeadline }, { createStrings }, table] = await Promise.all([
      import("./AppHealth"),
      import("./model"),
      import("../pages/shared/i18n"),
      import("../pages/server-cards/generated/strings.json"),
    ]);
    const strings = createStrings(table.default);
    // The row as the native footer lays it out (SidebarFooterBand): the avatar at the leading inset, the
    // spaces strip centered on the sidebar, the update button and Search at the trailing end.
    function Row({ line }: { line?: { text: string; tone: "danger" | "attention" | "muted" } | null }) {
      return (
        <div className="ahf-row">
          <span className="ahf-avatar">L</span>
          {line && (
            <span className="ahf-inline" data-tone={line.tone}>
              <AppHealthDot tone={line.tone} />
              <span className="ahf-text">{line.text}</span>
            </span>
          )}
          <span className="ahf-strip" data-pushed={line ? "true" : undefined}>
            <span className="ahf-space" data-active="true" />
            <span className="ahf-space" />
            <span className="ahf-plus">+</span>
          </span>
          <span className="ahf-button ahf-update" />
          <span className="ahf-button ahf-search" />
        </div>
      );
    }
    function Sidebar({ snapshot, placement, showing }: Props & { showing: boolean }) {
      // `before` drew the old words ("Agent pane: Slow") for every non-healthy part, slow included.
      const old = snapshot.parts[0]
        ? {
            text: strings.format(
              "appHealth.line",
              "Agent pane",
              strings.t(`appHealth.state.${snapshot.parts[0].state}`),
            ),
            tone: (snapshot.parts[0].state === "failed" || snapshot.parts[0].state === "stuck"
              ? "danger"
              : "attention") as "danger" | "attention",
          }
        : snapshot.pending?.[0]
          ? { text: strings.format("appHealth.pending", snapshot.pending[0].label), tone: "muted" as const }
          : null;
      const head = indicatorHeadline(snapshot, strings);
      return (
        <div className="ahf-sidebar">
          <div className="ahf-list">
            <span className="ahf-list-row">workspace-404</span>
            <span className="ahf-list-row">claude-sr2-coord</span>
            <span className="ahf-list-row">chat-export-anywhere</span>
          </div>
          {showing && placement === "overlay" && head && (
            <span className="ahf-overlay" data-tone={head.tone}>
              <AppHealthDot tone={head.tone} />
              <span className="ahf-text">{head.text}</span>
            </span>
          )}
          <Row line={showing && placement === "before" ? old : null} />
          {showing && placement === "badge" && head && (
            /* tooltip-allow: the badge has no text; the tooltip is its one line */
            <span className="ahf-badge" title={head.text}>
              <AppHealthDot tone={head.tone} />
            </span>
          )}
        </div>
      );
    }
    return function GalleryFooterRow(props: Props) {
      return (
        <div className="ahf-gallery" data-placement={props.placement}>
          <span className="ahf-caption">At rest</span>
          <Sidebar {...props} showing={false} />
          <span className="ahf-caption">With the indicator</span>
          <Sidebar {...props} showing />
        </div>
      );
    };
  },
  styles: async () => {
    await import("../pages/shared/pageBase.css");
    await import("../ui/ui.css");
    await import("./appHealth.css");
    await import("./AppHealthFooterRow.gallery.css");
  },
  variants,
});
