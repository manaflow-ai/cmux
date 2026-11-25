// l10n-allow-file: gallery fixtures (sample hosts and logins), not shipped UI.
//
// Door A's line under a new chat's composer (MachineJoinLine.tsx) while a machine picked from "Not
// added yet" is set up. Leo, 2026-11-16: "it should not take much at all to simply spin [stuff] up".
// Three looks of the same states: `line` (shipped), `tray` and `steps`.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { MachineJoinLine, MachineJoinLineLook } from "./MachineJoinLine";
import type { JoinCandidate, MachineJoin } from "./machineJoin";

type Props = ComponentProps<typeof MachineJoinLine>;

const NOW = 1_800_000_000_000;
const mine: JoinCandidate = { name: "gcp-3", address: "gcp-3.tail1234.ts.net", found: "tailnet", mine: true };
const other: JoinCandidate = { name: "build-box", address: "build-box", found: "ssh-config", mine: false };

const base = (candidate: JoinCandidate, extra: Partial<MachineJoin>): MachineJoin => ({
  joinId: "join-gallery",
  candidate,
  phase: "joining",
  step: "reach",
  seconds: 0,
  heardAt: NOW,
  confirmed: false,
  queued: false,
  ...extra,
});

const installing = base(mine, { step: "install", seconds: 6 });
const STATES: Record<string, { note: string; join: MachineJoin }> = {
  installing: {
    note: 'One of the person\'s own tailnet nodes, picked from Not added yet: "Setting up gcp-3 · installing 6 s", no question asked.',
    join: installing,
  },
  queued: {
    note: "The person pressed Send while it is set up: the prompt is kept, and the line says it goes once the machine is ready.",
    join: { ...installing, step: "connect", seconds: 14, queued: true },
  },
  confirm: {
    note: "A host that is not the person's own tailnet node asks once, naming the host and the login, before anything runs.",
    join: base(other, { phase: "confirm", login: "leo@build-box" }),
  },
  "failed-key": {
    note: "A failure says its next step in one line, with one button (Try Again) and Dismiss.",
    join: base(other, {
      phase: "failed",
      confirmed: true,
      failure: { kind: "needs_key", message: "Permission denied (publickey)", next: "ssh-copy-id build-box" },
    }),
  },
  "failed-signed-out": {
    note: "Signed out: the app refused the join before acpmux ran it; the button is Sign In.",
    join: base(mine, { phase: "failed", failure: { kind: "not_signed_in", message: "", next: "" } }),
  },
};

const LOOK_NOTES: Record<MachineJoinLineLook, string> = {
  line: "Look 1 of 3, shipped: quiet text under the composer with its one button.",
  tray: "Look 2 of 3: the same words on a flat tonal block.",
  steps: "Look 3 of 3: four dots for reach, token, install and connect, the running one named.",
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const look of ["line", "tray", "steps"] as const) {
  for (const [state, { note, join }] of Object.entries(STATES)) {
    variants[`${look}-${state}`] = {
      note: `${LOOK_NOTES[look]} ${note}`,
      props: { join, look, now: NOW + 400, onSignIn: () => undefined, onAddMachine: () => undefined },
    };
  }
}

export default componentEntry<Props>({
  id: "agent-pane.machine-join-line",
  title: "Machine join line",
  area: "Agent pane",
  covers: ["agent-session/acpmux/MachineJoinLine.tsx#MachineJoinLine"],
  load: () => import("./MachineJoinLine").then((module) => module.MachineJoinLine),
  styles: () => Promise.all([import("./styles.css"), import("./machineJoinLine.css")]),
  widths: { narrow: 360, normal: 560, wide: 760 },
  height: 56,
  anchors: [{ selector: ".acpmux-join-line" }],
  variants,
});
