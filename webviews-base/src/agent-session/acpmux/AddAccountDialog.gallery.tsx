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
    return ({
      family = "claude",
      kinds = ["direct-subscription", "direct-api-key"],
      unavailable,
    }: {
      family?: string;
      kinds?: ("direct-subscription" | "direct-api-key")[];
      unavailable?: boolean;
    }) => (
      <AddAccountDialog
        family={family}
        kinds={kinds}
        existing={["coderouter", "chatgpt-2"]}
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
    subscription: { props: { family: "claude" } },
    codex: { props: { family: "codex" } },
    "api-key": { props: { kinds: ["direct-api-key"] } },
    "other-family": { props: { family: "gemini", kinds: ["direct-subscription"] } },
    unavailable: { props: { family: "codex", unavailable: true } },
  },
});
