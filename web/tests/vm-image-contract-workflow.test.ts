import { readFileSync } from "node:fs";
import { expect, test } from "bun:test";

type Step = { name?: string; run?: string };
type Job = { if?: string; steps: Step[] };

const workflow = Bun.YAML.parse(
  readFileSync(new URL("../../.github/workflows/cloud-vm-image-contract.yml", import.meta.url), "utf8"),
) as { jobs: Record<string, Job> };

// A promote dispatch runs on a branch whose image sources moved past the
// checked-in manifest, so the contract job's source-drift check fails there
// by construction and turned every successful promote run red (cmux#46692).
test("a promote dispatch skips the contract job and checks the staged manifest instead", () => {
  const { contract, promote } = workflow.jobs;
  expect(contract.if).toBe("inputs.promote != true");

  const runs = promote.steps.map((step) => step.run ?? "");
  const bake = runs.findIndex((run) => run.includes("bun run devbox:promote"));
  const check = runs.findIndex((run, index) => index > bake && run.includes("bun run devbox:manifest:check"));
  expect(bake).toBeGreaterThanOrEqual(0);
  expect(check).toBeGreaterThan(bake);
  const contractTests = contract.steps.map((step) => step.run ?? "").find((run) => run.startsWith("bun test "))!;
  for (const file of contractTests.replace("bun test ", "").split(" ")) {
    expect(runs[check]).toContain(file);
  }
  expect(runs[check]).toContain("test_devbox_bubblewrap.py");
});
