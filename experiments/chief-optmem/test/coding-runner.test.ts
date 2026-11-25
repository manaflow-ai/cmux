import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { agentCommand, detached, runCodingTask, shellQuote } from "../src/coding/runner.ts";
import { FreestyleDriver, type VmDriver, type VmExecResult } from "../src/coding/vm.ts";

/**
 * A VM that runs commands in a real local bash, in its own directory
 * standing in for /tmp/chief and HOME. Agent CLIs are replaced by quote-free
 * stand-ins (they are spliced inside an already quoted string), so
 * the detached start, the done file and the quoting run for real.
 */
class LocalShellVm implements VmDriver {
  created: Array<{ label: string; maxRunSeconds: number }> = [];
  destroyed: Array<string> = [];
  envs: Array<Record<string, string> | undefined> = [];
  readonly root = mkdtempSync(join(tmpdir(), "chief-vm-"));

  async create(options: { label: string; maxRunSeconds: number }) {
    this.created.push(options);
    return { id: "vm_local" };
  }

  async exec(
    _id: string,
    command: string,
    options: { env?: Record<string, string>; timeoutMs: number },
  ): Promise<VmExecResult> {
    this.envs.push(options.env);
    const local = command
      .replaceAll("/tmp/chief", join(this.root, "chief"))
      // macOS has no setsid binary; the Linux VM does.
      .replaceAll("setsid bash", "nohup bash")
      .replaceAll("claude --version", "echo claude-9.9.9")
      .replaceAll("claude -p --dangerously-skip-permissions", "printf %s");
    try {
      const stdout = execFileSync("bash", ["-c", local], {
        env: { PATH: process.env.PATH ?? "", ...options.env, HOME: this.root },
        encoding: "utf8",
        timeout: options.timeoutMs,
      });
      return { statusCode: 0, stdout, stderr: "" };
    } catch (e) {
      const err = e as { status?: number; stdout?: string; stderr?: string };
      return { statusCode: err.status ?? 1, stdout: err.stdout ?? "", stderr: err.stderr ?? "" };
    }
  }

  async destroy(id: string) {
    this.destroyed.push(id);
  }
}

const options = {
  maxRunSeconds: 30,
  sleep: (ms: number) => new Promise<void>((r) => setTimeout(r, Math.min(ms, 50))),
  pollMs: { initial: 20, maximum: 50 },
};

describe("coding worker runner", () => {
  it("runs a dry run end to end on a real shell and deletes the VM", async () => {
    const vm = new LocalShellVm();
    const outcome = await runCodingTask(
      vm,
      { label: "w1", harness: "claude", prompt: "unused", dryRun: true },
      options,
    );
    expect(outcome).toEqual({ status: "done", answer: "claude-9.9.9", exitCode: 0 });
    expect(vm.created).toEqual([{ label: "w1", maxRunSeconds: 30 }]);
    expect(vm.destroyed).toEqual(["vm_local"]);
  });

  it("passes a prompt with quotes intact and the credential only through exec env", async () => {
    const vm = new LocalShellVm();
    const prompt = `fix "it's" $HOME \`now\``;
    const outcome = await runCodingTask(
      vm,
      { label: "w2", harness: "claude", prompt, credentialEnv: { CODEROUTER_TOKEN: "t0k" } },
      options,
    );
    expect(outcome).toEqual({ status: "done", answer: prompt, exitCode: 0 });
    expect(vm.envs[0]).toEqual({ HOME: "/home/ubuntu", CODEROUTER_TOKEN: "t0k" });
    expect(vm.envs.slice(1).every((e) => e === undefined)).toBe(true);
  });

  it("refuses a real task without a model credential and creates no VM", async () => {
    const vm = new LocalShellVm();
    const outcome = await runCodingTask(vm, { label: "w3", harness: "codex", prompt: "x" }, options);
    expect(outcome.status).toBe("refused");
    expect(vm.created).toEqual([]);
  });

  it("refuses without a Freestyle key and never calls the network", async () => {
    let called = false;
    const driver = new FreestyleDriver(undefined, "sh-x", (async () => {
      called = true;
      return new Response("{}");
    }) as typeof fetch);
    const outcome = await runCodingTask(driver, { label: "w4", harness: "claude", prompt: "x", dryRun: true }, options);
    expect(outcome).toEqual({
      status: "refused",
      reason: "No Freestyle key in this environment, so coding workers cannot start.",
    });
    expect(called).toBe(false);
  });

  it("gives up after the run budget and still deletes the VM", async () => {
    const destroyed: Array<string> = [];
    const stuck: VmDriver = {
      create: async () => ({ id: "vm_stuck" }),
      exec: async () => ({ statusCode: 0, stdout: "", stderr: "" }),
      destroy: async (id) => void destroyed.push(id),
    };
    const outcome = await runCodingTask(
      stuck,
      { label: "w5", harness: "claude", prompt: "x", dryRun: true },
      { ...options, maxRunSeconds: 0.1 },
    );
    expect(outcome).toEqual({ status: "failed", reason: "no answer within 0.1 s" });
    expect(destroyed).toEqual(["vm_stuck"]);
  });

  it("builds the commands it documents", () => {
    expect(agentCommand({ label: "x", harness: "codex", prompt: "a'b" })).toBe(`codex exec --yolo 'a'"'"'b'`);
    expect(shellQuote("x")).toBe("'x'");
    expect(detached("true")).toContain("setsid bash -c");
  });
});
