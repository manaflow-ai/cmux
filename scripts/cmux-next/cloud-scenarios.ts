/**
 * Leo's AutoCloud scenarios, run for real against NEXT Cloud's cmux VM API (vm.cmux.dev, vm-staging.cmux.dev):
 * each case makes its own machines, times what a person or an agent would wait for, prices it, and deletes them.
 * docs/cloud/autocloud-scenarios.md is the table these rows fill.
 *
 * Leo, 2026-11-25 09:22Z: "it starts growing its work. starts wanting to build more stuff. how does its work
 * auto-route to a bigger vm instead of your local machine? ... what if the user suddenly wants to compile chromium?
 * and likewise what if the agent wants to do that? what if someone/some agent suddenly wants to manually get a machine?"
 *
 * Cases (--cases a,b,...; default every case but chromium, which runs with --cases chromium or --chromium-minutes N):
 *   manual       a person gets a machine: 2, 8 and 32 vCPU created at once, time to running each
 *   grows        the agent starts building more: 8 busy loops on 2 vCPU, a live grow to 16 vCPU, time until the guest sees it
 *   webapp       compile a web app (create-vite react-ts): install + build on 2 vCPU, grow to 8, clean install + build again,
 *                then the dev server answers on its port
 *   lidclose     the laptop closes mid-turn: a counter keeps running with no client at all, on the default idle timeout
 *                (network idle pauses the VM: CPU work alone does not keep it awake) and on -1
 *   helpers      10 helpers on the parent's agent VM: +1 vCPU and +2 GiB per 2-3 helpers (2 -> 6 vCPU), then a shrink back
 *   fork         fork mid-turn: fork while a writer runs; time to the fork running; the fork has the file
 *   stranded     a VM killed with unsynced writes: stop/start keeps the disk; delete with unsynced bytes is refused or not
 *   conformance  the exec router's conformance suite: the same commands on an agent VM (local) and routed to a work VM
 *                (tree shipped there by tar, run, shipped back), compared on stdout, exit code and the file tree's hashes
 *   fanout       Chromium past one VM: four 32 vCPU machines at once, time until all run
 *   chromium     a 32 vCPU / 64 GiB / 128 GiB machine: fetch --no-history, gn gen, autoninja chrome, time-boxed
 *
 * Price: workers/cmux-vm/src/domain/agents.ts USD_PER_VCPU_HOUR 0.05 and USD_PER_GIB_HOUR 0.0075, over each machine's
 * lifetime at its current size. Keys come from the environment and are never printed. Every machine is made with
 * autoDeleteSeconds as a backstop and deleted by exact id at the end.
 *
 *   CMUX_VM_DOGFOOD_URL=https://vm-staging.cmux.dev CMUX_VM_SMOKE_API_KEY=... \
 *     bun scripts/cmux-next/cloud-scenarios.ts --cases manual,grows --result-file out.json
 */
import { writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const option = (name: string): string | undefined => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const ALL = ["manual", "grows", "webapp", "lidclose", "helpers", "fork", "stranded", "conformance", "fanout"];
const cases = (option("--cases") ?? ALL.join(",")).split(",").map((c) => c.trim()).filter(Boolean);
const chromiumMinutes = Number(option("--chromium-minutes") ?? "60");
const resultFile = option("--result-file");
const base = option("--url") ?? process.env["CMUX_VM_DOGFOOD_URL"] ?? "";
const tenantKey = process.env["CMUX_VM_SMOKE_API_KEY"] ?? "";
const serviceKey = process.env["CMUX_VM_SMOKE_SERVICE_KEY"] ?? "";
const serviceTeam = process.env["CMUX_VM_SMOKE_SERVICE_TEAM"] ?? "";
const useService = tenantKey === "" && serviceKey !== "" && serviceTeam !== "";
const bearer = useService ? serviceKey : tenantKey;
const teamHeaders: Record<string, string> = useService ? { "x-cmux-team-id": serviceTeam } : {};
if (base === "" || bearer === "") {
  console.error("needs CMUX_VM_DOGFOOD_URL and CMUX_VM_SMOKE_API_KEY (or the service key and team)");
  process.exit(2);
}
for (const c of cases) if (![...ALL, "chromium"].includes(c)) { console.error(`unknown case ${c}`); process.exit(2); }
const origin = new URL(base);
const runId = process.env["GITHUB_RUN_ID"] ?? `local-${Date.now()}`;

const USD_PER_VCPU_HOUR = 0.05;
const USD_PER_GIB_HOUR = 0.0075;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const now = () => performance.now();
const secs = (ms: number) => Math.round(ms / 100) / 10;

type Reply = { status: number; body: unknown; text: string };
async function call(method: string, path: string, body?: unknown, timeoutMs = 120_000, headers: Record<string, string> = {}): Promise<Reply> {
  const response = await fetch(new URL(path, origin), {
    method,
    headers: { authorization: `Bearer ${bearer}`, ...teamHeaders, ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
    body: body === undefined ? null : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  let parsed: unknown = null;
  try { parsed = text === "" ? null : JSON.parse(text); } catch { parsed = text; }
  return { status: response.status, body: parsed, text };
}
const field = (v: unknown, k: string): unknown => (typeof v === "object" && v !== null && k in v ? Reflect.get(v, k) : undefined);
const vmPath = (id: string) => `/v1/vms/${encodeURIComponent(id)}`;
function expect(reply: Reply, ok: number[], what: string): unknown {
  if (!ok.includes(reply.status)) throw new Error(`${what}: HTTP ${reply.status} ${reply.text.slice(0, 300)}`);
  return reply.body;
}

// Every machine this run made, with its size over time, for the price and the cleanup.
type Size = { vcpus: number; memoryMib: number };
const machines = new Map<string, { since: number; size: Size; usd: number; gone: boolean }>();
function account(id: string, next?: Size) {
  const m = machines.get(id);
  if (!m || m.gone) return;
  const hours = (now() - m.since) / 3_600_000;
  m.usd += hours * (m.size.vcpus * USD_PER_VCPU_HOUR + (m.size.memoryMib / 1024) * USD_PER_GIB_HOUR);
  m.since = now();
  if (next) m.size = next;
}
const usdOf = (ids: string[]) => {
  ids.forEach((id) => account(id));
  return Math.round(ids.reduce((s, id) => s + (machines.get(id)?.usd ?? 0), 0) * 10000) / 10000;
};

async function create(name: string, resources: Partial<Size & { diskMib: number }>, extra: Record<string, unknown> = {}): Promise<{ id: string; createMs: number; runningMs: number }> {
  const started = now();
  const reply = await call("POST", "/v1/vms", {
    displayName: `scenarios ${name}`.slice(0, 100),
    idleTimeoutSeconds: -1,
    autoDeleteSeconds: 3 * 3600,
    labels: { purpose: "scenarios", run: runId.slice(0, 63), ...(useService ? { role: "chief" } : {}) },
    resources,
    ...extra,
  }, 6 * 60_000, { "idempotency-key": `scenarios-${runId}-${name}` });
  const body = expect(reply, [201], `create ${name}`);
  const id = String(field(body, "id"));
  const createMs = now() - started;
  const got = field(body, "resources");
  machines.set(id, { since: now(), size: { vcpus: Number(field(got, "vcpus") ?? resources.vcpus ?? 2), memoryMib: Number(field(got, "memoryMib") ?? resources.memoryMib ?? 4096) }, usd: 0, gone: false });
  await waitState(id, "running", 10 * 60_000);
  return { id, createMs, runningMs: now() - started };
}
async function waitState(id: string, state: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const r = await call("GET", vmPath(id));
    if (r.status === 200 && field(r.body, "state") === state) return;
    if (Date.now() > deadline) throw new Error(`${id} not ${state} after ${timeoutMs}ms (last ${String(field(r.body, "state") ?? r.status)})`);
    await sleep(1_500);
  }
}
async function remove(id: string) {
  account(id);
  const m = machines.get(id);
  const r = await call("DELETE", vmPath(id)).catch(() => ({ status: 0 } as Reply));
  if (m && (r.status === 200 || r.status === 202 || r.status === 204 || r.status === 404)) m.gone = true;
  return r;
}
async function exec(id: string, command: string, timeoutMs = 60_000, stdin?: Buffer) {
  const r = await call("POST", `${vmPath(id)}/exec`, { command, timeoutMs, ...(stdin ? { stdinBase64: stdin.toString("base64") } : {}) }, timeoutMs + 60_000);
  const b = expect(r, [200], "exec");
  return { exitCode: field(b, "exitCode") as number | null, stdout: String(field(b, "stdout") ?? ""), stderr: String(field(b, "stderr") ?? "") };
}
const PROFILE = "for f in /etc/profile.d/*.sh; do [ -r \"$f\" ] && . \"$f\"; done; export PATH=\"$HOME/.local/bin:$HOME/.bun/bin:$PATH\";";
/** Long work past exec's 5-minute cap: start it detached, then poll its exit file. */
async function long(id: string, name: string, command: string, timeoutMs: number): Promise<{ rc: number | null; ms: number; tail: string }> {
  const started = now();
  const script = `${PROFILE} cd "$HOME"; ( ${command} ) > /tmp/${name}.log 2>&1; echo $? > /tmp/${name}.rc`;
  await exec(id, `rm -f /tmp/${name}.rc; nohup bash -c ${JSON.stringify(script)} >/dev/null 2>&1 & echo started`);
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    await sleep(5_000);
    const r = await exec(id, `cat /tmp/${name}.rc 2>/dev/null || echo running`).catch(() => ({ stdout: "running" }));
    const s = r.stdout.trim();
    if (s !== "running") {
      const tail = (await exec(id, `tail -c 1500 /tmp/${name}.log`)).stdout;
      return { rc: Number(s), ms: now() - started, tail };
    }
    if (Date.now() > deadline) {
      const tail = (await exec(id, `tail -c 1500 /tmp/${name}.log`)).stdout;
      return { rc: null, ms: now() - started, tail };
    }
  }
}
async function resize(id: string, size: Size): Promise<Reply> {
  const r = await call("POST", `${vmPath(id)}/resize`, { resources: size }, 5 * 60_000);
  if (r.status === 200) account(id, size);
  return r;
}
async function nproc(id: string) { return Number((await exec(id, "nproc")).stdout.trim()); }

type Row = { case: string; ok: boolean; what: string; timeToScaleS?: number | null; usd: number; numbers: Record<string, unknown>; gaps: string[] };
const rows: Row[] = [];

async function runCase(name: string, body: (ids: string[], numbers: Record<string, unknown>, gaps: string[]) => Promise<{ ok: boolean; what: string; scaleS?: number | null }>) {
  const ids: string[] = [];
  const numbers: Record<string, unknown> = {};
  const gaps: string[] = [];
  const started = now();
  let row: Row;
  try {
    const r = await body(ids, numbers, gaps);
    row = { case: name, ok: r.ok, what: r.what, timeToScaleS: r.scaleS ?? null, usd: 0, numbers, gaps };
  } catch (error) {
    row = { case: name, ok: false, what: `error: ${String(error instanceof Error ? error.message : error).slice(0, 500)}`, usd: 0, numbers, gaps };
  }
  for (const id of ids) await remove(id);
  row.usd = usdOf(ids);
  numbers["wallS"] = secs(now() - started);
  rows.push(row);
  console.error(`case ${name}: ${row.ok ? "green" : "red"}: ${row.what}`);
}

const CASES: Record<string, () => Promise<void>> = {
  manual: () => runCase("manual", async (ids, n) => {
    const sizes = [2, 8, 32];
    const made = await Promise.allSettled(sizes.map((v) => create(`manual-${v}`, { vcpus: v, memoryMib: Math.min(65536, v * 2048 < 4096 ? 4096 : v * 2048) })));
    const out: string[] = [];
    made.forEach((m, i) => {
      if (m.status === "fulfilled") { ids.push(m.value.id); n[`running_${sizes[i]}vcpu_s`] = secs(m.value.runningMs); out.push(`${sizes[i]} vCPU running in ${secs(m.value.runningMs)} s`); }
      else out.push(`${sizes[i]} vCPU refused: ${String(m.reason).slice(0, 160)}`);
    });
    const worst = Math.max(...made.map((m) => (m.status === "fulfilled" ? m.value.runningMs : Infinity)));
    return { ok: made.every((m) => m.status === "fulfilled"), what: out.join("; "), scaleS: Number.isFinite(worst) ? secs(worst) : null };
  }),

  grows: () => runCase("grows", async (ids, n) => {
    const vm = await create("grows", { vcpus: 2, memoryMib: 4096 });
    ids.push(vm.id);
    await exec(vm.id, "for i in $(seq 1 8); do nohup timeout 600 sh -c 'while :; do :; done' >/dev/null 2>&1 & done; echo ok");
    await sleep(5_000);
    n["load1_before"] = (await exec(vm.id, "cut -d' ' -f1 /proc/loadavg")).stdout.trim();
    const t = now();
    const r = await resize(vm.id, { vcpus: 16, memoryMib: 32768 });
    n["resize_http"] = r.status;
    n["resize_call_s"] = secs(now() - t);
    if (r.status !== 200) return { ok: false, what: `grow 2 -> 16 vCPU under load refused: HTTP ${r.status} ${r.text.slice(0, 200)}` };
    let seen = 0;
    const deadline = Date.now() + 120_000;
    while ((seen = await nproc(vm.id)) < 16 && Date.now() < deadline) await sleep(1_000);
    const scale = now() - t;
    n["guest_nproc"] = seen;
    n["mem_total_kib"] = (await exec(vm.id, "grep MemTotal /proc/meminfo | awk '{print $2}'")).stdout.trim();
    return { ok: seen >= 16, what: `8 busy loops on 2 vCPU; grow to 16 vCPU / 32 GiB live, guest saw ${seen} CPUs ${secs(scale)} s after the call, no reboot`, scaleS: secs(scale) };
  }),

  webapp: () => runCase("webapp", async (ids, n, gaps) => {
    const vm = await create("webapp", { vcpus: 2, memoryMib: 4096 });
    ids.push(vm.id);
    const tool = (await exec(vm.id, `${PROFILE} command -v npm || command -v bun || echo none`)).stdout.trim();
    n["tool"] = tool;
    if (tool === "none") return { ok: false, what: "no npm or bun in the image" };
    const npx = tool.endsWith("bun") ? "bunx" : "npx -y";
    const pm = tool.endsWith("bun") ? "bun" : "npm";
    const first = await long(vm.id, "web1", `${npx} create-vite@latest app --template react-ts && cd app && ${pm} install && ${pm} run build`, 15 * 60_000);
    n["install_build_2vcpu_s"] = secs(first.ms);
    if (first.rc !== 0) return { ok: false, what: `create-vite install+build on 2 vCPU failed rc=${first.rc}: ${first.tail.slice(-300)}` };
    const t = now();
    const r = await resize(vm.id, { vcpus: 8, memoryMib: 16384 });
    while ((await nproc(vm.id)) < 8 && now() - t < 120_000) await sleep(1_000);
    const scale = now() - t;
    n["grow_to_8_s"] = secs(scale);
    if (r.status !== 200) gaps.push(`grow refused HTTP ${r.status}`);
    const second = await long(vm.id, "web2", `cd app && rm -rf node_modules dist && ${pm} install && ${pm} run build`, 15 * 60_000);
    n["install_build_8vcpu_s"] = secs(second.ms);
    await exec(vm.id, `${PROFILE} cd "$HOME/app" && nohup ${pm} run dev -- --port 5173 --host 127.0.0.1 >/tmp/dev.log 2>&1 & echo ok`);
    let served = false;
    const t2 = now();
    while (!served && now() - t2 < 60_000) {
      served = (await exec(vm.id, "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:5173/ || true")).stdout.trim() === "200";
      if (!served) await sleep(1_000);
    }
    n["dev_server_first_200_s"] = secs(now() - t2);
    return { ok: second.rc === 0 && served, what: `install+build ${secs(first.ms)} s on 2 vCPU, grow to 8 in ${secs(scale)} s, clean install+build ${secs(second.ms)} s on 8 vCPU; dev server ${served ? "answered 200" : "did not answer"} on :5173`, scaleS: secs(scale) };
  }),

  lidclose: () => runCase("lidclose", async (ids, n, gaps) => {
    // No client at all for 150 s: the only thing a closed laptop changes on the VM side. One VM with the default
    // idle timeout the app sets (60 s here) and one with -1.
    const [a, b] = await Promise.all([create("lid-idle60", { vcpus: 2 }, { idleTimeoutSeconds: 60 }), create("lid-never", { vcpus: 2 })]);
    ids.push(a.id, b.id);
    const counter = "nohup sh -c 'i=0; while :; do i=$((i+1)); echo $i > /tmp/count; sleep 1; done' >/dev/null 2>&1 & echo ok";
    await Promise.all([exec(a.id, counter), exec(b.id, counter)]);
    await sleep(150_000);
    const states = await Promise.all([a.id, b.id].map(async (id) => String(field((await call("GET", vmPath(id))).body, "state"))));
    const counts = await Promise.all([a.id, b.id].map(async (id) => Number((await exec(id, "cat /tmp/count")).stdout.trim())));
    n["idle60_state_after_150s"] = states[0];
    n["idle60_count"] = counts[0];
    n["never_state_after_150s"] = states[1];
    n["never_count"] = counts[1];
    const idleKept = counts[0] >= 140;
    if (!idleKept) gaps.push(`with idleTimeoutSeconds 60 a running job stopped counting at ${counts[0]} s (state ${states[0]}): CPU work does not keep a VM awake, so a mid-turn build pauses once the laptop goes away`);
    return { ok: counts[1] >= 140 && idleKept, what: `no client for 150 s: idle-timeout -1 counted ${counts[1]} s (${states[1]}); idle-timeout 60 counted ${counts[0]} s (${states[0]})` };
  }),

  helpers: () => runCase("helpers", async (ids, n, gaps) => {
    const vm = await create("helpers-parent", { vcpus: 2, memoryMib: 4096 });
    ids.push(vm.id);
    // 10 helpers, one step per ~2.5 helpers: 2 -> 3 -> 4 -> 5 -> 6 vCPU, +2 GiB each, each step while the helpers run.
    await exec(vm.id, "for i in $(seq 1 10); do nohup timeout 900 sh -c 'while :; do :; done' >/dev/null 2>&1 & done; echo ok");
    const steps: number[] = [];
    for (let v = 3; v <= 6; v++) {
      const t = now();
      const r = await resize(vm.id, { vcpus: v, memoryMib: 4096 + (v - 2) * 2048 });
      if (r.status !== 200) { gaps.push(`grow to ${v} vCPU: HTTP ${r.status} ${r.text.slice(0, 160)}`); break; }
      while ((await nproc(vm.id)) < v && now() - t < 120_000) await sleep(1_000);
      steps.push(secs(now() - t));
    }
    n["grow_steps_s"] = steps;
    await exec(vm.id, "pkill -f 'while :; do :; done' || true");
    const shrink = await call("POST", `${vmPath(vm.id)}/resize`, { resources: { vcpus: 2, memoryMib: 4096 } });
    const after = await nproc(vm.id);
    n["shrink_http"] = shrink.status;
    n["nproc_after_shrink"] = after;
    if (after > 2) gaps.push(`helpers ended, shrink to 2 vCPU did nothing (HTTP ${shrink.status}, guest still ${after} CPUs): the VM API only grows`);
    return { ok: steps.length === 4 && after === 2, what: `10 busy helpers; grew 2->6 vCPU in 4 live steps (${steps.join(", ")} s); shrink after they ended: ${after === 2 ? "back to 2" : `stayed at ${after}`}`, scaleS: steps.length ? Math.max(...steps) : null };
  }),

  fork: () => runCase("fork", async (ids, n, gaps) => {
    const vm = await create("fork-src", { vcpus: 2 });
    ids.push(vm.id);
    await exec(vm.id, "echo before-fork > $HOME/mark; nohup sh -c 'i=0; while :; do i=$((i+1)); echo $i >> $HOME/turn.log; sleep 0.2; done' >/dev/null 2>&1 & echo ok");
    await sleep(3_000);
    const t = now();
    const r = await call("POST", `${vmPath(vm.id)}/fork`, { displayName: "scenarios fork-copy" }, 6 * 60_000);
    n["fork_http"] = r.status;
    if (r.status !== 201) return { ok: false, what: `fork mid-turn: HTTP ${r.status} ${r.text.slice(0, 200)}` };
    const fid = String(field(r.body, "id"));
    machines.set(fid, { since: now(), size: { vcpus: 2, memoryMib: 4096 }, usd: 0, gone: false });
    ids.push(fid);
    await waitState(fid, "running", 10 * 60_000);
    const scale = now() - t;
    const mark = (await exec(fid, "cat $HOME/mark")).stdout.trim();
    const lines = (await exec(fid, "wc -l < $HOME/turn.log")).stdout.trim();
    await sleep(2_000);
    const growing = (await exec(fid, "wc -l < $HOME/turn.log")).stdout.trim();
    n["fork_running_s"] = secs(scale);
    n["fork_has_file"] = mark === "before-fork";
    n["fork_process_kept"] = Number(growing) > Number(lines);
    if (Number(growing) <= Number(lines)) gaps.push("the fork has the disk but not the running turn (a disk fork, not a memory fork)");
    return { ok: mark === "before-fork", what: `forked mid-write; fork running in ${secs(scale)} s with the file; running process ${Number(growing) > Number(lines) ? "kept" : "not kept"}`, scaleS: secs(scale) };
  }),

  stranded: () => runCase("stranded", async (ids, n, gaps) => {
    const vm = await create("stranded", { vcpus: 2 });
    ids.push(vm.id);
    await exec(vm.id, "head -c 10485760 /dev/urandom > $HOME/unsynced.bin; sha256sum $HOME/unsynced.bin | cut -c1-16 > $HOME/unsynced.sum; cat $HOME/unsynced.sum");
    const sum = (await exec(vm.id, "cat $HOME/unsynced.sum")).stdout.trim();
    expect(await call("POST", `${vmPath(vm.id)}/stop`, undefined, 5 * 60_000), [200], "stop");
    await waitState(vm.id, "stopped", 5 * 60_000);
    expect(await call("POST", `${vmPath(vm.id)}/start`, undefined, 5 * 60_000), [200], "start");
    await waitState(vm.id, "running", 5 * 60_000);
    const after = (await exec(vm.id, "sha256sum $HOME/unsynced.bin | cut -c1-16")).stdout.trim();
    n["kept_across_stop_start"] = after === sum;
    const del = await remove(vm.id);
    n["delete_with_unsynced_http"] = del.status;
    const refused = del.status === 409;
    if (!refused) gaps.push(`DELETE of a VM holding 10 MiB never synced answered HTTP ${del.status}: nothing stops reaping unsynced bytes, and no list names them`);
    return { ok: after === sum && refused, what: `10 MiB unsynced write kept across stop/start: ${after === sum}; delete with it unsynced: HTTP ${del.status}${refused ? " (refused)" : " (deleted, bytes lost)"}` };
  }),

  conformance: () => runCase("conformance", async (ids, n, gaps) => {
    const [agent, work] = await Promise.all([create("conf-agent", { vcpus: 2 }), create("conf-work", { vcpus: 4, memoryMib: 8192 })]);
    ids.push(agent.id, work.id);
    // The fixture: a C build, tests, git, an npm install pinned by version, a dev server and an interactive tool.
    const fixture = `set -e; rm -rf $HOME/w; mkdir -p $HOME/w/src; cd $HOME/w/src
cat > hello.c <<'E'
#include <stdio.h>
int main(void){ puts("hello routed"); return 0; }
E
printf 'hello: hello.c\\n\\tcc -O2 -o hello hello.c\\n' > Makefile
printf '#!/bin/sh\\n./hello | grep -q routed && echo PASS 1/1\\n' > test.sh; chmod +x test.sh
printf '{"name":"conf","version":"1.0.0","private":true,"dependencies":{"left-pad":"1.3.0"}}\\n' > package.json
git init -q -b main . && git add -A && GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git -c user.name=c -c user.email=c@c commit -qm fixture && echo fixture`;
    expect({ status: (await exec(agent.id, `${PROFILE} ${fixture}`)).exitCode === 0 ? 200 : 500, body: null, text: "fixture" }, [200], "fixture");
    const commands: Record<string, string> = {
      build: "make hello 2>&1 && ./hello",
      tests: "./test.sh",
      git: "git status --porcelain=v1 --ignored=no -- ':!hello' && git log --format=%H%n%s && git rev-parse HEAD^{tree}",
      install: "npm install --no-audit --no-fund --ignore-scripts >/dev/null 2>&1; node -e \"console.log(require('left-pad')('x',5,'.'))\"",
      devserver: "(python3 -m http.server 8731 --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > /tmp/srv.pid); for i in $(seq 1 50); do curl -fsS http://127.0.0.1:8731/package.json 2>/dev/null && break; sleep 0.1; done; kill $(cat /tmp/srv.pid)",
      interactive: "printf '2+3\\nquit\\n' | python3 -i -q 2>&1 | tr -d '>' | tr -s ' \\n'",
    };
    const tree = "find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16";
    const per: Record<string, unknown> = {};
    let same = 0;
    let total = 0;
    for (const [name, cmd] of Object.entries(commands)) {
      // local: on the agent VM, in a copy of the source
      const local = await exec(agent.id, `${PROFILE} rm -rf $HOME/w/local && cp -a $HOME/w/src $HOME/w/local && cd $HOME/w/local && { ${cmd}; }; echo "rc=$?"; ${tree}`, 240_000);
      // routed: ship the source to the work VM, run there, ship the tree back, hash it on the agent VM
      const tar = await exec(agent.id, "cd $HOME/w/src && tar -cz . | base64 -w0", 120_000);
      const ran = await exec(work.id, `${PROFILE} rm -rf $HOME/r && mkdir -p $HOME/r && cd $HOME/r && base64 -d | tar -xz && { ${cmd}; }; echo "rc=$?"; tar -cz . | base64 -w0 > /tmp/back.b64`, 240_000, Buffer.from(tar.stdout));
      const back = await exec(work.id, "cat /tmp/back.b64", 120_000);
      const routedTree = await exec(agent.id, `rm -rf $HOME/w/routed && mkdir -p $HOME/w/routed && cd $HOME/w/routed && base64 -d | tar -xz && ${tree}`, 120_000, Buffer.from(back.stdout));
      const localLines = local.stdout.trim().split("\n");
      const localTree = localLines.pop();
      const routedOut = ran.stdout.trim();
      const stdoutSame = localLines.join("\n") === routedOut;
      const treeSame = localTree === routedTree.stdout.trim();
      const cmp = { stdoutSame, exitSame: (localLines.at(-1) ?? "") === (routedOut.split("\n").at(-1) ?? ""), treeSame };
      per[name] = cmp;
      for (const v of Object.values(cmp)) { total += 1; if (v) same += 1; }
      if (!stdoutSame || !treeSame) gaps.push(`${name}: local ${JSON.stringify(localLines.join("\\n").slice(-200))} vs routed ${JSON.stringify(routedOut.slice(-200))}; tree ${localTree} vs ${routedTree.stdout.trim()}`);
    }
    n["per_command"] = per;
    const pct = Math.round((same / total) * 1000) / 10;
    n["identical_pct"] = pct;
    return { ok: pct === 100, what: `${Object.keys(commands).length} commands local (agent VM) vs routed (work VM, tree shipped by tar): ${pct}% identical on stdout, exit code and tree hash. Not the exec router itself: its stand-in` };
  }),

  fanout: () => runCase("fanout", async (ids, n) => {
    const t = now();
    const made = await Promise.allSettled([0, 1, 2, 3].map((i) => create(`fanout-${i}`, { vcpus: 32, memoryMib: 65536 })));
    const ok = made.filter((m): m is PromiseFulfilledResult<{ id: string; createMs: number; runningMs: number }> => m.status === "fulfilled");
    ok.forEach((m) => ids.push(m.value.id));
    const all = now() - t;
    n["running_s"] = ok.map((m) => secs(m.value.runningMs));
    n["refused"] = made.filter((m) => m.status === "rejected").map((m) => String((m as PromiseRejectedResult).reason).slice(0, 200));
    return { ok: ok.length === 4, what: `4 x 32 vCPU / 64 GiB asked at once: ${ok.length} running, slowest in ${secs(all)} s${ok.length < 4 ? `; refused: ${String(n["refused"])}` : ""}`, scaleS: ok.length === 4 ? secs(all) : null };
  }),

  chromium: () => runCase("chromium", async (ids, n, gaps) => {
    const vm = await create("chromium", { vcpus: 32, memoryMib: 65536, diskMib: 131072 });
    ids.push(vm.id);
    n["running_s"] = secs(vm.runningMs);
    const budget = chromiumMinutes * 60_000;
    const started = now();
    const deps = await long(vm.id, "deps", "git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git && sudo apt-get install -y -qq python3 >/dev/null 2>&1 || true", 10 * 60_000);
    const env = "export PATH=$HOME/depot_tools:$PATH DEPOT_TOOLS_UPDATE=0;";
    const fetch = await long(vm.id, "fetch", `${env} mkdir -p chromium && cd chromium && fetch --nohooks --no-history chromium && cd src && gclient runhooks`, Math.max(60_000, budget - (now() - started)));
    n["fetch_s"] = secs(fetch.ms);
    n["disk_used"] = (await exec(vm.id, "df -h $HOME | tail -1")).stdout.trim();
    if (fetch.rc !== 0) {
      gaps.push(`fetch+runhooks ${fetch.rc === null ? "not finished" : `failed rc=${fetch.rc}`} after ${secs(fetch.ms)} s: ${fetch.tail.slice(-300)}`);
      return { ok: false, what: `32 vCPU running in ${secs(vm.runningMs)} s; Chromium fetch ${fetch.rc === null ? `still going at the ${chromiumMinutes} min box` : "failed"}` };
    }
    const left = budget - (now() - started);
    const build = await long(vm.id, "build", `${env} cd chromium/src && gn gen out/Default --args='is_debug=false symbol_level=0 is_component_build=true' && autoninja -C out/Default chrome`, Math.max(60_000, left));
    const progress = (await exec(vm.id, "grep -oE '\\[[0-9,]+/[0-9,]+\\]' /tmp/build.log | tail -1")).stdout.trim();
    n["build_s"] = secs(build.ms);
    n["ninja_progress"] = progress;
    const m = /\[([\d,]+)\/([\d,]+)\]/.exec(progress);
    if (m) {
      const done = Number(m[1]!.replace(/,/g, ""));
      const all = Number(m[2]!.replace(/,/g, ""));
      n["extrapolated_full_build_s"] = done > 0 ? Math.round((build.ms / 1000) * (all / done)) : null;
    }
    return { ok: build.rc === 0, what: `32 vCPU running in ${secs(vm.runningMs)} s; fetch+hooks ${secs(fetch.ms)} s; build ${build.rc === 0 ? `done in ${secs(build.ms)} s` : `at ${progress} after ${secs(build.ms)} s (extrapolated ${String(n["extrapolated_full_build_s"])} s)`}`, scaleS: secs(vm.runningMs) };
  }),
};

const finish = (code: number) => {
  const out = { ok: rows.every((r) => r.ok), base: origin.host, runId, rows };
  const text = JSON.stringify(out, null, 2);
  console.log(text);
  if (resultFile) writeFileSync(resultFile, text);
  process.exit(code);
};
process.on("SIGTERM", async () => { for (const id of machines.keys()) await remove(id); finish(1); });

// The small cases run side by side; fanout and chromium hold the big machines and run after them, alone.
const small = cases.filter((c) => !["fanout", "chromium"].includes(c));
await Promise.all(small.map((c) => CASES[c]!()));
for (const c of cases.filter((c) => ["fanout", "chromium"].includes(c))) await CASES[c]!();
for (const [id, m] of machines) if (!m.gone) await remove(id);
finish(0);
