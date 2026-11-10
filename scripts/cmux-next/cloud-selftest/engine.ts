/**
 * The Cloud self-test engine (plans/cmux-next/cloud-selftest-DESIGN.md): declarative scenarios of steps
 * (actor, action, args, expect), each action one `cmux` verb with --json where the verb exists, run per
 * actor with that actor's own signed-in identity and HOME. Pure parts (interpolation, matching, verdicts,
 * the report) are exported for the tests; nothing here holds a secret beyond the run.
 */
import { writeFileSync } from "node:fs";
import path from "node:path";
import { scrub } from "../cloud-journey";

/** Who builds the verb a step needs: "base" exists on feat-cmux-next today; A..E are the multiplayer lanes. */
export type Lane = "base" | "A" | "B" | "C" | "D" | "E";
export const LANES: Record<Lane, string> = {
  base: "feat-cmux-next",
  A: "cloud-mp-vmauth (login-free VM)",
  B: "cloud-mp-gateway (coderouter, owner gateway hub)",
  C: "cloud-mp-share (shared Cloud chats)",
  D: "cloud-mp-team (team sessions, follow, reassign, transfer, links)",
  E: "cloud-mp-keys (team shared keys)",
};

export type Outcome = "pass" | "fail" | "skip" | "pending";

/** What one action answered: `ok` with its JSON, or a stable error code (`auth.forbidden`, `inference.gateway_offline`). */
export type ActionResult = {
  ok: boolean;
  code?: string;
  message?: string;
  json: any;
  /** How it ran: the cmux CLI verb, the backend route that verb calls (no CLI verb yet), or this runner (harness). */
  transport: "cli" | "api" | "harness";
  argv?: string[];
};

/** A JSON subset to match, with a few operators in place of a value. */
export type Matcher =
  | null
  | boolean
  | number
  | string
  | Matcher[]
  | { $contains: Matcher }
  | { $absent: true }
  | { $exists: true }
  | { $re: string }
  | { $gte: number }
  | { $lte: number }
  | { $len: number }
  | { $not: Matcher }
  | { $oneOf: Matcher[] }
  | { [key: string]: Matcher };

export type Expect = {
  /** true: the action must succeed; false: it must fail (with `error` when given). Default true unless `error`. */
  ok?: boolean;
  /** The stable error code the action must fail with (exact, or one of a list). */
  error?: string | string[];
  /** A subset of the answer's JSON. */
  json?: Matcher;
  /**
   * Harness-only bounded wait (the product never polls): re-run the action until the expectation holds, for state that
   * converges (a membership revoked live, a gateway reconnecting, a machine waking). The verdict is the last try's.
   */
  within_ms?: number;
  every_ms?: number;
};

export type Step = {
  actor: string;
  action: string;
  args?: Record<string, unknown>;
  expect?: Expect;
  /** Save answer fields as variables: { vm: "machine_id" } stores json.machine_id as ${vm}. */
  save?: Record<string, string>;
  label?: string;
  /** Run without waiting for the step before it to finish (simultaneous prompts); joined at the next plain step. */
  concurrent?: boolean;
};

/**
 * `fixture` (default): a signed-in account the fixtures make, with its own HOME. `anon`: no account and no token (usage
 * errors). `app`: the person signed in to the tagged app (CMUX_TAG); its verbs go to that app's socket or this
 * computer's link, as that person (one per run, never a fixture).
 */
export type ActorKind = "fixture" | "anon" | "app";
export type ActorSpec = { name: string; team_role?: "owner" | "admin" | "member" | "billing" | "guest" | null; kind?: ActorKind };

