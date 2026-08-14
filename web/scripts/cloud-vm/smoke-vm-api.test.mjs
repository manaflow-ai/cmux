import { expect, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const smokeScript = path.join(scriptDir, "smoke-vm-api.mjs");

function makeFakeWebDir(fixtureDir) {
  const webDir = path.join(fixtureDir, "web");
  const stackModuleDir = path.join(webDir, "node_modules", "@stackframe", "js");
  mkdirSync(stackModuleDir, { recursive: true });
  writeFileSync(path.join(webDir, "package.json"), JSON.stringify({ private: true, type: "module" }));
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
    record("stack:create-user");
    return new FakeUser();
  }
}
`,
  );
  return webDir;
}

async function runSmoke({
  createdProvider = "daytona",
  deleteStatus = 200,
  retainVmAfterDelete = false,
} = {}) {
  const fixtureDir = mkdtempSync(path.join(tmpdir(), "cmux-cloud-vm-smoke-test-"));
  const eventsPath = path.join(fixtureDir, "events.log");
  const webDir = makeFakeWebDir(fixtureDir);
  let vms = [];
  const record = (event) => appendFileSync(eventsPath, `${event}\n`);

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      const authorized = request.headers.has("authorization");
      if (url.pathname === "/api/vm" && request.method === "GET") {
        record(`api:list:${authorized ? "authorized" : "unauthorized"}`);
        if (!authorized) return Response.json({ error: "unauthorized" }, { status: 401 });
        return Response.json({ vms });
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
        return Response.json(vms[0]);
      }
      if (url.pathname === "/api/vm/smoke-vm-1" && request.method === "DELETE") {
        record("api:delete");
        if (deleteStatus !== 200) {
          return Response.json({ error: "delete failed" }, { status: deleteStatus });
        }
        if (!retainVmAfterDelete) vms = [];
        return Response.json({ ok: true });
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
    const child = Bun.spawn(
      [
        process.execPath,
        smokeScript,
        webDir,
        "staging",
        "--create",
        "--provider",
        "daytona",
        "--url",
        server.url.origin,
        "--skip-attach",
      ],
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
    const events = readFileSync(eventsPath, "utf8").trim().split("\n");
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

test("finally cleanup is bounded and still deletes the test user when VM deletion fails", async () => {
  const result = await runSmoke({ deleteStatus: 500 });

  expect(result.exitCode).toBe(1);
  expect(result.events.filter((event) => event === "api:delete")).toHaveLength(2);
  expect(result.events.at(-1)).toBe("stack:delete-user");
  expect(result.stderr).toContain("cleanup_delete_failed_vm=smoke-vm-1");
  expect(result.stderr).toContain("cleanup_needed_vm=smoke-vm-1");
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
  expect(result.events.at(-1)).toBe("stack:delete-user");
  expect(result.stderr).toContain("cleanup_leaked_vm=smoke-vm-1");
  expect(result.stderr).toContain("cleanup_needed_vm=smoke-vm-1");
});
