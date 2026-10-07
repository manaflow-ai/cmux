// l10n-allow-file: gallery fixtures (public-safe sample Cloud data), not shipped UI.
import { cloudPageEntry } from "../../gallery/format";
import { sampleMachines, sampleSnapshots } from "./mockData";
import type { CloudMachine } from "./ops";

const machines = sampleMachines();
const snapshots = sampleSnapshots();
const manyMachines: CloudMachine[] = Array.from({ length: 24 }, (_, index) => ({
  ...structuredClone(machines[index % machines.length]!),
  id: `vm_gallery_${String(index + 1).padStart(2, "0")}`,
  name: `long-running-build-machine-${String(index + 1).padStart(2, "0")}`,
  status: index % 3 === 0 ? "running" : index % 3 === 1 ? "paused" : "provisioning",
  revision: String(index + 1),
})) as CloudMachine[];

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
  ],
  variants: {
    machines: {
      note: "Machines, snapshots, ports and account usage in the rows layout.",
      action: "select-machine",
      machines,
      snapshots,
    },
    creating: {
      note: "The create machine sheet with plan sizes and snapshot choices.",
      action: "create",
      machines,
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
    empty: {
      note: "A signed-in team with no machines yet.",
      machines: [],
      snapshots: [],
    },
    "signed-out": {
      note: "Cloud signed out, with the sign-in action.",
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
