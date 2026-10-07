// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { CloudMachine, CloudPlan } from "./ops";
import { minutesAgo } from "../../gallery/clock";
function fixture(count: number): BridgePageVariant {
  const machines: CloudMachine[] = Array.from({ length: count }, (_, i) => ({
    id: `vm_sample${i}`,
    name:
      count > 4
        ? `integration-environment-${i + 1}-with-a-long-project-and-branch-name`
        : ["api-dev", "build-cache", "test-runner", "docs-preview"][i]!,
    status: (["running", "paused", "provisioning", "failed"] as const)[i % 4]!,
    revision: "1",
    classic: false,
    size: { cpu: 4, memory_mb: 8192, disk_mb: 65536 },
    created_at: minutesAgo(120),
    last_active_at: minutesAgo(5),
    idle_policy: { idle_seconds: 300 },
    error: i % 4 === 3 ? { code: "upstream_error", message: "Sample provisioning failure" } : null,
  }));
  const plan: CloudPlan = {
    plan_id: "pro",
    limits: {
      max_active: 10,
      max_saved: 100,
      memory_options_mb: [4096, 8192],
      locked_memory_options_mb: [],
      vm_hours_included: 100,
    },
    usage: { active: count, saved: count, vm_hours_used: 12 },
  };
  return {
    streams: ["cmux.cloud.machine.watch", "cmux.cloud.file.transfer.changed"],
    replies: {
      "cmux.cloud.auth.status": { signedIn: true, team: "sample-team" },
      "cmux.cloud.machine.list": { machines, revision: 1 },
      "cmux.cloud.plan.get": plan,
      "cmux.cloud.team.list": [],
      "cmux.cloud.migration.status": { state: "none", classic_count: 0, imported: [] },
    },
  };
}
export default bridgePageEntry({
  id: "pages.cloud",
  title: "Cloud",
  area: "Pages",
  page: "cloud",
  covers: [
    "page:cmux.cloud",
    "pages/cloud/CloudPage.tsx",
    "pages/cloud/MachineList.tsx",
    "pages/cloud/AccountPanel.tsx",
  ],
  variants: {
    empty: fixture(0),
    loaded: fixture(4),
    "long-content": fixture(40),
    error: {
      ...fixture(0),
      failures: {
        "cmux.cloud.machine.list": { code: "cmux.page.failed", message: "Sample owner is unavailable. Try again." },
      },
    },
    loading: { ...fixture(0), pending: ["cmux.cloud.machine.list"] },
  },
});
