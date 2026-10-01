import { expect, test } from "vite-plus/test";
import { formatRunResult, runModule, type RunResult } from "../src/index.ts";

/** Evaluates the sandbox module in Node with a fake `env.API`. */
async function run(
  code: string,
  api: Record<string, (...args: unknown[]) => unknown>,
): Promise<RunResult> {
  const body = runModule(code)
    .replace(/^import .*\n/, "")
    .replace("export class Run extends WorkerEntrypoint", "class Run");
  // oxlint-disable-next-line no-implied-eval -- the test evaluates the generated sandbox module on purpose
  const Run = new Function(`${body}; return Run;`)() as new () => {
    env: unknown;
    run(): Promise<RunResult>;
  };
  const instance = new Run();
  instance.env = { API: api };
  return instance.run();
}

test("code calls the flat API through mux.* and returns value and logs", async () => {
  const calls: unknown[] = [];
  const result = await run(
    `const [m] = await mux.machines.list();
     const a = await mux.agents.spawn({ cwd: "/tmp", prompt: "hi", machine: m.id });
     console.log("spawned", a);
     return a.name;`,
    {
      machinesList: async () => [{ id: "mac", name: "mac", os: "macos", online: true }],
      agentsSpawn: async (options) => {
        calls.push(options);
        return { sessionId: "s1", name: "hi-agent" };
      },
    },
  );
  expect(result).toEqual({
    ok: true,
    value: "hi-agent",
    logs: ['spawned {"sessionId":"s1","name":"hi-agent"}'],
  });
  expect(calls).toEqual([{ cwd: "/tmp", prompt: "hi", machine: "mac" }]);
});

test("a thrown error comes back as a result, with logs so far", async () => {
  const result = await run(`console.log("before"); await mux.agents.list();`, {
    agentsList: async () => {
      throw new Error("no machine is connected");
    },
  });
  expect(result.ok).toBe(false);
  expect(result.error).toContain("no machine is connected");
  expect(result.logs).toEqual(["before"]);
});

test("large run results are truncated with a count", () => {
  const text = formatRunResult({ ok: true, value: "x".repeat(50), logs: [] }, 20);
  expect(text).toMatch(/^.{20}… \(\d+ more characters\)$/);
});
