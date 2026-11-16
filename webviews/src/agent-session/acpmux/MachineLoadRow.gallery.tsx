// l10n-allow-file: gallery fixtures (sample machines), not shipped UI.
//
// The composer's machine picker with each machine's load line (shared/MachineLoadLine.tsx): cores busy
// of total, free RAM, live chats and placement's verdict from acpmux's `peers[].load`, the same line
// Settings > Machines draws (settings.machine-load-rows). Idle, busy, offline and a long list.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ComponentProps } from "react";
import { ComposerContext } from "./ComposerContext";
import { idleLoad, busyLoad, offlineLoad, manyMachines, threeMachines } from "../shared/machineLoad.fixtures";
import type { MachineLoad } from "../shared/machineLoad";

type Props = ComponentProps<typeof ComposerContext>;

/** A new chat's composer whose machines are `loads`: connected unless offline in the row. */
function machines(loads: Record<string, MachineLoad>): Props {
  const names = Object.keys(loads);
  const up = (name: string) => loads[name]!.verdict !== "offline";
  return {
    sessions: [],
    projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
    localName: "studio-mac",
    onProject: () => undefined,
    onBrowseProject: () => undefined,
    onConnect: () => undefined,
    environments: true,
    cloudSignedIn: true,
    peers: names,
    peerKinds: Object.fromEntries(names.map((name) => [name, "ssh" as const])),
    peerConnected: Object.fromEntries(names.map((name) => [name, up(name)])),
    peerStates: Object.fromEntries(names.map((name) => [name, up(name) ? "connected" : "offline"])),
    peerLoads: loads,
  };
}

const openMachines: Play = async (ctx) => {
  await ctx.contextMenu({ role: "button", name: /^Environment/ });
  await ctx.click({ role: "menuitem", name: "Machines…" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-popover .machine-load"));
};

/** Opens the list and checks the named machine's row reads `words`. */
const reads =
  (name: string, words: string): Play =>
  async (ctx) => {
    await openMachines(ctx);
    const row = [...ctx.document.querySelectorAll(".acpmux-env-popover .acpmux-env-row")].find((candidate) =>
      candidate.textContent?.includes(name),
    );
    if (!row) throw new Error(`${name} is not listed`);
    if (!row.querySelector(".machine-load")?.textContent?.includes(words))
      throw new Error(`${name}'s load line does not read "${words}"`);
    // The load line never squeezes the machine's name out of its row.
    const label = row.querySelector<HTMLElement>(".acpmux-location-name .acpmux-menu-label");
    if (!label || label.getBoundingClientRect().width < label.scrollWidth - 0.5)
      throw new Error(`${name}'s name is cut by its load line`);
  };

export default componentEntry<Props>({
  id: "agent-pane.machine-load-row",
  title: "Machine picker load rows",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/shared/MachineLoadLine.tsx#MachineLoadLine"],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620 },
  height: 420,
  variants: {
    idle: {
      note: "A machine with room: its cores busy of total, free RAM, live chats, then 'room for 5'.",
      props: machines({ "gcp-3": idleLoad }),
      play: reads("gcp-3", "room for 5"),
    },
    busy: {
      note: "A machine over its budget: its numbers, then 'busy' in the warning colour. It is never refused.",
      props: machines({ "build-box": busyLoad }),
      play: reads("build-box", "busy"),
    },
    offline: {
      note: "A machine that dropped: no numbers, how long it has been offline.",
      props: machines({ "old-laptop": offlineLoad }),
      play: async (ctx) => {
        await openMachines(ctx);
        if (!ctx.document.querySelector(".acpmux-env-popover")?.textContent?.includes("offline 2 min"))
          throw new Error("the offline machine does not say how long");
      },
    },
    mixed: {
      note: "Room, busy and offline side by side, as Settings > Machines shows the same three.",
      props: machines(threeMachines),
      play: reads("build-box", "busy"),
    },
    "many-machines": {
      note: "40 machines: the list keeps one line each, and the numbers give up room before the names do.",
      props: machines(manyMachines(40)),
      play: openMachines,
    },
  },
});
