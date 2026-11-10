// l10n-allow-file: gallery fixtures (public-safe sample Cloud data), not shipped UI.
import { cloudPageEntry } from "../../gallery/format";
import { sampleMachines, sampleSnapshots } from "./mockData";
import type { CloudMachine, PortForward } from "./ops";

const machines = sampleMachines();
const snapshots = sampleSnapshots();
const samplePorts: PortForward[] = [
  {
    machine: machines[0]!.id,
    port: 3000,
    host: "127.0.0.1",
    localPort: 49152,
    generation: 1,
    state: "up",
    reason: null,
  },
];
const manyMachines: CloudMachine[] = Array.from({ length: 24 }, (_, index) => ({
  ...structuredClone(machines[index % machines.length]!),
  id: `vm_gallery_${String(index + 1).padStart(2, "0")}`,
  name: `long-running-build-machine-${String(index + 1).padStart(2, "0")}`,
  status: index % 3 === 0 ? "running" : index % 3 === 1 ? "paused" : "provisioning",
  revision: String(index + 1),
})) as CloudMachine[];

// The team's spending cap (cmuxterm-hq#8205; cmux-platform SpendCap.ts): fixed sample times, so the stage never moves.
const PERIOD_END = Date.UTC(2026, 11, 1);
const PAUSE_AT = Date.UTC(2026, 10, 18, 17, 45);
const capRead = { period_end: PERIOD_END, checked_at: Date.UTC(2026, 10, 18, 17, 30) };
const nearCap = { state: "near", spent_usd: 412.5, cap_usd: 500, pause_at: null, paused_at: null, ...capRead } as const;
const atCap = { ...nearCap, state: "at_cap", spent_usd: 503.1 } as const;
const pausingMachines = machines.map((machine) =>
  machine.status === "running" && !machine.classic ? { ...machine, spend_cap_pause_at: PAUSE_AT } : machine,
) as CloudMachine[];
const capPausedMachines = machines.map((machine) =>
  (machine.status === "running" || machine.status === "paused") && !machine.classic
    ? { ...machine, status: "paused", running_since: null, paused_by: "spend_cap" }
    : machine,
) as CloudMachine[];

export default cloudPageEntry({
  id: "pages.cloud",
  title: "Cloud",
  area: "Pages",
  height: 680,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: [
    "page:cmux.cloud",
    "pages/cloud/CloudPage.tsx",
    "pages/cloud/MachineList.tsx",
    "pages/cloud/MachineDetail.tsx",
    "pages/cloud/CreateSheet.tsx",
    "pages/cloud/AccountPanel.tsx",
    "pages/cloud/DetailSections.tsx",
    "pages/cloud/FilesSection.tsx",
    "pages/cloud/PortsSection.tsx",
    "pages/cloud/Notices.tsx",
    "pages/cloud/sectionParts.tsx",
    "pages/cloud/Storefront.tsx",
    "pages/cloud/spendCap.ts",
  ],
  variants: {
    machines: {
      note: "Machines, snapshots, ports and account usage in the rows layout.",
      action: "select-machine",
      machines,
      snapshots,
      ports: samplePorts,
    },
    creating: {
      note: "The create machine sheet with plan sizes and snapshot choices.",
      action: "create",
      machines,
      snapshots,
    },
    "creating-snapshots-failed": {
      note: "The create sheet when the snapshot list fails: Base image stays, with Retry.",
      action: "create",
      snapshotsFail: true,
      machines,
      snapshots,
    },
    "ports-pending": {
      note: "Cloud Ports actions while the host is still resolving.",
      action: "ports-pending",
      pendingAction: "browser",
      machines,
      snapshots,
      ports: samplePorts,
    },
    "ports-shared": {
      note: "A Cloud preview port after Share creates and copies an expiring link; Revoke stays available.",
      action: "ports-shared",
      machines,
      snapshots,
      ports: samplePorts,
    },
    "spend-cap-near": {
      note: "The team is near its spending cap: a dismissible warning with the spend, and team spend in Usage.",
      action: "select-machine",
      spendCap: nearCap,
      machines,
      snapshots,
    },
    "spend-cap-pausing": {
      note: "The team reached its cap: running machines pause in 15 minutes unless an admin raises it; each row says when.",
      spendCap: { ...atCap, pause_at: PAUSE_AT },
      machines: pausingMachines,
      snapshots,
    },
    "spend-cap-paused": {
      note: "The cap paused the team's machines: disks and memory kept; the banner says who can raise it and when it resets.",
      action: "select-machine",
      spendCap: { ...atCap, paused_at: PAUSE_AT },
      machines: capPausedMachines,
      snapshots,
    },
    "spend-cap-refused": {
      note: "Resume at the team's cap is refused: the notice says what was spent and that an admin can raise it.",
      action: "resume",
      spendCap: { ...atCap, paused_at: PAUSE_AT },
      machines: capPausedMachines,
      snapshots,
    },
    "member-budget-refused": {
      note: "Resume past the member's own monthly budget is refused: the notice says an admin can raise it.",
      action: "resume",
      memberBudget: { spent_usd: 50.2, limit_usd: 50 },
      machines: capPausedMachines.map((machine) => {
        const { paused_by: _cap, ...rest } = machine;
        return rest as CloudMachine;
      }),
      snapshots,
    },
    "many-machines": {
      note: "Twenty-four machines with long names for scrolling.",
      layout: "cards",
      machines: manyMachines,
      snapshots,
    },
    "read-only": {
      note: "A classic machine: overview and snapshots remain read-only.",
      action: "select-machine",
      machines: [machines[3]!],
      snapshots: [snapshots[2]!],
    },
    storefront: {
      note: "The storefront (#/get): hero, benefits, the plan's sizes with live availability and Get.",
      hash: "#/get",
      machines,
      snapshots,
    },
    "storefront-full": {
      note: "The storefront when every active machine on the plan is in use: Get is disabled.",
      hash: "#/get",
      maxActive: 3,
      machines,
      snapshots,
    },
    "storefront-get": {
      note: "Get on a size opens the create sheet on that size.",
      hash: "#/get",
      action: "get",
      machines,
      snapshots,
    },
    empty: {
      note: "A signed-in team with no machines yet: the storefront.",
      machines: [],
      snapshots: [],
    },
    "signed-out": {
      note: "Cloud signed out: the storefront with the sign-in action.",
      signedIn: false,
      machines: [],
      snapshots: [],
    },
    error: {
      note: "The Cloud owner returns a network error during startup.",
      mode: "error",
      error: { code: "cmux.cloud.upstream_error", message: "The Cloud service did not answer." },
      machines,
      snapshots,
    },
    loading: {
      note: "Cloud is still loading the account and machine projection.",
      mode: "loading",
      machines,
      snapshots,
    },
  },
});
