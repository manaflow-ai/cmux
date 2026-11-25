#!/usr/bin/env bun
/**
 * Provider adapter for the pause -> resume SLO measurement (RFD 0017 follow-up 4, RFD 0063 "Providers").
 *
 * MEASUREMENT ONLY. hq's rule stays: Cloud VMs use Freestyle only, with no provider fallback. This file adds no
 * product path; it lets the same cell grid (event to agent running, p50/p95, pause lengths 5 s to 1 h, n >= 20)
 * run against a second fast-resume provider so RFD 0063 can price a hedge (Morph snapshot floor $0.18, Hetzner with
 * our own Firecracker $0.33). The pause -> resume harness owned by lane aggressive-pause-resume drives any object
 * that satisfies {@link ProviderAdapter}; this module does not copy that harness, it only supplies the adapter, a
 * small cell runner for providers that harness does not know, and the percentile summary.
 *
 * Off unless asked and credentialed: `--provider morph` with MORPH_API_KEY set. Without the key the run prints
 * "skipped" and exits 0, so no CI job or script changes behavior. Nothing here prints a secret.
 *
 *   MORPH_API_KEY=... bun scripts/cmux-next/resume-slo-provider.ts --provider morph --pauses 5,30,300 --n 20
 */

export interface ProviderAdapter {
  readonly name: string;
  /** Create a machine from the provider's base image/snapshot; returns its id. */
  create(): Promise<string>;
  pause(id: string): Promise<void>;
  /** Resume and return only when the provider says the machine runs. */
  resume(id: string): Promise<void>;
  /** One trivial command inside the guest; resolves when the guest answers (the "agent running" stand-in). */
  probe(id: string): Promise<void>;
  remove(id: string): Promise<void>;
}

export const DEFAULT_PAUSES_S = [5, 30, 300, 900, 3600] as const;

export type Cell = { pauseS: number; n: number; resumeMs: number[]; firstExecMs: number[]; failures: number };

export const percentile = (xs: readonly number[], p: number): number | null => {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))] ?? null;
};

export const summarize = (cells: readonly Cell[]) =>
  cells.map((c) => ({
    pause_s: c.pauseS, n: c.n, failures: c.failures,
    resume_p50_ms: percentile(c.resumeMs, 50), resume_p95_ms: percentile(c.resumeMs, 95),
    to_running_p50_ms: percentile(c.firstExecMs, 50), to_running_p95_ms: percentile(c.firstExecMs, 95),
  }));

type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

/** Morph Cloud over its REST API (https://cloud.morph.so/api). Endpoint shapes are from its public docs; unverified without a key. */
export const morphAdapter = (opts: { apiKey: string; snapshotId: string; baseUrl?: string; fetch?: Fetch }): ProviderAdapter => {
  const base = opts.baseUrl ?? "https://cloud.morph.so/api";
  const f = opts.fetch ?? fetch;
  const call = async (method: string, path: string, body?: unknown) => {
    const r = await f(`${base}${path}`, {
      method,
      headers: { authorization: `Bearer ${opts.apiKey}`, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (!r.ok) throw new Error(`morph ${method} ${path}: HTTP ${r.status}`);
    return (await r.json().catch(() => ({}))) as Record<string, unknown>;
  };
  return {
    name: "morph",
    create: async () => String((await call("POST", `/instance?snapshot_id=${encodeURIComponent(opts.snapshotId)}`)).id),
    pause: async (id) => void (await call("POST", `/instance/${id}/pause`)),
    resume: async (id) => void (await call("POST", `/instance/${id}/resume`)),
    probe: async (id) => void (await call("POST", `/instance/${id}/exec`, { command: ["true"] })),
    remove: async (id) => void (await call("DELETE", `/instance/${id}`)),
  };
};

/** Hetzner with our own Firecracker: not built. Every call says so, so a flag typo cannot read as a measurement. */
export const hetznerFirecrackerStub = (): ProviderAdapter => {
  const no = async (): Promise<never> => { throw new Error("hetzner-firecracker: not implemented (RFD 0063 Providers: $0.33 floor, no host yet)"); };
  return { name: "hetzner-firecracker", create: no, pause: no, resume: no, probe: no, remove: no };
};

/** The adapter for `--provider`, or why there is none. Credentials come from the environment only. */
export const selectProvider = (name: string, env: Readonly<Record<string, string | undefined>>): { adapter: ProviderAdapter } | { skipped: string } => {
  if (name === "morph") {
    if (!env.MORPH_API_KEY) return { skipped: "morph: MORPH_API_KEY is not set" };
    if (!env.MORPH_SNAPSHOT_ID) return { skipped: "morph: MORPH_SNAPSHOT_ID (the base snapshot) is not set" };
    return { adapter: morphAdapter({ apiKey: env.MORPH_API_KEY, snapshotId: env.MORPH_SNAPSHOT_ID }) };
  }
  if (name === "hetzner-firecracker") return { adapter: hetznerFirecrackerStub() };
  return { skipped: `unknown provider ${JSON.stringify(name)} (morph, hetzner-firecracker)` };
};

export const runCell = async (a: ProviderAdapter, pauseS: number, n: number, sleep: (s: number) => Promise<void>, now: () => number = () => performance.now()): Promise<Cell> => {
  const cell: Cell = { pauseS, n, resumeMs: [], firstExecMs: [], failures: 0 };
  const id = await a.create();
  try {
    for (let i = 0; i < n; i++) {
      try {
        await a.probe(id);
        await a.pause(id);
        await sleep(pauseS);
        const t0 = now();
        await a.resume(id);
        const t1 = now();
        await a.probe(id);
        cell.resumeMs.push(Math.round(t1 - t0));
        cell.firstExecMs.push(Math.round(now() - t0));
      } catch { cell.failures++; }
    }
  } finally { await a.remove(id).catch(() => undefined); }
  return cell;
};

const arg = (argv: readonly string[], k: string, d: string) => { const i = argv.indexOf(k); return i >= 0 && argv[i + 1] ? argv[i + 1]! : d; };

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const name = arg(argv, "--provider", "");
  if (name === "") { console.log("skipped: no --provider (morph, hetzner-firecracker)"); process.exit(0); }
  const sel = selectProvider(name, process.env);
  if ("skipped" in sel) { console.log(`skipped: ${sel.skipped}`); process.exit(0); }
  const pauses = arg(argv, "--pauses", DEFAULT_PAUSES_S.join(",")).split(",").map(Number);
  const n = Number(arg(argv, "--n", "20"));
  const cells: Cell[] = [];
  for (const p of pauses) cells.push(await runCell(sel.adapter, p, n, (s) => new Promise((r) => setTimeout(r, s * 1000))));
  console.log(JSON.stringify({ provider: sel.adapter.name, cells: summarize(cells) }, null, 2));
}
