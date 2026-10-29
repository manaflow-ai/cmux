import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { harnessProfiles } from "../src/agent-session/acpmux/harnessProfiles";
import { pendingSpeed } from "../src/agent-session/acpmux/pendingSpeed";

test("a remembered Fast setting wins over the catalog fallback", () => {
  const harness = "pending-speed-profile";
  const model = "pending-speed-model";
  harnessProfiles.observe(
    {
      sessionId: "pending-speed-session",
      harness,
      model,
      configOptions: [
        {
          id: "fast-mode",
          name: "Fast mode",
          options: [
            { value: "off", name: "Off" },
            { value: "on", name: "On" },
          ],
          currentValue: "on",
        },
      ],
    } as NonNullable<AcpmuxSnapshot["summary"]>,
    true,
  );
  const option = pendingSpeed({
    summary: { sessionId: "", harness, model },
    catalog: [{ id: harness, name: "Profile", models: [{ id: model, fast: true }] }],
  } as AcpmuxSnapshot);
  expect(option?.currentValue).toBe("on");
  expect(option?.options.map((entry) => entry.value)).toEqual(["off", "on"]);
});

test("a fresh model uses Fast advertised by the joined catalog", () => {
  const option = pendingSpeed(
    {
      summary: { sessionId: "", harness: "pending-speed-fresh", model: "fresh-model" },
      catalog: [{ id: "pending-speed-fresh", name: "Fresh", models: [{ id: "fresh-model" }] }],
    } as AcpmuxSnapshot,
    { fast: true },
  );
  expect(option?.currentValue).toBe("off");
  expect(option?.options.map((entry) => entry.value)).toEqual(["off", "on"]);
});
