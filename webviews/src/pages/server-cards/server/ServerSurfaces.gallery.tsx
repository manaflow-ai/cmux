// l10n-allow-file: gallery fixtures, not shipped UI.
// The Mac server's menu bar popover (design/server-cards.md): the panel, Health and the pairing
// code, each in its shipped layout and the layouts it was picked over, on canned servers.
import { componentEntry } from "../../../gallery/format";
import { status } from "./fixtures";
import type { HealthLayout, PairingLayout, PanelLayout } from "./ServerViews";
import type { ServerStatus } from "./types";

type Props = {
  status: ServerStatus;
  surface: "panel" | "health" | "pairing";
  layout?: PanelLayout | HealthLayout | PairingLayout;
};

const chief = { serverName: "build-01", state: "ready" as const, lastReply: Date.UTC(2026, 9, 2, 21, 18) };

export default componentEntry<Props>({
  id: "pages.server-cards-server-surfaces",
  title: "Server menu bar panel, Health and pairing",
  area: "Server cards",
  height: 560,
  widths: { narrow: 380, normal: 380, wide: 380 },
  covers: [
    "pages/server-cards/server/ServerViews.tsx",
    "pages/server-cards/server/ServerSurfaceHost.tsx",
    "pages/server-cards/server/icons.tsx",
  ],
  keywords: ["server", "menu bar", "health", "pairing", "qr", "devices", "revoke"],
  load: async () => {
    const [views, { createStrings }, table] = await Promise.all([
      import("./ServerViews"),
      import("../../shared/i18n"),
      import("../generated/strings.json"),
    ]);
    const strings = createStrings(table.default);
    const actions = { send: () => {}, openHealth: () => {} };
    return function GalleryServerSurface({ status, surface, layout }: Props) {
      return (
        <div className="sv-frame">
          {surface === "panel" && (
            <views.ServerPanel status={status} actions={actions} strings={strings} layout={layout as PanelLayout} />
          )}
          {surface === "health" && (
            <views.ServerHealth status={status} actions={actions} strings={strings} layout={layout as HealthLayout} />
          )}
          {surface === "pairing" && (
            <views.ServerPairing status={status} actions={actions} strings={strings} layout={layout as PairingLayout} />
          )}
        </div>
      );
    };
  },
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../../../ui/ui.css");
    await import("../styles.css");
    await import("./server.css");
  },
  variants: {
    "panel-compact": {
      props: { status: status("healthyMac", { chief }), surface: "panel" },
      note: "Shipped: one row per role with its count and Health's dot.",
    },
    "panel-dashboard": {
      props: { status: status("healthyMac", { chief }), surface: "panel", layout: "dashboard" },
      note: "Variant: a tile per role with a meter, and the pairing box.",
    },
    "panel-list": {
      props: { status: status("linuxHeadless"), surface: "panel", layout: "list" },
      note: "Variant: every app, open alert and device in one list.",
    },
    "panel-attention": {
      props: { status: status("batteryLowDisk"), surface: "panel" },
      note: "On battery with low disk: Health shows the worst open severity.",
    },
    "panel-unpaired": {
      props: { status: status("unpaired"), surface: "panel" },
      note: "Not paired: the pairing code shows on its row.",
    },
    "panel-off": {
      props: {
        status: status("healthyMac", { snapshot: { ...status("healthyMac").snapshot!, enabled: false } }),
        surface: "panel",
      },
      note: "The server is off.",
    },
    "panel-unavailable": {
      props: { status: status(null), surface: "panel" },
      note: "The app cannot reach its server.",
    },
    "panel-refused": {
      props: { status: status("healthyMac", { lastReject: "cmux could not stop the server." }), surface: "panel" },
      note: "The last change was refused.",
    },
    "health-checklist": {
      props: { status: status("batteryLowDisk"), surface: "health" },
      note: "Shipped: every check, failing first, each with its Fix.",
    },
    "health-summary": {
      props: { status: status("batteryLowDisk"), surface: "health", layout: "summary" },
      note: "Variant: only the open issues, each with its body.",
    },
    "health-timeline": {
      props: { status: status("batteryLowDisk"), surface: "health", layout: "timeline" },
      note: "Variant: raised and resolved alerts over time.",
    },
    "health-fixing": {
      props: {
        status: status("linuxHeadless", {
          pending: { switching: false, pairing: false, fixing: ["linger.off"], revoking: [] },
        }),
        surface: "health",
      },
      note: "A Fix in flight: its button waits.",
    },
    "pairing-code": {
      props: { status: status("unpaired"), surface: "pairing" },
      note: "Shipped: the code large, the QR and the four words beside it.",
    },
    "pairing-qr": {
      props: { status: status("unpaired"), surface: "pairing", layout: "qr" },
      note: "Variant: the QR first, for a phone.",
    },
    "pairing-words": {
      props: { status: status("unpaired"), surface: "pairing", layout: "words" },
      note: "Variant: the four words first.",
    },
    "pairing-paired": {
      props: { status: status("healthyMac"), surface: "pairing" },
      note: "Paired: the team and owner.",
    },
  },
});
