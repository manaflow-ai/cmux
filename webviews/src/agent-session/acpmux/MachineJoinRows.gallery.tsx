// l10n-allow-file: gallery fixtures (sample machines and hosts), not shipped UI.
//
// Door A in the new chat's Where control (cmuxterm-hq docs/design/remote-spin-up.md, section 2.1):
// the machine list shows the machines this Mac reaches and has not added under "Not added yet",
// the person's own tailnet nodes first (one click joins and picks one), then a folded "Other
// machines on your network" whose rows ask once before they join. Leo, 2026-11-16: "it should not
// take much at all to simply spin [stuff] up".
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ComposerContext } from "./ComposerContext";
import type { JoinCandidate, MachineJoinState } from "./machineJoin";

type Props = ComponentProps<typeof ComposerContext>;

const candidates: JoinCandidate[] = [
  { name: "gcp-3", address: "gcp-3.tail1234.ts.net", os: "linux", found: "tailnet", mine: true },
  { name: "gcp-4", address: "gcp-4.tail1234.ts.net", os: "linux", found: "tailnet", mine: true },
  { name: "pi-kitchen", address: "pi-kitchen.tail1234.ts.net", os: "linux", found: "tailnet", mine: true },
  { name: "build-box", address: "build-box", found: "ssh-config", mine: false },
  { name: "shared-gpu", address: "shared-gpu.tail1234.ts.net", os: "linux", found: "tailnet", mine: false },
];
const listed: MachineJoinState = { candidates, loaded: true };

const base: Props = {
  sessions: [],
  projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
  localName: "studio-mac",
  onProject: () => undefined,
  onBrowseProject: () => undefined,
  onConnect: () => undefined,
  environments: true,
  cloudSignedIn: true,
  runMode: { mode: "persistent", onMode: () => undefined },
  onJoinMachine: (candidate) => {
    document.documentElement.dataset.galleryJoined = candidate.address;
  },
};
/// Two machines already added, so Where > Remote picks the first and opens the machine list.
const withMachines: Props = {
  ...base,
  peers: ["studio-mini", "gpu-box"],
  peerKinds: { "studio-mini": "ssh", "gpu-box": "ssh" },
  peerConnected: { "studio-mini": true, "gpu-box": true },
  machineJoin: listed,
};

const openWhere: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover.acpmux-env-rows-where [role="option"]'));
};
const openMachines: Play = async (ctx) => {
  await openWhere(ctx);
  await ctx.click({ selector: '.acpmux-env-popover [data-action="another"]' });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-action="join"]'));
};
const pickMine: Play = async (ctx) => {
  await openMachines(ctx);
  await ctx.click({ selector: '.acpmux-env-popover [data-action="join"][data-mine]' });
  await ctx.waitFor(() => ctx.document.documentElement.dataset.galleryJoined === "gcp-3.tail1234.ts.net");
};

export default componentEntry<Props>({
  id: "agent-pane.machine-join-rows",
  title: "Machine list: Not added yet",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentPicker",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 420,
  anchors: [{ selector: ".acpmux-composer-context" }],
  variants: {
    "rows-mine": {
      note: "Where > Remote: the added machines, then Not added yet with the person's own tailnet nodes (one click each), the other hosts folded, Add Machine… last.",
      props: withMachines,
      play: openMachines,
    },
    "rows-other-open": {
      note: "Other machines on your network, open: hosts that are not the person's own tailnet nodes; each asks once, naming the host and login, before it joins.",
      props: { ...withMachines, joinOtherExpanded: true },
      play: openMachines,
    },
    "rows-none-added": {
      note: "No machine added yet: Remote opens on the machines this Mac reaches, so the first machine is one click instead of Add Machine….",
      props: { ...base, machineJoin: listed },
      play: async (ctx) => {
        await openWhere(ctx);
        await ctx.click({ selector: '.acpmux-env-popover [data-action="another"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-action="join"]'));
      },
    },
    "picked-setting-up": {
      note: "A row picked: the machine control names it as being set up (gcp-3 · Setting up) while the line under the composer counts.",
      props: {
        ...withMachines,
        machineJoin: {
          ...listed,
          join: {
            joinId: "join-gallery",
            candidate: candidates[0]!,
            phase: "joining",
            step: "install",
            seconds: 6,
            heardAt: 1_800_000_000_000,
            confirmed: false,
            queued: false,
          },
        },
      },
    },
    "click-joins": {
      note: "One click on the person's own node joins it: no confirmation for a node the tailnet says is theirs.",
      props: withMachines,
      play: pickMine,
    },
  },
});
