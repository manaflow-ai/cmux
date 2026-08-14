import { expect, test } from "bun:test";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const smokeScript = path.join(scriptDir, "smoke-vm-api.mjs");

function makeTimerScalePreload(fixtureDir) {
  const preloadPath = path.join(fixtureDir, "scale-timers.mjs");
  writeFileSync(
    preloadPath,
    `const nativeSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = (callback, delay, ...args) => nativeSetTimeout(
  callback,
  Math.max(1, Math.ceil(Number(delay) * 0.001)),
  ...args,
);
`,
  );
  return preloadPath;
}

function makeFakeWebDir(fixtureDir, { stackFailure = false } = {}) {
  const webDir = path.join(fixtureDir, "web");
  const stackModuleDir = path.join(webDir, "node_modules", "@stackframe", "js");
  mkdirSync(stackModuleDir, { recursive: true });
  writeFileSync(path.join(webDir, "package.json"), JSON.stringify({ private: true, type: "module" }));
  const createUserImplementation = stackFailure
    ? `throw new Error("fake Stack create failure");`
    : `record("stack:create-user");
    return new FakeUser();`;
  writeFileSync(
    path.join(stackModuleDir, "package.json"),
    JSON.stringify({ name: "@stackframe/js", type: "module", exports: "./index.js" }),
  );
  writeFileSync(
    path.join(stackModuleDir, "index.js"),
    `import { appendFileSync } from "node:fs";

function record(event) {
  appendFileSync(process.env.FAKE_STACK_EVENTS_PATH, event + "\\n");
}

class FakeUser {
  id = "fake-stack-user-id";

  async createSession() {
    record("stack:create-session");
    return {
      async getTokens() {
        record("stack:get-tokens");
        return { accessToken: "fake-access", refreshToken: "fake-refresh" };
      },
    };
  }

  async delete() {
    record("stack:delete-user");
  }
}

export class StackServerApp {
  async createUser() {
    ${createUserImplementation}
  }
}
`,
  );
  return webDir;
}

