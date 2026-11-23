import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { sessionEnforcement } from "../handoff/review";
import { EarnedAccessPreview } from "./EarnedAccessPreview";
import { earnedAccessPreview } from "./earnedAccess.experiment";
import { experimentArm } from "../../../experiments/experiment";

const original = globalThis.cmuxExperiments;
afterEach(() => {
  if (original === undefined) delete globalThis.cmuxExperiments;
  else globalThis.cmuxExperiments = original;
});
const report = {
  policy: "approve-all",
  label: "native_policy",
  isolation: "unverified",
  detail: null,
  accessPreview: { current: "full", eligibility: "unavailable" },
};

test("earned access is off by default and legacy daemon snapshots remain hidden", () => {
  globalThis.cmuxExperiments = { "earned-access-preview": "off" };
  expect(experimentArm(earnedAccessPreview, { overrides: {}, stored: {} })).toBe("off");
  expect(renderToStaticMarkup(<EarnedAccessPreview enforcement={sessionEnforcement(report)} />)).toBe("");
  globalThis.cmuxExperiments = { "earned-access-preview": "on" };
  expect(
    renderToStaticMarkup(
      <EarnedAccessPreview enforcement={sessionEnforcement({ ...report, accessPreview: undefined })} />,
    ),
  ).toBe("");
});

test("daemon preview survives the real snapshot boundary without changing the policy", () => {
  globalThis.cmuxExperiments = { "earned-access-preview": "on" };
  const enforcement = sessionEnforcement(report);
  expect(enforcement?.policy).toBe("approve-all");
  expect(enforcement?.accessPreview?.eligibility).toBe("unavailable");
  const html = renderToStaticMarkup(<EarnedAccessPreview enforcement={enforcement} />);
  expect(html).toContain("data-earned-access-preview");
  expect(html).toContain('aria-expanded="false"');
  expect(report.policy).toBe("approve-all");
});
