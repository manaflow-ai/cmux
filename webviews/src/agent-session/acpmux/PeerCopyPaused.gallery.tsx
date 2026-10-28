// l10n-allow-file: gallery fixtures (machine names), not shipped UI.
// A chat on a paused Cloud machine (cmuxterm-hq#4755: "a paused machine's chat reads 'offline'.
// There is no Resume in the pane"). Before, the banner said the machine was offline; now it says a
// paused machine is paused with Resume, and spins while it starts. Compare arms shows the three
// places of Resume in the `paused-machine-resume` experiment; the actions row ships.
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
    before: {
      note: "Before: a paused Cloud machine's chat says the machine is offline, with nothing to do about it.",
      props: { copy, now: GALLERY_NOW },
    },
    paused: {
      note: "After: the machine is paused, and Resume starts it (the actions row, as the watch banner's choices).",
      props: { copy, now: GALLERY_NOW, machine: "paused", onResume },
    },
    starting: {
      note: "After Resume, or while the machine boots: a spinner and Starting, no second Resume.",
      props: { copy, now: GALLERY_NOW, machine: "starting", onResume },
    },
    "paused-no-time": {
      note: "A copy that names no time.",
      props: { copy: { peer: "dev-vm-2", offline: true }, machine: "paused", onResume },
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
