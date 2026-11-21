/**
 * The deterministic model plane of the self-test: the shared model stub (tests/fixtures/model-stub, with its queued
 * faults: rate limits, auth errors, overloads, delays) on this computer, and `cmux inference gateway` processes in
 * front of it, which a scenario starts, stops and doubles to drive gateway offline, reconnect and two gateways for one
 * owner. Only processes this run started are ever stopped, by their own pid.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { MODEL_STUB_PY } from "../cloud-journey";

export type StubFault = { status?: number; type?: string; message?: string; retry_after?: number; delay_ms?: number; count?: number; path?: string };

export type LocalStub = {
  url: string;
  nonce: string;
  setFaults(faults: StubFault[]): Promise<number>;
  clearFaults(): Promise<number>;
  rows(): Promise<any[]>;
  stop(): Promise<void>;
};

/** Start the stub on 127.0.0.1 with a script; resolves once it printed its ready line. */
export function startLocalStub(dir: string, script: unknown, nonce: string, python = "python3"): Promise<LocalStub> {
  const scriptFile = path.join(dir, "stub-script.json");
  writeFileSync(scriptFile, JSON.stringify(script));
  const log = path.join(dir, "stub.jsonl");
  const child = spawn(python, [MODEL_STUB_PY, "--port", "0", "--script", scriptFile, "--nonce", nonce, "--log", log], { stdio: ["ignore", "pipe", "pipe"] });
  return new Promise((resolve, reject) => {
    let out = "";
    let err = "";
    child.stderr!.setEncoding("utf8").on("data", (c: string) => (err += c));
    child.on("error", reject);
    child.on("exit", (code) => reject(new Error(`model stub exited ${code}: ${err.slice(-300)}`)));
    child.stdout!.setEncoding("utf8").on("data", (c: string) => {
      out += c;
      const nl = out.indexOf("\n");
      if (nl < 0) return;
      const ready = JSON.parse(out.slice(0, nl));
      const url = String(ready.url);
      const control = async (method: string, body?: unknown) => {
        const r = await fetch(`${url}/__stub/faults`, { method, headers: { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
        return r.json() as Promise<any>;
      };
      resolve({
        url,
        nonce,
        setFaults: async (faults) => Number((await control("POST", { faults })).pending),
        clearFaults: async () => Number((await control("DELETE")).cleared),
        rows: async () => ((await (await fetch(`${url}/__stub/log`)).json()) as any).rows ?? [],
        stop: () => stopChild(child),
      });
    });
  });
}

export function stopChild(child: ChildProcess, graceMs = 5_000): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const kill = setTimeout(() => child.kill("SIGKILL"), graceMs);
    child.once("exit", () => {
      clearTimeout(kill);
      resolve();
    });
    child.kill("SIGTERM");
  });
}

export type Gateway = { id: string; pid: number; log: string; stop(): Promise<void>; running(): boolean; tail(): string };

/**
 * `cmux inference gateway` on this computer as the actor: its token in a 0600 file the gateway reads again on every
 * connect, the upstream the stub (or a URL), `--team` when the actor acts in a shared team.
 */
export function startGateway(cmux: string, env: Record<string, string>, opts: { id: string; api: string; upstream: string; token: string; team?: string | null; personal?: boolean; dir: string }): Gateway {
  const dir = mkdtempSync(path.join(opts.dir, `gateway-${opts.id}-`));
  const tokenFile = path.join(dir, "token");
  writeFileSync(tokenFile, opts.token, { mode: 0o600 });
  const log = path.join(dir, "gateway.log");
  const fd = openSync(log, "a");
  const args = ["inference", "gateway", "--api", opts.api, "--upstream", opts.upstream, "--token-file", tokenFile, ...(opts.team ? ["--team", opts.team] : []), ...(opts.personal ? ["--personal"] : [])];
  const child = spawn(cmux, args, { env, stdio: ["ignore", fd, fd] });
  closeSync(fd);
  return {
    id: opts.id,
    pid: child.pid ?? -1,
    log,
    running: () => child.exitCode === null && child.signalCode === null,
    stop: () => stopChild(child),
    tail: () => {
      try {
        return readFileSync(log, "utf8").slice(-1500);
      } catch {
        return "";
      }
    },
  };
}
