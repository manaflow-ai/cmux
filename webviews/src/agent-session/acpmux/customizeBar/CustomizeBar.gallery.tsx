// l10n-allow-file: synthetic gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { CustomizeBarLook, CustomizeBarOutcome } from "./CustomizeBar";
import type { CustomizeBarState } from "./customizeBarModel";

const preview: CustomizeBarState = {
  kind: "preview",
  wish: "a Dracula-like theme, denser sidebar, ⌘⇧D to split down",
  parts: ["settings", "keybindings", "themes"],
  files: 3,
  byHand: false,
  problems: [],
  canApply: true,
  generation: 4,
};
const problems: CustomizeBarState = {
  ...preview,
  canApply: false,
  problems: [{ path: "cmux-next.json", line: 12, message: "unknown key `sidebar.densty`" }],
};

export default componentEntry({
  id: "agent-pane.customize-bar",
  title: "Customize bar (live customization: Apply, Discard, Undo, Save)",
  area: "Agent pane",
  height: 260,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: ["agent-session/acpmux/customizeBar/CustomizeBar.tsx#CustomizeBar"],
  load: async () => {
    const { CustomizeBar } = await import("./CustomizeBar");
    return ({
      look,
      state = preview,
      outcome = { kind: "none" },
    }: {
      look: CustomizeBarLook;
      state?: CustomizeBarState;
      outcome?: CustomizeBarOutcome;
    }) => (
      <div style={{ display: "flex", flexDirection: "column", justifyContent: "flex-end", height: 240, padding: 8 }}>
        <CustomizeBar look={look} state={state} outcome={outcome} run={() => undefined} initiallyOpen />
      </div>
    );
  },
  styles: () => Promise.all([import("../../../ui/ui.css")]),
  variants: {
    "strip-preview": { props: { look: "strip" } },
    "strip-applied": { props: { look: "strip", state: { kind: "idle", generation: 5 }, outcome: { kind: "applied" } } },
    "card-preview": { props: { look: "card" } },
    "card-problems": { props: { look: "card", state: problems } },
    "card-saved": {
      props: { look: "card", state: { kind: "idle", generation: 5 }, outcome: { kind: "saved", name: "night-owl" } },
    },
    "chip-preview": { props: { look: "chip" } },
    "chip-failed": {
      props: { look: "chip", outcome: { kind: "failed", message: "Nothing earlier to roll back to." } },
    },
  },
});