/** What a scenario needs from the run; a missing need skips the scenario with the reason. */
export type Need =
  | "fixtures.mutate"
  | "machine"
  | "gateway"
  | "stub"
  | "cmux"
  /** A tagged app answers on its socket (CMUX_TAG or --app-socket), and --cmux is a CLI that has the app's verbs. */
  | "app"
  /** --app-session KEY: a team Cloud session of the app's team this run may follow, archive and reassign (back). */
  | "app.session"
  /** --app-tab TAB: a Cloud chat tab in the tagged app to transfer to this Mac. */
  | "app.tab"
  /** --link-host ID: a Cloud machine this computer's link reaches (`cmux link chat`), as the app's person. */
  | "link"
  /** Each actor its own signed-in cmux link (a member steering, a guest held): this runner makes none. */
  | "link.actors";

export type Scenario = {
  name: string;
  summary: string;
  /** The edge cases (UPDATE 1 list and the multiplayer surface) this scenario covers. */
  covers: string[];
  tags: string[];
  actors: ActorSpec[];
  needs?: Need[];
  steps: Step[];
  /** Steps that always run at the end, pass or fail (cleanup). */
  finally?: Step[];
};

export type StepRecord = {
  scenario: string;
  index: number;
  label: string;
  actor: string;
  action: string;
  outcome: Outcome;
  ms: number;
  transport?: ActionResult["transport"];
  code?: string;
  detail: string;
  tries?: number;
};

export type ScenarioRecord = { name: string; outcome: Outcome; ms: number; reason: string; pending_lanes: Lane[]; covers: string[]; steps: StepRecord[] };

/** `${name}` and `${actor.field}` in strings (deep), from the run's variables; an unknown name throws. */
export function interpolate(value: unknown, vars: Record<string, unknown>): unknown {
  if (typeof value === "string") {
    const whole = /^\$\{([A-Za-z0-9_.-]+)\}$/.exec(value);
    if (whole) return lookup(vars, whole[1]!);
    return value.replace(/\$\{([A-Za-z0-9_.-]+)\}/g, (_, name: string) => String(lookup(vars, name)));
  }
  if (Array.isArray(value)) return value.map((v) => interpolate(v, vars));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, interpolate(v, vars)]));
  return value;
}

function lookup(vars: Record<string, unknown>, name: string): unknown {
  let at: any = vars;
  for (const part of name.split(".")) {
    if (at === null || at === undefined || !(part in Object(at))) throw new Error(`no variable \${${name}}`);
    at = at[part];
  }
  return at;
}

/** A dotted path into JSON (`machine.id`, `turns.0.prompt`). */
export function pick(json: unknown, dotted: string): unknown {
  let at: any = json;
  for (const part of dotted.split(".")) {
    if (at === null || at === undefined) return undefined;
    at = at[part];
  }
  return at;
}

/** Why `actual` does not match `want`, or null when it does. */
export function mismatch(actual: unknown, want: Matcher, at = "$"): string | null {
  if (want !== null && typeof want === "object" && !Array.isArray(want)) {
    const keys = Object.keys(want);
    const op = keys.length === 1 && keys[0]!.startsWith("$") ? keys[0]! : null;
    const w = want as any;
    switch (op) {
      case "$absent":
        return actual === undefined || actual === null ? null : `${at}: expected absent, got ${short(actual)}`;
      case "$exists":
        return actual === undefined || actual === null ? `${at}: expected a value` : null;
      case "$re":
        return typeof actual === "string" && new RegExp(w.$re).test(actual) ? null : `${at}: ${short(actual)} does not match /${w.$re}/`;
      case "$gte":
        return typeof actual === "number" && actual >= w.$gte ? null : `${at}: ${short(actual)} is not >= ${w.$gte}`;
      case "$lte":
        return typeof actual === "number" && actual <= w.$lte ? null : `${at}: ${short(actual)} is not <= ${w.$lte}`;
      case "$len":
        return Array.isArray(actual) && actual.length === w.$len ? null : `${at}: expected ${w.$len} items, got ${Array.isArray(actual) ? actual.length : short(actual)}`;
      case "$not":
        return mismatch(actual, w.$not, at) === null ? `${at}: ${short(actual)} matches what it must not` : null;
      case "$oneOf":
        return (w.$oneOf as Matcher[]).some((m) => mismatch(actual, m, at) === null) ? null : `${at}: ${short(actual)} is none of ${short(w.$oneOf)}`;
      case "$contains": {
        if (!Array.isArray(actual)) return `${at}: expected a list, got ${short(actual)}`;
        return actual.some((item) => mismatch(item, w.$contains, at) === null) ? null : `${at}: no item matches ${short(w.$contains)}`;
      }
      default: {
        if (actual === null || typeof actual !== "object" || Array.isArray(actual)) return `${at}: expected an object, got ${short(actual)}`;
        for (const k of keys) {
          const why = mismatch((actual as any)[k], w[k], `${at}.${k}`);
          if (why) return why;
        }
        return null;
      }
    }
  }
  if (Array.isArray(want)) {
    if (!Array.isArray(actual) || actual.length !== want.length) return `${at}: expected ${want.length} items, got ${short(actual)}`;
    for (let i = 0; i < want.length; i++) {
      const why = mismatch(actual[i], want[i]!, `${at}.${i}`);
      if (why) return why;
    }
    return null;
  }
  return Object.is(actual, want) ? null : `${at}: expected ${short(want)}, got ${short(actual)}`;
}

