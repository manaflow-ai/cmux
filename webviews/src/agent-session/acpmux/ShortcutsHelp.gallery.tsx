// l10n-allow-file: gallery fixtures, not shipped UI.
import { useLayoutEffect } from "react";
import { componentEntry } from "../../gallery/format";
import type { ShortcutLabels } from "./shortcuts";

type Props = { enabled: boolean; labels: ShortcutLabels };
const labels = {
  "palette.newAgentChat": "⇧⌘I",
  "palette.toggleDictation": "⌥D",
  "agentPane.searchChats": "⌘K",
  "palette.copySurfaceLink": "⇧⌘L",
  "agentPane.permission.allowOnce": "⌘Y",
  splitRight: "⌘D",
  splitBrowserRight: "⌥⌘B",
};

export default componentEntry<Props>({
  id: "agent-pane.shortcuts-help",
  title: "Chat keyboard shortcuts",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 640,
  widths: { narrow: 320, normal: 560, wide: 860 },
  covers: ["agent-session/acpmux/ShortcutsHelp.tsx#ShortcutsHelp"],
  load: async () => {
    const { ShortcutsHelp } = await import("./ShortcutsHelp");
    const { ShortcutsContext } = await import("./shortcuts");
    const { configureLabs } = await import("./labs");
    return function ShortcutsHelpGallery(props: Props) {
      useLayoutEffect(() => {
        configureLabs({ labs: { shortcutsHelp: props.enabled } });
        return () => configureLabs(undefined);
      }, [props.enabled]);
      return (
        <ShortcutsContext.Provider value={props.labels}>
          <ShortcutsHelp open onOpenChange={() => undefined} />
        </ShortcutsContext.Provider>
      );
    };
  },
  variants: {
    bound: { props: { enabled: true, labels } },
    rebound: { props: { enabled: true, labels: { ...labels, "palette.newAgentChat": "⌃N" } } },
    unbound: { props: { enabled: true, labels: {} } },
    "lab-off": { props: { enabled: false, labels } },
  },
});
