// l10n-allow-file: gallery fixtures, not shipped UI.
// App health (design/app-health.md): the indicator in three treatments (where it sits in the sidebar
// footer row and why it moves nothing there: AppHealthFooterRow.gallery.tsx), each in the same seven
// states, with the popover it opens drawn under it. A: the sidebar footer's dot and line (shipped);
// B: the titlebar's trailing dot, its line a tooltip; C: an inline pill with the worst part's
// Repair. Healthy renders nothing in every treatment.
import { componentEntry } from "../gallery/format";
import type { ComponentVariant } from "../gallery/format";
import type { AppHealthTreatment } from "./AppHealth";
import type { HealthPart, HealthReceipt, HealthSnapshot } from "./types";

type Props = { snapshot: HealthSnapshot; treatment: AppHealthTreatment };

type PartFields = Partial<HealthPart> & Pick<HealthPart, "id" | "kind" | "label" | "state" | "detail">;

function part(fields: PartFields): HealthPart {
  return { sinceMs: 1_000, action: "none", attempt: 0, maxAttempts: 3, nextAtMs: null, canRepair: false, ...fields };
}

function receipt(
  atMs: number,
  id: string,
  action: HealthReceipt["action"],
  outcome: HealthReceipt["outcome"],
  detail: string,
): HealthReceipt {
  return { atMs, id, action, outcome, detail };
}

const again = "Restarted the web renderer; it stopped answering again.";

const STATES: Record<string, { note: string; snapshot: HealthSnapshot }> = {
  "page-repairing": {
    note: "A page stopped answering; the app reloads it and keeps the draft.",
    snapshot: {
      worst: "repairing",
      parts: [
        part({
          id: "page:42",
          kind: "page",
          label: "Agent chat",
          state: "repairing",
          detail: "Not answering for 12 s. Reloading it (attempt 1 of 3); your draft is kept.",
          action: "reloadPage",
          attempt: 1,
          nextAtMs: 5_678,
          canRepair: true,
        }),
      ],
      receipts: [],
    },
  },
  "renderer-failed": {
    note: "Repairs ran out: the person's one Repair now.",
    snapshot: {
      worst: "failed",
      parts: [
        part({
          id: "renderer:4121",
          kind: "renderer",
          label: "Web renderer",
          state: "failed",
          detail: "Restarted 3 times in 10 minutes and still not answering. Repair restarts it once more.",
          action: "restartRenderer",
          attempt: 3,
          canRepair: true,
        }),
        part({
          id: "page:42",
          kind: "page",
          label: "Agent chat",
          state: "stuck",
          sinceMs: 2_000,
          detail: "Not answering since its renderer stopped.",
          action: "reloadPage",
          canRepair: true,
        }),
      ],
      receipts: [
        receipt(9_000, "renderer:4121", "restartRenderer", "gaveUp", again),
        receipt(6_000, "renderer:4121", "restartRenderer", "failed", again),
        receipt(3_000, "page:42", "reloadPage", "ok", "Reloaded Agent chat; the draft was kept."),
      ],
    },
  },
  "daemon-loop-held": {
    note: "The launcher keeps the restoring owner instead of replacing it; no button.",
    snapshot: {
      worst: "stuck",
      parts: [
        part({
          id: "sessionDaemon",
          kind: "sessionDaemon",
          label: "Sessions",
          state: "stuck",
          detail:
            "Restarting in a loop: started 3 times in 10 minutes and never got ready. Keeping the current one running so it can finish.",
          action: "holdReplace",
          attempt: 1,
        }),
      ],
      receipts: [receipt(4_000, "sessionDaemon", "holdReplace", "ok", "Stopped replacing Sessions while it restores.")],
    },
  },
  "restoring-slow": {
    note: "Slow, still making progress: never repaired by force. The indicator shows nothing for a slow part (ui.app-health.footer-row); the popover lists it.",
    snapshot: {
      worst: "slow",
      parts: [
        part({
          id: "sessionDaemon",
          kind: "sessionDaemon",
          label: "Sessions",
          state: "slow",
          detail: "Restoring workspaces, 12.4 GB read.",
        }),
      ],
      receipts: [],
    },
  },
  "oversize-data": {
    note: "Workspace data past 8 GB: a warning in the popover, no button; the indicator shows nothing for it.",
    snapshot: {
      worst: "slow",
      parts: [
        part({
          id: "sessionDaemon",
          kind: "sessionDaemon",
          label: "Sessions",
          state: "slow",
          detail: "Workspace data is 59 GB; startup will be slow.",
        }),
      ],
      receipts: [],
    },
  },
  "pending-close": {
    note: "Every part healthy, a tab close queued until the link is back: it never applies and reverts.",
    snapshot: {
      worst: "healthy",
      parts: [],
      receipts: [],
      pending: [
        { id: "intent-7", label: "close Background task", sinceMs: 7_000 },
        { id: "intent-6", label: "select Build logs", sinceMs: 6_500 },
      ],
      pendingMore: 0,
    },
  },
  healthy: {
    note: "Healthy, nothing queued: nothing renders.",
    snapshot: {
      worst: "healthy",
      parts: [],
      receipts: [receipt(3_000, "page:42", "reloadPage", "ok", "Reloaded Agent chat; the draft was kept.")],
    },
  },
};

const TREATMENTS: Record<AppHealthTreatment, string> = {
  footer: "A, shipped: the sidebar footer's dot and line.",
  titlebar: "B: the titlebar's trailing dot; the line is its tooltip.",
  pill: "C: an inline pill with the worst part's Repair.",
};

const variants: Record<string, ComponentVariant<Props>> = {};
for (const [treatment, lead] of Object.entries(TREATMENTS) as [AppHealthTreatment, string][])
  for (const [state, { note, snapshot }] of Object.entries(STATES))
    variants[`${treatment}-${state}`] = { props: { snapshot, treatment }, note: `${lead} ${note}` };

export default componentEntry<Props>({
  id: "ui.app-health",
  title: "App health indicator and popover",
  area: "Pages",
  height: 520,
  widths: { narrow: 300, normal: 380, wide: 560 },
  covers: ["app-health/AppHealth.tsx", "app-health/AppHealthHost.tsx#AppHealthHost", "app-health/model.ts"],
  keywords: ["health", "stuck", "repair", "daemon", "renderer", "restore", "reconnecting", "status"],
  load: async () => {
    const [views, { createStrings }, table] = await Promise.all([
      import("./AppHealth"),
      import("../pages/shared/i18n"),
      import("../pages/server-cards/generated/strings.json"),
    ]);
    const strings = createStrings(table.default);
    const actions = { open: () => {}, repair: () => {} };
    return function GalleryAppHealth({ snapshot, treatment }: Props) {
      return (
        <div className="ah-gallery" data-treatment={treatment}>
          <div className="ah-gallery-slot" data-slot={treatment}>
            {treatment === "titlebar" && <span className="ah-gallery-title">cmux</span>}
            <views.AppHealthIndicator snapshot={snapshot} strings={strings} actions={actions} treatment={treatment} />
          </div>
          <div className="ah-gallery-popover">
            <views.AppHealthPopover snapshot={snapshot} strings={strings} repair={actions.repair} />
          </div>
        </div>
      );
    };
  },
  styles: async () => {
    await import("../pages/shared/pageBase.css");
    await import("../ui/ui.css");
    await import("./appHealth.css");
    await import("./AppHealth.gallery.css");
  },
  variants,
});
