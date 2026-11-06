import { afterEach, expect, spyOn, test } from "bun:test";
import { machineLoginApi, MachineLoginError } from "./machineLogin";
import { ExpiredSession } from "./wire";

const login = { loginId: "login_1", url: "https://claude.com/cai/oauth/authorize", needsCode: true };
const signal = () => new AbortController().signal;
let fetchMock: ReturnType<typeof spyOn<typeof globalThis, "fetch">> | undefined;
afterEach(() => {
  fetchMock?.mockRestore();
  fetchMock = undefined;
});
function respond(value: unknown, status = 200, ok = true) {
  fetchMock = spyOn(globalThis, "fetch").mockImplementation(
    Object.assign(async () => Response.json(ok ? { ok: true, value } : { ok: false, error: value }, { status }), {
      preconnect: globalThis.fetch.preconnect,
    }),
  );
  return fetchMock;
}
test("machine status uses only the run on the cookie-authenticated same origin", async () => {
  const fetch = respond({ waiting: true, harness: "claude", login });
  expect(await machineLoginApi.status("run_42", signal())).toEqual({
    waiting: true,
    harness: "claude",
    login,
  });
  const [url, options] = fetch.mock.calls[0]!;
  expect(url).toBe("/v1/chief/machine-login/run_42");
  expect(options).toMatchObject({
    method: "GET",
    credentials: "include",
    cache: "no-store",
    referrerPolicy: "no-referrer",
  });
  expect(options?.body).toBeUndefined();
  expect(new Headers(options?.headers).has("Authorization")).toBe(false);
});
test("start does not invent agent or conversation fields", async () => {
  const fetch = respond(login);
  await machineLoginApi.start("run_42", signal());
  expect(JSON.parse(String(fetch.mock.calls[0]![1]?.body))).toEqual({ action: "start" });
});
test("finish and safe recovery distinguish false from resumed and omit absent code", async () => {
  const fetch = respond({ signedIn: false });
  expect(await machineLoginApi.finish("run_42", "login_1", "synthetic-code", signal())).toEqual({
    signedIn: false,
  });
  expect(JSON.parse(String(fetch.mock.calls[0]![1]?.body))).toEqual({
    action: "finish",
    loginId: "login_1",
    code: "synthetic-code",
  });
  await machineLoginApi.finish("run_42", "login_1", undefined, signal());
  expect(JSON.parse(String(fetch.mock.calls[1]![1]?.body))).toEqual({
    action: "finish",
    loginId: "login_1",
  });
});
test("cancel has only its login id and requires acknowledgement", async () => {
  const fetch = respond({ cancelled: true });
  await machineLoginApi.cancel("run_42", "login_1", signal());
  expect(JSON.parse(String(fetch.mock.calls[0]![1]?.body))).toEqual({
    action: "cancel",
    loginId: "login_1",
  });
});
test("resumed status survives a lost finish reply", async () => {
  respond({ signedIn: true, resumed: true });
  expect(await machineLoginApi.status("run_42", signal())).toEqual({
    signedIn: true,
    resumed: true,
  });
  expect(await machineLoginApi.finish("run_42", "login_1", undefined, signal())).toEqual({
    signedIn: true,
    resumed: true,
  });
});
for (const run of ["run_", "run_1/subrun", "run_1234567890123456", "agent_other", "../run_1"])
  test(`invalid run cannot change the proxy target (${run})`, async () => {
    const fetch = respond(login);
    await expect(machineLoginApi.start(run, signal())).rejects.toBeInstanceOf(MachineLoginError);
    expect(fetch).not.toHaveBeenCalled();
  });
for (const url of [
  "http://claude.ai/oauth",
  "https://claude.ai.evil.test/",
  "https://user@claude.ai/",
  "https://claude.ai:8443/",
  "javascript:alert(1)",
])
  test(`rejects an unsafe provider page (${url})`, async () => {
    respond({ ...login, url });
    await expect(machineLoginApi.start("run_1", signal())).rejects.toBeInstanceOf(MachineLoginError);
  });
test("401 expires the account, while provider failures preserve only their safe code", async () => {
  respond({ code: "auth.unauthenticated", message: "secret" }, 401, false);
  await expect(machineLoginApi.status("run_1", signal())).rejects.toBeInstanceOf(ExpiredSession);
});
for (const status of [400, 403, 404, 409, 410, 503])
  test(`${status} stays a typed machine-login failure`, async () => {
    respond({ code: "chief.machine.login_unavailable", message: "secret-provider-output" }, status, false);
    const error = await machineLoginApi.status("run_1", signal()).catch((error: unknown) => error);
    expect(error).toMatchObject({ status, code: "chief.machine.login_unavailable" });
    expect(String(error)).not.toContain("secret-provider-output");
  });
test("HTTP-200 failure envelopes cannot be mistaken for login success", async () => {
  respond({ code: "chief.machine.login_busy" }, 200, false);
  await expect(machineLoginApi.start("run_1", signal())).rejects.toBeInstanceOf(MachineLoginError);
});
test("request cancellation follows card removal", async () => {
  const fetch = respond({ waiting: true, harness: "codex", login: null });
  const controller = new AbortController();
  await machineLoginApi.status("run_1", controller.signal);
  const requested = fetch.mock.calls[0]![1]?.signal;
  controller.abort();
  expect(requested?.aborted).toBe(true);
});

test("device finish has a seventeen-minute deadline while status remains short", async () => {
  respond({ signedIn: true, resumed: true });
  const timer = spyOn(globalThis, "setTimeout");
  try {
    await machineLoginApi.finish("run_42", "login_1", undefined, signal());
    expect(timer.mock.calls.some((call) => call[1] === 17 * 60_000)).toBe(true);
    await machineLoginApi.status("run_42", signal());
    expect(timer.mock.calls.some((call) => call[1] === 30_000)).toBe(true);
  } finally {
    timer.mockRestore();
  }
});

for (const value of [
  null,
  {},
  { waiting: true, harness: "pi-durable", login: null },
  { waiting: true, harness: "claude" },
  { signedIn: true },
  { waiting: true, harness: "codex", login: { ...login, needsCode: "true" } },
])
  test("malformed status cannot offer an unsafe or invented sign-in", async () => {
    respond(value);
    await expect(machineLoginApi.status("run_42", signal())).rejects.toBeInstanceOf(MachineLoginError);
  });
