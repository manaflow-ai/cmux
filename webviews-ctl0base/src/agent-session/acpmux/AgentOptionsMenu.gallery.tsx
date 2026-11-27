// l10n-allow-file: gallery options are fixture labels as a harness reports them; the chip uses the translated Options label.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ConfigOption } from "./agentOptions";

const custom: ConfigOption[] = [
  {
    id: "thinking",
    name: "Thinking",
    currentValue: "on",
    options: [
      { value: "off", name: "Off" },
      { value: "on", name: "On", description: "Think before each answer." },
    ],
  },
  {
    id: "sandbox",
    name: "Sandbox",
    currentValue: "workspace-write",
    options: [
      { value: "read-only", name: "Read only" },
      { value: "workspace-write", name: "Workspace write" },
      { value: "danger-full-access", name: "Full access" },
    ],
  },
];

type Props = { several?: boolean };

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Options" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.options-menu",
  title: "Agent options chip",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 320, normal: 420, wide: 560 },
  anchors: [{ selector: ".acpmux-options" }],
  covers: ["agent-session/acpmux/AgentOptionsMenu.tsx#AgentOptionsMenu"],
  load: async () => {
    const { AgentOptionsMenu } = await import("./AgentOptionsMenu");
    return function GalleryAgentOptionsMenu({ several }: Props) {
      const [options, setOptions] = useState(several ? custom : [custom[0]!]);
      return (
        <AgentOptionsMenu
          options={options}
          onPick={(id, value) =>
            setOptions((list) => list.map((option) => (option.id === id ? { ...option, currentValue: value } : option)))
          }
        />
      );
    };
  },
  styles: () =>
    Promise.all([import("./styles.css"), import("./composerControls.css"), import("./composerLocation.css")]),
  variants: {
    closed: { note: "One custom option: the chip names it and its choice.", props: {} },
    "one-open": { note: "A custom harness option, Off or On.", props: {}, play: open },
    "several-open": { note: "A custom harness's two options, one group each.", props: { several: true }, play: open },
  },
});
