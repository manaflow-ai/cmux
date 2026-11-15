import { describe, expect, test } from "bun:test";
import { FIXTURE_LOGIN, runJourney } from "./cloud-journey-fake";

// The journey plays the app's part on a warm spare (--preclaim-login): before create it copies the login on the
// spare's cloud.spare.ready, and after the claim a login receipt for the machine leaves only the post-bind check.
describe("the production journey copies the login on spare.ready, as the app's SpareReady path", () => {
  test("with a receipt, the full copy after bind is skipped and only the post-bind check runs", () => {
    const { steps, probe, log } = runJourney({ preclaim: { receipt: true }, login: FIXTURE_LOGIN });
    const create = log.indexOf("create");
    expect(create).toBeGreaterThan(-1);
    // The copy happened on the spare, before create; none after it.
    expect(log.slice(0, create)).toContain("fs/write credential");
    expect(log.slice(create)).not.toContain("fs/write credential");
    // The login step after the claim is the launcher check alone.
    expect(log.slice(create)).toContain("own-login check");
    const pre = steps.find((s) => s.step === "preclaim login (spare.ready)");
    expect(pre?.status).toBe("pass");
    const login = steps.find((s) => s.step === "pass Claude login");
    expect(login?.status).toBe("pass");
    expect(login?.detail).toContain("receipt installed");
    expect(probe.login_path).toBe("receipt");
    expect(probe.outcome).toBe("ok");
    // Before create, so outside the first-text window.
    expect(pre?.fields?.create_marks_ms).toBeUndefined();
  });

  test("without a receipt, the full copy runs after bind", () => {
    const { steps, probe, log } = runJourney({ preclaim: { receipt: false }, login: FIXTURE_LOGIN });
    const create = log.indexOf("create");
    expect(log.slice(create)).toContain("fs/write credential");
    const login = steps.find((s) => s.step === "pass Claude login");
    expect(login?.status).toBe("pass");
    expect(login?.detail).toContain("written by the app's installer");
    expect(probe.login_path).toBe("copy");
  });

  test("without --preclaim-login the login is the copy after bind, as before", () => {
    const { steps, probe, log } = runJourney({ login: FIXTURE_LOGIN });
    expect(steps.find((s) => s.step === "preclaim login (spare.ready)")).toBeUndefined();
    expect(log.slice(0, log.indexOf("create"))).not.toContain("fs/write credential");
    expect(probe.login_path).toBe("copy");
  });
});
