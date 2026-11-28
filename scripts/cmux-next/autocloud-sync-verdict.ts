/**
 * The storage sync probe's verdict (autocloud-sync-probe.ts): pure, so its rules are tested without a Cloud.
 *
 * Leo, 2026-11-27: "all we need obv is storage reliable sync SO MAKE IT RELIABLE AND FAST". The probe's row is red
 * on its first failing step, named in `error`, and every timing it measured rides along even when an earlier
 * step failed, so a red run still says how fast the rest was.
 */

export type StepName =
  | "sign_in" | "install" | "machine" | "auto_machine" | "vm_harness" | "clock" | "mac_daemon" | "scratch_chat"
  | "toggle_on" | "tree_visible" | "mac_edit_to_vm" | "vm_edit_to_mac" | "both_match" | "toggle_off"
  | "mac_has_vm_edits";

/** The order the steps run in; the row's error names the first of these that did not pass. */
export const STEPS: StepName[] = [
  "sign_in", "install", "machine", "auto_machine", "vm_harness", "clock", "mac_daemon", "scratch_chat",
  "toggle_on", "tree_visible", "mac_edit_to_vm", "vm_edit_to_mac", "both_match", "toggle_off", "mac_has_vm_edits",
];

/** The brief's bounds: the tree on the machine within 3 s of the toggle, each edit across within 2 s. */
export const GATES_MS: Partial<Record<StepName, number>> = {
  tree_visible: 3000,
  mac_edit_to_vm: 2000,
  vm_edit_to_mac: 2000,
};

export type StepResult = { step: StepName; status: "pass" | "fail" | "skip"; ms: number | null; detail: string };

/** A timed step against its gate: a measured time over the gate fails, naming both numbers. */
export function gated(step: StepName, ms: number | null, detail: string): StepResult {
  const gate = GATES_MS[step];
  if (ms === null || !Number.isFinite(ms)) return { step, status: "fail", ms: null, detail: detail || "not measured" };
  const r = Math.round(ms);
  if (gate !== undefined && r > gate) return { step, status: "fail", ms: r, detail: `${r} ms, over the ${gate} ms bound; ${detail}` };
  return { step, status: "pass", ms: r, detail };
}

/** A delay from one clock's event to the other's sighting: SEEN and SENT in their own clocks (ms), OFFSET the
 * second clock minus the first (the machine's minus the runner's). Negative only by clock error: clamped to 0. */
export function crossClockMs(sentRunnerMs: number, seenVmMs: number, offsetMs: number): number {
  return Math.max(0, seenVmMs - offsetMs - sentRunnerMs);
}

/** The machine's clock minus the runner's from round trips (`date` on the machine between two runner reads): the
 * sample with the shortest round trip, its midpoint. Returns the offset and that round trip. */
export function clockOffset(samples: Array<{ before: number; vm: number; after: number }>): { offsetMs: number; rttMs: number } {
  const good = samples.filter((s) => Number.isFinite(s.vm) && s.after >= s.before);
  if (!good.length) throw new Error("no clock sample from the machine");
  const best = good.reduce((a, b) => (b.after - b.before < a.after - a.before ? b : a));
  return { offsetMs: Math.round(best.vm - (best.before + best.after) / 2), rttMs: best.after - best.before };
}

/** A watcher's output on the machine: `@@start NS` then `@@seen NS` or `@@timeout DETAIL`. */
export function parseWatch(stdout: string): { startMs: number | null; seenMs: number | null; firstPoll: boolean; detail: string } {
  const start = /@@start (\d+)/.exec(stdout);
  const seen = /@@seen (\d+)( first)?/.exec(stdout);
  const timeout = /@@timeout ?(.*)/.exec(stdout);
  return {
    startMs: start ? Number(start[1]) / 1e6 : null,
    seenMs: seen ? Number(seen[1]) / 1e6 : null,
    firstPoll: Boolean(seen?.[2]),
    detail: seen ? "" : timeout ? `not there in time (${timeout[1].trim().slice(0, 300) || "nothing"})` : `no answer: ${stdout.trim().slice(-300) || "empty"}`,
  };
}

export type Row = {
  probe: string;
  outcome: "ok" | "fail";
  error?: string;
  ms?: number;
  steps: StepResult[];
  [field: string]: unknown;
};

/** The probe's row: ok only when every step passed; else the error names the first step that did not, with its detail.
 * Steps that never ran (an earlier one stopped the run) are listed as skip. `ms` is the tree's time to the machine. */
export function verdict(probe: string, results: StepResult[], fields: Record<string, unknown>): Row {
  const by = new Map(results.map((r) => [r.step, r]));
  const steps = STEPS.map((s) => by.get(s) ?? { step: s, status: "skip" as const, ms: null, detail: "did not run" });
  const firstBad = steps.find((s) => s.status !== "pass");
  const timings: Record<string, number> = {};
  for (const s of steps) if (GATES_MS[s.step] !== undefined || s.step === "toggle_on" || s.step === "toggle_off") {
    if (s.ms !== null) timings[`${s.step}_ms`] = s.ms;
  }
  const row: Row = { probe, outcome: firstBad ? "fail" : "ok", ...fields, ...timings, steps };
  if (firstBad) row.error = `${firstBad.step}: ${firstBad.detail}`.slice(0, 500);
  if (timings.tree_visible_ms !== undefined) row.ms = timings.tree_visible_ms;
  return row;
}

/** The tree's fingerprint, the same shell on both sides: each file directly in DIR (the probe's tree is flat), dot
 * files too, with its sha256, in byte order. A glob, not `find`: nothing it runs differs between the runner and the guest.
 * The leading space: inside "$(...)" a bare "((" would read as arithmetic. */
export const TREE_HASH_SH = (dir: string) =>
  ` (cd ${dir} 2>/dev/null && export LC_ALL=C && for f in * .[!.]*; do [ -f "$f" ] && sha256sum "$f"; done | sha256sum | cut -c1-64)`;
