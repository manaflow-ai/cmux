// l10n-allow-file: developer gallery fixtures.
import { cloudPageEntry } from "../../gallery/format";
import { providerRehearsal } from "./providerRehearsal.experiment";
import { sampleMachines, sampleSnapshots } from "./mockData";

export default cloudPageEntry({
  id: "pages.cloud-provider-rehearsal",
  title: "Provider rehearsal",
  area: "Pages",
  covers: ["pages/cloud/ProviderRehearsal.tsx"],
  height: 680,
  experiment: { definition: providerRehearsal, script: [] },
  variants: {
    machines: {
      note: "Existing machines remain alongside the opt-in rehearsal.",
      machines: sampleMachines(),
      snapshots: sampleSnapshots(),
    },
    empty: { note: "Rehearsal before creating a real machine.", machines: [], snapshots: [] },
    "signed-out": { note: "Local rehearsal needs no credentials.", signedIn: false, machines: [], snapshots: [] },
  },
});
