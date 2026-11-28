import { describe, expect, test } from "bun:test";
import { FIXTURE_LOGIN, runJourney } from "./cloud-journey-fake";

// The journey plays the app's part on a warm spare (--preclaim-login): before create it copies the login on the
// spare's cloud.spare.ready, and after the claim a login receipt for the machine leaves only the post-bind check.
describe("the production journey copies the login on spare.ready, as the app's SpareReady path", () => {
  test("ordinary and warmed journeys request the app's machine size, so the warm pool can satisfy either", () => {
    for (const preclaim of [undefined, { receipt: true }]) {
      const { steps, log } = runJourney({ preclaim, login: FIXTURE_LOGIN });
      expect(steps.find((step) => step.step === "create machine")?.status).toBe("pass");
      const sizes = log.filter((line) => line.startsWith("create size ")).map((line) => JSON.parse(line.slice("create size ".length)));
      expect(sizes).toEqual([{ cpu: 2, memory_mb: 4096, disk_mb: 20480 }]);
    }
  });

  test("with a receipt, the full copy after bind is skipped and only the post-bind check runs", () => {
    const { steps, probe, log } = runJourney({ preclaim: { receipt: true }, login: FIXTURE_LOGIN });
    const create = log.indexOf("create");
    expect(create).toBeGreaterThan(-1);
    // The copy happened on the spare, before create; none after it.
    expect(log.slice(0, create)).toContain("fs/write credential");
    expect(log.slice(create)).not.toContain("fs/write credential");
    // The app reads the receipt from its ledger and runs no launcher check before the chat: the journey's check
    // still runs, after the first text, so it is outside create_to_first_text_ms.
    expect(log.slice(create)).toContain("own-login check");
    const pre = steps.find((s) => s.step === "preclaim login (spare.ready)");
    expect(pre?.status).toBe("pass");
    const login = steps.find((s) => s.step === "pass Claude login");
    expect(login?.status).toBe("pass");
    expect(login?.detail).toContain("receipt installed");
    const names = steps.map((s) => s.step);
    const launcher = names.indexOf("login seen by the launcher");
    expect(steps[launcher]?.status).toBe("pass");
    expect(launcher).toBeGreaterThan(names.indexOf("reply"));
    expect(names.indexOf("reply")).toBeGreaterThan(-1);
    expect(probe.login_path).toBe("receipt");
    expect(probe.outcome).toBe("ok");
    // Before create, so outside the first-text window.
    expect(pre?.fields?.create_marks_ms).toBeUndefined();
  });

  // A miss no longer pays a post-bind login copy: the login goes with the agent's start (cmux#50935).
  test("without a receipt, the login goes with the agent's start, never a copy after bind", () => {
    const { steps, probe, log } = runJourney({ preclaim: { receipt: false }, login: FIXTURE_LOGIN });
    const create = log.indexOf("create");
    expect(log.slice(create)).not.toContain("fs/write credential");
    const login = steps.find((s) => s.step === "pass Claude login");
    expect(login?.status).toBe("pass");
    expect(login?.detail).toContain("given to the agent at its start");
    expect(probe.login_path).toBe("launch");
  });

  test("the warm goes to client-config's platform_origin, never the API host (an empty 404 there)", () => {
    // Every production journey from 11-18 to 11-20 skipped this step with "the cmux platform refused the reservation
    // (404 )": the warm named cloud-api.cmux.dev, which forwards no /v1/machines/reservations. The fake cmux-tui refuses
    // the same way unless the request names the platform, so a pass here means the warm reached it.
    const { steps } = runJourney({ preclaim: { receipt: true }, login: FIXTURE_LOGIN });
    const pre = steps.find((s) => s.step === "preclaim login (spare.ready)");
    expect(pre?.detail ?? "").not.toContain("refused");
    expect(pre?.status).toBe("pass");
  });

  test("without --preclaim-login the login goes with the agent's start, as the app sends it (cmux#40159), never a copy", () => {
    const { steps, probe, log } = runJourney({ login: FIXTURE_LOGIN });
    expect(steps.find((s) => s.step === "preclaim login (spare.ready)")).toBeUndefined();
    expect(log).not.toContain("fs/write credential");
    expect(probe.login_path).toBe("launch");
  });
});
