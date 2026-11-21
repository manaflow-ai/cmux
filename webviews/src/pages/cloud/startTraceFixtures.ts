// l10n-allow-file: fixtures (public-safe sample start traces), not shipped UI.
// Cloud start traces shaped like the platform's answers (cmux-platform GET /v1/cloud/start-traces and
// /v1/cloud/start-traces/{trace}), for the mock provider, the tests and the gallery. Times are relative
// to `now`, so "3 min ago" reads the same in every run. The app's click is not timed (the create is
// the app's own), so only the CLI start has a `click` span.
import type { StartSpan, StartTrace, StartTraceList } from "./startTraces";

const MIN = 60_000;

type Piece = [hop: string, start: number, length: number, source?: string, attrs?: Record<string, string | number>];

function trace(id: string, machine: string, startedAt: number, path: string, pieces: Piece[]): StartTrace {
  const spans: StartSpan[] = pieces
    .map(([hop, start, length, source = "platform", attrs = {}]) => ({
      hop,
      start_ms: startedAt + start,
      end_ms: startedAt + start + length,
      source,
      attrs: { path, outcome: "ok", ...attrs },
    }))
    .sort((a, b) => a.start_ms - b.start_ms);
  const total = Math.max(...spans.map((span) => span.end_ms)) - startedAt;
  return { trace: id, machine, started_at: startedAt, total_ms: total, path, spans };
}

/** A fresh create: every server hop, the image restore and both network pieces, then the client's connect. */
export function createTrace(now: number): StartTrace {
  return trace("st_create_7Qm2xK4p", "vm_c41", now - 3 * MIN, "create", [
    ["api", 0, 46],
    ["placement", 46, 38],
    ["network", 84, 120, "platform", { part: "prepare" }],
    ["provider_create", 204, 2810],
    ["restore", 3014, 1940],
    ["boot", 4954, 3260],
    ["network", 8214, 410, "platform", { part: "attach" }],
    ["network", 8624, 690, "app", { part: "connect" }],
    ["agent_auth", 9314, 2280, "machine"],
    ["first_token", 11594, 1630, "machine"],
  ]);
}

/** A claimed spare: no restore, a short claim, the guest already bound. */
export function spareTrace(now: number): StartTrace {
  return trace("st_spare_Lr8vN2qe", "vm_s17", now - 22 * MIN, "spare", [
    ["api", 0, 41],
    ["placement", 41, 29],
    ["provider_create", 70, 310],
    ["boot", 380, 220],
    ["network", 600, 260, "platform", { part: "attach" }],
    ["network", 860, 540, "app", { part: "connect" }],
    ["agent_auth", 1400, 1710, "machine"],
    ["first_token", 3110, 1480, "machine"],
  ]);
}

/** A CLI start (`cmux vm new`), which times its own click, and a slow boot. */
export function cliTrace(now: number): StartTrace {
  return trace("st_cli_Hy3cT9wb", "vm_c44", now - 47 * MIN, "create", [
    ["click", 0, 180, "cli"],
    ["api", 180, 52],
    ["placement", 232, 44],
    ["network", 276, 130, "platform", { part: "prepare" }],
    ["provider_create", 406, 3120],
    ["restore", 3526, 2010],
    ["boot", 5536, 9840],
    ["network", 15376, 450, "platform", { part: "attach" }],
    ["network", 15826, 720, "cli", { part: "connect" }],
    ["agent_auth", 16546, 2410, "machine"],
    ["first_token", 18956, 1720, "machine"],
  ]);
}

/** A resumed paused machine that has not answered its first token yet (the trace is still open). */
export function resumeTrace(now: number): StartTrace {
  return trace("st_resume_Pz6kW1sd", "vm_c41", now - 95 * MIN, "resume", [
    ["api", 0, 39],
    ["placement", 39, 21],
    ["provider_create", 60, 880],
    ["restore", 940, 2380],
    ["boot", 3320, 1460],
    ["network", 4780, 380, "platform", { part: "attach" }],
  ]);
}

export function sampleTraces(now: number): StartTrace[] {
  return [createTrace(now), spareTrace(now), cliTrace(now), resumeTrace(now)];
}

/** The last day's answer: the newest starts first, and each hop's percentiles over the day. */
export function sampleTraceList(now: number, traces: StartTrace[] = sampleTraces(now)): StartTraceList {
  return {
    window_ms: 86_400_000,
    since_ms: now - 86_400_000,
    traces: traces.map((one) => ({
      trace: one.trace,
      machine: one.machine,
      started_at: one.started_at,
      total_ms: one.total_ms,
      path: one.path,
      hops_seen: [...new Set(one.spans.map((span) => span.hop))],
    })),
    hops: {
      click: { n: 3, p50_ms: 170, p95_ms: 240 },
      api: { n: 41, p50_ms: 44, p95_ms: 71 },
      placement: { n: 41, p50_ms: 33, p95_ms: 58 },
      provider_create: { n: 41, p50_ms: 2640, p95_ms: 3380 },
      restore: { n: 29, p50_ms: 1960, p95_ms: 2700 },
      boot: { n: 40, p50_ms: 3180, p95_ms: 6900 },
      network: { n: 40, p50_ms: 1150, p95_ms: 1620 },
      agent_auth: { n: 38, p50_ms: 2190, p95_ms: 2950 },
      first_token: { n: 37, p50_ms: 1590, p95_ms: 2240 },
    },
  };
}

/** A day with no starts yet. */
export function emptyTraceList(now: number): StartTraceList {
  return { window_ms: 86_400_000, since_ms: now - 86_400_000, traces: [], hops: {} };
}