async function runSmoke({
  createDelayMs = 0,
  createdProvider = "daytona",
  deleteDelayMs = 0,
  deleteStatuses,
  deleteStatus = 200,
  extraVmAfterDelete = false,
  removeVmOnDeleteFailure = false,
  retainVmAfterDelete = false,
  scaleTimers = false,
  stackFailure = false,
  verifyListStatus = 200,
} = {}) {
  const fixtureDir = mkdtempSync(path.join(tmpdir(), "cmux-cloud-vm-smoke-test-"));
  const eventsPath = path.join(fixtureDir, "events.log");
  const webDir = makeFakeWebDir(fixtureDir, { stackFailure });
  const timerScalePreload = scaleTimers ? makeTimerScalePreload(fixtureDir) : undefined;
  let vms = [];
  let deleteCompleted = false;
  let deleteAttempt = 0;
  const record = (event) => appendFileSync(eventsPath, `${event}\n`);
  const delayResponse = async (response, delayMs) => {
    if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));
    return response;
  };

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      const authorized = request.headers.has("authorization");
      if (url.pathname === "/api/vm" && request.method === "GET") {
        record(`api:list:${authorized ? "authorized" : "unauthorized"}`);
        if (!authorized) return Response.json({ error: "unauthorized" }, { status: 401 });
        if (deleteCompleted && verifyListStatus !== 200) {
          return Response.json({ error: "verify failed" }, { status: verifyListStatus });
        }
        const listedVms = deleteCompleted && extraVmAfterDelete
          ? [...vms, { id: "unrelated-vm", provider: "daytona" }]
          : vms;
        return Response.json({ vms: listedVms });
      }
      if (url.pathname === "/api/vm" && request.method === "POST") {
        record("api:create");
        vms = [
          {
            id: "smoke-vm-1",
            provider: createdProvider,
            status: "running",
            imageVersion: "daytona-test",
          },
        ];
        return delayResponse(Response.json(vms[0]), createDelayMs);
      }
      if (url.pathname === "/api/vm/smoke-vm-1" && request.method === "DELETE") {
        record("api:delete");
        const status = deleteStatuses?.[Math.min(deleteAttempt, deleteStatuses.length - 1)] ?? deleteStatus;
        deleteAttempt += 1;
        if (status !== 200) {
          if (removeVmOnDeleteFailure) {
            vms = [];
            deleteCompleted = true;
          }
          return Response.json({ error: "delete failed" }, { status });
        }
        deleteCompleted = true;
        if (!retainVmAfterDelete) vms = [];
        return delayResponse(Response.json({ ok: true }), deleteDelayMs);
      }
      record(`api:unexpected:${request.method}:${url.pathname}`);
      return Response.json({ error: "not found" }, { status: 404 });
    },
  });

  const childEnv = { ...process.env };
  delete childEnv.DAYTONA_API_KEY;
  delete childEnv.E2B_API_KEY;
  delete childEnv.FREESTYLE_API_KEY;
  Object.assign(childEnv, {
    CMUX_CLOUD_VM_ENV_SOURCE: "process",
    NEXT_PUBLIC_STACK_PROJECT_ID: "fake-project",
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "fake-publishable-key",
    STACK_SECRET_SERVER_KEY: "fake-secret-key",
    FAKE_STACK_EVENTS_PATH: eventsPath,
  });

  try {
    const command = [process.execPath];
    if (timerScalePreload) command.push("--preload", timerScalePreload);
    command.push(
      smokeScript,
      webDir,
      "staging",
      "--create",
      "--provider",
      "daytona",
      "--url",
      server.url.origin,
      "--skip-attach",
    );
    const child = Bun.spawn(
      command,
      {
        env: childEnv,
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    const rawEvents = existsSync(eventsPath) ? readFileSync(eventsPath, "utf8").trim() : "";
    const events = rawEvents ? rawEvents.split("\n") : [];
    return { events, exitCode, stderr, stdout };
  } finally {
    server.stop(true);
    rmSync(fixtureDir, { recursive: true, force: true });
  }
}

test("successful create deletes once and verifies the VM did not leak", async () => {
  const result = await runSmoke();

  expect(result.exitCode).toBe(0);
  expect(result.stderr).toBe("");
  expect(result.events.filter((event) => event === "api:delete")).toHaveLength(1);
  expect(result.events.filter((event) => event === "api:list:authorized")).toHaveLength(2);
  expect(result.events.at(-1)).toBe("stack:delete-user");
  expect(JSON.parse(result.stdout)).toMatchObject({
    destroyed: true,
    leakVerified: true,
    afterCount: 0,
  });
});

test("finally cleanup keeps the test user when VM deletion fails", async () => {
  const result = await runSmoke({ deleteStatus: 500 });

  expect(result.exitCode).toBe(1);
  expect(result.events.filter((event) => event === "api:delete")).toHaveLength(2);
  expect(result.events).not.toContain("stack:delete-user");
  expect(result.stderr).toContain("cleanup_delete_failed_vm=smoke-vm-1");
  expect(result.stderr).toContain("cleanup_needed_vm=smoke-vm-1");
  expect(result.stderr).toContain("cleanup_preserved_user reason=vm_cleanup_unconfirmed");
  expect(result.stderr).not.toContain("fake-stack-user-id");
});

test("a mismatched create response is still cleaned up and checked for leaks", async () => {
  const result = await runSmoke({ createdProvider: "freestyle" });

  expect(result.exitCode).toBe(1);
  expect(result.events.filter((event) => event === "api:delete")).toHaveLength(1);
  expect(result.events.filter((event) => event === "api:list:authorized")).toHaveLength(2);
  expect(result.events.at(-1)).toBe("stack:delete-user");
  expect(result.stderr).toContain("returned provider freestyle, expected daytona");
});

test("post-delete list membership fails the smoke as a leaked VM", async () => {
  const result = await runSmoke({ retainVmAfterDelete: true });

  expect(result.exitCode).toBe(1);
  expect(result.events.filter((event) => event === "api:delete")).toHaveLength(1);
  expect(result.events.filter((event) => event === "api:list:authorized")).toHaveLength(2);
  expect(result.events).not.toContain("stack:delete-user");
  expect(result.stderr).toContain("cleanup_leaked_vm=smoke-vm-1");
  expect(result.stderr).toContain("cleanup_needed_vm=smoke-vm-1");
});

test("a retry 404 verifies absence after an earlier delete response failed", async () => {
  const result = await runSmoke({
    deleteStatuses: [500, 404],
    removeVmOnDeleteFailure: true,
  });

  expect(result.exitCode).toBe(0);
  expect(result.events.filter((event) => event === "api:delete")).toHaveLength(2);
  expect(result.events.filter((event) => event === "api:list:authorized")).toHaveLength(2);
  expect(JSON.parse(result.stdout)).toMatchObject({ leakVerified: true, afterCount: 0 });
});

test("a first-attempt 404 remains a cleanup failure", async () => {
  const result = await runSmoke({ deleteStatuses: [404, 500] });

  expect(result.exitCode).toBe(1);
  expect(result.events.filter((event) => event === "api:delete")).toHaveLength(2);
  expect(result.events.filter((event) => event === "api:list:authorized")).toHaveLength(1);
  expect(result.events).not.toContain("stack:delete-user");
  expect(result.stderr).toContain("cleanup_delete_failed_vm=smoke-vm-1");
});

test("a post-delete list status failure is reported with child diagnostics", async () => {
  const result = await runSmoke({ verifyListStatus: 503 });

  expect(result.exitCode).toBe(1);
  expect(result.events.filter((event) => event === "api:list:authorized")).toHaveLength(2);
  expect(result.events).not.toContain("stack:delete-user");
  expect(result.stderr).toContain("cleanup_verify_failed_vm=smoke-vm-1");
});

test("post-delete count drift fails even when the deleted VM is absent", async () => {
  const result = await runSmoke({ extraVmAfterDelete: true });

  expect(result.exitCode).toBe(1);
  expect(result.events.filter((event) => event === "api:list:authorized")).toHaveLength(2);
  expect(result.events).not.toContain("stack:delete-user");
  expect(result.stderr).toContain("cleanup_leaked_vm=smoke-vm-1");
  expect(result.stderr).toContain("returned 1 VMs, expected 0");
});

test("create request timeout covers the provider create budget", async () => {
  const result = await runSmoke({ createDelayMs: 100, scaleTimers: true });

  expect(result.exitCode).toBe(0);
  expect(result.stderr).toBe("");
  expect(JSON.parse(result.stdout)).toMatchObject({ destroyed: true, leakVerified: true });
});

test("delete request timeout covers the provider delete budget", async () => {
  const result = await runSmoke({ deleteDelayMs: 100, scaleTimers: true });

  expect(result.exitCode).toBe(0);
  expect(result.stderr).toBe("");
  expect(JSON.parse(result.stdout)).toMatchObject({ destroyed: true, leakVerified: true });
});

test("smoke preserves child diagnostics when the event log is missing", async () => {
  const result = await runSmoke({ stackFailure: true });

  expect(result.exitCode).toBe(1);
  expect(result.events).toEqual([]);
  expect(result.stdout).toBe("");
  expect(result.stderr).toContain("fake Stack create failure");
});
