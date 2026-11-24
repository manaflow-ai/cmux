// l10n-allow-file: gallery fixtures for manifest-supplied button labels.
import { useMemo, useState } from "react";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { componentEntry } from "../../../gallery/format";
import { ComposerPlusMenu } from "../ComposerPlusMenu";
import { composerPlusRegistry } from "../composerPlusRegistry";
import type { ToolbarButton } from "./toolbarButtons";

type Props = { buttons: ToolbarButton[] };

function ToolbarExample({ buttons }: Props) {
  const client = useMemo(() => {
    const mock = new MockAppPanelsClient();
    mock.toolbarButtons = buttons;
    return mock;
  }, [buttons]);
  const [action, setAction] = useState("");
  return (
    <div className="acpmux-composer">
      <ComposerPlusMenu client={client} entries={composerPlusRegistry()} onCommand={setAction} onSlash={() => {}} />
      <output>{action}</output>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.composer-toolbar-buttons",
  title: "Composer toolbar buttons",
  area: "Agent pane",
  pane: true,
  height: 100,
  covers: ["agent-session/acpmux/ComposerPlusMenu.tsx"],
  load: async () => ToolbarExample,
  styles: () => Promise.all([import("../styles.css"), import("../composerLocation.css")]),
  variants: {
    default: { props: { buttons: [] } },
    attachment: {
      props: { buttons: [{ action: "composer.attachFiles", label: "Attach a file" }] },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Attach a file" });
        await ctx.waitFor(() => ctx.document.querySelector("output")?.textContent === "composer.attachFiles");
      },
    },
    multiple: {
      props: {
        buttons: [{ action: "composer.attachFiles" }, { action: "composer.mention" }, { action: "composer.commands" }],
      },
    },
  },
});
