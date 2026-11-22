// l10n-allow-file: gallery fixtures (machine names), not shipped UI.
// A chat on a paused Cloud machine (cmuxterm-hq#4755: "a paused machine's chat reads 'offline'.
// There is no Resume in the pane"). Before, the banner said the machine was offline; now it says a
// paused machine is paused with Resume, and spins while it starts. Compare arms shows the three
// places of Resume in the `paused-machine-resume` experiment; the actions row ships. A machine that
// is only away (its link dropped) or that the app wakes on its own draws no banner at all (Leo,
// 2026-11-22: "i want it to just work"), so only paused and a start the person asked for are here.
import { componentEntry } from "../../gallery/format";
import { GALLERY_NOW } from "../../gallery/clock";
import type { PeerCopyBanner } from "./PeerCopyBanner";
import { pausedMachineResume } from "./pausedMachine.experiment";

type Props = Parameters<typeof PeerCopyBanner>[0];

const copy = { peer: "dev-vm-2", capturedAt: GALLERY_NOW - 39 * 60_000, offline: true };
const onResume = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.peer-copy-paused",
  title: "Peer chat while its Cloud machine is paused",
  area: "Agent pane",
  height: 140,
  covers: ["agent-session/acpmux/PeerCopyBanner.tsx#PeerCopyBanner"],
  pane: true,
  load: () => import("./PeerCopyBanner").then((module) => module.PeerCopyBanner),
  variants: {
    paused: {
      note: "After: the machine is paused, and Resume starts it (the actions row, as the watch banner's choices).",
      props: { noteDelayMs: 0, copy, now: GALLERY_NOW, machine: "paused", onResume },
    },
    starting: {
      note: "After Resume: a spinner and Starting, no second Resume. A start the app makes on its own draws nothing.",
      props: { noteDelayMs: 0, copy, now: GALLERY_NOW, machine: "starting", asked: true, onResume },
    },
    "paused-no-time": {
      note: "A copy that names no time.",
      props: { noteDelayMs: 0, copy: { peer: "dev-vm-2", offline: true }, machine: "paused", onResume },
    },
  },
  experiment: {
    definition: pausedMachineResume,
    script: [
      {
        name: "hover Resume",
        run: async (ctx) => {
          await ctx.hover({ deep: ".acpmux-peer-copy button" });
        },
      },
    ],
  },
});