/** Why a result fails its step's expectation, or null. */
export function judge(result: ActionResult, expect: Expect = {}): string | null {
  const wantOk = expect.ok ?? (expect.error === undefined);
  if (wantOk && !result.ok) return `failed ${result.code ?? "?"}: ${result.message ?? short(result.json)}`;
  if (!wantOk && result.ok) return `succeeded, expected ${expect.error ? `error ${[expect.error].flat().join(" or ")}` : "a failure"}: ${short(result.json)}`;
  if (!wantOk && expect.error !== undefined) {
    const codes = [expect.error].flat();
    if (!codes.includes(result.code ?? "")) return `failed ${result.code ?? "(no code)"}, expected ${codes.join(" or ")}: ${result.message ?? ""}`;
  }
  if (expect.json !== undefined) return mismatch(result.json, expect.json);
  return null;
}

const short = (v: unknown) => {
  const s = JSON.stringify(v ?? null) ?? "undefined";
  return s.length > 200 ? `${s.slice(0, 200)}...` : s;
};

/** A scenario's verdict from its steps: fail beats pending beats skip beats pass. */
export function scenarioOutcome(steps: StepRecord[]): Outcome {
  if (steps.some((s) => s.outcome === "fail")) return "fail";
  if (steps.some((s) => s.outcome === "pending")) return "pending";
  if (steps.length && steps.every((s) => s.outcome === "skip")) return "skip";
  return steps.some((s) => s.outcome === "skip") ? "skip" : "pass";
}

export type Report = { backend: { name: string; api: string }; started_at: string; meta: Record<string, string>; scenarios: ScenarioRecord[] };

export function summaryMarkdown(report: Report): string {
  const count = (o: Outcome) => report.scenarios.filter((s) => s.outcome === o).length;
  const head = `Cloud self-test on \`${report.backend.name}\` (${report.backend.api}): ${count("pass")} pass, ${count("fail")} fail, ${count("pending")} pending, ${count("skip")} skip`;
  const rows = report.scenarios.map((s) => `| ${s.outcome === "fail" ? "**FAIL**" : s.outcome.toUpperCase()} | ${s.name} | ${s.ms} | ${s.pending_lanes.join(",") || "-"} | ${s.reason.replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 240)} |`);
  return [head, "", "| result | scenario | ms | waits on | why |", "|---|---|---:|---|---|", ...rows, ""].join("\n");
}

/** journey.json (the per-step record, latency per step) and summary.md, scrubbed of every secret the run holds. */
export function writeReport(outDir: string, report: Report, secrets: string[]): void {
  const clean = JSON.parse(scrub(JSON.stringify(report), secrets));
  writeFileSync(path.join(outDir, "journey.json"), `${JSON.stringify(clean, null, 2)}\n`);
  writeFileSync(path.join(outDir, "summary.md"), scrub(summaryMarkdown(report), secrets));
}
