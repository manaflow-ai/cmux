import { expect, test } from "bun:test";
import { CmuxVmError, CmuxVmPlanRequired, CmuxVmQuotaExceeded, createCmuxVm } from "../src/vm.ts";

type Call = { method: string; url: string; body: unknown; headers: Headers };
const harness = (replies: Array<{ status: number; body?: unknown }>) => {
  const calls: Call[] = [];
  const fetch = async (request: Request) => {
    const text = await request.text();
    calls.push({ method: request.method, url: request.url, body: text ? JSON.parse(text) : undefined, headers: request.headers });
    const reply = replies.shift() ?? { status: 500 };
    return new Response(reply.body === undefined ? null : JSON.stringify(reply.body), { status: reply.status, headers: { "content-type": "application/json" } });
  };
  return { calls, vm: createCmuxVm({ token: "cmuxvm_sk_x", teamId: "team_1", baseUrl: "https://vm.test", fetch }) };
};
const VM = { id: "vm_1", state: "running" };

test("create sends the body and returns the VM", async () => {
  const { calls, vm } = harness([{ status: 201, body: VM }]);
  expect(await vm.create({ displayName: "t" })).toEqual(VM as never);
  expect(calls[0]?.method).toBe("POST");
  expect(calls[0]?.url).toBe("https://vm.test/v1/vms");
  expect(calls[0]?.body).toEqual({ displayName: "t" });
  expect(calls[0]?.headers.get("x-cmux-team-id")).toBe("team_1");
});

test("a 402 is a typed plan refusal carrying the upgrade URL, never retried", async () => {
  const { calls, vm } = harness([{ status: 402, body: { _tag: "PaymentRequired", message: "no VMs on Free", upgradeUrl: "https://cmux.com/checkout?plan=pro" } }]);
  const error = await vm.create({}).catch((e: unknown) => e);
  expect(error).toBeInstanceOf(CmuxVmPlanRequired);
  expect((error as CmuxVmPlanRequired).upgradeUrl).toBe("https://cmux.com/checkout?plan=pro");
  expect((error as CmuxVmPlanRequired).retryable).toBe(false);
  expect(calls.length).toBe(1);
});

test("a 402 without a URL falls back to the pricing page", async () => {
  const { vm } = harness([{ status: 402, body: { message: "no" } }]);
  const error = (await vm.create({}).catch((e: unknown) => e)) as CmuxVmPlanRequired;
  expect(error.upgradeUrl).toBe("https://cmux.com/pricing");
});

test("a 429 is a typed quota refusal with the budget and retry delay", async () => {
  const { vm } = harness([{ status: 429, body: { _tag: "QuotaExceeded", message: "full", budget: "vms", retryAfterSeconds: 7 } }]);
  const error = (await vm.create({}).catch((e: unknown) => e)) as CmuxVmQuotaExceeded;
  expect(error).toBeInstanceOf(CmuxVmQuotaExceeded);
  expect(error.budget).toBe("vms");
  expect(error.retryAfterSeconds).toBe(7);
  expect(error.retryable).toBe(true);
});

test("other errors keep status and tag", async () => {
  const { vm } = harness([{ status: 404, body: { _tag: "NotFound", message: "gone" } }]);
  const error = (await vm.pause("vm_1").catch((e: unknown) => e)) as CmuxVmError;
  expect(error).toBeInstanceOf(CmuxVmError);
  expect(error.status).toBe(404);
  expect(error.tag).toBe("NotFound");
});

test("pause, resume, delete and list hit the right routes", async () => {
  const { calls, vm } = harness([{ status: 200, body: { ...VM, state: "paused" } }, { status: 200, body: VM }, { status: 204 }, { status: 200, body: { items: [VM] } }]);
  await vm.pause("vm_1");
  await vm.resume("vm_1");
  await vm.delete("vm_1");
  await vm.list();
  expect(calls.map((c) => `${c.method} ${new URL(c.url).pathname}`)).toEqual(["POST /v1/vms/vm_1/pause", "POST /v1/vms/vm_1/resume", "DELETE /v1/vms/vm_1", "GET /v1/vms"]);
});

test("exec sends the command and returns exit code and output", async () => {
  const { calls, vm } = harness([{ status: 200, body: { exitCode: 0, stdout: "ok\n", stderr: "" } }]);
  const result = await vm.exec("vm_1", "echo ok", { timeoutMs: 5000 });
  expect(result).toEqual({ exitCode: 0, stdout: "ok\n", stderr: "" });
  expect(calls[0]?.body).toEqual({ command: "echo ok", timeoutMs: 5000 });
});

test("acpmuxRun runs one agent turn with a shell-quoted prompt", async () => {
  const { calls, vm } = harness([{ status: 200, body: { exitCode: 0, stdout: "tenant ok\n", stderr: "" } }]);
  const result = await vm.acpmuxRun("vm_1", "it's a test; echo $HOME", { model: "claude" });
  expect(result.stdout).toBe("tenant ok\n");
  expect((calls[0]?.body as { command: string }).command).toBe(`acpmux run -m 'claude' 'it'\\''s a test; echo $HOME'`);
});

test("acpmuxRun fails with the guest's stderr when acpmux is missing", async () => {
  const { vm } = harness([{ status: 200, body: { exitCode: 127, stdout: "", stderr: "acpmux: not found" } }]);
  const error = (await vm.acpmuxRun("vm_1", "hi").catch((e: unknown) => e)) as CmuxVmError;
  expect(error).toBeInstanceOf(CmuxVmError);
  expect(error.tag).toBe("AcpmuxMissing");
});
