#!/usr/bin/env bun
/**
 * How fast a Cloud machine's pause and resume reach a subscriber of its pushed state, with no polling: the socket
 * the Cloud app server opens (GET /v1/cloud/machines/{machine}/state on the platform, cmux-platform MachineState.ts).
 *
 *   bun scripts/cmux-next/cloud-state-latency.ts --backend prod --credentials ~/.secrets/cmuxterm-prod.env
 *   bun scripts/cmux-next/cloud-state-latency.ts --backend prod --credentials F --machine vm_... --rounds 5
 *
 * It signs in as the agent test account (as cloud-journey.ts), makes a machine (or uses --machine, kept), opens the
 * state socket, and per round times a pause and a resume: from the call to the first pushed frame of the change
 * (`pausing`, `starting`) and to the pushed end state (`paused`, `running`). For each end state it also prints the
 * push lag: the frame's arrival minus the record's own updated_at (the commit time on the backend's clock, so a
 * few ms of clock skew are in it). The machine it made is deleted at the end unless --keep.
 *
 * Secrets come from the environment or the --credentials file, go only into headers, and are never printed.
 */
import { readFileSync } from "node:fs";
import { STACK, STACK_API, readEnvFile, resolveBackend } from "./cloud-journey";

const arg = (name: string, argv: string[]) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

type Frame = { v: 1; t: string; machine?: string; revision?: number; state?: any };

async function main(argv = process.argv.slice(2)): Promise<number> {
  const backend = resolveBackend(arg("--backend", argv) ?? "prod", arg("--api", argv));
  const credFile = arg("--credentials", argv);
  const creds = credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {};
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL ?? creds.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? creds.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
  const rounds = Number(arg("--rounds", argv) ?? 3);
  const keep = argv.includes("--keep");
  const team = arg("--team", argv);
  let machine = arg("--machine", argv);
  const made = !machine;

  const config = await (await fetch(`${backend.api}/v1/client-config`).catch(() => null))?.json().catch(() => null);
  const platform: string = arg("--platform", argv) ?? config?.platform_origin ?? "https://cmux-platform-production.debussy.workers.dev";

  const stack = STACK[backend.stack];
  const signIn = await fetch(`${STACK_API}/api/v1/auth/password/sign-in`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-stack-access-type": "client",
      "x-stack-project-id": stack.project,
      ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
    },
    body: JSON.stringify({ email, password }),
  });
  const session = (await signIn.json()) as { access_token?: string };
  if (signIn.status !== 200 || !session.access_token) throw new Error(`Stack sign-in HTTP ${signIn.status}`);
  const headers = { authorization: `Bearer ${session.access_token}`, ...(team ? { "x-cmux-team": team } : {}) };
  const call = async (path: string, body: unknown) => {
    const r = await fetch(`${backend.api}${path}`, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify(body) });
    const j = (await r.json().catch(() => ({}))) as any;
    if (r.status !== 200 || j.ok === false) throw new Error(`${(body as any).op}: HTTP ${r.status} ${JSON.stringify(j.error ?? j).slice(0, 300)}`);
    return j.value;
  };
  const op = (name: string, params: unknown) => call("/v1/ops", { op: name, params, idempotency_key: `state-latency-${crypto.randomUUID()}` });
  const read = (name: string, params: unknown) => call("/v1/read", { op: name, params });

  await op("user.ensure", {});
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  try {
    if (!machine) {
      const v = await op("cloud.machine.create", { name: "state latency", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } });
      machine = v.machine.id as string;
      console.log(`created ${machine}`);
    }
    // The harness waits for the machine to run (not the product path); then nothing below reads it.
    for (let t0 = Date.now(); ; ) {
      const m = await read("cloud.machine.get", { machine });
      if (m.status === "running") break;
      if (m.status === "paused") await op("cloud.machine.start", { machine });
      if (m.status === "failed") throw new Error(`machine failed: ${JSON.stringify(m.error)}`);
      if (Date.now() - t0 > 300_000) throw new Error(`still ${m.status} after 300 s`);
      await sleep(1000);
    }

    const frames: Array<{ at: number; f: Frame }> = [];
    const waiters: Array<() => void> = [];
    const ws = new WebSocket(`${platform.replace(/^http/, "ws")}/v1/cloud/machines/${machine}/state`, { headers } as any);
    await new Promise<void>((resolve, reject) => {
      ws.addEventListener("open", () => resolve(), { once: true });
      ws.addEventListener("error", () => reject(new Error("the state socket did not open")), { once: true });
    });
    ws.addEventListener("message", (e) => {
      frames.push({ at: Date.now(), f: JSON.parse(String(e.data)) });
      for (const w of waiters.splice(0)) w();
    });
    ws.addEventListener("close", (e) => console.log(`socket closed ${e.code} ${e.reason}`));
    const keepalive = setInterval(() => ws.send(JSON.stringify({ v: 1, t: "ping" })), 20_000);
    const pushed = (status: string, after: number, budget: number) =>
      new Promise<{ at: number; f: Frame }>((resolve, reject) => {
        const check = () => {
          const hit = frames.find((x) => x.at >= after && x.f.t === "state" && x.f.state?.status === status);
          if (hit) return resolve(hit);
          if (Date.now() - after > budget) return reject(new Error(`no ${status} push within ${budget} ms`));
          waiters.push(check);
          setTimeout(check, 250);
        };
        check();
      });
    await new Promise<void>((r) => (frames.length ? r() : waiters.push(r)));
    console.log(`socket open; first frame revision ${frames[0]!.f.revision} status ${frames[0]!.f.state?.status}`);

    const rows: string[] = [];
    const ms = (n: number) => `${n} ms`;
    for (let i = 1; i <= rounds; i++) {
      for (const [verb, opName, changing, done] of [
        ["pause", "cloud.machine.pause", "pausing", "paused"],
        ["resume", "cloud.machine.start", "starting", "running"],
      ] as const) {
        const t0 = Date.now();
        const answered = op(opName, { machine }).then(() => Date.now());
        const first = await pushed(changing, t0, 30_000);
        const end = await pushed(done, t0, 300_000);
        const callMs = (await answered) - t0;
        const updated = Number(end.f.state?.record?.updated_at);
        const lag = Number.isFinite(updated) && updated > 0 ? end.at - updated : NaN;
        rows.push(`| ${i} | ${verb} | ${ms(callMs)} | ${ms(first.at - t0)} | ${ms(end.at - t0)} | ${Number.isNaN(lag) ? "?" : ms(lag)} |`);
        console.log(rows.at(-1));
      }
    }
    clearInterval(keepalive);
    ws.close(1000, "done");
    console.log(`\n${backend.name}, platform ${platform}, machine ${machine}\n`);
    console.log("| round | change | call answered | first push (changing) | end-state push | end push lag after commit |");
    console.log("| --- | --- | --- | --- | --- | --- |");
    for (const r of rows) console.log(r);
    return 0;
  } finally {
    if (made && machine && !keep) {
      await op("cloud.machine.delete", { machine }).then(
        () => console.log(`deleted ${machine}`),
        (e) => console.log(`delete ${machine} failed: ${String(e).slice(0, 200)}`),
      );
    }
  }
}

if (import.meta.main) process.exit(await main().catch((e) => (console.error(String(e).slice(0, 500)), 1)));
