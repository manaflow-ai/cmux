import { describe, it, expect, afterEach } from "bun:test";
import { tmpdir } from "os";
import { HookRegistry, HOOK_TIMEOUT_MS } from "@/hooks/index";
import type { HookConfig, HookEvent, HookResponse } from "@/core/types";

// Track tmp files for cleanup
const tmpFiles: string[] = [];

async function writeTmpHook(script: string): Promise<string> {
  const path = `${tmpdir()}/hook-${crypto.randomUUID()}.sh`;
  await Bun.write(path, `#!/bin/sh\n${script}\n`);
  await Bun.spawn(["chmod", "+x", path]).exited;
  tmpFiles.push(path);
  return path;
}

afterEach(async () => {
  for (const f of tmpFiles.splice(0)) {
    try { await Bun.spawn(["rm", "-f", f]).exited; } catch { /* ignore */ }
  }
});

const warnings: string[] = [];
function makeLogger() {
  warnings.length = 0;
  return (level: string, msg: string) => {
    if (level === "warn") warnings.push(msg);
  };
}

function makeEvent(overrides: Partial<HookEvent> = {}): HookEvent {
  return {
    event: "tool.pre",
    sessionId: "sess-1",
    data: { tool: "bash", input: "ls" },
    ...overrides,
  };
}

// Subclass that overrides the timeout for speed in tests
class FastTimeoutRegistry extends HookRegistry {
  protected override async runHook(
    hook: HookConfig,
    event: HookEvent,
    payloadJson: string,
  ): Promise<HookResponse> {
    return super.runHook(hook, event, payloadJson, 300 /* ms */);
  }
}

describe("HookRegistry", () => {
  it("returns pass when hook prints {action:'pass'}", async () => {
    const log = makeLogger();
    const hookPath = await writeTmpHook(`echo '{"action":"pass"}'`);
    const cfg: HookConfig = { event: "tool.pre", command: hookPath };
    const registry = new HookRegistry([cfg], log);
    const resp = await registry.fire(makeEvent());
    expect(resp.action).toBe("pass");
  });

  it("returns block immediately and skips subsequent hooks", async () => {
    const log = makeLogger();

    // First hook: block
    const blockPath = await writeTmpHook(`echo '{"action":"block","message":"no"}'`);

    // Second hook: writes a sentinel file to prove it was (not) invoked
    const sentinelFile = `${tmpdir()}/sentinel-${crypto.randomUUID()}`;
    const secondPath = await writeTmpHook(`touch ${sentinelFile} && echo '{"action":"pass"}'`);
    tmpFiles.push(sentinelFile);

    const cfgs: HookConfig[] = [
      { event: "tool.pre", command: blockPath },
      { event: "tool.pre", command: secondPath },
    ];
    const registry = new HookRegistry(cfgs, log);
    const resp = await registry.fire(makeEvent());

    expect(resp.action).toBe("block");
    expect(resp.message).toBe("no");
    // Second hook must NOT have run
    expect(await Bun.file(sentinelFile).exists()).toBe(false);
  });

  it("transforms data and chains the transformed data to the next hook", async () => {
    const log = makeLogger();

    // First hook: transform with new data
    const transformPath = await writeTmpHook(
      `echo '{"action":"transform","data":{"transformed":true}}'`,
    );

    // Second hook: save its received stdin so we can verify the chained payload
    const captureFile = `${tmpdir()}/capture-${crypto.randomUUID()}`;
    tmpFiles.push(captureFile);
    const capturePath = await writeTmpHook(
      `cat > ${captureFile} && echo '{"action":"pass"}'`,
    );

    const cfgs: HookConfig[] = [
      { event: "tool.pre", command: transformPath },
      { event: "tool.pre", command: capturePath },
    ];
    const registry = new HookRegistry(cfgs, log);
    const resp = await registry.fire(makeEvent());

    expect(resp.action).toBe("pass");

    // The second hook received the transformed payload on stdin
    const captured = await Bun.file(captureFile).text();
    const parsedCapture = JSON.parse(captured) as HookEvent;
    expect(parsedCapture.data).toEqual({ transformed: true });
  });

  it("treats a hook that times out as pass with a warning", async () => {
    const log = makeLogger();
    // Hook that sleeps longer than the fast timeout (300 ms)
    const sleepPath = await writeTmpHook(`sleep 60`);
    const cfg: HookConfig = { event: "tool.pre", command: sleepPath };
    const registry = new FastTimeoutRegistry([cfg], log);
    const resp = await registry.fire(makeEvent());
    expect(resp.action).toBe("pass");
    expect(warnings.some((w) => w.includes("timed out"))).toBe(true);
  }, 5_000);

  it("treats garbage stdout as pass with a warning", async () => {
    const log = makeLogger();
    const garbagePath = await writeTmpHook(`printf 'not json at all!!!'`);
    const cfg: HookConfig = { event: "tool.pre", command: garbagePath };
    const registry = new HookRegistry([cfg], log);
    const resp = await registry.fire(makeEvent());
    expect(resp.action).toBe("pass");
    expect(warnings.length).toBeGreaterThan(0);
  });

  it("matcher regex narrows which hooks run", async () => {
    const log = makeLogger();
    const sentinelFile = `${tmpdir()}/sentinel-matcher-${crypto.randomUUID()}`;
    tmpFiles.push(sentinelFile);

    // Hook that only matches events containing "bash" as the tool
    const hookPath = await writeTmpHook(
      `touch ${sentinelFile} && echo '{"action":"pass"}'`,
    );

    const cfgs: HookConfig[] = [
      { event: "tool.pre", command: hookPath, matcher: '"tool":"bash"' },
    ];
    const registry = new HookRegistry(cfgs, log);

    // Fire with a non-matching event (different tool)
    await registry.fire(makeEvent({ data: { tool: "read_file", input: "/etc/hosts" } }));
    expect(await Bun.file(sentinelFile).exists()).toBe(false); // hook did NOT run

    // Fire with a matching event
    await registry.fire(makeEvent({ data: { tool: "bash", input: "ls" } }));
    expect(await Bun.file(sentinelFile).exists()).toBe(true); // hook DID run
  });

  it("only fires hooks whose event name matches", async () => {
    const log = makeLogger();
    const sentinelFile = `${tmpdir()}/sentinel-event-${crypto.randomUUID()}`;
    tmpFiles.push(sentinelFile);

    const hookPath = await writeTmpHook(
      `touch ${sentinelFile} && echo '{"action":"pass"}'`,
    );
    const cfg: HookConfig = { event: "session.start", command: hookPath };
    const registry = new HookRegistry([cfg], log);

    // Fire a different event — hook must NOT run
    await registry.fire(makeEvent({ event: "tool.pre" }));
    expect(await Bun.file(sentinelFile).exists()).toBe(false);

    // Fire the matching event — hook MUST run
    await registry.fire(makeEvent({ event: "session.start" }));
    expect(await Bun.file(sentinelFile).exists()).toBe(true);
  });
});
