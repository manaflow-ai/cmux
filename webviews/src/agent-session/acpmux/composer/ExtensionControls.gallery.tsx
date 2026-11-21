// l10n-allow-file: gallery fixtures for manifest-supplied control labels.
import { useMemo, useState } from "react";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { componentEntry } from "../../../gallery/format";
import { ExtensionControls } from "./ExtensionControls";
import { extensionControlsFrom } from "./extensionControls";

type Props = { controls: unknown[] };

function ControlsExample({ controls }: Props) {
  const client = useMemo(() => new MockAppPanelsClient(), []);
  const listed = useMemo(() => extensionControlsFrom({ controls }), [controls]);
  const [inserted, setInserted] = useState("");
  return (
    <div className="acpmux-composer">
      <div className="acpmux-composer-bar acpmux-composer-inner">
        <ExtensionControls controls={listed} placement="left" client={client} onInsert={setInserted} />
        <span className="acpmux-composer-actions">
          <ExtensionControls controls={listed} placement="right" client={client} onInsert={setInserted} />
        </span>
      </div>
      <output>{inserted}</output>
    </div>
  );
}

const PLAN = {
  app: "local/footer",
  extension: "Footer",
  id: "plan",
  kind: "button",
  label: "Plan",
  tooltip: "Ask for a plan first",
  placement: "left",
  order: 0,
  insert: "Plan first: ",
};
const STAR = { ...PLAN, id: "star", label: "Favorite", symbol: "star", tooltip: "Favorite", insert: "★ " };
const GO = {
  app: "local/footer",
  extension: "Footer",
  id: "go",
  kind: "menu",
  label: "Go",
  placement: "right",
  order: 0,
  items: [
    { id: "window", label: "New window", description: "Open another window", action: "newWindow" },
    { id: "review", label: "Review", insert: "Review the diff." },
  ],
};

export default componentEntry<Props>({
  id: "agent-pane.composer-extension-controls",
  title: "Composer extension controls",
  area: "Agent pane",
  pane: true,
  height: 120,
  covers: ["agent-session/acpmux/composer/ExtensionControls.tsx"],
  load: async () => ControlsExample,
  styles: () => Promise.all([import("../styles.css"), import("../composerLocation.css")]),
  variants: {
    none: { props: { controls: [] } },
    button: {
      props: { controls: [PLAN] },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Plan" });
        await ctx.waitFor(() => ctx.document.querySelector("output")?.textContent === "Plan first: ");
      },
    },
    "symbol-and-menu": { props: { controls: [PLAN, STAR, GO] } },
  },
});
