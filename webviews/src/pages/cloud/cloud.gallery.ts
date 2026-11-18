// l10n-allow-file: gallery fixtures (public-safe sample Cloud data), not shipped UI.
import { cloudPageEntry } from "../../gallery/format";
import { sampleMachines, sampleSnapshots } from "./mockData";
import type { CloudMachine, CloudRetention, CloudSnapshot, PortForward } from "./ops";

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

// Automatic cleanup (retention.ts): dates relative to now, so "Deletes in 9 days" reads the same every run.
const DAY = 86_400_000;
const now = Date.now();
const freeRetention: CloudRetention = {
  mode: "on",
  settings: {
    tier: "retained",
    failed_create_hours: 1,
    never_used_hours: 24,
    idle_pause_minutes: 30,
    worked_in_days: 60,
    heads_up_days: 14,
    last_note_days: 1,
    archive_days: 90,
  },
  team: {},
  email_heads_up: true,
};
const paidRetention: CloudRetention = {
  ...freeRetention,
  settings: { ...freeRetention.settings!, tier: "kept", worked_in_days: null },
};
const [apiDev, buildCache] = machines;
const unused = (days: number, notice?: "heads_up" | "last_note"): CloudMachine => ({
  ...structuredClone(buildCache!),
  evict_at: now + days * DAY - 60_000,
  delete_reason: "unused",
  notice: notice ? { kind: notice, at: now - 3_600_000, delete_at: now + days * DAY - 60_000 } : null,
});
const failedCreate: CloudMachine = {
  ...structuredClone(buildCache!),
  id: "vm_f5",
  name: "try-node-22",
  status: "failed",
  host: null,
  last_active_at: null,
  created_at: now - 30 * 60_000,
  error: { code: "cloud.provider.unavailable", message: "The machine did not start.", at: now - 20 * 60_000 },
  evict_at: now + 30 * 60_000,
  delete_reason: "failed_create",
  revision: "1",
};
const neverUsed: CloudMachine = {
  ...structuredClone(buildCache!),
  id: "vm_g6",
  name: "scratch",
  last_active_at: null,
  created_at: now - 2 * 3_600_000,
  evict_at: now + 22 * 3_600_000,
  delete_reason: "never_used",
  revision: "1",
};
const oldPaused: CloudMachine = {
  ...structuredClone(buildCache!),
  id: "vm_h7",
  name: "spring-prototype",
  size: { cpu: 2, memory_mb: 4096, disk_mb: 32_768 },
  created_at: now - 120 * DAY,
  last_active_at: now - 75 * DAY,
  revision: "3",
};
const archiveSnapshots: CloudSnapshot[] = [
  {
    id: "snap_arch1",
    machine: "vm_x8",
    name: null,
    size_mb: 12_288,
    status: "ready",
    created_at: now - 4 * DAY,
    archive_of: { machine: "vm_x8", name: "docs-preview", until: now + 86 * DAY },
    revision: "1",
  },
  {
    id: "snap_arch2",
    machine: "vm_y9",
    name: null,
    size_mb: 20_480,
    status: "creating",
    created_at: now - 600_000,
    archive_of: { machine: "vm_y9", name: "load-test", until: now + 90 * DAY },
    revision: "1",
  },
];
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

// A paused machine exactly as staging's cloud.machine.get answered it (sleep-keeps probe, run 42823810342), only its
// ids and name changed: the paused rate is the backend's own (cmux-platform Cost.ts), not a fixture's guess.
const stagingPaused: CloudMachine = {
  ...structuredClone(buildCache!),
  id: "vm_staging_paused",
  name: "sleeps-when-idle",
  size: { cpu: 2, memory_mb: 4096, disk_mb: 16_384 },
  status: "paused",
  hourly_rate_usd: 0.1322,
  paused_hourly_rate_usd: 0.001376,
  running_since: null,
  revision: "1",
};

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
    "pages/cloud/ArchiveList.tsx",
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
    "creating-at-limit": {
      note: "The create sheet when every machine the plan runs at once is running: Create stays open; a create pauses an idle machine.",
      action: "create",
      maxActive: 3,
      machines,
      snapshots,
    },
    "creating-at-limit-idle": {
      note: "Create at the running-machines limit with an idle machine: the new machine starts and the idle one shows paused.",
      action: "create-at-cap",
      maxActive: 3,
      idle: [machines[0]!.id],
      machines,
      snapshots,
    },
    "creating-at-limit-busy": {
      note: "Create at the running-machines limit with nothing idle: the sheet offers to pause the running machine used longest ago, then create.",
      action: "create-at-cap",
      maxActive: 3,
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
    "paused-price-staging": {
      note: "A paused machine with the paused rate staging sends: the row and detail say what the pause costs a month.",
      action: "select-machine",
      machines: [stagingPaused, apiDev!],
      snapshots,
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
      note: "The storefront when every machine the plan runs at once is running: Get stays open and says a new one pauses one of yours.",
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
    "cleanup-dates": {
      note: "Free plan cleanup: a calm delete date in the rows of a paused, a never-used and a failed machine; the running one has none.",
      retention: freeRetention,
      machines: [apiDev!, unused(9), neverUsed, failedCreate],
      snapshots,
    },
    "cleanup-heads-up": {
      note: "The one heads-up, inline under its row, 14 days before: Keep or Dismiss. No banner, no modal.",
      retention: freeRetention,
      machines: [apiDev!, unused(14, "heads_up")],
      snapshots,
    },
    "cleanup-last-note": {
      note: "The last note the day before the delete, with Keep.",
      retention: freeRetention,
      machines: [apiDev!, unused(1, "last_note")],
      snapshots,
    },
    "cleanup-kept": {
      note: "A kept machine: the Kept toggle is on and the row has no date.",
      retention: freeRetention,
      machines: [apiDev!, { ...unused(9), keep: true, evict_at: null, delete_reason: null }],
      snapshots,
    },
    "cleanup-paid-archive": {
      note: "A paid plan keeps worked-in machines: paused ones offer Archive and delete; the archives list with Restore.",
      retention: paidRetention,
      machines: [apiDev!, structuredClone(buildCache!), oldPaused],
      snapshots: [...snapshots, ...archiveSnapshots],
    },
    "cleanup-archives-only": {
      note: "The last machine went to an archive: the storefront, with the archives and Restore under it.",
      retention: freeRetention,
      machines: [],
      snapshots: archiveSnapshots,
    },
    "cleanup-cap-delete": {
      note: "Create refused at the machines cap: the sheet offers to delete the failed create the platform named, then create.",
      action: "create-at-cap",
      retention: freeRetention,
      machinesCap: 3,
      freeUp: { machine: failedCreate.id, name: failedCreate.name, reason: "failed_create" },
      machines: [apiDev!, structuredClone(buildCache!), failedCreate],
      snapshots,
    },
    "cleanup-cap-archive": {
      note: "Create refused at the machines cap with nothing disposable: archive and delete the oldest paused machine, then create.",
      action: "create-at-cap",
      retention: paidRetention,
      machinesCap: 3,
      machines: [apiDev!, structuredClone(buildCache!), oldPaused],
      snapshots,
    },
    "cleanup-settings": {
      note: "Cloud settings: the plan's cleanup in words, the email heads-up toggle and the team's numbers.",
      action: "cleanup-team",
      retention: { ...freeRetention, team: { heads_up_days: 7 } },
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
