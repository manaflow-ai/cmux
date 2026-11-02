// l10n-allow-file: synthetic gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";

export default componentEntry({
  id: "agent-pane.add-account",
  title: "Picker Add account",
  area: "Agent pane",
  height: 540,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: ["agent-session/acpmux/AddAccountDialog.tsx#AddAccountDialog"],
  load: async () => {
    const { AddAccountDialog } = await import("./AddAccountDialog");
    return ({ kind, unavailable }: { kind: "direct-subscription" | "direct-api-key"; unavailable?: boolean }) => (
      <AddAccountDialog
        kinds={[kind]}
        add={async () => {
          if (unavailable) throw new Error("The local agent service is unavailable.");
        }}
        onClose={() => undefined}
        onAdded={() => undefined}
      />
    );
  },
  styles: () => Promise.all([import("../../ui/ui.css"), import("../../ui/popupSurface.css")]),
  variants: {
    subscription: { props: { kind: "direct-subscription" } },
    "api-key": { props: { kind: "direct-api-key" } },
    unavailable: { props: { kind: "direct-subscription", unavailable: true } },
  },
});
