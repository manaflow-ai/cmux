#!/usr/bin/env bun
/**
 * The NEXT Cloud journey: one command checks a backend end to end, with no app build.
 *
 *   bun scripts/cmux-next/cloud-journey.ts --backend staging
 *   bun scripts/cmux-next/cloud-journey.ts --backend preview-35100 --out /tmp/journey
 *   bun scripts/cmux-next/cloud-journey.ts --backend prod --credentials ~/.secrets/cmuxterm-prod.env --team team_...
 *   bun scripts/cmux-next/cloud-journey.ts --backend local            # wrangler dev on 127.0.0.1:8787
 *   bun scripts/cmux-next/cloud-journey.ts --api https://cmux-api-preview-35100.debussy.workers.dev --stack dev
 *   bun scripts/cmux-next/cloud-journey.ts --app-cli "$APP/Contents/Resources/bin/cmux" --socket /tmp/cmux-debug-TAG.sock
 *     (the commands a person runs, through a running NEXT build's CLI: list-machines, vm token create,
 *     new-machine, machine-status, exec, start-session, start-chat --wait, kill-machine; cmux#35086)
 *   bun scripts/cmux-next/cloud-journey.ts --backend prod --credentials F --machine vm_... --keyed-start --model stub
 *     (an existing machine, kept: no create, pause or delete; the dev machine of scripts/cmux-next/cloud-devloop.ts.
 *     --keyed-start runs the app's keyed acpmux start (POST .../acpmux/keyed-start) and checks the keyed daemon still
 *     serves after acpmux.service's restart delay: the take-over race of cmux-platform#845)
 *   bun scripts/cmux-next/cloud-journey.ts --backend dev --surge --out /tmp/surge
 *     (Cloud Surge, cmux-platform#1594: cloud.surge.preview, then cloud.surge.create {count 2, ttl 300 s} under one
 *     key, the same key again (must answer replayed with the same slots), the same key with count 1 (must answer
 *     idempotency.conflict), then every machine_id the slots named is deleted. No chat machine, no agent)
 *
 * It signs in as the agent test account (Stack password sign-in; CMUX_DOGFOOD_STACK_EMAIL and
 * CMUX_DOGFOOD_STACK_PASSWORD from the environment or a KEY=value --credentials file; or, in a GitHub Actions
 * job with `id-token: write`, --sign-in oidc: the job's OIDC token for a short session, no stored password,
 * hq#7076; or --fresh-account: a new person's own sign-up on the dev Stack project, made for this run, so the
 * journey sees what a teammate's first account gets) and walks the
 * same routes the app and the cmux CLI use, against the cmux API Worker (which forwards Cloud ops to
 * cmux-platform):
 *
 *   health -> sign in -> user.ensure -> install token -> sweep leaked journey machines -> create machine
 *   -> running (status) -> listed
 *   -> first exec -> pass Claude login -> start agent (acpmux on the machine) -> send chat -> reply -> turn 2 (same
 *   session) -> daemon restart keeps the session (the guest's agent daemon killed, then a turn) -> connect_info
 *   -> carrier dial (an identify answered over the machine's relay slot) -> handoff record -> pause -> resume
 *   -> carrier dial after resume -> turn after resume -> delete. `--skip lifecycle` leaves out the later turns and the daemon restart.
 *   --chaos adds the chaos leg after the carrier dial: a relay cut, 5 s and 60 s network drops, a session host and an
 *   agent daemon restart, each mid-turn and timed from a send at its end to the reply (cloud-chaos.ts).
 *   --start-via app starts the agent the way the app does (`agent-session-start` over the carrier dial, needs --cmux),
 *   not `acp ensure`: the step passes on a started session and fails with the refusal's code and `data.harness`
 *   (cloud-chat-matrix.ts judges its `start` cells on that, hq#11225); the chat steps after it are skipped.
 *
 * Each step prints PASS/FAIL/SKIP with its latency; --out DIR also gets journey.json (the steps) and
 * summary.md (a table for a PR comment or job summary). The machine this run made is deleted at the
 * end, pass or fail, by its exact id, unless --keep. A run that was killed before its cleanup leaves its
 * machines behind, holding the test account's machine quota: so before create (not with --machine or --keep),
 * the journey deletes `cloud journey auto jr-<tag>` machines (and their gateways) whose tag says they started
 * more than 3 hours ago (no journey job runs past 90 minutes) and that have had no activity for an hour, so a
 * running journey's machines are never touched.
 * Only a run that deletes its machine gives the `auto` name; a --keep run's plain `cloud journey jr-<tag>` is never
 * swept. Every page of the machine list is read, and each machine is logged before its delete.
 * A sweep error is recorded as a skip and the run goes on. Exit 0 only when no step failed.
 *
 * Exec goes the CLI's own way (`cmux machine access exec`: a client session minted at
 * POST /v1/cloud/machines/{id}/client-session, then the provider's exec-await). --cmux PATH runs every
 * exec through that cmux binary instead, so a CLI change is checked by the same journey.
 *
 * Pass Claude login gives the journey's machine a login of its own (cmux-platform#587): a `claude setup-token`
 * login (CLAUDE_CODE_OAUTH_TOKEN from the environment or --credentials; a made-up one with --model stub) goes
 * from the client straight to the machine over the machine routes, never kept by the platform. The app itself
 * copies no login (a Cloud machine's agents reach models through the Cloud service's model route), so the
 * preflight and installer programs are the journey's own, read from cloud-journey-login-installer.txt and run
 * through the exec and fs/write routes. Without a token the step is skipped and the reply fails "Not logged in".
 * A Claude login (stub or real model) is instead what a Cloud chat runs on since cmux#40159: the person's model
 * connection, given to the agent at its start (`session/new` `_meta.acpmux.credentials`, as the app's
 * `agent-session-start` relays it), never written onto the machine.
 *
 * --model stub makes the model endpoint the only stand-in: the shared model stub (tests/fixtures/model-stub) runs on
 * the machine's loopback
 * and Claude Code's settings point there (after the login copy, whose installer refuses a custom endpoint). The login
 * passed is a made-up setup-token shape, so no real credential exists. The reply must carry the stub's nonce, every
 * model request must carry the passed login (its SHA-256, which the stub logs: the credential hop), and one Bash tool
 * call must come back with its output. Account, machine, acpmux and the Claude Code binary are the real ones.
 *
 * --seed none|auto sets the create's seed (none: boot from the image even when the person has a machine to copy;
 * auto, the default, the server's choice). The summary and the probe row carry ready_ms, create machine to agent
 * running (create, running, first exec, login copy, start agent), when every one of those passed.
 *
 * --gateway CMUX_BIN: the chat machine holds no login at all (Leo, 2026-11-07: "VMs stop holding tokens"). A second
 * machine becomes the team's inference gateway: the person's own subscription proxy runs on it (--gateway-upstream URL,
 * or by default the shared model stub with the journey's nonce, as `stub`), and CMUX_BIN runs `cmux inference setup
 * --gateway-machine` (the install token in a 0600 file), which names it, starts `cmux inference gateway` there and
 * checks one real call from the chat machine. The chat's model calls then go chat machine -> coderouter edge -> cmux
 * (InferenceGateway) -> gateway machine -> proxy. Checked: the reply (with the stub, its nonce and tool round trip),
 * the gateway's log line for the chat machine's /v1/responses or /v1/messages, the proxy's own log, and that the chat
 * machine has no login file. The gateway machine is deleted with the chat machine.
 *
 * --gateway-local CMUX_BIN --gateway-upstream URL: the same chat, with `cmux inference gateway` on this computer (the
 * person's Mac) in front of the person's proxy at URL, holding this run's own install token in a 0600 file. Checked:
 * the reply, the local gateway's log line for the chat machine's call, and that the chat machine has no login file.
 * Either way the team is put in gateway mode before the chat machine is made (its edge route is picked when it is
 * made) and set back to its earlier mode at the end.
 *
 * Clean room: after the chat, the journey runs cloud-key-probe.py on the chat machine (as root when sudo asks no
 * password): every process's environment and command line, and the files under the homes, /etc, /opt, /srv and the
 * temp folders, searched for a model provider's key. The step names each finding by place and kind, never a value;
 * a run that could not read everything (not root, an unreadable file or process, the walk past its budget) is unknown.
 * With --gateway, --gateway-local or --keys-clean a finding or an unknown fails the step; otherwise it is report-only,
 * a skip that lists the findings (the login copy puts the person's login on the machine by design).
 * --keys-probe-out FILE appends the probe's whole answer with the run's tag and mode, one JSON line a run (back-to-back
 * runs keep every record); --skip keys leaves it out.
 *
 * --machines lists the agent test account's machines (one JSON line each, with `eligible` by the leaked journey
 * machine rule; --also-team T lists a second team too), and --delete-ids vm_a@JOB,vm_b@JOB deletes exactly those (at
 * most 5), each only when JOB is a trusted cmux-vm.yml deploy-staging job whose log shows it made the machine and its cleanup delete failed
 * (GITHUB_TOKEN reads it), the live list has it and the rule allows it, logged first (cmux-vm.yml action
 * journey-machines-staging).
 *
 * --desktop-link (with --cmux): once the machine runs, the desktop's UDP link instead of the chat. The journey is a
 * viewer of `cmux carrier dial --service desktop` (hello, start, a feedback datagram every half second) with its own
 * state dir, prints the account's team id and every `cloud.desktop_link machine=vm_… <note>` line of the dial's connect
 * log, writes them to desktop-link.json in --out, and fails unless a note is `up` or `host_up`. No line means the
 * platform sent no rd_link (the team's CLOUD_RD_LINK is off). Then the machine is deleted (cloud-rd-link-readback.yml).
 * --cleanup-tag jr-… deletes the machine a run with that tag made (`cloud journey auto jr-…`, its exact name), for a
 * workflow's always() step after a run cut off before its own cleanup. With --kept it also deletes the machine a
 * --keep run with that tag made (`cloud journey jr-…`), for the operator who kept it.
 *
 * --probe-out FILE writes the run as one synthetic-probe result row (cmuxterm-hq probes.py: probe, at,
 * outcome ok|fail, ms = send to first reply, error), --probe NAME naming it.
 *
 * Secrets are read from the environment or files, sent only in headers or request bodies, and never printed.
 */
import { AsyncLocalStorage } from "node:async_hooks";
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { appendFileSync, closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { constants as osConstants, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appStartDetail } from "./cloud-chat-matrix.ts";
import { collectGuestDiagnostics, type GuestDiagnostics } from "./cloud-journey-guest-diagnostics.ts";
import { parseRepoSeed, REPO_SEED_STEP, repoSeedDetail, repoSeedRuns, repoSeedScripts } from "./cloud-journey-repo-seed.ts";
import { ChatClient, chaosProbeRow, countingTurnScript, feltTurnScript, runChaos } from "./cloud-chaos.ts";
import { awaitPaused, runWakeEcho, setupProbe, startWithRetry, wakeEchoMarkdown, summarize as wakeEchoSummary, type WakeCycle } from "./cloud-wake-echo.ts";
import { FAIL_STREAK, parseServerTiming, RESUME_ARMS, type ResumeArm, resumeMarkdown, resumeRouteCall, type ResumeSample, type ResumeStop, runProviderArm, runResumeMatrix, syncRunning } from "./cloud-resume-matrix.ts";
import { clientSpans, hopDurations, mintSendTrace, modelFloor, readSendTrace, readStartTrace, sendTraceRows, sendTraceTable, slowestHop, snappyReport, snappyRun, traceMarkdown } from "./cloud-start-trace.ts";
import { answeredPath, answerTimings, DAEMON_CHECK, MachineFailed, pickVmApiTenant, type StartPath, type StartSample, type StartTarget, startBenchMarkdown, summarize, timeStart, traceFacts } from "./cloud-start-bench.ts";

// The shipped app's CloudMachineCreateFlow.named and the platform's CHAT_START_SHAPE (2/4/20, cmux-platform#1756).
// Any other explicit ask cannot claim that pool, even when warm-spare just reported a ready machine.
export const CHAT_START_SIZE = Object.freeze({ cpu: 2, memory_mb: 4096, disk_mb: 20480 });
/** The "default machine size" step: after the create, cloud.machine.get reads back the chat start size. */
export const DEFAULT_SIZE_STEP = "default machine size";

/** Null when the size cloud.machine.get recorded is CHAT_START_SIZE on every axis; else what it read. */
export function defaultSizeProblem(size: { cpu?: unknown; memory_mb?: unknown; disk_mb?: unknown } | null | undefined): string | null {
  const read = `${size?.cpu ?? "?"}/${size?.memory_mb ?? "?"}/${size?.disk_mb ?? "?"}`;
  const want = `${CHAT_START_SIZE.cpu}/${CHAT_START_SIZE.memory_mb}/${CHAT_START_SIZE.disk_mb}`;
  return read === want ? null : `cloud.machine.get size ${read}, not the default ${want} (cpu/memory_mb/disk_mb)`;
}
/**
 * The "cold create" cell's size: the catalog's md (4 vCPU / 8 GiB / 32 GiB). The Scaler makes spares at the chat start
 * size only and gives one only to a create asking exactly that (cmux-platform Scaler requestShape), so a create at md
 * boots cold, as a person's own create of a picked size does. It differs from the image's own 2/4/16 on every axis, so
 * a create the VM API booted at the image's size reads as one.
 */
export const COLD_CREATE_SIZE = Object.freeze({ cpu: 4, memory_mb: 8192, disk_mb: 32768 });
/** The guest reads a little under the size asked: the kernel keeps some memory, the filesystem some disk (16203 of 16384 MiB, 64328 of 65536 MiB at 4/16/64). */
const SIZE_READ_SLACK = 0.06;

/**
 * Null when a guest's `cpu=N mem_mib=N disk_mib=N` reading (the "first exec" command) is the size asked: the CPU count
 * exactly, memory and disk at most the size asked and within SIZE_READ_SLACK under it. Else why not.
 */
export function sizeReadingProblem(stdout: string, asked: { cpu: number; memory_mb: number; disk_mb: number }): string | null {
  const read = (key: string) => {
    const m = new RegExp(`\\b${key}=(\\d+)`).exec(stdout);
    return m ? Number(m[1]) : null;
  };
  const cpu = read("cpu");
  const mem = read("mem_mib");
  const disk = read("disk_mib");
  if (cpu === null || mem === null || disk === null) return `no cpu=, mem_mib= and disk_mib= reading in ${JSON.stringify(stdout.trim().slice(-200))}`;
  const near = (got: number, want: number) => got <= want && got >= want * (1 - SIZE_READ_SLACK);
  const off = [
    cpu === asked.cpu ? "" : `cpu ${cpu} (asked ${asked.cpu})`,
    near(mem, asked.memory_mb) ? "" : `mem_mib ${mem} (asked ${asked.memory_mb})`,
    near(disk, asked.disk_mb) ? "" : `disk_mib ${disk} (asked ${asked.disk_mb})`,
  ].filter(Boolean);
  return off.length ? `booted at another size than asked: ${off.join(", ")}` : null;
}

export const STACK_API = "https://api.stack-auth.com";
export const STACK = {
  dev: { project: "454ecd03-1db2-4050-845e-4ce5b0cd9895", clientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g" },
  prod: { project: "9790718f-14cd-4f7e-824d-eaf527a82b82", clientKey: "" },
} as const;
type StackName = keyof typeof STACK;

export type Backend = { name: string; api: string; stack: StackName };

/** Preserve custom API names; canonicalize environment aliases only for the built-in routes. */
function normalizeBackendName(name: string, apiOverride?: string): string {
  if (apiOverride) return name || "custom";
  return name === "production" ? "prod" : name === "development" ? "dev" : name;
}

/** The backend names this journey knows (CloudConfiguration.swift, backend/scripts/deploy-worker.sh). */
export function resolveBackend(name: string, apiOverride?: string, stackOverride?: string, localPort = 8787): Backend {
  name = normalizeBackendName(name, apiOverride);
  const stack = (s: StackName): StackName => (stackOverride === "dev" || stackOverride === "prod" ? stackOverride : s);
  if (apiOverride) return { name, api: apiOverride.replace(/\/+$/, ""), stack: stack("dev") };
  // preview-<PR> (backend.yml) or preview-<tag> (a personal dev Worker, cloud-dev-loop.sh).
  const preview = /^preview-([a-z0-9][a-z0-9-]{0,40})$/.exec(name);
  if (preview) return { name, api: `https://cmux-api-preview-${preview[1]}.debussy.workers.dev`, stack: stack("dev") };
  switch (name) {
    case "local":
      return { name, api: `http://127.0.0.1:${localPort}`, stack: stack("dev") };
    case "dev":
      return { name: "dev", api: "https://cmux-api-development.debussy.workers.dev", stack: stack("dev") };
    case "staging":
      return { name, api: "https://cloud-api-staging.cmux.dev", stack: stack("dev") };
    case "prod":
      return { name: "prod", api: "https://cloud-api.cmux.dev", stack: stack("prod") };
    default:
      throw new Error(`--backend ${name}: one of local, dev, preview-N (or preview-TAG), staging, prod (or --api URL)`);
  }
}

/** KEY=value lines; values never leave this process. */
export function readEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (m) out[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, "$2");
  }
  return out;
}

export type Status = "pass" | "fail" | "skip";
export type FirstTextFields = { create_marks_ms?: Record<string, number>; create_to_first_text_ms?: number; guest_ms?: Record<string, number>; reserved_hit?: boolean };
export type Step = { step: string; status: Status; ms: number; detail: string; fields?: FirstTextFields };

/** One runner monotonic clock, from the create call. Reused machines have no create measurement. */
export class FirstTextTiming {
  private start: number | undefined;
  private marks: Record<string, number> = {};
  private onGuest: Record<string, number> = {};
  constructor(private readonly clock = () => performance.now()) {}
  /** A part as the guest timed it (its own clock, without the exec route's trip): `guest_ms` beside the marks. */
  guest(part: string, ms: number | null): void {
    if (ms !== null && Number.isFinite(ms) && ms >= 0 && !(part in this.onGuest)) this.onGuest[part] = Math.round(ms);
  }
  mark(phase: string): void {
    if (phase === "create" && this.start === undefined) {
      this.start = this.clock();
      this.marks.create = 0;
      return;
    }
    if (this.start === undefined || phase in this.marks) return;
    this.marks[phase] = Math.round(this.clock() - this.start);
  }
  fields(): FirstTextFields {
    if (this.start === undefined) return {};
    return {
      create_marks_ms: { ...this.marks },
      ...(this.marks.first_text !== undefined ? { create_to_first_text_ms: this.marks.first_text } : {}),
      ...(Object.keys(this.onGuest).length ? { guest_ms: { ...this.onGuest } } : {}),
    };
  }
}

/** Words that may never reach the log, the JSON or a PR comment, whatever an answer holds. */
// scrub also runs on serialized JSON, so no shape may cross a `"` or `\`: `Bearer\s+\S+` ate the `\"}` after "bearer
// token" in a 401 and left all five 300 s wake-echo.json files unparsable (run 45510772491).
// No word boundaries: a token glued to other characters (`prefix_<key>` in a path) is still a token.
const SECRET_SHAPES = [/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+/g, /(cmvm|cmk|cmuxvm_sk|cmm|pck|ssk)_[A-Za-z0-9_-]{8,}/g, /[Bb]earer\s+[^\s"\\]+/g,
  // Every shape in cloud-key-probe.py SHAPES, whatever text carries one: a probe answer, an error, a path. A test
  // holds one example of each probe shape and checks this list removes it, so a new shape cannot miss it.
  /sk-ant-[a-z]{3}\d\d-[A-Za-z0-9_-]{20,}/g, /sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}/g, /sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}/g,
  /sk-or-v1-[0-9a-f]{32,}/g, /AIza[0-9A-Za-z_-]{35}/g, /xai-[A-Za-z0-9]{40,}/g, /gsk_[A-Za-z0-9]{40,}/g, /hf_[A-Za-z0-9]{30,}/g,
  /(?:AKIA|ASIA)[0-9A-Z]{16}/g, /("refresh_token"\s*:\s*")[^"\s]{20,}"/g];
export function scrub(text: string, secrets: string[] = []): string {
  let out = text;
  for (const s of secrets) if (s && s.length >= 6) out = out.split(s).join("[secret]");
  for (const re of SECRET_SHAPES) out = out.replace(re, (whole, field?: string) => (typeof field === "string" ? `${field}[secret]"` : "[secret]"));
  return out;
}

/** The steps from asking for a machine to its agent running, in order (cmux#36050). */
export const READY_STEPS: readonly ((step: string) => boolean)[] = [
  (s) => s === "create machine",
  (s) => s === "running (status)",
  (s) => s === "first exec",
  (s) => s === "pass Claude login" || s === "pass Codex login",
  (s) => s.startsWith("start agent ("),
];

/** Create machine to agent running, in ms: the sum of the READY_STEPS, or null unless each one ran and passed. */
export function readyMs(steps: Step[]): number | null {
  let total = 0;
  for (const is of READY_STEPS) {
    const s = steps.find((x) => is(x.step));
    if (s?.status !== "pass") return null;
    total += s.ms;
  }
  return total;
}

/** A failed command's output for a step's detail: its start, where a CLI puts the error, and its end. */
const headTail = (out: string): string => (out.length <= 600 ? out : `${out.slice(0, 300)} ... ${out.slice(-300)}`);

export function summaryMarkdown(backend: Backend, steps: Step[], meta: Record<string, string> = {}): string {
  const failed = steps.filter((s) => s.status === "fail").length;
  const total = steps.reduce((n, s) => n + s.ms, 0);
  const ready = readyMs(steps);
  const head = `${failed ? "FAIL" : "PASS"}: Cloud journey on \`${backend.name}\` (${backend.api}), ${(total / 1000).toFixed(1)} s${ready === null ? "" : `; create machine to agent running ${(ready / 1000).toFixed(1)} s`}`;
  const extra = Object.entries(meta).map(([k, v]) => `${k}: ${v}`).join(", ");
  const rows = steps.map((s) => `| ${s.status === "pass" ? "pass" : s.status === "fail" ? "**FAIL**" : "skip"} | ${s.step} | ${s.ms} | ${s.detail.replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 1000)} |`);
  return [head, extra ? `\n${extra}` : "", "", "| result | step | ms | detail |", "|---|---|---:|---|", ...rows, ""].join("\n");
}

/** Preclaim artifacts are public: retain only the step outcome, never an API response or identifier. */
export function preclaimPublicStep(step: Step): Step {
  return { ...step, detail: step.status };
}

/** Preclaim artifacts carry no account, team, install, or run identifiers in their metadata. */
export function preclaimPublicMeta(): Record<string, string> {
  return { mode: "preclaim" };
}

export class Journey {
  readonly steps: Step[] = [];
  readonly guestDiagnostics: GuestDiagnostics[] = [];
  readonly secrets: string[] = [];
  readonly firstText = new FirstTextTiming();
  preclaimRows: PreclaimClaimRecord[] | null = null;
  preclaimBurst: PreclaimBurstFacts | null = null;
  preclaimFailures: PreclaimFailureRecord[] = [];
  constructor(readonly backend: Backend, private readonly outDir: string | null, readonly meta: Record<string, string>, private readonly publicSafe = false) {}
  async step<T>(name: string, fn: () => Promise<{ value: T; detail: string }>): Promise<T> {
    const t0 = Date.now();
    // Notes the API client adds while this step runs (a retried answer), so a retry stays visible in the step's detail.
    const notes: string[] = [];
    const withNotes = (detail: string) => (notes.length ? `${detail}; ${[...new Set(notes)].join("; ")}` : detail);
    try {
      const { value, detail } = await stepNotes.run(notes, fn);
      this.record({ step: name, status: "pass", ms: Date.now() - t0, detail: withNotes(detail) });
      return value;
    } catch (error) {
      this.record({ step: name, status: "fail", ms: Date.now() - t0, detail: withNotes(String((error as Error)?.message ?? error)).slice(0, 1000) });
      throw error;
    }
  }
  skip(name: string, why: string): void {
    this.record({ step: name, status: "skip", ms: 0, detail: why });
  }
  record(s: Step): void {
    const fields = this.firstText.fields();
    if (fields.create_marks_ms) s.fields = { ...fields, ...s.fields };
    s = this.publicSafe ? preclaimPublicStep(s) : { ...s, detail: scrub(s.detail, this.secrets) };
    this.steps.push(s);
    console.log(`${s.status.toUpperCase().padEnd(4)} ${s.step} ${s.ms} ms :: ${s.detail}`);
    this.flush();
  }
  flush(): void {
    if (!this.outDir) return;
    const meta = this.publicSafe ? preclaimPublicMeta() : this.meta;
    writeFileSync(path.join(this.outDir, "journey.json"), `${JSON.stringify({ backend: this.backend, meta, steps: this.steps }, null, 2)}\n`);
    writeFileSync(path.join(this.outDir, "guest-updater.json"), `${JSON.stringify({ schema: 1, observations: this.guestDiagnostics }, null, 2)}\n`);
    const preclaim = this.preclaimRows === null ? "" : `\n${preclaimSummaryMarkdown(this.preclaimRows, this.preclaimFailures, this.preclaimBurst)}`;
    writeFileSync(path.join(this.outDir, "summary.md"), summaryMarkdown(this.backend, this.steps, meta) + preclaim);
  }
}

type Answer = { status: number; body: any; headers?: Headers };

/**
 * The request died on its socket before any answer came back: the peer reset or closed it (Bun: ECONNRESET "The
 * socket connection was closed unexpectedly", or ConnectionClosed; Node: UND_ERR_SOCKET, EPIPE). A timeout is not one:
 * the server may still be working on it.
 */
/**
 * The client gave up waiting (AbortSignal.timeout): the server may still finish the op. Under an idempotency key
 * asking again is safe and returns that op's answer; staging's create under its VM cap ran past 60 s and failed
 * cloud-fork-placement and runnable-link at parent create (runs 45573771511, 45570177493, 45571955695).
 */
export function requestTimedOut(error: unknown): boolean {
  for (let e: any = error, depth = 0; e && depth < 3; e = e.cause, depth++) {
    if (e.name === "TimeoutError" || /the operation timed out/i.test(String(e.message ?? ""))) return true;
  }
  return false;
}

export function socketDropped(error: unknown): boolean {
  for (let e: any = error, depth = 0; e && depth < 3; e = e.cause, depth++) {
    if (["ECONNRESET", "ConnectionClosed", "UND_ERR_SOCKET", "EPIPE", "ECONNABORTED"].includes(String(e.code ?? ""))) return true;
    if (/socket connection was closed unexpectedly/i.test(String(e.message ?? ""))) return true;
  }
  return false;
}

/**
 * One HTTP request. With `repeatable` (a read, a GET, or an op under an idempotency key) a request whose socket
 * drops before any answer is sent once more on a fresh connection (keepalive off), so one stale pooled socket can't
 * fail a step: run 43927514723's connect_info read died 40 ms in with ECONNRESET on the first request after a
 * 122 s idle step, a socket the edge had closed while it sat in the pool.
 */
export async function http(method: string, url: string, body: unknown, headers: Record<string, string>, timeoutMs = 30_000, repeatable = method === "GET" || method === "HEAD"): Promise<Answer> {
  const send = (fresh: boolean) =>
    fetch(url, {
      method,
      headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
      ...(fresh ? { keepalive: false } : {}),
    });
  let res: Response;
  try {
    res = await send(false);
  } catch (error) {
    if (!repeatable || !socketDropped(error)) throw error;
    try {
      res = await send(true);
    } catch (again) {
      throw new Error(`${(again as Error)?.message ?? again} (sent once more on a fresh connection after: ${(error as Error)?.message ?? error})`);
    }
  }
  const text = await res.text();
  let parsed: any;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text.slice(0, 300) };
  }
  return { status: res.status, body: parsed, headers: res.headers };
}

/** Lets a provider request still running after 60 s answer 202 instead of being held open (see settleBackground). */
export const BACKGROUND_AFTER = { "x-freestyle-background-after-secs": "60" } as const;
const BACKGROUND_ID = /^[A-Za-z0-9_.:-]{1,128}$/;

/**
 * The final answer of a provider request sent with BACKGROUND_AFTER. Freestyle's edge cuts a request it holds open at
 * about 120 s (an exec-await of a 290 s command answered 524 after 125 s, production 2026-11-21), so a request still
 * running after 60 s answers 202 with a request id, and GET /v5/background-requests/{id} (with the same `headers`)
 * answers 202 until the stored answer is ready, then that answer, which comes back whatever its status. Five failed
 * polls in a row (no answer, 429 or 5xx), or no answer by `deadlineAt`, throw: the command may have run. cmux-vm
 * (workers/cmux-vm/src/upstream/live-background.ts) and the CLI (cmux-cloud-api background.rs) do the same.
 */
export async function settleBackground(answer: Answer, apiBase: string, headers: Record<string, string>, deadlineAt: number, pollMs = 2_000, fetchJson: typeof http = http): Promise<Answer> {
  if (answer.status !== 202) return answer;
  const id = answer.headers?.get("x-freestyle-background-request-id") ?? answer.body?.requestId ?? answer.body?.request_id;
  if (typeof id !== "string" || !BACKGROUND_ID.test(id)) throw new Error("background request: the 202 names no request");
  const url = `${apiBase.replace(/\/+$/, "")}/v5/background-requests/${id}`;
  let failures = 0;
  while (Date.now() + pollMs < deadlineAt) {
    await new Promise((r) => setTimeout(r, pollMs));
    const poll = await fetchJson("GET", url, undefined, headers, Math.max(1, Math.min(30_000, deadlineAt - Date.now()))).catch(() => null);
    if (poll && poll.status === 202) failures = 0;
    else if (poll && poll.status !== 429 && poll.status < 500) return poll;
    else if (++failures >= 5) break;
  }
  throw new Error(`background request ${id}: no answer by the deadline (the command may have run)`);
}

const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300);

/**
 * --sign-in oidc: the GitHub Actions job's OIDC token (audience: the API origin) traded at the API's
 * POST /v1/auth/github-actions for a short Stack session of the one test account the API trusts that job
 * with (backend/apps/api/src/ci-session.ts). Both tokens are pushed to `secrets` before anything can print.
 */
export async function oidcSignIn(apiOrigin: string, env: Record<string, string | undefined>, secrets: string[], fetchJson: typeof http = http): Promise<{ token: string; user: string; expiresAt: string }> {
  const url = env.ACTIONS_ID_TOKEN_REQUEST_URL;
  const bearer = env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
  if (!url || !bearer) throw new Error("no GitHub Actions OIDC token: the job needs `permissions: id-token: write`");
  secrets.push(bearer);
  const sep = url.includes("?") ? "&" : "?";
  const gh = await fetchJson("GET", `${url}${sep}audience=${encodeURIComponent(apiOrigin)}`, undefined, { authorization: `bearer ${bearer}` });
  if (gh.status !== 200 || typeof gh.body.value !== "string") throw new Error(`GitHub OIDC token HTTP ${gh.status}`);
  secrets.push(gh.body.value);
  const r = await fetchJson("POST", `${apiOrigin}/v1/auth/github-actions`, undefined, { authorization: `Bearer ${gh.body.value}` });
  // Name the two ways a correct job is refused, so a red run says what to change (cmux#35703).
  if (r.status === 404) throw new Error(`OIDC sign-in HTTP 404: ${apiOrigin} has no POST /v1/auth/github-actions yet (deploy a cmux-api commit with ci-session.ts)`);
  if (r.status === 401) throw new Error(`OIDC sign-in HTTP 401: ${apiOrigin} refused this job's token: no valid CI_SESSION_TRUST row matches it (repository, ref, workflow_ref, event_name and sub must equal a row's), or the token was already used`);
  if (r.status !== 200 || typeof r.body.access_token !== "string") throw new Error(`OIDC sign-in HTTP ${r.status} ${String(r.body.error ?? "")}`);
  secrets.push(r.body.access_token);
  return { token: r.body.access_token, user: String(r.body.user ?? "?"), expiresAt: String(r.body.session_expires_at ?? "?") };
}

const OP_ATTEMPTS = 3;
/** How long a machine delete keeps retrying an indeterminate answer under its key. */
const DELETE_BUDGET_MS = 180_000;
/** The ops API says a provider call was cut off and the same idempotency key may be sent again. */
export const opRetryable = (body: any): boolean => body?.ok !== true && body?.error?.code === "mutation.indeterminate" && body?.error?.retryable === true;
/**
 * The platform says the request's owner was reset or cut off mid-call (owner.unreachable, retryable), for example
 * HTTP 503 `{"code":"owner.unreachable","message":"Error: Network connection lost.","retryable":true}` or a
 * CallTimedOut. A real client sends the same request once more. The error sits under `error` or at the top.
 */
export const ownerUnreachable = (body: any): boolean => {
  if (body?.ok === true) return false;
  const e = body?.error && typeof body.error === "object" ? body.error : body;
  return e?.code === "owner.unreachable" && e?.retryable === true;
};
/** How long the resume matrix's send arm waits for cmux's own idle pause: the aggressive policy's 60 s window after
 * the turn ends, the VM's next activity report, and the pause itself. */
const AUTO_PAUSE_WAIT_MS = 300_000;
/** The pause before that one retry. */
const OWNER_RETRY_MS = 1000;
const OWNER_RETRY_NOTE = "retried once after owner.unreachable";
/** The running Journey step's notes; the API client adds a note here when it retries. */
const stepNotes = new AsyncLocalStorage<string[]>();

/** One cloud.machine.create attempt's wait. A fresh staging create holds the call open past 60 s
 *  (151 s, 2026-11-25), so a 60 s cut made every journey and bench fail its create and leak the machine. */
export const CREATE_OP_TIMEOUT_MS = 300_000;

export class Api {
  bearer = "";
  constructor(readonly origin: string, readonly team?: string) {}
  private headers(): Record<string, string> {
    return { authorization: `Bearer ${this.bearer}`, ...(this.team ? { "x-cmux-team": this.team } : {}) };
  }
  /** `extra`: headers for this op only (a send's trace headers, cloud-start-trace.ts mintSendTrace).
   *  `timeoutMs` is one attempt's wait; a machine create gets CREATE_OP_TIMEOUT_MS by default. */
  async op(op: string, params: unknown, key?: string, extra: Record<string, string> = {}, timeoutMs = op === "cloud.machine.create" ? CREATE_OP_TIMEOUT_MS : 60_000): Promise<any> {
    let ownerRetried = false;
    for (let attempt = 1; ; attempt++) {
      let r: Answer;
      try {
        r = await http("POST", `${this.origin}/v1/ops`, { op, params, ...(key ? { idempotency_key: key } : {}) }, { ...this.headers(), ...extra }, timeoutMs, !!key);
      } catch (error) {
        // A keyed op the client stopped waiting on: ask again under the same key, which cannot apply it twice.
        if (key && attempt < OP_ATTEMPTS && requestTimedOut(error)) { await sleep(2000 * attempt); continue; }
        throw error;
      }
      // A provider call cut off mid-way is safe to repeat under the same key; without it a cleanup delete leaks the VM.
      if (key && attempt < OP_ATTEMPTS && opRetryable(r.body)) { await sleep(2000 * attempt); continue; }
      // An owner reset: once more, under the same key so the op cannot apply twice.
      if (key && !ownerRetried && ownerUnreachable(r.body)) {
        ownerRetried = true;
        stepNotes.getStore()?.push(OWNER_RETRY_NOTE);
        await sleep(OWNER_RETRY_MS);
        continue;
      }
      if (r.status !== 200 || r.body.ok !== true) throw new Error(`${op}: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
      return r.body.value;
    }
  }
  /**
   * A machine delete that must not leak: retried under the same key while the ops API answers it was cut off
   * (mutation.indeterminate, retryable), for up to `budgetMs`. op() gives up after three tries in about six
   * seconds, which leaked a machine on a 502 storm (cmux-vm run 42485334511).
   */
  async deleteMachine(machine: string, key: string, budgetMs = DELETE_BUDGET_MS): Promise<any> {
    const until = Date.now() + budgetMs;
    for (let attempt = 1; ; attempt++) {
      const r = await http("POST", `${this.origin}/v1/ops`, { op: "cloud.machine.delete", params: { machine }, idempotency_key: key }, this.headers(), 60_000, true);
      if (opRetryable(r.body) && Date.now() < until) { await sleep(Math.min(2000 * attempt, 15_000)); continue; }
      if (r.status !== 200 || r.body.ok !== true) throw new Error(`cloud.machine.delete: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
      return r.body.value;
    }
  }
  async read(op: string, params: unknown, timeoutMs = 30_000): Promise<any> {
    let r = await http("POST", `${this.origin}/v1/read`, { op, params }, this.headers(), timeoutMs, true);
    // A read changes nothing, so an owner reset is read once more.
    if (ownerUnreachable(r.body)) {
      stepNotes.getStore()?.push(OWNER_RETRY_NOTE);
      await sleep(OWNER_RETRY_MS);
      r = await http("POST", `${this.origin}/v1/read`, { op, params }, this.headers(), timeoutMs, true);
    }
    if (r.status !== 200 || (r.body.ok === false)) throw new Error(`${op}: HTTP ${r.status} ${short(r.body.error ?? r.body)}`);
    return r.body.value;
  }
  async raw(method: string, route: string, body?: unknown, timeoutMs = 60_000, extra: Record<string, string> = {}): Promise<Answer> {
    return http(method, `${this.origin}${route}`, body, { ...this.headers(), ...extra }, timeoutMs);
  }
}

export type PreclaimClaimSplit = {
  claim_answer_ms: number | null;
  join_ms: number | null;
  guest_bind_ms: number | null;
  connect_info_ms: number | null;
  bound_ms: number | null;
};

export type PreclaimHealthSnapshot = {
  http_status: number;
  outcome: "ok" | "error";
  commit: string | null;
  /** Why `commit` is null: the answer's status, or what it named instead of a deploy commit. */
  commit_unavailable: string | null;
};

/**
 * The MET table's per-claim fields. Every value that could not be measured is null with its `*_unavailable` reason,
 * never 0, so the table reads `unavailable: <reason>` instead of a number nobody measured.
 */
export type PreclaimMetFields = {
  /** The claim's spare, from its created_at to its cloud.spare.ready (the frame's `at`, else its running_since). */
  refill_to_ready_ms: number | null;
  refill_to_ready_unavailable: string | null;
  /** The claim answer's value.claim.behind (cmux-platform#1429) for that same spare: one image roll behind or current. */
  refill_image: "behind" | "current" | null;
  refill_image_unavailable: string | null;
  /** After bind, the login check: the spare's receipt on a hit, the post-bind copy on a miss. */
  post_bind_login_ms: number | null;
  post_bind_login_ms_unavailable: string | null;
  /** From the claim's create request to the agent's first reply text. */
  claim_to_first_text_ms: number | null;
  claim_to_first_text_unavailable: string | null;
  /** The platform deploy commit serving the claim (its /v1/health `commit`), else the API's. */
  staging_sha: string | null;
  staging_sha_unavailable: string | null;
  /** Whether a deploy commit changed between the claim's health_before and health_after reads. */
  deploy_overlap: boolean | null;
  deploy_overlap_unavailable: string | null;
};

export type PreclaimClaimRecord = {
  claim: number;
  machine: string | null;
  spare: string | null;
  lease_id: string | null;
  lease_hit: boolean | null;
  health_before: PreclaimHealthSnapshot;
  health_after: PreclaimHealthSnapshot;
  /** The platform origin's /v1/health around the claim: the API's carries only a fixed API version. */
  platform_health_before: PreclaimHealthSnapshot;
  platform_health_after: PreclaimHealthSnapshot;
  claim_to_bound: PreclaimClaimSplit;
  post_bind_login: "receipt" | "post-bind" | "missing" | "not_checked";
  first_chat_ms: number | null;
  first_reply_ms: number | null;
  /**
   * Whether the warm (the app's pre-claim login path, POST /v1/cloud/spare/warm) named a spare before the claim. Kept
   * apart from lease_hit, which the claim answer says: a hit the warm did not name got no login attached in advance.
   */
  warm_named: boolean;
  /**
   * Whether the install token's team (the team the Rust warm warms in, install_team) was the team a claim with no
   * x-cmux-team lands on (the session's personal team); null when either is unknown. When not, the burst sends its claims
   * in the warm's team, as the app sends both in its active team.
   */
  warm_team_matches_claim: boolean | null;
  /** The warm's own reason when it named none (spare.none, not_eligible, no_plan, ...), else null. */
  warm_reason: string | null;
  /** What ended the claim's wait for a ready spare: the warm named one, or the claim path reported one ready; null otherwise. */
  spare_ready_by: "warm" | "claim_path" | null;
} & PreclaimMetFields;

/** The burst-wide MET facts, read once before claim 0. */
export type PreclaimBurstFacts = {
  claims_expected: number;
  /** The account's machine-minutes this period at t0 (cloud.plan.get usage, the caller's share when it is split). */
  hold_minutes_t0: number | null;
  hold_minutes_t0_unavailable: string | null;
  /**
   * Why the first reply was not judged (the model refused or never answered the turn), else null. The reply is measured,
   * never gated: run 43860687099's claim worked and its turn hit the test account's weekly limit.
   */
  reply_not_judged: string | null;
  /** How long the claim waited for the warm to name a ready spare (--spare-wait); null when the burst does not wait. */
  spare_wait_ms: number | null;
  /** The wait's bound ran out with no ready spare, so the claim went ahead: a cold create here is not a claim-path miss. */
  cold_after_wait: boolean;
  /** The claim answer's value.claim.behind (cmux-platform#1429): the spare was held across an image roll; null with no claim. */
  claimed_behind: boolean | null;
  /** The claim answer's skipped spares by reason (cmux-platform#1418), e.g. image or a #1414 guard reason; null when absent. */
  spare_skips: Record<string, number> | null;
  spare_fallback: string | null;
};

export type PreclaimFailureRecord = {
  claim: number;
  outcome: "fail";
  error: string;
  /** The claimed machine's facts at the failure (preclaimGuestFacts), when it existed. */
  guest?: string;
  /** Whether the failed claim had taken a spare held across a roll (null when it failed before the claim answered). */
  claimed_behind: boolean | null;
};

/**
 * Guest facts within 12,000 characters, the sections before the journal first: run 43873927808 kept only the last 8,000,
 * and the journal pushed out the own-login and acp tail sections that say why a claim failed.
 */
function guestFactsCapped(guest: string, max = 12_000): string {
  const at = guest.indexOf("== journal");
  if (guest.length <= max || at < 0) return guest.slice(0, max);
  const head = guest.slice(0, Math.min(at, max / 2));
  const mark = "== journal (last lines)\n";
  return head + mark + guest.slice(at).slice(-(max - head.length - mark.length));
}

/** A failed claim stays visible in the private evidence without exposing credentials publicly. */
export function preclaimFailureRecord(claim: number, error: unknown, secrets: string[] = [], claimedBehind: boolean | null = null, guest?: string): PreclaimFailureRecord {
  return { claim, outcome: "fail", error: scrub(String(error instanceof Error ? error.message : error), secrets).slice(0, 600), claimed_behind: claimedBehind, ...(guest === undefined ? {} : { guest: guestFactsCapped(scrub(guest, secrets)) }) };
}

/**
 * What the claimed machine shows when a claim fails after it exists (run 43824872130: the first chat's `acp wait` exited
 * 1 and the machine was deleted with no trace): whether the guest sees its own Claude login, the chat session's acp
 * events and the journal's agent lines. Private rows only, scrubbed by the caller; never the login itself.
 */
export async function preclaimGuestFacts(exec: Exec, session: string): Promise<string> {
  const facts = await exec([
    `${GUEST}echo "== own login"; (. /etc/cmux/agent-auth.sh >/dev/null 2>&1 && HOME=/home/cmux cmux_agent_has_own_login claude) && echo yes || echo no`,
    `echo "== acp tail ${session}"; "$c" acp tail ${shq(session)} 2>&1 | tail -40 | cut -c1-400`,
    `echo "== acp list"; "$c" acp list 2>&1 | tail -10 | cut -c1-300`,
    `echo "== journal"; journalctl -m --no-pager -o short-monotonic --since -15min 2>/dev/null | grep -iE 'acp|claude|auth|login|harness' | tail -80 | cut -c1-400`,
  ].join("; "), 60_000).catch((error) => ({ code: 1, stdout: `unreadable: ${String((error as Error)?.message ?? error).slice(0, 200)}`, stderr: "" }));
  return facts.stdout;
}

export function preclaimRunComplete(rows: PreclaimClaimRecord[], failures: PreclaimFailureRecord[], expectedClaims: number): boolean {
  return rows.length === expectedClaims && failures.length === 0;
}

type WireEvent = { t?: string; event?: string; stream?: string; data?: Record<string, unknown>; spares_needing_login?: unknown };

/** The claim answer's explicit lease evidence. Text is accepted only for the broker's named lease field. */
export function classifyLeaseHit(answer: unknown, brokerLog = ""): boolean | null {
  const row = answer && typeof answer === "object" ? answer as Record<string, unknown> : {};
  for (const key of ["lease_hit", "leaseHit", "spare_hit", "spareHit"]) {
    if (typeof row[key] === "boolean") return row[key] as boolean;
  }
  for (const key of ["source", "claim_source", "claimSource", "allocation_source"]) {
    if (typeof row[key] === "string" && /^(spare|warm|lease)$/i.test(row[key] as string)) return true;
    if (typeof row[key] === "string" && /^(cold|create)$/i.test(row[key] as string)) return false;
  }
  const explicit = /(?:^|\s)lease[_-]?hit=(yes|no)\b/i.exec(brokerLog);
  return explicit ? explicit[1].toLowerCase() === "yes" : null;
}

/**
 * Whether the claim took a spare, from the create answer's own report (cmux-platform#1418, #1429): a `claim` object and
 * no `spare_fallback` is a take; a fallback is a create. Null when the answer carries neither (a platform from before).
 * Burst 43951741299 called 9 of 9 claims cold because the warm had named no spare, while 7 of their answers took one.
 */
export function claimTookSpare(answer: unknown): boolean | null {
  const v = answer && typeof answer === "object" ? answer as Record<string, unknown> : {};
  if (typeof v.spare_fallback === "string" && v.spare_fallback) return false;
  return v.claim && typeof v.claim === "object" && !Array.isArray(v.claim) ? true : null;
}

/** The team claim of an install token (its JWT payload's `team`): the team the Rust warm-spare verb warms in (install_team). */
export function installTokenTeam(token: string): string | null {
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const claims = JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
    return typeof claims?.team === "string" && claims.team ? claims.team : null;
  } catch {
    return null;
  }
}

/** The warm's reason as a bare code (`spare.none`, `not_eligible`), else null: never an id or free text. */
function warmReasonToken(value: unknown): string | null {
  return typeof value === "string" && /^[a-z][a-z0-9_.]{0,39}$/.test(value) && !ID_SHAPE.test(value) ? value : null;
}

/** Convert the broker's ordered stage timings into the named claim-to-bound split. */
export function claimToBoundSplit(stages: unknown): PreclaimClaimSplit {
  const out: PreclaimClaimSplit = { claim_answer_ms: null, join_ms: null, guest_bind_ms: null, connect_info_ms: null, bound_ms: null };
  const entries: unknown[] = Array.isArray(stages)
    ? stages
    : stages && typeof stages === "object" && Array.isArray((stages as Record<string, unknown>).steps)
      ? (stages as Record<string, unknown>).steps as unknown[]
      : [];
  let total = 0;
  for (const stage of entries) {
    if (!stage || typeof stage !== "object" || typeof (stage as any).ms !== "number") continue;
    total += Number((stage as any).ms);
    const name = String((stage as any).step ?? (stage as any).name ?? "");
    const key = name === "machine" || name === "claim" || name === "claim_answer" ? "claim_answer_ms"
      : name === "join" ? "join_ms"
      : name === "guest_bind" || name === "bind" ? "guest_bind_ms"
      : name === "connect_info" || name === "connect" ? "connect_info_ms"
      : name === "bound" ? "bound_ms" : null;
    if (key) out[key] = Math.round(total);
  }
  return out;
}

export function preclaimClaimRecord(input: {
  claim: number;
  machine?: unknown;
  spare?: unknown;
  answer?: unknown;
  brokerLog?: string;
  leaseId?: unknown;
  leaseHit?: boolean | null;
  healthBefore?: PreclaimHealthSnapshot;
  healthAfter?: PreclaimHealthSnapshot;
  platformHealthBefore?: PreclaimHealthSnapshot;
  platformHealthAfter?: PreclaimHealthSnapshot;
  postBindLogin?: "receipt" | "post-bind" | "missing" | "not_checked";
  firstChatMs?: number | null;
  firstReplyMs?: number | null;
  met?: Partial<PreclaimMetFields>;
  replyNotJudged?: string | null;
  spareWait?: SpareWait | null;
  /** The warm named a spare before the claim; defaults to whether `spare` is set. */
  warmNamed?: boolean;
  warmReason?: string | null;
  warmTeamMatchesClaim?: boolean | null;
}): PreclaimClaimRecord {
  const answer = input.answer && typeof input.answer === "object" ? input.answer as Record<string, unknown> : {};
  const machine = typeof input.machine === "string" ? input.machine : typeof answer.machine_id === "string" ? answer.machine_id : null;
  const spare = typeof input.spare === "string" ? input.spare : null;
  const unread: PreclaimHealthSnapshot = { http_status: 0, outcome: "error", commit: null, commit_unavailable: "not read" };
  const healthBefore = input.healthBefore ?? unread, healthAfter = input.healthAfter ?? unread;
  const platformBefore = input.platformHealthBefore ?? unread, platformAfter = input.platformHealthAfter ?? unread;
  const none = "not recorded";
  const met: PreclaimMetFields = {
    refill_to_ready_ms: null, refill_to_ready_unavailable: none, refill_image: null, refill_image_unavailable: none,
    post_bind_login_ms: null, post_bind_login_ms_unavailable: none, claim_to_first_text_ms: null, claim_to_first_text_unavailable: none,
    ...preclaimDeployFields(healthBefore, healthAfter, platformBefore, platformAfter),
    ...input.met,
  };
  return {
    claim: input.claim,
    machine,
    spare,
    lease_id: typeof input.leaseId === "string" ? input.leaseId : null,
    lease_hit: input.leaseHit !== undefined ? input.leaseHit : classifyLeaseHit(answer, input.brokerLog) ?? claimTookSpare(answer),
    health_before: healthBefore,
    health_after: healthAfter,
    platform_health_before: platformBefore,
    platform_health_after: platformAfter,
    claim_to_bound: claimToBoundSplit(answer.stages_ms ?? answer.claim_to_bound ?? answer.claimToBound),
    post_bind_login: input.postBindLogin ?? "not_checked",
    first_chat_ms: input.firstChatMs ?? null,
    first_reply_ms: input.firstReplyMs ?? null,
    warm_team_matches_claim: input.warmTeamMatchesClaim ?? null,
    warm_named: input.warmNamed ?? spare !== null,
    warm_reason: (input.warmNamed ?? spare !== null) ? null : warmReasonToken(input.warmReason),
    spare_ready_by: input.spareWait?.ready_by ?? null,
    ...met,
    reply_not_judged: input.replyNotJudged ?? null,
    spare_wait_ms: input.spareWait?.waited_ms ?? null,
    cold_after_wait: input.spareWait?.cold_after_wait === true,
    ...spareFields(answer),
  };
}

/** A held claim (one roll behind) fails when its login never arrived; a failed claim that took one counts too. Claim-path facts only: the reply is never judged. */
const heldRowFailed = (r: PreclaimClaimRecord) => r.post_bind_login === "missing";

/**
 * The burst's counts. Held claims (a spare kept claimable across an image roll, CLOUD_SPARE_ROLL_HOLD) are counted apart from
 * normal hits, with their failures, so a roll-crossing burst shows whether held spares still passed the claim guard (#1414).
 */
export function preclaimSummary(rows: PreclaimClaimRecord[], failures: PreclaimFailureRecord[] = []) {
  const values = rows.flatMap((row) => Object.values(row.claim_to_bound).filter((v): v is number => typeof v === "number"));
  const p90 = values.length ? values.sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * 0.9) - 1)] : null;
  const heldRows = rows.filter((r) => r.claimed_behind === true);
  const heldFailed = failures.filter((f) => f.claimed_behind === true);
  const lease_misses = rows.filter((r) => r.lease_hit === false).length;
  const waits = rows.map((r) => r.spare_wait_ms).filter((v): v is number => v !== null).sort((a, b) => a - b);
  return {
    claims: rows.length,
    lease_hits: rows.filter((r) => r.lease_hit === true).length,
    lease_misses,
    // The same hits, named for what says them (the claim answer), beside what the warm named before each claim.
    claim_taken: rows.filter((r) => r.lease_hit === true).length,
    warm_named: rows.filter((r) => r.warm_named).length,
    warm_missed_hits: rows.filter((r) => r.lease_hit === true && !r.warm_named).length,
    // A miss after a ready spare was reported (or with no wait at all); a miss after the wait ran out counts apart.
    cold_creates: rows.filter((r) => r.lease_hit === false && !r.cold_after_wait).length,
    cold_after_wait: rows.filter((r) => r.lease_hit === false && r.cold_after_wait).length,
    spare_wait_p90_ms: waits.length ? waits[Math.max(0, Math.ceil(waits.length * 0.9) - 1)] : null,
    held_claims: heldRows.length + heldFailed.length,
    held_failures: heldRows.filter(heldRowFailed).length + heldFailed.length,
    image_skips: rows.reduce((n, r) => n + (r.spare_skips?.image ?? 0), 0),
    claims_with_image_skip: rows.filter((r) => (r.spare_skips?.image ?? 0) > 0).length,
    post_bind_receipts: rows.filter((r) => r.post_bind_login === "receipt").length,
    replies: rows.filter((r) => r.first_reply_ms !== null).length,
    replies_not_judged: rows.filter((r) => r.reply_not_judged !== null).length,
    claim_to_bound_p90_ms: p90,
  };
}

/** A git commit (7 to 40 hex). Staging's API answers `version: "0.1.0"` (its deploy config API_VERSION): a version, not a deploy. */
const DEPLOY_COMMIT = /^[0-9a-f]{7,40}$/i;

/** Keep health evidence useful without copying response bodies or account identifiers into the run output. */
export function preclaimHealthSnapshot(answer: Answer): PreclaimHealthSnapshot {
  const body = answer.body && typeof answer.body === "object" ? answer.body as Record<string, unknown> : {};
  const value = body.value && typeof body.value === "object" ? body.value as Record<string, unknown> : body;
  const ok = answer.status >= 200 && answer.status < 300;
  const commit = ok ? [value.commit, value.sha, value.revision, value.version].find((v): v is string => typeof v === "string" && DEPLOY_COMMIT.test(v)) ?? null : null;
  const named = publicVersion(value.commit) ?? publicVersion(value.version);
  const why = commit !== null ? null : !ok ? `/v1/health answered HTTP ${answer.status}` : named ? `/v1/health names ${named}, not a deploy commit` : "/v1/health names no deploy commit";
  return { http_status: answer.status, outcome: ok ? "ok" : "error", commit, commit_unavailable: why };
}

/**
 * The deploy serving a claim and whether one landed during it: the platform's commit first (it runs the claim; staging's
 * API answers only a fixed version), and an overlap wherever a service named a commit both before and after.
 */
export function preclaimDeployFields(apiBefore: PreclaimHealthSnapshot, apiAfter: PreclaimHealthSnapshot, platformBefore: PreclaimHealthSnapshot, platformAfter: PreclaimHealthSnapshot): Pick<PreclaimMetFields, "staging_sha" | "staging_sha_unavailable" | "deploy_overlap" | "deploy_overlap_unavailable"> {
  const sha = platformBefore.commit ?? apiBefore.commit;
  const pairs = [[platformBefore, platformAfter], [apiBefore, apiAfter]].filter(([a, b]) => a.commit !== null && b.commit !== null);
  return {
    staging_sha: sha,
    staging_sha_unavailable: sha !== null ? null : `platform: ${platformBefore.commit_unavailable}; api: ${apiBefore.commit_unavailable}`,
    deploy_overlap: pairs.length ? pairs.some(([a, b]) => a.commit !== b.commit) : null,
    deploy_overlap_unavailable: pairs.length ? null : "no service's /v1/health named a deploy commit both before and after the claim",
  };
}

/**
 * The claim's spare from its created_at to ready, both on the platform's clock: the cloud.spare.ready frame's `at`
 * (SpareReady.ts), else the spare's running_since when the journey subscribed after it was ready (the subscribe
 * snapshot names the spare but carries no time). Claim 0's spare was warmed before the burst, not refilled after a claim.
 */
export function preclaimRefillToReady(claim: number, spare: string | null, readyFrame: unknown, spareRow: unknown): Pick<PreclaimMetFields, "refill_to_ready_ms" | "refill_to_ready_unavailable"> {
  const no = (why: string) => ({ refill_to_ready_ms: null, refill_to_ready_unavailable: why });
  if (claim === 0) return no("claim 0's spare was warmed before the burst, not refilled after a claim");
  if (spare === null) return no("warm-spare named no spare (the claim was a cold create)");
  const event = normalizedWireValue(readyFrame);
  const data = event.data && typeof event.data === "object" ? event.data as Record<string, unknown> : event;
  const row = spareRow && typeof spareRow === "object" ? spareRow as Record<string, unknown> : {};
  const readyAt = typeof data.at === "number" ? data.at : typeof row.running_since === "number" ? row.running_since : null;
  if (readyAt === null) return no("neither the spare.ready frame nor the spare's record carries a ready time");
  if (typeof row.created_at !== "number") return no("the spare's record has no created_at");
  const ms = readyAt - row.created_at;
  return ms < 0 ? no("the spare's ready time precedes its created_at") : { refill_to_ready_ms: Math.round(ms), refill_to_ready_unavailable: null };
}

/** Whether the claim took the spare the journey timed, and that spare's image: value.claim.behind (cmux-platform#1429). */
export function preclaimRefillImage(answer: unknown, spare: string | null, machine: unknown): Pick<PreclaimMetFields, "refill_image" | "refill_image_unavailable"> {
  const no = (why: string) => ({ refill_image: null, refill_image_unavailable: why });
  if (spare === null) return no("warm-spare named no spare (the claim was a cold create)");
  if (machine !== spare) return no("the claim did not take the spare the journey timed");
  const behind = spareFields(answer).claimed_behind;
  if (behind === null) return no("the claim answer has no value.claim to say behind or current");
  return { refill_image: behind ? "behind" : "current", refill_image_unavailable: null };
}

/**
 * The account's machine-minutes at t0 from cloud.plan.get's usage: the caller's own share when the plan splits it, else
 * the team's. The meter answers null while the month's total is unknown; that reads as unavailable, never 0.
 */
export function preclaimHoldMinutes(plan: unknown, secrets: string[] = []): Pick<PreclaimBurstFacts, "hold_minutes_t0" | "hold_minutes_t0_unavailable"> {
  if (plan instanceof Error) return { hold_minutes_t0: null, hold_minutes_t0_unavailable: `cloud.plan.get failed: ${publicError(plan.message, secrets).slice(0, 200)}` };
  const usage = (plan as { usage?: Record<string, unknown> } | null)?.usage ?? {};
  const hours = typeof usage.vm_hours_used_by_you === "number" ? usage.vm_hours_used_by_you : typeof usage.vm_hours_used === "number" ? usage.vm_hours_used : null;
  if (hours === null) return { hold_minutes_t0: null, hold_minutes_t0_unavailable: "cloud.plan.get usage names no machine-hours (the meter has no total for this month)" };
  return { hold_minutes_t0: Math.round(hours * 600) / 10, hold_minutes_t0_unavailable: null };
}

/** Lease ids are correlation handles in the public summary, never bearer values or machine ids. */
export function opaquePreclaimLeaseId(value: unknown): string | null {
  if (typeof value !== "string" || value.length < 1) return null;
  return `lease:${createHash("sha256").update(value).digest("hex").slice(0, 12)}`;
}

/** Public preclaim evidence is limited to timings, outcomes, opaque lease handles and short deploy commits. */
export function preclaimSummaryMarkdown(rows: PreclaimClaimRecord[], failures: PreclaimFailureRecord[] = [], burst: PreclaimBurstFacts | null = null): string {
  const summary = preclaimSummary(rows, failures);
  const yesNo = (v: boolean | null) => (v === null ? "unknown" : v ? "yes" : "no");
  return ["## Staging preclaim login measurement", "", `- claims: ${summary.claims}`, `- lease hits: ${summary.lease_hits}`, `- lease misses: ${summary.lease_misses}`, `- claim took a spare (from the claim answer): ${summary.claim_taken}`, `- warm named a spare: ${summary.warm_named}`, `- hits the warm did not name (no login attached in advance): ${summary.warm_missed_hits}`, ...(rows.some((r) => r.warm_team_matches_claim !== null) ? [`- warm's team was the claim's default team: ${rows.some((r) => r.warm_team_matches_claim === false) ? "no (claims sent in the warm's team)" : "yes"}`] : []), `- cold creates: ${summary.cold_creates}`, ...(rows.some((r) => r.spare_wait_ms !== null) ? [`- cold after the ready-spare wait ran out: ${summary.cold_after_wait}`, `- ready-spare wait p90: ${summary.spare_wait_p90_ms ?? "-"} ms`] : []), `- held claims (one image roll behind): ${summary.held_claims}`, `- held claim failures: ${summary.held_failures}`, `- image skips: ${summary.image_skips} (claims with one: ${summary.claims_with_image_skip})`, `- post-bind login receipts: ${summary.post_bind_receipts}`, `- replies: ${summary.replies}`, `- replies not judged: ${summary.replies_not_judged}`, `- claim-to-bound p90 (all named stages): ${summary.claim_to_bound_p90_ms ?? "-"} ms`, "", "| claim | lease id | lease hit | warm named | held | spare wait | health before | health after | claim answer | join | guest bind | connect_info | bound | post-bind login | first chat | first reply |", "|---:|:---|:---:|:---:|:---:|---:|:---:|:---:|---:|---:|---:|---:|---:|:---|---:|---:|", ...rows.map((r) => `| ${r.claim} | ${r.lease_id ?? "-"} | ${yesNo(r.lease_hit)} | ${r.warm_named ? "yes" : `no${r.warm_reason ? ` (${r.warm_reason})` : ""}`} | ${yesNo(r.claimed_behind)} | ${r.spare_wait_ms === null ? "-" : `${r.spare_wait_ms}${r.cold_after_wait ? " (ran out)" : ""}`} | ${r.health_before.outcome} | ${r.health_after.outcome} | ${r.claim_to_bound.claim_answer_ms ?? "-"} | ${r.claim_to_bound.join_ms ?? "-"} | ${r.claim_to_bound.guest_bind_ms ?? "-"} | ${r.claim_to_bound.connect_info_ms ?? "-"} | ${r.claim_to_bound.bound_ms ?? "-"} | ${r.post_bind_login} | ${r.first_chat_ms ?? "-"} | ${r.first_reply_ms ?? "-"} |`)].join("\n") + "\n" + (burst ? `\n${preclaimMetMarkdown(rows, burst)}` : "");
}

/** Nearest-rank percentile (the burst's p90 rule), or null with no values. */
const rankOf = (values: number[], q: number): number | null => values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * q) - 1)] : null;
const metCell = (value: unknown, why: string | null) => (value === null || value === undefined ? `unavailable: ${why ?? "not recorded"}` : String(value)).replace(/\|/g, "\\|");
/** The distinct reasons the rows give for a missing value, so an empty aggregate names why. */
const metWhy = (rows: PreclaimClaimRecord[], why: (r: PreclaimClaimRecord) => string | null, fallback: string) => [...new Set(rows.map(why).filter((w): w is string => Boolean(w)))].join("; ") || fallback;

/**
 * The lead's MET table: hit rate (bar 10/10), refill-to-ready p50/p90 split behind/current, post-bind login p90 on
 * hits (bar 0.5 s), claim-to-first-text p90 against bound p90 + reply turn + 2 s, hold minutes at t0, and each claim's
 * staging SHA and deploy overlap. Timings, outcomes and short commits only; any field not measured says why.
 */
export function preclaimMetMarkdown(rows: PreclaimClaimRecord[], burst: PreclaimBurstFacts): string {
  const n = rows.length;
  const hits = rows.filter((r) => r.lease_hit === true).length;
  const lines = ["### MET table", "", "| measure | value | bar | met |", "|:---|:---|:---|:---:|"];
  lines.push(n ? `| hit rate | ${hits}/${n} | 10/10 | ${hits === n && n >= 10 ? "yes" : "no"} |` : "| hit rate | unavailable: no claim completed | 10/10 | no |");
  for (const image of ["behind", "current"] as const) {
    const vs = rows.filter((r) => r.refill_image === image && r.refill_to_ready_ms !== null).map((r) => r.refill_to_ready_ms!);
    const why = rows.some((r) => r.refill_to_ready_ms !== null) ? `no timed refill took a spare ${image === "behind" ? "one image roll behind" : "on the current image"}` : metWhy(rows, (r) => r.refill_to_ready_unavailable, "no claim completed");
    lines.push(`| refill-to-ready p50 / p90 (${image}) | ${vs.length ? `${rankOf(vs, 0.5)} / ${rankOf(vs, 0.9)} ms (n=${vs.length})` : metCell(null, why)} | - | - |`);
  }
  const logins = rows.filter((r) => r.lease_hit === true && r.post_bind_login_ms !== null).map((r) => r.post_bind_login_ms!);
  const loginP90 = rankOf(logins, 0.9);
  const loginWhy = hits ? metWhy(rows.filter((r) => r.lease_hit === true), (r) => r.post_bind_login_ms_unavailable, "not recorded") : "no claim was a lease hit";
  lines.push(`| post-bind login p90 (hits) | ${loginP90 === null ? metCell(null, loginWhy) : `${loginP90} ms (n=${logins.length})`} | 500 ms | ${loginP90 === null ? "-" : loginP90 <= 500 ? "yes" : "no"} |`);
  const texts = rows.filter((r) => r.claim_to_first_text_ms !== null).map((r) => r.claim_to_first_text_ms!);
  const textP90 = rankOf(texts, 0.9);
  const boundP90 = rankOf(rows.filter((r) => r.claim_to_bound.bound_ms !== null).map((r) => r.claim_to_bound.bound_ms!), 0.9);
  const replyP90 = rankOf(rows.filter((r) => r.first_reply_ms !== null).map((r) => r.first_reply_ms!), 0.9);
  const bar = boundP90 !== null && replyP90 !== null ? boundP90 + replyP90 + 2000 : null;
  const barWhy = boundP90 === null ? "no claim answer named its bound stage" : "no reply turn was timed";
  lines.push(`| claim-to-first-text p90 | ${textP90 === null ? metCell(null, metWhy(rows, (r) => r.claim_to_first_text_unavailable, "no claim completed")) : `${textP90} ms (n=${texts.length})`} | ${bar === null ? metCell(null, barWhy) : `${bar} ms (bound p90 ${boundP90} + reply p90 ${replyP90} + 2000)`} | ${textP90 === null || bar === null ? "-" : textP90 <= bar ? "yes" : "no"} |`);
  lines.push(`| hold minutes at t0 | ${metCell(burst.hold_minutes_t0, burst.hold_minutes_t0_unavailable)} | - | - |`);
  lines.push(`| claims | ${n} of ${burst.claims_expected} | 10 | ${n === burst.claims_expected && n >= 10 ? "yes" : "no"} |`);
  lines.push("", "| claim | lease hit | refill to ready ms | refill image | post-bind login ms | claim to first text ms | staging sha | deploy overlap |", "|---:|:---:|:---|:---|:---|:---|:---|:---|");
  for (const r of rows) {
    const overlap = r.deploy_overlap === null ? null : r.deploy_overlap ? "yes" : "no";
    lines.push(`| ${r.claim} | ${r.lease_hit === null ? "unknown" : r.lease_hit ? "yes" : "no"} | ${metCell(r.refill_to_ready_ms, r.refill_to_ready_unavailable)} | ${metCell(r.refill_image, r.refill_image_unavailable)} | ${metCell(r.post_bind_login_ms, r.post_bind_login_ms_unavailable)} | ${metCell(r.claim_to_first_text_ms, r.claim_to_first_text_unavailable)} | ${metCell(r.staging_sha?.slice(0, 12) ?? null, r.staging_sha_unavailable)} | ${metCell(overlap, r.deploy_overlap_unavailable)} |`);
  }
  return `${lines.join("\n")}\n`;
}

function normalizedWireValue(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object") return {};
  const row = value as Record<string, unknown>;
  const nested = row.data;
  if (nested && typeof nested === "object" && (nested as Record<string, unknown>).event === "cloud.spare.ready") return nested as Record<string, unknown>;
  return row;
}

/** Accept only the owner's cloud stream and the named spare; snapshots are replayed on subscribe. */
export function cloudSpareReadyFrame(value: unknown, machine: string, team?: string): boolean {
  if (!value || typeof value !== "object") return false;
  const row = value as Record<string, unknown>;
  if (row.t === "snapshot") {
    const stream = typeof row.stream === "string" ? row.stream : "";
    const wanted = team ? `cloud:${team}` : "cloud";
    const ids = Array.isArray(row.spares_needing_login) ? row.spares_needing_login : [];
    return stream === wanted && ids.includes(machine);
  }
  const event = normalizedWireValue(value);
  const stream = typeof event.stream === "string" ? event.stream : "";
  const wanted = team ? `cloud:${team}` : "cloud";
  const data = event.data && typeof event.data === "object" ? event.data as Record<string, unknown> : event;
  return event.event === "cloud.spare.ready"
    && (stream === wanted || (!team && stream === "cloud"))
    && data.machine === machine
    && (!team || data.team === undefined || data.team === team);
}

/** Wait for the creator's cloud.spare.ready push; the wire replays committed events from sequence zero. */
export function waitForCloudSpareReady(api: Pick<Api, "origin" | "bearer" | "team">, machine: string, budgetMs = 120_000, signal?: AbortSignal): Promise<WireEvent> {
  const url = `${api.origin.replace(/^http/, "ws")}/v1/wire/cloud`;
  return new Promise((resolve, reject) => {
    const protocols = ["cmux.wire.v1", ...(api.team ? [`team.${api.team}`] : [])];
    const ws = new (globalThis as any).WebSocket(url, { protocols, headers: { authorization: `Bearer ${api.bearer}` } });
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error(`cloud.spare.ready did not arrive for ${machine} within ${budgetMs} ms`)); }, budgetMs);
    const done = (error?: Error, event?: WireEvent) => { clearTimeout(timer); try { ws.close(); } catch {} error ? reject(error) : resolve(event!); };
    signal?.addEventListener("abort", () => done(new Error("cloud.spare.ready wait aborted")), { once: true });
    ws.addEventListener("open", () => ws.send(JSON.stringify({ t: "subscribe", after_seq: 0, pending: [] })));
    ws.addEventListener("error", () => done(new Error("cloud wire did not open")), { once: true });
    ws.addEventListener("message", (message: any) => {
      let value: any;
      try { value = JSON.parse(String(message.data)); } catch { return; }
      if (!cloudSpareReadyFrame(value, machine, api.team)) return;
      done(undefined, value as WireEvent);
    });
  });
}

/** A spare's own record says it is up: running on a host, the same test prepareSpareLogin's next waitMachine makes. */
export function spareRecordReady(m: any): boolean {
  return m?.status === "running" && Boolean(m?.host);
}

/** Whether a machine's guest runs a command for this caller now (the machine exec route, MachineGuest.ts). */
export async function spareAnswersExec(api: Pick<Api, "raw">, machine: string): Promise<boolean> {
  const r = await api.raw("POST", `/v1/cloud/machines/${machine}/exec`, { command: "true", timeoutMs: 5_000 }, 15_000);
  const v: any = r.body?.value ?? r.body;
  return r.status >= 200 && r.status < 300 && v?.ok !== false && Number(v?.exitCode ?? v?.exit_code ?? 1) === 0;
}

/**
 * Wait for a named spare to be ready: its cloud.spare.ready frame, or its own record showing it running, whichever is
 * first. The frame is told once, to the creator's sockets live when the spare turned ready (SpareReady.ts), and only
 * development's subscribe snapshot names an already-ready spare (CLOUD_SPARE_LOGIN_SNAPSHOT, off in production by
 * prod-parity-allowlist). The warm names a spare that is often ready already, so in production the journey's socket,
 * opened after the warm, never heard of it and timed out at 120 s (11-22 00:55Z) on a spare it could have used.
 */
export async function waitForSpareReady(api: Api, machine: string, budgetMs = 120_000, deps: { frame?: typeof waitForCloudSpareReady; read?: (machine: string) => Promise<any>; answers?: (machine: string) => Promise<boolean>; pollMs?: number; sleep?: (ms: number) => Promise<void> } = {}): Promise<{ frame: WireEvent | null; row: any; by: "frame" | "record" | "exec" }> {
  const frameWait = deps.frame ?? waitForCloudSpareReady;
  const read = deps.read ?? ((id: string) => api.read("cloud.machine.get", { machine: id }));
  const answers = deps.answers ?? ((id: string) => spareAnswersExec(api, id));
  const pollMs = deps.pollMs ?? 2_000;
  const pause = deps.sleep ?? sleep;
  const stop = new AbortController();
  let settled = false;
  const viaFrame = frameWait(api, machine, budgetMs, stop.signal).then((frame) => ({ frame, row: null, by: "frame" as const }));
  const viaRecord = (async () => {
    const t0 = Date.now();
    let lastError = "";
    while (!settled && Date.now() - t0 < budgetMs) {
      try {
        const row = await read(machine);
        if (spareRecordReady(row)) return { frame: null, row, by: "record" as const };
        if (row?.status === "failed") throw new Error(`spare ${machine} failed before ready: ${short(row)}`);
      } catch (error) {
        if (String((error as Error).message).startsWith(`spare ${machine} failed`)) throw error;
        lastError = String((error as Error).message);
        // A person's read never names an unclaimed spare (CloudCore's cloud.machine.get answers not_found for a row
        // still under its reservation, to anyone but the reservation's own principal), so in production this poll
        // could never see one (11-23 05:24Z-07:24Z: three 120 s waits on a spare bound 20-80 min before). The exec
        // route does answer the spare's own creator (CloudDO.ownerExec), the same route the login copy then uses:
        // a guest that runs `true` is up.
        if (/not[ _.-]?found/i.test(lastError) && await answers(machine).catch(() => false)) return { frame: null, row: { status: "running", ready_by: "exec" }, by: "exec" as const };
      }
      await pause(pollMs);
    }
    throw new Error(`spare ${machine} was not ready within ${budgetMs} ms (no cloud.spare.ready frame, and its record never showed running${lastError ? `; last read: ${lastError.slice(0, 160)}` : ""})`);
  })();
  // A wire that fails or times out leaves the record poll to answer; the poll's own budget, or a failed spare, ends it.
  const frameOnly = viaFrame.catch(() => new Promise<never>(() => {}));
  try {
    return await Promise.race([frameOnly, viaRecord]);
  } finally {
    settled = true;
    stop.abort();
    viaFrame.catch(() => {});
    viaRecord.catch(() => {});
  }
}

/**
 * The app's machine choice for a Cloud chat (`cmux link start-chat plan`, cmux-tui start_chat_cli/pick.rs), asked as
 * a person's second chat from the same Mac workspace is: one VM per agent means the second chat gets a new machine
 * (`machine: null`), never the first chat's, and a retry of the first chat's own send keeps its machine. The plan runs
 * on a ledger of its own, sends no credential and so asks the platform nothing.
 */
export async function secondChatPlan(cmux: string, account: string, first: { id: string; title: string }): Promise<string> {
  const stateDir = mkdtempSync(path.join(tmpdir(), "cmux-journey-plan-"));
  const workspace = "journey-workspace";
  const run = (args: string[]) => new Promise<Record<string, any>>((resolve, reject) => {
    const child = spawn(cmux, ["link", "start-chat", ...args], { env: { ...process.env, CMUX_TUI_STATE_DIR: stateDir }, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout!.setEncoding("utf8").on("data", (chunk: string) => stdout += chunk);
    child.stderr!.setEncoding("utf8").on("data", (chunk: string) => stderr += chunk);
    const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error(`start-chat ${args[0]} timed out`)); }, 30_000);
    child.on("error", reject);
    child.on("close", (code: number | null) => {
      clearTimeout(timer);
      const answer = cliAnswer(stdout);
      if (code !== 0 || !answer || answer.ok === false) reject(new Error(`start-chat ${args[0]} exit ${code}: ${short(answer ?? (stderr.trim().split("\n").pop() || stdout))}`));
      else resolve(answer);
    });
  });
  try {
    const firstKey = randomUUID(), secondKey = randomUUID();
    const plan = (key: string) => run(["plan", "--request", JSON.stringify({ key, account, workspace, loaded: true, machines: [first] })]);
    const one = await plan(firstKey);
    if (one.machine !== null) throw new Error(`the first chat's plan named ${one.machine}, not a new machine`);
    await run(["pin", "--key", firstKey, "--account", account, "--machine", first.id, "--workspace", workspace]);
    const retry = await plan(firstKey);
    if (retry.machine !== first.id) throw new Error(`a retry of the first chat's send went to ${retry.machine ?? "a new machine"}, not its own ${first.id}`);
    const two = await plan(secondKey);
    if (two.machine !== null) throw new Error(`the second chat from the same workspace shares the first chat's VM ${two.machine}: one VM per agent is broken`);
    return `second chat: a new machine (${two.new_name ?? "unnamed"}), not ${first.id}; a retry of the first send keeps ${first.id}`;
  } finally {
    rmSync(stateDir, { recursive: true, force: true });
  }
}

async function runWarmSpare(cmux: string, api: Pick<Api, "origin" | "bearer" | "team">, stateDir: string, installToken: string, request: Record<string, unknown>): Promise<Record<string, any>> {
  const env = { ...process.env, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer, CMUX_TUI_STATE_DIR: stateDir };
  const args = ["link", "start-chat", "warm-spare", "--request", JSON.stringify(request), ...(api.team ? ["--team", api.team] : [])];
  const result = await new Promise<{ code: number; stdout: string; stderr: string }>((resolve, reject) => {
    const child = spawn(cmux, args, { env, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout!.setEncoding("utf8").on("data", (chunk: string) => stdout += chunk);
    child.stderr!.setEncoding("utf8").on("data", (chunk: string) => stderr += chunk);
    const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error("warm-spare timed out")); }, 120_000);
    child.on("error", reject);
    child.on("close", (code: number | null) => { clearTimeout(timer); resolve({ code: code ?? 1, stdout, stderr }); });
    // A cmux that exits before reading stdin (a usage refusal) closes the pipe: its exit code and answer say why, not EPIPE.
    child.stdin!.on("error", () => undefined);
    child.stdin!.end(`${api.bearer}\n${installToken}\n`);
  });
  if (result.code !== 0) throw new Error(warmSpareRefusal(result));
  const answer = cliAnswer(result.stdout);
  if (answer) return answer.value ?? answer;
  throw new Error("warm-spare returned no JSON answer");
}

/** The last JSON object a cmux CLI printed on stdout (the whole output first, then line by line from the end). */
function cliAnswer(stdout: string): Record<string, any> | null {
  for (const line of [stdout, ...stdout.split("\n").reverse()]) {
    try { const value = JSON.parse(line); if (value && typeof value === "object") return value; } catch {}
  }
  return null;
}

/**
 * Why warm-spare refused: the verb prints its refusal as `{"ok":false,"error_code","error"}` on stdout before it
 * exits 1, so the error names that code and message, else stderr's last line (run 43804741509 recorded only "exit 1").
 */
export function warmSpareRefusal(result: { code: number; stdout: string; stderr: string }): string {
  const answer = cliAnswer(result.stdout);
  const said = answer && (answer.error_code || answer.error)
    ? [answer.error_code, answer.error].filter((part) => typeof part === "string" && part).join(": ")
    : result.stderr.trim().split("\n").pop() ?? "";
  return `warm-spare refused (exit ${result.code})${said ? `: ${said.slice(0, 300)}` : ""}`;
}

/** The platform origin a backend's client-config names (`platform_origin`, an https origin), as the app reads it. */
export function clientPlatformOrigin(body: unknown): string {
  const raw = (body as { platform_origin?: unknown } | null)?.platform_origin;
  let url: URL | null = null;
  try { url = typeof raw === "string" ? new URL(raw) : null; } catch {}
  if (!url || url.protocol !== "https:" || url.origin !== String(raw).replace(/\/+$/, "")) throw new Error("client-config names no https platform_origin");
  return url.origin;
}

/**
 * The first chat on a claimed machine. The agent starting and taking the prompt are claim-path facts and throw; the reply
 * is the model's, so a refused or missing reply comes back as replyNotJudged and never fails the claim (lead: "make the
 * gate read claim-path fields only, so a model limit can never block it again").
 */
export async function runPreclaimChat(exec: Exec, session: string, prompt: string, budgetMs: number): Promise<{ chatMs: number; replyMs: number | null; replyNotJudged: string | null }> {
  const started = Date.now();
  const ensured = await exec(`${GUEST}"$c" acp ensure ${shq(session)} -m claude --json 2>&1; echo "@@exit $?"`, 120_000);
  const ensureExit = /@@exit (\d+)/.exec(ensured.stdout)?.[1];
  if (ensureExit !== "0") {
    // Say why (run 43873927808 claim 4 kept only "agent start refused"): ensure's own exit, or the exec cutting it off.
    const ran = `after ${Math.round((Date.now() - started) / 1000)} s`;
    const how = ensureExit === undefined ? `no exit within the 120 s exec, code ${ensured.code}, ${ran}` : `exit ${ensureExit} ${ran}`;
    const said = `${ensured.stdout.replace(/@@exit \d+\n?/, "")}${ensured.stderr}`.trim().slice(-300);
    throw new Error(`preclaim ${session}: agent start refused (${how})${said ? `: ${said}` : ""}`);
  }
  const chatMs = Date.now() - started;
  const sent = await exec(`${GUEST}printf '%s' ${shq(prompt)} | "$c" acp send --no-wait ${shq(session)} - 2>&1; echo "@@exit $?"`, 60_000);
  if (!/@@exit 0/.test(sent.stdout)) throw new Error(`preclaim ${session}: chat send refused`);
  const waitStarted = Date.now();
  while (Date.now() - waitStarted < budgetMs) {
    let reply: { stdout: string };
    try {
      reply = await exec(`${GUEST}"$c" acp wait ${shq(session)} --timeout 20 >/dev/null 2>&1; echo "@@wait $?"; "$c" acp last ${shq(session)} 2>&1`, 45_000);
    } catch (error) {
      // The agent started and took the prompt; a read that drops now (run 43918388959: ECONNRESET) says nothing about the claim.
      return { chatMs, replyMs: null, replyNotJudged: `reply wait read failed: ${String((error as Error)?.message ?? error).slice(0, 300)}` };
    }
    const wait = /@@wait (\d+)/.exec(reply.stdout)?.[1];
    const text = reply.stdout.replace(/@@wait \d+\n?/, "").trim();
    if (wait === "0" && text) return { chatMs, replyMs: Date.now() - waitStarted, replyNotJudged: null };
    // The send is queued: an idle exit before the turn starts is not a failed reply.
    if (wait && wait !== "0" && wait !== "3") return { chatMs, replyMs: null, replyNotJudged: `reply wait exit ${wait}: ${await failedTurnWhy(exec, session, text)}` };
  }
  return { chatMs, replyMs: null, replyNotJudged: `no reply within ${budgetMs / 1000} s` };
}

export type EnsureBenchCondition = "boot" | "settled" | "loaded";
export type EnsureBenchRun = { condition: EnsureBenchCondition; run: number; ms: number | null; exit: string; load1: string; state: string; top: string; output: string; slow: string };

/**
 * --ensure-bench: one timed `acp ensure` in its own session (claim 4 of run 43873927808 read "agent start refused" after
 * about 2 min at load 3.9 on 2 cores). Prints load1, the boot state and the top CPU users at its start; with load, two
 * busy children hold both cores for its length and are killed by their PIDs. Past 30 s, the session's acp tail and the
 * journal of its span follow @@slow. Ensure gets 280 s, inside the 300 s exec, so a slow start is timed, not cut off.
 */
export function ensureBenchCommand(session: string, load: boolean): string {
  const s = shq(session);
  return `${GUEST}load1=$(cut -d' ' -f1 /proc/loadavg); state=$(systemctl is-system-running 2>/dev/null); ` +
    `top=$(ps -eo pcpu,comm --sort=-pcpu | sed -n 2,6p | sed 's/^ *//' | paste -sd';'); ` +
    (load ? "yes >/dev/null & y1=$!; yes >/dev/null & y2=$!; " : "") +
    `s0=$(date +%s); t0=$(date +%s%N); out=$(timeout 280 "$c" acp ensure ${s} -m claude --json 2>&1); rc=$?; t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 )); ` +
    (load ? "kill $y1 $y2 2>/dev/null; " : "") +
    `printf '@@ms %s\n@@exit %s\n@@load1 %s\n@@state %s\n@@top %s\n@@out %s\n' "$ms" "$rc" "$load1" "$state" "$top" "$(printf '%s' "$out" | tail -c 300 | tr '\n' ' ')"; ` +
    `if [ "$ms" -gt 30000 ]; then echo "@@slow"; "$c" acp tail ${s} 2>&1 | tail -30 | cut -c1-300; journalctl -m --no-pager -o short-monotonic --since "@$s0" 2>/dev/null | tail -60 | cut -c1-300; fi; ` +
    `"$c" acp stop ${s} >/dev/null 2>&1; true`;
}

/** One ensureBenchCommand answer; a run with no answer reads ms null and exit "none". */
export function parseEnsureBench(stdout: string, condition: EnsureBenchCondition, run: number): EnsureBenchRun {
  const field = (key: string) => new RegExp(`^@@${key} ?(.*)$`, "m").exec(stdout)?.[1]?.trim() ?? "";
  const ms = Number(field("ms"));
  const slowAt = stdout.indexOf("@@slow\n");
  return { condition, run, ms: field("ms") !== "" && Number.isFinite(ms) ? ms : null, exit: field("exit") || "none", load1: field("load1"), state: field("state"), top: field("top"), output: field("out"), slow: slowAt < 0 ? "" : stdout.slice(slowAt + 7).trim() };
}

/** The public table: per condition p50, max and runs past the 120 s exec; per run its time, exit, load and top CPU users. */
export function ensureBenchMarkdown(runs: EnsureBenchRun[]): string {
  const over = (ms: number | null) => ms !== null && ms > 120_000;
  const lines = ["## acp ensure on a fresh staging machine", "", `- runs: ${runs.length}; crossed 120 s: ${runs.filter((r) => over(r.ms)).length} of ${runs.length}`, "", "| condition | runs | p50 ms | max ms | over 120 s |", "|:---|---:|---:|---:|---:|"];
  for (const condition of ["boot", "settled", "loaded"] as const) {
    const ms = runs.filter((r) => r.condition === condition && r.ms !== null).map((r) => r.ms!).sort((a, b) => a - b);
    if (ms.length) lines.push(`| ${condition} | ${ms.length} | ${ms[Math.max(0, Math.ceil(ms.length * 0.5) - 1)]} | ${ms[ms.length - 1]} | ${ms.filter((m) => m > 120_000).length} |`);
  }
  lines.push("", "| condition | run | ms | exit | load1 | boot state | top CPU at start |", "|:---|---:|---:|---:|---:|:---|:---|");
  for (const r of runs) lines.push(`| ${r.condition} | ${r.run} | ${r.ms ?? "-"} | ${r.exit} | ${r.load1 || "-"} | ${r.state || "-"} | ${(r.top || "-").replace(/\|/g, "\\|")} |`);
  return `${lines.join("\n")}\n`;
}

/** Where each exec probe leaves its nonce on the guest, so a lost answer shows whether its command ran there. */
export const EXEC_PROBE_NONCES = "/tmp/.cmux-exec-probe-nonces";
const EXEC_PROBE_SHORT = 100;
const EXEC_PROBE_WAITS = 5;
const EXEC_PROBE_IDLE_S = [5, 5, 15, 15, 30, 30, 65, 65];
/** Both cores busy for the loaded sweep, bounded by timeout, every descriptor closed so the exec answers at once. */
const EXEC_PROBE_LOAD_START = "for i in 1 2; do setsid timeout 900 yes </dev/null >/dev/null 2>&1 & echo $! >> /tmp/.cmux-exec-probe-load; done; true";
const EXEC_PROBE_LOAD_STOP = "kill $(cat /tmp/.cmux-exec-probe-load) 2>/dev/null; rm -f /tmp/.cmux-exec-probe-load; true";
export type ExecProbeKind = "short" | "idle" | "wait";
export type ExecProbeRun = { condition: EnsureBenchCondition; kind: ExecProbeKind; run: number; nonce: string; ms: number; status: number | null; code: string; cause: string; ranOnGuest: boolean | null; at?: number };

/** A probe's command: its nonce first, then `holdS` seconds of waiting (an `acp wait` read is about 20 s), then `ok`. */
export function execProbeCommand(nonce: string, holdS: number): string {
  return `echo ${nonce} >> ${EXEC_PROBE_NONCES}; ${holdS > 0 ? `sleep ${holdS}; ` : ""}echo ok`;
}

/**
 * One probe through the machine exec route (POST /v1/cloud/machines/{machine}/exec, the route a staging machine's exec
 * takes), kept whatever happens: the answer's status and refusal, or what the request threw with no answer
 * (run 43918388959's claim 2 kept only "ECONNRESET").
 */
export async function execProbe(post: (body: unknown, timeoutMs: number) => Promise<Answer>, nonce: string, holdS: number): Promise<Pick<ExecProbeRun, "ms" | "status" | "code" | "cause">> {
  const t0 = Date.now();
  try {
    const r = await post({ command: execProbeCommand(nonce, holdS), timeoutMs: (holdS + 30) * 1000 }, (holdS + 45) * 1000);
    const v: any = r.body?.value ?? r.body;
    if (r.status >= 200 && r.status < 300 && v?.ok !== false && Number(v?.exitCode) === 0 && String(v?.stdout ?? "").includes("ok")) return { ms: Date.now() - t0, status: r.status, code: "", cause: "" };
    const code = v?.error ? String(v.error.reason ?? v.error.code ?? "error") : `exit ${v?.exitCode ?? "?"}`;
    return { ms: Date.now() - t0, status: r.status, code, cause: String(v?.error?.message ?? v?.stderr ?? short(v)).slice(0, 200) };
  } catch (error) {
    const e = error as any;
    return { ms: Date.now() - t0, status: null, code: String(e?.code ?? e?.cause?.code ?? e?.name ?? "error"), cause: String(e?.message ?? error).slice(0, 200) };
  }
}

/** The fields of a machine row that say who stopped it (CloudIdle pause_reason, SpendCap paused_by), not the whole row. */
export function machineStopFields(m: any): Record<string, unknown> {
  const keep = ["status", "pause_reason", "paused_by", "paused_at", "stopped_at", "status_reason", "reason", "error", "last_op", "transport", "platform", "provider", "updated_at"];
  return Object.fromEntries(keep.filter((k) => m?.[k] !== undefined).map((k) => [k, m[k]]));
}

/** Where a failed probe ended, from its answer (MachineGuest.ts names each refusal) or, with none, the guest's nonces. */
export function execProbeHop(r: ExecProbeRun): string | null {
  if (r.status !== null && r.code === "") return null;
  if (r.status === null) {
    if (r.ranOnGuest === true) return "answer lost after the guest ran it";
    if (r.ranOnGuest === false) return "request lost before the guest";
    return "no answer; guest nonces unread";
  }
  if (r.status === 503 && ["overloaded", "restarted", "unreachable"].includes(r.code)) return `Worker → CloudDO (${r.code})`;
  if (r.status === 502) return "CloudDO → provider exec";
  if (r.status >= 520 && r.status <= 530) return `edge → Worker (HTTP ${r.status})`;
  if (r.status >= 200 && r.status < 300) return `guest command (${r.code})`;
  return `HTTP ${r.status} ${r.code}`;
}

/** The public table: per condition and kind the probes, failures, p50 and max; then one row per failed probe. */
export function execProbeMarkdown(runs: ExecProbeRun[]): string {
  const failed = runs.filter((r) => execProbeHop(r) !== null);
  const lines = ["## Machine exec drops on a fresh staging machine", "", `- probes: ${runs.length}; failed: ${failed.length} (no answer: ${failed.filter((r) => r.status === null).length}, refused: ${failed.filter((r) => r.status !== null).length})`, "", "| condition | kind | probes | failed | p50 ms | max ms |", "|:---|:---|---:|---:|---:|---:|"];
  for (const condition of ["boot", "settled", "loaded"] as const) {
    for (const kind of ["short", "idle", "wait"] as const) {
      const group = runs.filter((r) => r.condition === condition && r.kind === kind);
      if (!group.length) continue;
      const ms = group.map((r) => r.ms).sort((a, b) => a - b);
      lines.push(`| ${condition} | ${kind} | ${group.length} | ${group.filter((r) => execProbeHop(r) !== null).length} | ${ms[Math.max(0, Math.ceil(ms.length * 0.5) - 1)]} | ${ms[ms.length - 1]} |`);
    }
  }
  if (failed.length) {
    lines.push("", "| condition | kind | run | ms | status | code | ran on guest | hop | cause |", "|:---|:---|---:|---:|---:|:---|:---|:---|:---|");
    for (const r of failed) lines.push(`| ${r.condition} | ${r.kind} | ${r.run} | ${r.ms} | ${r.status ?? "-"} | ${r.code} | ${r.ranOnGuest === null ? "unread" : r.ranOnGuest ? "yes" : "no"} | ${execProbeHop(r)} | ${r.cause.replace(/\|/g, "\\|").replace(/\n/g, " ")} |`);
  }
  return `${lines.join("\n")}\n`;
}

/** Which failed probes' nonces the guest holds: null for every one when the nonce file could not be read. */
export function markRanOnGuest(runs: ExecProbeRun[], nonces: string | null): ExecProbeRun[] {
  const seen = nonces === null ? null : new Set(nonces.split("\n").map((l) => l.trim()).filter(Boolean));
  return runs.map((r) => (r.status !== null ? r : { ...r, ranOnGuest: seen === null ? null : seen.has(r.nonce) }));
}

/**
 * The acpmux daemon a first ensure would reach: each acpmux or cmux-tui process with its parent and start, and its PATH,
 * HOME, ACPMUX_* and CMUX_* (never a token, key or secret); the login-env cache; the binary `$c` runs; `acp status`;
 * where `claude` is; and the store's bin directories.
 */
export const ensureBenchDaemonFacts = (): string => `${GUEST}` +
  `for d in /proc/[0-9]*; do case "$(cat "$d/comm" 2>/dev/null)" in acpmux*|cmux-tui*) ;; *) continue;; esac; p=\${d#/proc/}; echo "== pid $p"; ps -o pid=,ppid=,lstart=,user=,args= -p "$p" 2>/dev/null | cut -c1-300; ` +
  `pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$pp" ] && ps -o pid=,args= -p "$pp" 2>/dev/null | cut -c1-200; ` +
  `tr '\\0' '\\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^(PATH|HOME|USER|ACPMUX_[A-Z_]+|CMUX_[A-Z_]+)=' | grep -viE 'TOKEN|KEY|SECRET|PASS' | cut -c1-300; done; ` +
  `echo "== login-env"; ls -la "$HOME/.acpmux/login-env.json" 2>&1; echo "== binary"; readlink -f "$(command -v "$c")" 2>&1; "$c" --version 2>&1 | head -2; ` +
  `echo "== status"; timeout 20 "$c" acp status --json 2>&1 | head -c 2000; echo; echo "== claude"; command -v claude 2>&1; ls -d /opt/cmux/store/*/bin 2>&1 | head -5; ` +
  `systemctl list-units 'cmux*' --no-pager --plain 2>&1 | head -10; true`;

/**
 * --ensure-bench N: one fresh machine created as a cold claim is, its Claude login installed as a cold claim's is, then N
 * timed ensures right after it runs (first-boot work still going), N once boot settles (systemctl is-system-running
 * --wait), and N with both cores busy. Public table to the out dir; outputs and slow-run journals to the private rows.
 */
/** The VM API origin a backend's platform creates its machines through (cmux-platform wrangler CLOUD_VM_API_ORIGIN). */
export function vmApiOrigin(backend: string): string | null {
  return backend === "staging" ? "https://vm-staging.cmux.dev" : backend === "prod" ? "https://vm.cmux.dev" : null;
}

/** The VM API tenant for a Stack session: the user's Stack teams and selected team, as a Stack client reads them. */
async function stackVmTenant(stack: { project: string; clientKey: string }, accessToken: string): Promise<ReturnType<typeof pickVmApiTenant>> {
  const headers = {
    "x-stack-access-type": "client",
    "x-stack-project-id": stack.project,
    ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
    "x-stack-access-token": accessToken,
  };
  const teams = await http("GET", `${STACK_API}/api/v1/teams?user_id=me`, undefined, headers, 15_000);
  if (teams.status !== 200) return { team: null, why: `Stack GET /api/v1/teams?user_id=me: HTTP ${teams.status} ${String(teams.body?.code ?? "")}` };
  const me = await http("GET", `${STACK_API}/api/v1/users/me`, undefined, headers, 15_000).catch(() => null);
  return pickVmApiTenant(teams.body, me?.status === 200 ? me.body?.selected_team_id ?? me.body?.selected_team?.id : null);
}

/**
 * --start-bench N (with --preclaim): create-to-first-command, phase by phase, N samples on each start path
 * (cloud-start-bench.ts says which paths and phases). Every machine, VM and snapshot it makes is deleted by exact id.
 */
export async function runStartBench(args: {
  api: Api;
  journey: Journey;
  backend: string;
  tag: string;
  n: number;
  cmux: string;
  install: { id: string; token: string; team?: string };
  account: string;
  accountTeam: string;
  /** The Stack project the session belongs to: the VM API's tenant is one of the user's Stack teams there. */
  stack: { project: string; clientKey: string };
  login: string;
  outDir: string | null;
  privateRowsPath?: string;
}): Promise<StartSample[]> {
  const samples: StartSample[] = [];
  const notes: string[] = [];
  const size = CHAT_START_SIZE;
  const write = () => {
    const md = `${startBenchMarkdown(samples, `Start bench (${args.backend}, N=${args.n})`)}${notes.length ? `\n${notes.map((n) => `- ${n}`).join("\n")}\n` : ""}`;
    if (args.outDir) { mkdirSync(args.outDir, { recursive: true }); writeFileSync(path.join(args.outDir, "start-bench.md"), md); }
    if (args.privateRowsPath) writeFileSync(args.privateRowsPath, `${JSON.stringify({ header: { backend: args.backend, summary: summarize(samples), notes }, rows: samples.map((s) => ({ ...s, error: s.error === null ? null : scrub(s.error, args.journey.secrets) })) }, null, 2)}\n`);
  };
  const machineOf = (answer: any): string => {
    const machine = typeof answer?.machine === "string" ? answer.machine : answer?.machine?.id ?? answer?.machine_id ?? answer?.id ?? null;
    if (typeof machine !== "string") throw new Error(`create answered no machine: ${short(answer)}`);
    return machine;
  };
  const platformRunning = async (machine: string) => {
    const m = await args.api.read("cloud.machine.get", { machine }, 15_000);
    if (m?.status === "failed") throw new MachineFailed("machine failed");
    return m?.status === "running" && Boolean(m?.host);
  };
  const platformRemove = (machine: string) => args.api.deleteMachine(machine, `${args.tag}-start-delete-${machine}`).then(() => undefined);
  const platformExec = (machine: string) => directExec(args.api, machine, args.journey);

  // The warm pool: the warm the app sends names a ready spare (as runPreclaimBurst's), no login copy. At most 180 s:
  // twice the refill p50 (hq#12332); run 43951741299's warm named no spare in 300 s while its claims took one, so the
  // claim answer, not the warm, says whether a sample took a spare.
  const stateDir = mkdtempSync(path.join(tmpdir(), "cmux-start-bench-"));
  const platform = clientPlatformOrigin((await args.api.raw("GET", "/v1/client-config", undefined, 30_000)).body);
  const scope = { platform, team: args.accountTeam, install: args.install.id, credential: createHash("sha256").update(args.login).digest("hex") };
  const request = { platform, account: args.account, scope, currentScope: scope };
  // The platform's kept create trace, read after the timed phases (cmux-platform GET /v1/machines/{id}?include=trace).
  const platformTrace = async (machine: string) => {
    const r = await http("GET", `${platform}/v1/machines/${encodeURIComponent(machine)}?include=trace`, undefined, { authorization: `Bearer ${args.api.bearer}`, ...(args.api.team ? { "x-cmux-team": args.api.team } : {}) }, 15_000);
    if (r.status !== 200) return `HTTP ${r.status}`;
    return traceFacts(r.body) ?? "no createTrace";
  };
  const readySpare = async (): Promise<Record<string, unknown>> => {
    const { prepared, wait } = await waitForReadySpare(async () => {
      const warm = await runWarmSpare(args.cmux, args.api, stateDir, args.install.token, request);
      const spare = typeof warm.machine === "string" ? warm.machine : null;
      if (spare) {
        await waitForSpareReady(Object.assign(Object.create(Object.getPrototypeOf(args.api)), args.api, { team: args.accountTeam || args.api.team }), spare);
        await runWarmSpare(args.cmux, args.api, stateDir, args.install.token, { ...request, ready: spare });
      }
      return { spare };
    }, 180_000);
    return { spare_named: prepared.spare !== null, spare_wait_ms: wait?.waited_ms ?? null, cold_after_wait: wait?.cold_after_wait ?? null };
  };
  const platformCreate = (asked: "spare" | "cold") => async (run: number) => {
    const answer = await args.api.op("cloud.machine.create", { name: `cloud start bench ${args.tag} ${asked} ${run}`, size }, `${args.tag}-start-${asked}-${run}`);
    const timings = answerTimings(answer);
    return { machine: machineOf(answer), path: answeredPath(answer) ?? asked, facts: { ...spareFields(answer), ...(timings ? { timings } : {}) } };
  };

  // The VM API, as an agent spawning VMs calls it: the account's session and one of its Stack teams. The VM API takes a
  // session only with X-Cmux-Team-Id naming a Stack team the user is in (workers/cmux-vm/src/auth/middleware.ts
  // fromSession); the platform's personal_team (accountTeam, team_<hex>) is none, so it answered 403 to every create.
  let vmOrigin = vmApiOrigin(args.backend);
  let vmTeam = "";
  if (vmOrigin) {
    const tenant = await stackVmTenant(args.stack, args.api.bearer).catch((e: unknown) => ({ team: null, why: `Stack team list failed: ${String((e as Error)?.message ?? e).slice(0, 200)}` }));
    if (tenant.team === null) {
      notes.push(`VM API paths skipped: ${tenant.why}`);
      vmOrigin = null;
    } else {
      vmTeam = tenant.team;
      notes.push(`VM API team: ${tenant.via}`);
    }
  }
  const vmHeaders = { authorization: `Bearer ${args.api.bearer}`, "x-cmux-team-id": vmTeam };
  const vm = (method: string, route: string, body?: unknown, timeoutMs = 130_000) => http(method, `${vmOrigin}${route}`, body, vmHeaders, timeoutMs, method !== "POST");
  const vmCreate = (snapshotId: string | null, asked: StartPath) => async (run: number) => {
    const r = await vm("POST", "/v1/vms", { displayName: `start bench ${args.tag} ${asked} ${run}`, resources: { vcpus: size.cpu, memoryMib: size.memory_mb, diskMib: size.disk_mb }, idleTimeoutSeconds: 300, autoDeleteSeconds: 3600, ...(snapshotId ? { snapshotId } : {}) });
    if (r.status !== 200 && r.status !== 201 && r.status !== 202) throw new Error(`POST /v1/vms: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
    const id = r.body?.id ?? r.body?.vm?.id;
    if (typeof id !== "string") throw new Error(`POST /v1/vms answered no id: ${short(r.body)}`);
    return { machine: id, facts: { state_at_answer: String(r.body?.state ?? r.body?.vm?.state ?? "") } };
  };
  const vmRunning = async (id: string) => (await vm("GET", `/v1/vms/${id}`, undefined, 30_000)).body?.state === "running";
  const vmExec = (id: string) => async (command: string, timeoutMs = 30_000) => {
    const r = await vm("POST", `/v1/vms/${id}/exec`, { command, timeoutMs }, timeoutMs + 30_000);
    if (r.status !== 200) throw new Error(`exec: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
    return { code: Number(r.body?.exitCode ?? 1), stdout: String(r.body?.stdout ?? ""), stderr: String(r.body?.stderr ?? "") };
  };
  // http() answers a refusal instead of throwing: a delete that is neither 204 nor 404 is said, never silent.
  const vmDeleted = async (route: string) => {
    const r = await vm("DELETE", route, undefined, 60_000);
    if (r.status !== 204 && r.status !== 200 && r.status !== 404) throw new Error(`DELETE ${route.split("/").slice(0, 3).join("/")}: HTTP ${r.status}`);
  };
  const vmRemove = (id: string) => vmDeleted(`/v1/vms/${id}`);

  let platformSnapshot: string | null = null;
  let vmSnapshot: string | null = null;
  try {
    // The snapshots, once, before any sample: a machine that ran its first boot, captured with its memory.
    try {
      const source = machineOf(await args.api.op("cloud.machine.create", { name: `cloud start bench ${args.tag} source`, size }, `${args.tag}-start-source`));
      try {
        await waitMachine(args.api, source, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
        const exec = platformExec(source);
        for (let i = 0; i < 120; i++) { if ((await exec(DAEMON_CHECK, 30_000).catch(() => ({ stdout: "" }))).stdout.includes("daemon-ok")) break; await sleep(2_000); }
        const snap = await args.api.op("cloud.snapshot.create", { machine: source, name: `start bench ${args.tag}` }, `${args.tag}-start-snapshot`);
        const id = snap?.snapshot?.id ?? snap?.snapshot ?? snap?.id;
        if (typeof id !== "string") throw new Error(`snapshot.create answered no id: ${short(snap)}`);
        platformSnapshot = id;
        let ready = false;
        for (let i = 0; i < 180 && !ready; i++) {
          const list = await args.api.read("cloud.snapshot.list", {}).catch(() => null);
          const rows: any[] = Array.isArray(list) ? list : list?.snapshots ?? list?.items ?? [];
          const row = rows.find((s) => s?.id === id);
          if (row?.status === "failed") throw new Error("snapshot failed");
          ready = row?.status === "ready";
          if (!ready) await sleep(2_000);
        }
        // A capture still running when the source goes would make every restore wait on it: no snapshot path then.
        if (!ready) throw new Error("snapshot not ready within 6 minutes");
      } finally {
        await platformRemove(source).catch(() => undefined);
      }
    } catch (error) {
      notes.push(`platform snapshot not taken: ${scrub(String((error as Error)?.message ?? error), args.journey.secrets).slice(0, 300)}`);
    }
    if (vmOrigin) {
      try {
        const { machine: source } = await vmCreate(null, "vm-api-cold")(-1);
        try {
          for (let i = 0; i < 300 && !(await vmRunning(source).catch(() => false)); i++) await sleep(1_000);
          await vmExec(source)("echo ok");
          // ttlSeconds: a run killed before its own delete leaves no snapshot behind for good.
          const s = await vm("POST", `/v1/vms/${source}/snapshots`, { displayName: `start bench ${args.tag}`, ttlSeconds: 3600 }, 300_000);
          const id = s.body?.id ?? s.body?.snapshot?.id;
          if (typeof id !== "string") throw new Error(`snapshot: HTTP ${s.status} ${short(s.body?.error ?? s.body)}`);
          vmSnapshot = id;
        } finally {
          await vmRemove(source).catch(() => undefined);
        }
      } catch (error) {
        notes.push(`VM API snapshot not taken: ${scrub(String((error as Error)?.message ?? error), args.journey.secrets).slice(0, 300)}`);
      }
    }
    const targets: StartTarget[] = [
      { path: "spare", prepare: () => readySpare(), create: platformCreate("spare"), running: platformRunning, exec: platformExec, daemon: true, trace: platformTrace, remove: platformRemove },
      // Right after the claim the one-spare pool is empty, so this create takes none (its answer says so).
      { path: "cold", create: platformCreate("cold"), running: platformRunning, exec: platformExec, daemon: true, trace: platformTrace, remove: platformRemove },
      ...(platformSnapshot ? [{ path: "snapshot" as const, create: async (run: number) => {
        const answer = await args.api.op("cloud.snapshot.restore", { snapshot: platformSnapshot, name: `cloud start bench ${args.tag} snapshot ${run}` }, `${args.tag}-start-restore-${run}`);
        const timings = answerTimings(answer);
        return { machine: machineOf(answer), ...(timings ? { facts: { timings } } : {}) };
      }, running: platformRunning, exec: platformExec, daemon: true, trace: platformTrace, remove: platformRemove }] : []),
      ...(vmOrigin ? [{ path: "vm-api-cold" as const, create: vmCreate(null, "vm-api-cold"), running: vmRunning, exec: vmExec, remove: vmRemove }] : []),
      ...(vmSnapshot ? [{ path: "vm-api-snapshot" as const, create: vmCreate(vmSnapshot, "vm-api-snapshot"), running: vmRunning, exec: vmExec, remove: vmRemove }] : []),
    ];
    // The matrix step stops at 80 minutes and a killed run deletes nothing: no new round starts past 55.
    const until = Date.now() + 55 * 60_000;
    for (let run = 0; run < args.n; run++) {
      if (Date.now() > until) {
        notes.push(`stopped after ${run} rounds: past 55 minutes`);
        break;
      }
      for (const target of targets) {
        const sample = await timeStart(target, run);
        // The table is public (the job summary): an error is scrubbed before it is kept.
        if (sample.error !== null) sample.error = scrub(sample.error, args.journey.secrets);
        samples.push(sample);
        console.log(`start bench ${sample.path}${sample.asked !== sample.path ? ` (asked ${sample.asked})` : ""} #${run}: ${sample.ok ? "ok" : "FAIL"} ${JSON.stringify(sample.ms)}${sample.error ? ` ${scrub(sample.error, args.journey.secrets)}` : ""}`);
        write();
      }
    }
  } finally {
    write();
    // A snapshot whose capture still runs answers busy: the same keyed delete again, for up to two minutes.
    if (platformSnapshot) {
      const snapshot = platformSnapshot;
      for (let attempt = 1; ; attempt++) {
        const error = await args.api.op("cloud.snapshot.delete", { snapshot }, `${args.tag}-start-snapshot-delete-${attempt}`).then(() => null, (e: unknown) => String((e as Error)?.message ?? e));
        if (error === null || /not_found/.test(error)) break;
        if (attempt >= 12) { notes.push(`platform snapshot delete failed: ${scrub(error, args.journey.secrets).slice(0, 200)}`); break; }
        await sleep(10_000);
      }
    }
    if (vmSnapshot) await vmDeleted(`/v1/snapshots/${vmSnapshot}`).catch((e) => notes.push(`VM API snapshot delete failed (its ttl ends it within the hour): ${String((e as Error)?.message ?? e)}`));
    rmSync(stateDir, { recursive: true, force: true });
    write();
  }
  return samples;
}

export async function runEnsureBench(args: { api: Api; journey: Journey; backend: string; tag: string; n: number; login: string; programs: ReturnType<typeof loginPrograms>; ownerScope: string; outDir: string | null; privateRowsPath?: string }): Promise<EnsureBenchRun[]> {
  const runs: EnsureBenchRun[] = [];
  let probes: ExecProbeRun[] = [];
  const boot: Record<string, string> = {};
  const answer = await args.api.op("cloud.machine.create", { name: `cloud ensure bench ${args.tag}`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${args.tag}-ensure-bench`);
  const machine = typeof answer?.machine === "string" ? answer.machine : answer?.machine?.id ?? answer?.machine_id ?? answer?.id ?? null;
  if (typeof machine !== "string") throw new Error(`create answered no machine: ${short(answer)}`);
  const created = Date.now();
  boot.machine = machine;
  // A create may take a spare (CloudDO.ts claim path): its daemon was started before this bench.
  boot.create_answer = short({ spare: spareFields(answer), claimed: answer?.claimed ?? answer?.spare ?? answer?.lease ?? null, status: answer?.machine?.status ?? answer?.status ?? null });
  const write = () => {
    // The uploader keeps only header, rows and failures, so each failed probe's time since create rides in the header.
    const failed = probes.filter((r) => execProbeHop(r) !== null).map(({ condition, kind, run, at, ms, status, code }) => ({ condition, kind, run, at, ms, status, code }));
    // The first 30 keep it under the header's 4000-character cut, so the JSON stays whole.
    if (failed.length) boot.probe_failures = JSON.stringify(failed.slice(0, 30));
    if (args.outDir) { mkdirSync(args.outDir, { recursive: true }); writeFileSync(path.join(args.outDir, "ensure-bench.md"), `${ensureBenchMarkdown(runs)}\n${execProbeMarkdown(probes)}`); }
    const rows = runs.map((r) => ({ ...r, output: scrub(r.output, args.journey.secrets), slow: scrub(r.slow, args.journey.secrets).slice(-6000) }));
    if (args.privateRowsPath) writeFileSync(args.privateRowsPath, `${JSON.stringify({ header: { backend: args.backend, summary: { runs: runs.length, crossed_120s: runs.filter((r) => r.ms !== null && r.ms > 120_000).length, probes: probes.length, probes_failed: probes.filter((r) => execProbeHop(r) !== null).length }, boot: Object.fromEntries(Object.entries(boot).map(([k, v]) => [k, scrub(v, args.journey.secrets).slice(-4000)])) }, rows, probes: probes.map((r) => ({ ...r, cause: scrub(r.cause, args.journey.secrets) })) }, null, 2)}\n`);
  };
  try {
    await waitMachine(args.api, machine, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
    const exec = directExec(args.api, machine, args.journey);
    const post = (body: unknown, timeoutMs: number) => args.api.raw("POST", `/v1/cloud/machines/${machine}/exec`, body, timeoutMs);
    const probe = async (condition: EnsureBenchCondition, kind: ExecProbeKind, run: number, holdS: number) => {
      const nonce = `${args.tag}-${condition}-${kind}-${run}`.replace(/[^A-Za-z0-9_.-]/g, "-");
      const at = Date.now() - created;
      const r = await execProbe(post, nonce, holdS);
      probes.push({ condition, kind, run, nonce, ranOnGuest: null, at, ...r });
      // Run 43983037186: the machine stopped during a 20 s exec and every probe after was 409 vm_not_running. Who
      // stopped it: the platform's row (status, pause_reason, paused_by) at the first one, with ms since create, so
      // a VM-side idle timeout (cmux-vm DEV_TEST_MAX_IDLE_SECONDS) shows against the probe times.
      // One read per distinct 409 refusal, so an unrelated conflict first does not hide vm_not_running.
      const key = `first_409_${r.code.replace(/[^A-Za-z0-9_]/g, "_")}`.slice(0, 64);
      if (r.status === 409 && boot[key] === undefined)
        boot[key] = JSON.stringify({ at: Date.now() - created, code: r.code, row: await args.api.read("cloud.machine.get", { machine }).then(machineStopFields, (e) => `read failed: ${String((e as Error)?.message ?? e)}`) });
    };
    // Short execs back to back, 20 s holds like an `acp wait` read, and (settled) one after each idle gap, where a
    // pooled connection the far end already closed would be reused.
    const sweep = async (condition: EnsureBenchCondition) => {
      for (let i = 0; i < EXEC_PROBE_SHORT; i++) await probe(condition, "short", i, 0);
      if (condition === "settled") for (const [i, gapS] of EXEC_PROBE_IDLE_S.entries()) { await sleep(gapS * 1000); await probe(condition, "idle", i, 0); }
      for (let i = 0; i < EXEC_PROBE_WAITS; i++) await probe(condition, "wait", i, 20);
      write();
    };
    await sweep("boot");
    boot.jobs_at_running = (await exec("systemctl list-jobs --no-pager 2>&1 | head -20; systemctl is-system-running 2>&1", 60_000)).stdout;
    await installPreclaimLogin(args.api, machine, exec, args.programs, args.login, 0, args.ownerScope);
    // Run 43931369542: every ensure answered `unknown harness "claude"; families: chief, unii` in ~13 ms from a daemon
    // already up, while the run before cold-started its own. Which daemon serves the first ensure, and with what PATH.
    boot.daemon_before_ensure = (await exec(ensureBenchDaemonFacts(), 60_000).catch((e) => ({ stdout: `read failed: ${String((e as Error)?.message ?? e)}` }))).stdout;
    const timed = async (condition: EnsureBenchCondition) => {
      for (let i = 0; i < args.n; i++) {
        const result = await exec(ensureBenchCommand(`bench-${args.tag}-${condition}-${i}`, condition === "loaded"), 300_000).catch((e) => ({ code: 1, stdout: "", stderr: String((e as Error)?.message ?? e) }));
        runs.push(parseEnsureBench(result.stdout, condition, i));
        write();
      }
    };
    await timed("boot");
    boot.settle = (await exec("timeout 600 systemctl is-system-running --wait 2>&1; systemctl list-jobs --no-pager 2>&1 | head -10; systemd-analyze blame 2>/dev/null | head -15", 300_000)).stdout;
    await timed("settled");
    await sweep("settled");
    await timed("loaded");
    await exec(`${EXEC_PROBE_LOAD_START}`, 60_000).catch(() => undefined);
    await sweep("loaded");
    await exec(`${EXEC_PROBE_LOAD_STOP}`, 60_000).catch(() => undefined);
    const nonces = await exec(`cat ${EXEC_PROBE_NONCES}`, 60_000).then((r) => (r.code === 0 ? r.stdout : null), () => null);
    probes = markRanOnGuest(probes, nonces);
  } finally {
    write();
    await args.api.deleteMachine(machine, `${args.tag}-ensure-bench-delete`).catch(() => undefined);
  }
  return runs;
}

/**
 * Why a turn failed: a failed turn (`acp wait` exit 1) prints no reply, so this names the session's last turn_error
 * (e.g. a harness with no sign-in on the machine), else the last message (run 43817240410 recorded only "exit 1").
 */
export async function failedTurnWhy(exec: Exec, session: string, last: string): Promise<string> {
  const h = await exec(`${GUEST}"$c" acp tail ${shq(session)} 2>&1 | grep -E '"kind":"turn_error"' | tail -1`, 45_000).catch(() => null);
  const why = /"error":"((?:[^"\\]|\\.)*)"/.exec(h?.stdout ?? "")?.[1] ?? "";
  return (why || last).slice(-300);
}

/** A cold claim has no warm receipt, so it uses the same credential transfer after bind. */
export function preclaimLoginMode(spare: string | null, machine: string | null = null): "preclaim" | "post-bind" {
  return spare !== null && machine === spare ? "preclaim" : "post-bind";
}

async function installPreclaimLogin(api: Api, machine: string, exec: Exec, programs: ReturnType<typeof loginPrograms>, login: string, index: number, ownerScope: string): Promise<void> {
  await waitPreflight(exec, programs.preflight, ownerScope, 300_000);
  const folder = "/home/cmux/.cmux/credential-transfer";
  const file = `${folder}/${randomUUID().toUpperCase()}.json`;
  try {
    const wrote = await api.raw("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: file, dataBase64: Buffer.from(login).toString("base64"), mode: 0o644 });
    if (wrote.status < 200 || wrote.status >= 300 || wrote.body?.ok === false) throw new Error(`preclaim ${index}: credential stage refused`);
    const installed = await exec(programs.install(file));
    if (installed.code !== 0) throw new Error(`preclaim ${index}: credential installer refused`);
  } finally {
    await exec(`rm -f -- ${shq(file)}`).catch(() => undefined);
  }
}

/**
 * A spare warmed for the account with the person's login copied onto it on spare.ready, as the app's SpareReady path.
 * `readyFrame` and `spareRow` time its refill to ready (preclaimRefillToReady); both null with no spare.
 */
export type PreparedSpare = { spare: string | null; generation: unknown; leaseId: string | null; request: Record<string, unknown>; readyFrame?: unknown; spareRow?: unknown; warmReason?: string | null };

/** A claim's bounded wait for a ready spare: how long, how many warms, and whether the bound ran out first. */
export type SpareWait = { waited_ms: number; attempts: number; cold_after_wait: boolean; ready_by: "warm" | "claim_path" | null };

/**
 * --spare-wait: before a claim, ask the warm (the same warm-spare the claim path reads) until it names a ready spare, for at
 * most budgetMs, so a one-spare pool can refill between claims and a burst tests make-before-break rather than refill speed.
 * With no budget it asks once (wait null). When the bound runs out the claim still goes ahead, marked cold_after_wait.
 */
export async function waitForReadySpare<T extends { spare: string | null }>(prepare: () => Promise<T>, budgetMs: number, opts: { pollMs?: number; now?: () => number; sleep?: (ms: number) => Promise<void>; ready?: (ms: number) => Promise<string | null> } = {}): Promise<{ prepared: T; wait: SpareWait | null }> {
  if (!(budgetMs > 0)) return { prepared: await prepare(), wait: null };
  const pollMs = opts.pollMs ?? 15_000;
  const now = opts.now ?? Date.now;
  const pause = opts.sleep ?? sleep;
  const started = now();
  for (let attempts = 1; ; attempts++) {
    const prepared = await prepare();
    const waited = now() - started;
    if (prepared.spare !== null) return { prepared, wait: { waited_ms: waited, attempts, cold_after_wait: false, ready_by: "warm" } };
    if (waited + pollMs > budgetMs) return { prepared, wait: { waited_ms: waited, attempts, cold_after_wait: true, ready_by: null } };
    // Between warms, listen for the claim path's own ready spare (waitForAnySpareReady): one the claim takes counts as
    // ready even when the warm named none, so the claim goes now and the warm's miss stays on the row (warm_named).
    if (!opts.ready) { await pause(pollMs); continue; }
    if (await opts.ready(pollMs) !== null) return { prepared, wait: { waited_ms: now() - started, attempts, cold_after_wait: false, ready_by: "claim_path" } };
  }
}

/**
 * A ready spare the claim path reports on the team's Cloud wire: a `cloud.spare.ready` frame (SpareReady.ts, sent when an
 * unclaimed spare's connection turns ready) or a subscribe snapshot's `spares_needing_login`. Its machine, else null.
 */
export function anyCloudSpareReady(value: unknown, team?: string): string | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  const wanted = team ? `cloud:${team}` : "cloud";
  if (row.t === "snapshot") {
    const ids = Array.isArray(row.spares_needing_login) ? row.spares_needing_login : [];
    return row.stream === wanted && typeof ids[0] === "string" ? ids[0] : null;
  }
  const event = normalizedWireValue(value);
  if (event.event !== "cloud.spare.ready") return null;
  const stream = typeof event.stream === "string" ? event.stream : "";
  const data = event.data && typeof event.data === "object" ? event.data as Record<string, unknown> : event;
  if (!(stream === wanted || (!team && stream === "cloud")) || (team && data.team !== undefined && data.team !== team)) return null;
  return typeof data.machine === "string" ? data.machine : null;
}

/** Listen on the team's Cloud wire for up to `budgetMs` for any spare the claim path reports ready; null when none. */
export function waitForAnySpareReady(api: Pick<Api, "origin" | "bearer" | "team">, budgetMs: number): Promise<string | null> {
  const url = `${api.origin.replace(/^http/, "ws")}/v1/wire/cloud`;
  return new Promise((resolve) => {
    const protocols = ["cmux.wire.v1", ...(api.team ? [`team.${api.team}`] : [])];
    let ws: any;
    const done = (machine: string | null) => { clearTimeout(timer); try { ws?.close(); } catch {} resolve(machine); };
    // A wire that cannot open waits out the poll like a sleep: the warm is asked again after it.
    const timer = setTimeout(() => done(null), budgetMs);
    try {
      ws = new (globalThis as any).WebSocket(url, { protocols, headers: { authorization: `Bearer ${api.bearer}` } });
    } catch {
      return;
    }
    ws.addEventListener("open", () => ws.send(JSON.stringify({ t: "subscribe", after_seq: 0, pending: [] })));
    ws.addEventListener("message", (message: any) => {
      let value: unknown;
      try { value = JSON.parse(String(message.data)); } catch { return; }
      const machine = anyCloudSpareReady(value, api.team);
      if (machine !== null) done(machine);
    });
  });
}

/**
 * The app's part on a warm spare (SpareReady): warm-spare names a spare, the journey waits for its cloud.spare.ready,
 * marks it ready, copies the login through the existing transfer (preflight, fs/write, installer), checks the guest's
 * launcher sees it, and reports it installed. A warm-spare that names no spare answers `spare: null`; the claim then
 * makes a machine and the login goes with the agent's start (loginPathAfterClaim).
 */
export async function prepareSpareLogin(a: {
  api: Api;
  cmux: string;
  stateDir: string;
  installToken: string;
  request: Record<string, unknown>;
  wireTeam?: string;
  programs: ReturnType<typeof loginPrograms>;
  login: string;
  ownerScope: string;
  index: number;
  journey: Journey;
  readyBudgetMs?: number;
}): Promise<PreparedSpare> {
  const warm = await runWarmSpare(a.cmux, a.api, a.stateDir, a.installToken, a.request);
  const spare = typeof warm.machine === "string" ? warm.machine : null;
  let copy = warm.copy && typeof warm.copy === "object" ? warm.copy as Record<string, unknown> : {};
  let leaseId = opaquePreclaimLeaseId(warm.lease_id ?? warm.leaseId ?? warm.reservation_id ?? warm.reservationId);
  let readyFrame: unknown = null, spareRow: unknown = null;
  if (spare) {
    const ready0 = await waitForSpareReady(Object.assign(Object.create(Object.getPrototypeOf(a.api)), a.api, { team: a.wireTeam ?? a.api.team }), spare, a.readyBudgetMs);
    readyFrame = ready0.frame;
    const ready = await runWarmSpare(a.cmux, a.api, a.stateDir, a.installToken, { ...a.request, ready: spare });
    leaseId ??= opaquePreclaimLeaseId(ready.lease_id ?? ready.leaseId ?? ready.reservation_id ?? ready.reservationId);
    if (!Object.keys(copy).length && ready.copy && typeof ready.copy === "object") copy = ready.copy as Record<string, unknown>;
    const exec = directExec(a.api, spare, a.journey);
    // The ready wait's own answer when it has one; a frame names no row, so read it (exec-checked, as the wait is).
    spareRow = ready0.row ?? (await waitForSpareReady(a.api, spare, 300_000, { frame: () => new Promise<never>(() => {}) })).row;
    await installPreclaimLogin(a.api, spare, exec, a.programs, a.login, a.index, a.ownerScope);
    const own = await exec(". /etc/cmux/agent-auth.sh >/dev/null 2>&1 && HOME=/home/cmux cmux_agent_has_own_login claude && echo own-login");
    if (!own.stdout.includes("own-login")) throw new Error(`preclaim ${a.index}: guest receipt missing before claim`);
    if (copy.generation) await runWarmSpare(a.cmux, a.api, a.stateDir, a.installToken, { ...a.request, installed: spare, generation: copy.generation });
  }
  return { spare, generation: copy.generation, leaseId, request: a.request, readyFrame, spareRow, warmReason: spare ? null : warmReasonToken(warm.reason) };
}

/** Whether the claim answer's machine carries the login the spare's copy installed (warm-spare loginReceipt). */
export async function spareLoginReceipt(cmux: string, api: Pick<Api, "origin" | "bearer" | "team">, stateDir: string, installToken: string, prepared: PreparedSpare, machine: string): Promise<boolean> {
  if (!prepared.generation) return false;
  const receipt = await runWarmSpare(cmux, api, stateDir, installToken, { ...prepared.request, loginReceipt: { machine, provider: "claude" } }).catch(() => ({} as Record<string, any>));
  return receipt.installed === true;
}

export async function runPreclaimBurst(args: {
  backend: Backend;
  api: Api;
  cmux: string;
  install: { id: string; token: string; team?: string };
  account: string;
  login: string;
  claims: number;
  tag: string;
  journey: Journey;
  outDir: string | null;
  privateRowsPath?: string;
  team?: string;
  user: any;
  /** The platform origin's /v1/health read (tests answer it; the API's own reads go through `api`). */
  fetchJson?: typeof http;
  /** --spare-wait: the bound on each claim's wait for a ready spare (waitForReadySpare); 0 claims at once. */
  spareWaitMs?: number;
}): Promise<number> {
  if (!args.cmux) throw new Error("--preclaim needs --cmux PATH so the shipped Rust warm/ready path is exercised");
  if (!validLogin("claude", args.login)) throw new Error("--preclaim needs a valid Claude setup-token login (or --model stub)");
  if (!Number.isInteger(args.claims) || args.claims < 1 || args.claims > 20) throw new Error("--claims must be 1..20");
  const stateDir = mkdtempSync(path.join(tmpdir(), "cmux-preclaim-"));
  const rows: PreclaimClaimRecord[] = [];
  const failures: PreclaimFailureRecord[] = [];
  let verificationFailed = false;
  const scopeTeam = args.team ?? args.install.team ?? String(args.user?.personal_team ?? args.user?.team ?? "");
  // The Rust warm warms the install token's team (install_team); a claim with no x-cmux-team lands on the session's
  // default (personal) team. The app sends both in its active team, so the burst claims in the warm's team and each row
  // says whether the two differed (warm_team_matches_claim): different teams are different pools.
  const warmTeam = installTokenTeam(args.install.token);
  const claimTeamBefore = args.api.team ?? (String(args.user?.personal_team ?? "") || null);
  const warmTeamMatchesClaim = warmTeam === null || claimTeamBefore === null ? null : warmTeam === claimTeamBefore;
  const api: Api = warmTeam && warmTeam !== args.api.team ? Object.assign(Object.create(Object.getPrototypeOf(args.api)), args.api, { team: warmTeam }) : args.api;
  const wireTeam = warmTeam ?? (scopeTeam || args.api.team);
  // The platform the app sends a warm to: client-config's platform_origin (CloudConfiguration.artifactsAPIBaseURL), never the
  // API host: cloud-api forwards a fixed list of platform paths, and /v1/cloud/spare/warm is not one (an empty 404).
  let platform: string | null = null;
  const scopeOf = (origin: string) => ({ platform: origin, team: scopeTeam, install: args.install.id, credential: createHash("sha256").update(args.login).digest("hex") });
  const programs = loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), "claude", Boolean(args.team));
  const account = args.account;
  const fetchJson = args.fetchJson ?? http;
  // The platform runs the claim, so its deploy commit is the staging SHA; a failed read is a reason, not a failed claim.
  const platformHealth = (origin: string) => fetchJson("GET", `${origin}/v1/health`, undefined, {}, 30_000).then(preclaimHealthSnapshot, (error): PreclaimHealthSnapshot => ({ http_status: 0, outcome: "error", commit: null, commit_unavailable: `platform /v1/health failed: ${publicError(String((error as Error)?.message ?? error), args.journey.secrets).slice(0, 120)}` }));
  const burst: PreclaimBurstFacts = { claims_expected: args.claims, hold_minutes_t0: null, hold_minutes_t0_unavailable: "not read yet" };
  const writeOutput = () => {
    // The journey's own summary gets the rows and failures whether or not anything is written to disk.
    args.journey.preclaimRows = rows;
    args.journey.preclaimBurst = burst;
    args.journey.preclaimFailures = failures;
    if (!args.outDir && !args.privateRowsPath) return;
    if (args.outDir) mkdirSync(args.outDir, { recursive: true });
    const summary = { ...preclaimSummary(rows, failures), outcome: verificationFailed || !preclaimRunComplete(rows, failures, args.claims) ? "fail" : "pass", complete: preclaimRunComplete(rows, failures, args.claims) };
    if (args.privateRowsPath) writeFileSync(args.privateRowsPath, `${JSON.stringify({ header: { backend: args.backend.name, summary, burst }, rows, failures }, null, 2)}\n`);
    args.journey.flush();
  };
  try {
    // Hold minutes at t0: the account's machine-minutes before claim 0 makes any machine.
    Object.assign(burst, preclaimHoldMinutes(await Promise.resolve().then(() => api.read("cloud.plan.get", {})).catch((error) => error instanceof Error ? error : new Error(String(error))), args.journey.secrets));
    for (let index = 0; index < args.claims; index++) {
      let claimedMachine: string | null = null;
      let claimedBehind: boolean | null = null;
      // The step a failure happened in, named on its row (run 43918388959 kept only "ECONNRESET").
      let step = "health before";
      try {
      const healthBefore = preclaimHealthSnapshot(await api.raw("GET", "/v1/health", undefined, 30_000));
      step = "client-config";
      platform ??= clientPlatformOrigin((await api.raw("GET", "/v1/client-config", undefined, 30_000)).body);
      const platformHealthBefore = await platformHealth(platform);
      const scope = scopeOf(platform);
      const request = { platform, account, scope, currentScope: scope };
      step = "warm spare";
      const { prepared, wait: spareWait } = await waitForReadySpare(() => prepareSpareLogin({ api: api, cmux: args.cmux, stateDir, installToken: args.install.token, request, wireTeam, programs, login: args.login, ownerScope: args.team ? "owner or team" : "owner", index, journey: args.journey }), args.spareWaitMs ?? 0, { ready: (ms) => waitForAnySpareReady({ ...api, team: wireTeam }, ms) });
      const { spare, leaseId } = prepared;
      const claimSentAt = Date.now();
      step = "claim";
      const answer = await api.op("cloud.machine.create", { name: `cloud preclaim ${args.tag} ${index}`, size: CHAT_START_SIZE }, `${args.tag}-preclaim-${index}`);
      const machine = typeof answer?.machine === "string" ? answer.machine : answer?.machine?.id ?? answer?.machine_id ?? answer?.id ?? null;
      claimedMachine = typeof machine === "string" ? machine : null;
      claimedBehind = spareFields(answer).claimed_behind;
      const explicitLease = classifyLeaseHit(answer);
      // The claim answer says the hit (claimTookSpare); whether the warm named that spare is warm_named, apart.
      const leaseHit = explicitLease ?? claimTookSpare(answer) ?? (spare === null ? false : typeof machine === "string" ? machine === spare : null);
      const loginMode = preclaimLoginMode(spare, typeof machine === "string" ? machine : null);
      // Post-bind login: the receipt check on a hit (the login is already on the spare), the copy itself on a miss.
      let postBindLoginMs: number | null = null;
      let postBindLoginWhy: string | null = "the claim answered no machine";
      if (typeof machine === "string") {
        step = "wait running";
        await waitMachine(api, machine, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
        if (loginMode === "post-bind") {
          step = "post-bind login";
          const copyAt = Date.now();
          await installPreclaimLogin(api, machine, directExec(api, machine, args.journey), programs, args.login, index, args.team ? "owner or team" : "owner");
          postBindLoginMs = Date.now() - copyAt;
          postBindLoginWhy = null;
        }
      }
      step = "login receipt";
      const receiptAt = Date.now();
      const receiptInstalled = typeof machine === "string" ? await spareLoginReceipt(args.cmux, api, stateDir, args.install.token, prepared, machine) : false;
      if (typeof machine === "string" && loginMode === "preclaim") {
        postBindLoginMs = prepared.generation ? Date.now() - receiptAt : null;
        postBindLoginWhy = prepared.generation ? null : "the spare's copy named no generation, so no login receipt was asked";
      }
      let firstChatMs: number | null = null;
      let firstReplyMs: number | null = null;
      let claimToFirstTextMs: number | null = null;
      let replyNotJudged: string | null = null;
      if (typeof machine === "string") {
        step = "first chat";
        const chat = await runPreclaimChat(directExec(api, machine, args.journey), `preclaim-${args.tag}-${index}`, `Reply with one short sentence for preclaim ${index}.`, 300_000);
        claimToFirstTextMs = chat.replyMs === null ? null : Date.now() - claimSentAt;
        firstChatMs = chat.chatMs;
        firstReplyMs = chat.replyMs;
        replyNotJudged = chat.replyNotJudged === null ? null : scrub(chat.replyNotJudged, args.journey.secrets).slice(0, 600);
      }
      step = "health after";
      const healthAfter = preclaimHealthSnapshot(await api.raw("GET", "/v1/health", undefined, 30_000));
      const platformHealthAfter = await platformHealth(platform);
      const met: Partial<PreclaimMetFields> = {
        ...preclaimRefillToReady(index, spare, prepared.readyFrame ?? null, prepared.spareRow ?? null),
        ...preclaimRefillImage(answer, spare, machine),
        post_bind_login_ms: postBindLoginMs, post_bind_login_ms_unavailable: postBindLoginWhy,
        claim_to_first_text_ms: claimToFirstTextMs, claim_to_first_text_unavailable: claimToFirstTextMs !== null ? null : replyNotJudged !== null ? `no first text: ${replyNotJudged.slice(0, 200)}` : "the claim answered no machine, so no chat ran",
      };
      const record = preclaimClaimRecord({ claim: index, machine, spare, leaseId, answer, leaseHit, healthBefore, healthAfter, platformHealthBefore, platformHealthAfter, firstChatMs, firstReplyMs, replyNotJudged, spareWait, met, warmNamed: spare !== null, warmTeamMatchesClaim, warmReason: prepared.warmReason ?? null, postBindLogin: loginMode === "post-bind" ? "post-bind" : receiptInstalled ? "receipt" : "missing" });
      rows.push(record);
      if (typeof machine === "string") {
        await api.deleteMachine(machine, `${args.tag}-preclaim-delete-${index}`).catch(() => undefined);
        claimedMachine = null;
      }
      writeOutput();
      } catch (error) {
        // The machine's own facts first: deleting it is the end of every log that says why.
        const guest = claimedMachine ? await preclaimGuestFacts(directExec(api, claimedMachine, args.journey), `preclaim-${args.tag}-${index}`) : undefined;
        if (claimedMachine) await api.deleteMachine(claimedMachine, `${args.tag}-preclaim-delete-${index}`).catch(() => undefined);
        failures.push(preclaimFailureRecord(index, `${step}: ${String(error instanceof Error ? error.message : error)}`, args.journey.secrets, claimedBehind, guest));
        writeOutput();
        // Record it and go on: claim-path rows keep coming, and the burst still ends red (preclaimRunComplete).
      }
    }
  } finally {
    writeOutput();
    rmSync(stateDir, { recursive: true, force: true });
  }
  // A hit on the spare the warm named must find its login there; a hit the warm never named is counted (warm_missed_hits).
  verificationFailed = rows.some((r) => r.lease_hit === true && r.warm_named && r.post_bind_login !== "receipt");
  writeOutput();
  return verificationFailed || !preclaimRunComplete(rows, failures, args.claims) ? 1 : 0;
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Why a running machine has not paused, from its record: `last_active_at` (Idle.ts idleClockStart: null means no
 * report speaks for its activity, so the idle rule never runs; a recent time means something keeps it in use), the
 * activity the platform keeps (open sessions, the workload block), whichever the record carries, and `idle_kept`: the
 * platform's own reason with the names of what holds it.
 */
export async function idleHeldBy(api: Api, machine: string, now = Date.now()): Promise<string> {
  const m = await Promise.resolve().then(() => api.read("cloud.machine.get", { machine })).catch((error) => error as Error);
  if (m instanceof Error) return `idle facts unreadable: ${m.message.slice(0, 200)}`;
  const last = m?.last_active_at;
  const clock = typeof last === "number" ? `idle clock started ${Math.round((now - last) / 1000)} s ago` : "idle clock not running (last_active_at null: no report speaks for its activity)";
  const activity = m?.activity ?? m?.report?.activity;
  const bits = [clock, `idle policy ${m?.idle_seconds ?? m?.idle_policy?.idle_seconds ?? "?"} s`];
  if (activity && typeof activity === "object") bits.push(`activity ${short(activity)}`);
  // The platform's reason (cmux-platform#2154 `idle_kept`, the cloud.idle.kept line's): sessions, or the workload's
  // process, port and timer names, so a walk that never paused names what held it.
  const kept = m?.idle_kept;
  if (kept && typeof kept === "object") {
    const { running_s: _r, report_age_s: _a, daemon: _d, ...facts } = kept as Record<string, unknown>;
    bits.push(`kept by ${short(facts)}`);
  }
  return bits.join("; ");
}

/** The idle policy a machine's record carries, in seconds; null when it names none. */
export async function machineIdleSeconds(api: Api, machine: string): Promise<number | null> {
  const m = await api.read("cloud.machine.get", { machine });
  const s = Number(m?.idle_seconds ?? m?.idle_policy?.idle_seconds);
  return Number.isFinite(s) && s > 0 ? s : null;
}

/**
 * How long the journey waits for an idle pause: the idle policy or the post-chat hold, whichever is longer, plus
 * 300 s for the alarm's re-check. A record that names no policy is a failure now, not a 24 h wait: sizing the wait
 * from the 24 h backstop hung the walk until the CI job's own timeout killed it, so idleHeldBy never said why.
 */
export function idlePauseDeadlineMs(policyS: number | null, holdS: number): number {
  if (policyS === null) throw new Error("cloud.machine.get names no idle policy for this machine (idle_seconds and idle_policy.idle_seconds both unset), so there is no pause to wait for");
  return (Math.max(policyS, holdS) + 300) * 1000;
}

/** Test-side bounded wait on a machine field (the product never polls; this is the harness). */
export async function waitMachine(api: Api, machine: string, want: (m: any) => boolean, budgetMs: number, goneOk = false): Promise<any> {
  const t0 = Date.now();
  let last: any = null;
  let lastError = "";
  while (Date.now() - t0 < budgetMs) {
    try {
      last = await api.read("cloud.machine.get", { machine });
      if (want(last)) return last;
      // A machine that failed never gets there: say why now instead of waiting the budget out.
      if (last?.status === "failed") throw new Error(`machine failed: ${short({ error: last.error ?? last.failure ?? last.reason ?? last.status_reason, provider: last.provider, op: last.last_op ?? last.op })} (full row: ${short(last)})`);
    } catch (error) {
      if (String((error as Error).message).startsWith("machine failed:")) throw error;
      if (goneOk && /HTTP 404|not[ _.-]?found/i.test(String((error as Error).message))) return null;
      lastError = String((error as Error).message);
    }
    await sleep(1000);
  }
  throw new Error(`timed out after ${budgetMs} ms; last status ${last?.status} host ${last?.host}${lastError ? `; last error ${lastError}` : ""}`);
}

/** ES256 over the UTF-8 message, base64url raw r||s (host-agent.ts signMessage). */
async function sign(key: CryptoKey, message: string): Promise<string> {
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(message)));
  return Buffer.from(sig).toString("base64url");
}

export type ExecResult = { code: number; stdout: string; stderr: string };
export type Exec = (command: string, timeoutMs?: number) => Promise<ExecResult>;

/** Follow a fresh session's ACP stream on the guest and return on text, not turn end. The exec response carries
 * only a marker, never the model's text: `@@first-text TURN THOUGHT`, the guest's own ms from the turn's start
 * (acpmux took the prompt) to the first text and to the first thinking (-1: none), apart from the exec route. --since 0 closes the subscribe/send race on this run's unique session.
 * The process is bounded and reaped by its own parent; no daemon or unrelated process is signalled. */
export function firstTextCommand(session: string, budgetMs: number): string {
  return `python3 - "$c" ${shq(session)} ${Math.min(270_000, budgetMs) / 1000} <<'CMUX_FIRST_TEXT'
import json, os, selectors, signal, subprocess, sys, time
p = subprocess.Popen([sys.argv[1], 'acp', 'tail', sys.argv[2], '--since', '0', '--follow'],
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
sel = selectors.DefaultSelector()
sel.register(p.stdout, selectors.EVENT_READ)
end = time.monotonic() + float(sys.argv[3])
buf = b''
discarding = False
started = False
turn_at = None
thought_ms = -1
try:
    while time.monotonic() < end:
        if not sel.select(max(0, end - time.monotonic())):
            break
        data = os.read(p.stdout.fileno(), 65536)
        if not data:
            break
        if discarding:
            if b'\\n' not in data:
                continue
            data = data.split(b'\\n', 1)[1]
            discarding = False
        buf += data
        while b'\\n' in buf:
            line, buf = buf.split(b'\\n', 1)
            if len(line) > 1048576:
                continue
            try:
                event = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(event, dict):
                continue
            if event.get('kind') == 'turn_started':
                started = True
                if turn_at is None:
                    turn_at = time.monotonic()
            if event.get('kind') in ('turn_result', 'turn_error'):
                sys.exit('first turn ended without assistant text')
            if not started or event.get('kind') not in (None, 'agent_message_chunk', 'agent_thought_chunk'):
                continue
            msg = event.get('msg', event)
            params = msg.get('params', {}) if isinstance(msg, dict) else {}
            meta = params.get('_meta', {}) if isinstance(params, dict) else {}
            acpmux = meta.get('acpmux', {}) if isinstance(meta, dict) else {}
            if isinstance(acpmux, dict) and acpmux.get('subagent'):
                continue
            update = params.get('update', {}) if isinstance(params, dict) else {}
            if isinstance(update, dict) and update.get('sessionUpdate') == 'agent_thought_chunk' and thought_ms < 0:
                thought_ms = int((time.monotonic() - turn_at) * 1000)
            if not isinstance(update, dict) or update.get('sessionUpdate') != 'agent_message_chunk':
                continue
            content = update.get('content', {})
            if isinstance(content, dict) and content.get('type') == 'text' and isinstance(content.get('text'), str) and content['text']:
                print('@@first-text %d %d' % (int((time.monotonic() - turn_at) * 1000), thought_ms), flush=True)
                sys.exit(0)
        if len(buf) > 1048576:
            buf = b''
            discarding = True
    sys.exit('first-text stream ended or timed out without assistant text')
finally:
    sel.close()
    if p.poll() is None:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    p.wait()
CMUX_FIRST_TEXT`;
}

/** Start before send and record as soon as the observer answers. Never reject an unawaited background promise. */
export async function observeFirstText(exec: Exec, session: string, budgetMs: number, timing: FirstTextTiming, record: (step: Step) => void): Promise<void> {
  try {
    const r = await exec(`${GUEST}${firstTextCommand(session, budgetMs)}`, Math.min(270_000, budgetMs) + 5000);
    const m = /^@@first-text(?: (\d+) (-?\d+))?$/.exec(r.stdout.trim());
    if (r.code !== 0 || !m) throw new Error(`first-text observer: exit ${r.code}; ${r.stderr.slice(-300) || "no text marker"}`);
    timing.mark("first_text");
    if (m[1] !== undefined) timing.guest("first_token", Number(m[1]));
    if (m[2] !== undefined && Number(m[2]) >= 0) timing.guest("first_thought", Number(m[2]));
    record({ step: "first text", status: "pass", ms: 0, detail: "streamed assistant text observed (parallel to send/reply; includes exec return)", fields: timing.fields() });
  } catch (error) {
    record({ step: "first text", status: "pass", ms: 0, detail: `measurement unavailable: ${String((error as Error)?.message ?? error)}`, fields: timing.fields() });
  }
}

/** All callers, including a signal during delete, wait for the same cleanup to finish. */
export function sharedCleanup(action: () => Promise<void>): () => Promise<void> {
  let completion: Promise<void> | undefined;
  return () => completion ??= Promise.resolve().then(action);
}

/** Keep cancellation cleanup installed throughout the observer wait, and delete before waiting. */
export async function finishJourney(cleanup: () => Promise<void>, observer: Promise<void> | undefined, onSignal: (signal: string) => void): Promise<void> {
  try {
    await cleanup();
    await observer;
  } finally {
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
  }
}

/** The CLI's exec (cloud_client_session.rs): mint a client session, then the provider's exec-await. */
export function directExec(api: Api, machine: string, journey: Pick<Journey, "secrets">, backgroundPollMs = 2_000): Exec {
  let session: { token: string; vm_id: string; linux_user: string; api_base_url: string; expires_at: number } | null = null;
  let guestRoute = false;
  const guestExec: Exec = async (command, timeoutMs = 60_000) => {
    // A VM API machine has no client sessions: the machine exec route (MachineGuest.ts) runs it instead.
    // The HTTP request waits as long as the command may run, plus room for the answer to travel.
    const runMs = Math.min(timeoutMs, 300_000);
    const g = await api.raw("POST", `/v1/cloud/machines/${machine}/exec`, { command, timeoutMs: runMs }, runMs + 15_000);
    const v: any = g.body?.value ?? g.body;
    if (g.status < 200 || g.status >= 300 || v?.ok === false) throw new Error(`exec: HTTP ${g.status} ${short(v?.error?.code ?? v?.error ?? v)}`);
    return { code: Number(v.exitCode ?? v.exit_code ?? 1), stdout: String(v.stdout ?? ""), stderr: String(v.stderr ?? "") };
  };
  return async (command, timeoutMs = 60_000) => {
    if (guestRoute) return guestExec(command, timeoutMs);
    if (!session || session.expires_at - Date.now() < 60_000) {
      const r = await api.raw("POST", `/v1/cloud/machines/${machine}/client-session`, { ttl_seconds: 900 });
      if (r.status === 501 && String(r.body?.error?.code ?? "") === "cloud.provider.unsupported") {
        guestRoute = true;
        return guestExec(command, timeoutMs);
      }
      if (r.status !== 200 || r.body.ok !== true) throw new Error(`client-session: HTTP ${r.status} ${short(r.body.error?.code ?? r.body.error ?? r.body)}`);
      session = r.body.value;
      journey.secrets.push(session!.token);
    }
    const s = session!;
    const identity = { "x-freestyle-identity-access-token": s.token };
    const deadlineAt = Date.now() + timeoutMs + 15_000;
    const sent = await http("POST", `${s.api_base_url.replace(/\/+$/, "")}/v5/vms/${s.vm_id}/exec-await`, { command, linuxUser: s.linux_user, timeoutMs }, { ...identity, ...BACKGROUND_AFTER }, timeoutMs + 15_000);
    const r = await settleBackground(sent, s.api_base_url, identity, deadlineAt, backgroundPollMs);
    if (r.status < 200 || r.status >= 300) throw new Error(`exec-await: HTTP ${r.status}`);
    const rawCode = r.body.statusCode ?? r.body.exitCode ?? r.body.code;
    // Freestyle leaves statusCode null or missing when the command timed out; the cmux CLI maps that to 124.
    return { code: rawCode === null || rawCode === undefined ? 124 : Number(rawCode), stdout: String(r.body.stdout ?? ""), stderr: String(r.body.stderr ?? "") };
  };
}

/**
 * The CLI's answer as an exec result: its JSON (`exit_code`, `stdout`, `stderr`) when it printed one, else the
 * process's own status and output. A CLI that died on a signal has no status: the code is 128 + the signal's number
 * (a shell's convention) and stderr names the signal, and a CLI that printed nothing says so, so a failed step
 * never reads `exit 1` with nothing beside it. The resume matrix's first run read exactly that: a cmux-tui built with
 * the build runner's native CPU features (libghostty-vt's zig default) killed by SIGILL on every other runner CPU.
 */
export function cliExecResult(done: { status: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }): { code: number; stdout: string; stderr: string } {
  try {
    const result = JSON.parse(done.stdout);
    if (Number.isInteger(result?.exit_code)) {
      return { code: Number(result.exit_code), stdout: String(result.stdout ?? ""), stderr: String(result.stderr ?? "") };
    }
  } catch {
    // Preserve the raw CLI answer below when it did not produce its JSON contract.
  }
  const signo = done.signal ? (osConstants.signals as Record<string, number>)[done.signal] ?? 0 : 0;
  const code = done.status ?? (done.signal ? 128 + signo : 1);
  const said = done.signal
    ? `[the cmux CLI was killed by ${done.signal}${done.signal === "SIGILL" ? ": an instruction this CPU lacks (a binary built for another CPU)" : ""}]`
    : !done.stdout.trim() && !done.stderr.trim() ? `[the cmux CLI exited ${code} and printed nothing]` : "";
  return { code, stdout: done.stdout, stderr: said ? `${done.stderr}${done.stderr && !done.stderr.endsWith("\n") ? "\n" : ""}${said}` : done.stderr };
}

/** `cmux machine access exec` with the same credential: the journey drives the real CLI, which takes the
 * machine exec route itself on a machine whose provider has no client sessions (a VM API machine). */
function cliExec(cmux: string, api: Api, machine: string): Exec {
  return async (command, timeoutMs = 60_000) => {
    const env = { ...process.env, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer };
    const args = ["--json", "machine", "access", "exec", "--target", `machine:${machine}`, "--timeout-ms", String(Math.min(timeoutMs, 300_000)), ...(api.team ? ["--team", api.team] : []), "--", command];
    // Asynchronous, so a carrier dial this process holds (the chaos leg's) keeps being read while a command runs.
    const done = await new Promise<{ status: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }>((resolve, reject) => {
      const child = spawn(cmux, args, { env, stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      child.stdout!.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
      child.stderr!.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
      const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs + 30_000);
      child.on("error", (error) => {
        clearTimeout(timer);
        reject(new Error(`${cmux}: ${error.message}`));
      });
      child.on("close", (status, signal) => {
        clearTimeout(timer);
        resolve({ status, signal, stdout, stderr });
      });
    });
    return cliExecResult(done);
  };
}

/** An awk function that reads one string field of a journalctl JSON line, past escaped quotes (`\"` reads as `"`). */
export const JOURNAL_FIELD = `function field(name,   r) { if (match($0, "\\"" name "\\":\\"([^\\"\\\\\\\\]|\\\\\\\\.)*\\"")) { r = substr($0, RSTART, RLENGTH); sub(/^"[^"]*":"/, "", r); sub(/"$/, "", r); gsub(/\\\\"/, "\\"", r); return r } return "" }`;

/**
 * When the guest set up its carrier: the bind the host finished (bound.json; the platform's bind.json is gone by now,
 * since the host deletes it once bound.json is written, cmux-host cloud/client.rs), the carrier.json and grant the host
 * wrote from it, the session host's start (it is respawned with the relay flags), and the host's journal lines about
 * them. Times are on the guest's boot clock where it has one, so a wall clock stepped after boot (a machine resumed
 * from a snapshot, then synced) moves nothing: `guest_now <wall ms> <uptime ms>` read together, `mono <name> <ms since
 * boot>` (the session host), `journal <ms since boot> <message>`, `wall <name> <epoch ms>` (a file's mtime) and
 * `clock <epoch ms> <boot's epoch ms>` each time the journal's wall clock moved against its boot clock. The pid and the
 * journal may need root: each tries `sudo -n` (journalctl run without root can exit 0 with nothing to show).
 */
export const GUEST_CARRIER_TIMELINE = [
  `echo "guest_now $(date +%s%3N) $(awk '{ printf "%.0f", $1 * 1000 }' /proc/uptime)"`,
  "for f in /var/lib/cmux/bound.json /var/lib/cmux/carrier.json /run/cmux/carrier-grant.json; do",
  '  t=$(date -r "$f" +%s%3N 2>/dev/null || sudo -n date -r "$f" +%s%3N 2>/dev/null) && echo "wall $(basename "$f") $t"',
  "done",
  "pid=$(cat /run/cmux-host/daemon.pid 2>/dev/null || sudo -n cat /run/cmux-host/daemon.pid 2>/dev/null)",
  'if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then',
  "  st=$(awk '{print $22}' \"/proc/$pid/stat\"); hz=$(getconf CLK_TCK)",
  "  awk -v s=\"$st\" -v h=\"$hz\" 'BEGIN { printf \"mono session_host_start %.0f\\n\", s * 1000 / h }'",
  "fi",
  "{ sudo -n journalctl -b -o json --no-pager 2>/dev/null || journalctl -b -o json --no-pager 2>/dev/null; } | head -n 4000 \\",
  `  | awk '${JOURNAL_FIELD} { rt = field("__REALTIME_TIMESTAMP"); mo = field("__MONOTONIC_TIMESTAMP"); if (rt == "" || mo == "") next; bw = (rt - mo) / 1000; if (!n || bw - last > 500 || last - bw > 500) { printf "clock %.0f %.0f\\n", rt / 1000, bw; last = bw; n++ } }'`,
  "{ sudo -n journalctl -b -u cmux-host.service -o json --no-pager -n 400 2>/dev/null || journalctl -b -u cmux-host.service -o json --no-pager -n 400 2>/dev/null; } \\",
  `  | awk '${JOURNAL_FIELD} { m = field("MESSAGE"); if (tolower(m) ~ /carrier|session host|relay|regist/) line[++n] = sprintf("journal %.0f %s", field("__MONOTONIC_TIMESTAMP") / 1000, m) } END { for (i = (n > 8 ? n - 7 : 1); i <= n; i++) print line[i] }'`,
  "true",
].join("\n");

/**
 * GUEST_CARRIER_TIMELINE's lines as ms after create's answer. Each time goes to the guest's boot clock (a file's mtime
 * through the wall clock segment it was written in), then to this computer's clock through the uptime read at the
 * exec's midpoint (`before`, `after`), so a time is good to about half the exec, whatever the guest's wall clock did.
 */
export function guestTimeline(stdout: string, answeredAt: number, before: number, after: number, sentAt = answeredAt): string {
  const t = readGuestTimeline(stdout, answeredAt, before, after, sentAt);
  if (!t.clockRead) return `after create's answer (±${t.half} ms): no guest clock read`;
  const rel = (ms: number) => `${ms >= 0 ? "+" : ""}${ms} ms`;
  const parts = t.events.map((e) => `${e.name}${e.text ? ` "${e.text.slice(0, 80)}"` : ""} ${rel(e.ms)}`);
  const spare = t.claimedSpare ? `; a claimed spare: bound ${t.boundBeforeAnswerMs} ms before create answered` : "";
  return `after create's answer (±${t.half} ms${t.step ? `; the guest's wall clock stepped ${t.step >= 0 ? "+" : ""}${t.step} ms after boot` : ""}${spare}): ${parts.join("; ")}`;
}

/** The guest timeline's public facts for probe.json: event names and ms after create's answer, no text, no ids. */
export type GuestTimelineFacts = { clock_read: boolean; uncertainty_ms: number; clock_step_ms: number; claimed_spare: boolean | null; events: Array<{ event: string; ms: number }> };

/** A journal line's kind, from the words the timeline's reader selects it by, so no journal text reaches probe.json. */
const JOURNAL_KINDS = ["carrier", "session host", "relay", "regist"];

export function guestTimelineFacts(stdout: string, answeredAt: number, before: number, after: number, sentAt = answeredAt): GuestTimelineFacts {
  const t = readGuestTimeline(stdout, answeredAt, before, after, sentAt);
  return {
    clock_read: t.clockRead,
    uncertainty_ms: t.half,
    clock_step_ms: t.step,
    claimed_spare: t.claimedSpare,
    events: t.events.map((e) => {
      const kind = e.text ? JOURNAL_KINDS.find((k) => e.text!.toLowerCase().includes(k)) ?? "other" : null;
      return { event: kind ? `journal:${kind.replace(" ", "_")}` : e.name, ms: e.ms };
    }),
  };
}

/**
 * GUEST_CARRIER_TIMELINE's lines as ms after create's answer. `claimedSpare` is null when the guest showed no bind
 * (bound.json), true when it bound before create was sent, false when it bound after.
 */
function readGuestTimeline(stdout: string, answeredAt: number, before: number, after: number, sentAt: number) {
  let wallNow = NaN;
  let upNow = NaN;
  const segments: Array<{ rt: number; boot: number }> = [];
  const events: Array<{ name: string; mono?: number; wall?: number; text?: string }> = [];
  for (const line of stdout.split("\n").map((l) => l.trim()).filter(Boolean)) {
    const [kind, a, b, ...rest] = line.split(" ");
    if (kind === "guest_now") [wallNow, upNow] = [Number(a), Number(b)];
    else if (kind === "clock") segments.push({ rt: Number(a), boot: Number(b) });
    else if (kind === "wall") events.push({ name: a, wall: Number(b) });
    else if (kind === "mono") events.push({ name: a, mono: Number(b) });
    else if (kind === "journal") events.push({ name: "journal", mono: Number(a), text: [b, ...rest].join(" ") });
  }
  const half = Math.round((after - before) / 2);
  if (!Number.isFinite(wallNow) || !Number.isFinite(upNow)) {
    return { clockRead: false, half, step: 0, claimedSpare: null as boolean | null, boundBeforeAnswerMs: NaN, events: [] as Array<{ name: string; text?: string; ms: number }> };
  }
  const bootNow = wallNow - upNow;
  const clock = segments.filter((c) => Number.isFinite(c.rt) && Number.isFinite(c.boot));
  if (!clock.length || Math.abs(clock[clock.length - 1].boot - bootNow) > 500) clock.push({ rt: wallNow, boot: bootNow });
  // A wall time in the boot clock, through the segment whose boot-clock span it falls in.
  const toMono = (wall: number) => {
    for (let i = 0; i < clock.length; i += 1) {
      const mono = wall - clock[i].boot;
      const start = i === 0 ? -Infinity : clock[i].rt - clock[i].boot;
      const end = i + 1 < clock.length ? clock[i + 1].rt - clock[i + 1].boot : Infinity;
      if (mono >= start && mono < end) return mono;
    }
    return wall - bootNow;
  };
  const mid = Math.round((before + after) / 2);
  const rel = (mono: number) => Math.round(mid - (upNow - mono) - answeredAt);
  const out = [{ name: "guest boot", ms: rel(0) } as { name: string; text?: string; ms: number }, ...events.flatMap((e) => {
    const mono = e.mono ?? (e.wall !== undefined ? toMono(e.wall) : NaN);
    return Number.isFinite(mono) ? [{ name: e.name, ...(e.text ? { text: e.text } : {}), ms: rel(mono) }] : [];
  })];
  const step = clock.length > 1 ? Math.round(clock[clock.length - 1].boot - clock[0].boot) : 0;
  // A machine bound before create was sent is a claimed spare (made and bound ahead, handed out at create); a cold
  // machine can bind while create's answer is on its way back, so the send, not the answer, is the line. Its boot
  // time is the snapshot base's, so the bind, not the boot, is what says so.
  const bound = events.find((e) => e.name === "bound.json" && e.wall !== undefined);
  const boundAt = bound ? mid - (upNow - toMono(bound.wall!)) : NaN;
  const claimedSpare = Number.isFinite(boundAt) ? boundAt < sentAt : null;
  return { clockRead: true, half, step, claimedSpare, boundBeforeAnswerMs: Math.round(answeredAt - boundAt), events: out };
}

/** A carrier answer's `relay`, as the dial takes it (cmux-tui carrier/answer.rs relay_route): a bare `relay+do://<host>`. */
function relayDoProblem(text: unknown): string | null {
  if (typeof text !== "string") return "relay is missing";
  let url: URL;
  try { url = new URL(text); } catch { return "relay is not a URL"; }
  const bare = !url.username && !url.password && !url.search && !url.hash && (url.pathname === "" || url.pathname === "/");
  return url.protocol === "relay+do:" && bare && url.hostname ? null : "relay is not a relay+do:// origin";
}

/** A ticket or grant as the dial takes it (answer.rs secret): 1 to 4096 visible ASCII bytes. */
const visibleSecret = (v: unknown): boolean => typeof v === "string" && /^[\x21-\x7e]{1,4096}$/.test(v);

/** A canonical 32-byte base64url key without padding (answer.rs key_bytes: it re-encodes to the same text). */
export function canonicalKey(v: unknown): boolean {
  if (typeof v !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(v)) return false;
  const bytes = Buffer.from(v, "base64url");
  return bytes.length === 32 && bytes.toString("base64url") === v;
}

/**
 * What `cmux carrier dial` would refuse in a POST /v1/cloud/machines/{id}/carrier answer for a person who sent a
 * noise_key (cmux-platform CarrierRoute.ts), or null when the dial would take it. The rules are answer.rs
 * parse_answer's (relay, slot, ticket, expires_at, grant) and client.rs pinned_daemon's (the daemon key a dial pins),
 * plus a ticket still live and a grant present, which a dial with a noise_key needs.
 */
export function carrierTicketProblem(status: number, body: any, nowS = Date.now() / 1000): string | null {
  if (status !== 200 || body?.ok !== true) return `HTTP ${status} ${short(body?.error ?? body)}`;
  const v = body.value ?? {};
  const relay = relayDoProblem(v.relay);
  if (relay) return relay;
  if (typeof v.slot !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(v.slot)) return "slot is not 1 to 128 base64url characters";
  if (!visibleSecret(v.ticket)) return "ticket is not 1 to 4096 visible ASCII bytes";
  if (!Number.isSafeInteger(v.expires_at) || v.expires_at < 0) return "expires_at is missing";
  if (v.expires_at <= nowS) return `the ticket is not live (expires_at ${v.expires_at})`;
  if (!visibleSecret(v.grant)) return "grant is not 1 to 4096 visible ASCII bytes";
  if (!canonicalKey(v.daemon_key)) return "no canonical 32-byte daemon_key: the dial refuses an answer without one";
  return null;
}

/** The first text's epoch ms: the create's send plus its first_text mark; null when either was not reached. */
export function firstTextEpoch(timing: FirstTextTiming, createSentAt: number | null): number | null {
  const at = timing.fields().create_marks_ms?.first_text;
  return createSentAt === null || at === undefined ? null : createSentAt + at;
}

/** How long after the first token the send's trace is read, so the platform's last spans have landed. */
export const SEND_TRACE_SETTLE_MS = 5_000;

/**
 * The send's Chrome trace (cloud-start-trace.ts readSendTrace), ~5 s after its first token: saved as send-trace.json
 * in the run's out dir, its hops printed with their floors, and its id printed. A 404 or any error is printed only.
 */
export async function saveSendTrace(api: Pick<Api, "raw">, id: string, firstTextAt: number | null, outDir: string | null, now = Date.now, wait = sleep): Promise<boolean> {
  const left = (firstTextAt ?? now()) + SEND_TRACE_SETTLE_MS - now();
  if (left > 0) await wait(left);
  const got = await readSendTrace((m, r, b, t) => api.raw(m, r, b, t), id);
  if ("missing" in got) {
    console.log(`send trace ${id}: not read: ${got.missing}`);
    return false;
  }
  if (outDir) writeFileSync(path.join(outDir, "send-trace.json"), `${JSON.stringify(got.body)}\n`);
  console.log(`send trace ${id} (Chrome trace JSON, opens in ui.perfetto.dev)${outDir ? `: ${path.join(outDir, "send-trace.json")}` : ""}`);
  console.log(sendTraceTable(sendTraceRows(got.body)));
  return true;
}

/** The carrier dials still running, so a cancelled journey stops them instead of leaving them to their deadline. */
const carrierDials = new Set<ReturnType<typeof spawn>>();
/** Their state dirs, which a cancel (SIGTERM skips `finally`) removes too. */
const carrierStateDirs = new Set<string>();

/**
 * `cmux carrier dial` (design/cloud-carrier.md): this device reaches the machine's session daemon over its relay slot,
 * with the person's credential, as the app will. It passes when the dial reports the carrier route and one identify
 * line gets the daemon's answer. connectMs is the dial's own `cloud.connect ... ms=` (ticket, relay, Noise handshake);
 * replyMs runs from the spawn to the answer.
 */
/**
 * The dial's `carrier.phases` lines (cmux-tui carrier/contract.rs phases_line, one per attempt, written only to the
 * connect log) as `<phase> <outcome>: ticket N, relay N, parked N, handshake N, mux N ms, lanes N, N ms`, without the
 * machine id. A key the line does not have is left out, so a later field (a detail) shows as `key value`.
 */
export function dialPhases(log: string): string[] {
  const named = ["ticket_ms", "relay_ms", "parked_ms", "handshake_ms", "mux_ms"];
  return log.split("\n").filter((l) => l.startsWith("carrier.phases ")).map((line) => {
    const f = Object.fromEntries(line.split(" ").slice(1).map((kv) => kv.split("=")).filter((kv) => kv.length === 2));
    const steps = named.filter((k) => k in f).map((k) => `${k.replace(/_ms$/, "")} ${f[k]}`);
    const rest = Object.keys(f).filter((k) => ![...named, "machine", "phase", "carrier", "outcome", "lanes", "ms"].includes(k));
    return `${f.phase} ${f.outcome}: ${steps.join(", ")} ms${"lanes" in f ? `, lanes ${f.lanes}` : ""}${rest.map((k) => `, ${k} ${f[k]}`).join("")}, ${f.ms} ms`;
  });
}

/** A carrier dial step's detail: the connect and reply times, the failed attempts, and each attempt's phases. */
export function dialDetail(d: { connectMs: number; replyMs: number; retries: number; failed: string[]; phases: string[]; reply: string }): string {
  return `connect ${d.connectMs} ms, reply ${d.replyMs} ms, ${d.retries} retried attempts${d.failed.length ? ` (${d.failed.join(", ")})` : ""}`
    + `${d.phases.length ? `; phases: ${d.phases.join("; ")}` : ""}: ${d.reply.slice(0, 160)}`;
}

/** cmux-autocloud's plain transcript (RFD 0139): null when readiness reached 100 and an agent line (not the
 * `> ` prompt, a `  · ` tool, a `  ! ` note or a `[` status line) names `word` (any agent line when `word` is null:
 * the model stub's reply); else what is missing. */
export function autocloudTuiVerdict(out: string, word: string | null): string | null {
  const ready = /readiness 100\b/.test(out);
  const agent = out.split("\n").filter((l) => l.trim() && !/^(> |  [·!] |\[)/.test(l));
  const said = word === null ? agent.length > 0 : agent.some((l) => new RegExp(`\\b${word}\\b`, "i").test(l));
  if (ready && said) return null;
  return [ready ? "" : "readiness never reached 100", said ? "" : word === null ? "no agent line" : `no agent line says ${word}`].filter(Boolean).join("; ");
}

/** `cmux-autocloud --machine` (RFD 0139's terminal client) on this machine: a new chat over the carrier's acpmux
 * service, one prompt, until the agent's turn ends. `cmux` is put on PATH as the cmux-tui this run built. */
export function autocloudTuiChat(tui: string, cmux: string, api: Pick<Api, "origin" | "bearer" | "team">, machine: string, agent: string, word: string | null): string {
  const bin = mkdtempSync(path.join(tmpdir(), "cmux-autocloud-bin-"));
  symlinkSync(path.resolve(cmux), path.join(bin, "cmux"));
  const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
  const env = { ...inherited, PATH: `${bin}:${process.env.PATH ?? ""}`, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer, ...(api.team ? { CMUX_CLOUD_TEAM: api.team } : {}), CMUX_AUTOCLOUD_TRACE: "1" };
  const started = Date.now();
  const r = spawnSync(tui, ["--machine", machine, "-m", agent, "--plain", "--until-idle", "Reply with the single word pong."], { env, encoding: "utf8", timeout: 120_000, stdio: ["ignore", "pipe", "pipe"] });
  rmSync(bin, { recursive: true, force: true });
  const out = r.stdout ?? "";
  const tail = (s: string) => s.trim().split("\n").slice(-6).join(" | ").slice(0, 600);
  // The first dial's trace says why a link that never comes up dropped; later redials repeat it.
  // The last lines say where a link that did come up stopped (a session/new with no answer); each line is
  // clipped so one long initialize reply cannot push them out.
  const head = (s: string) => {
    // The step's detail is cut at 1000 characters, so keep only the last lines, short: where the link stopped.
    const lines = s.trim().split("\n").map((line) => (line.length > 160 ? `${line.slice(0, 160)}…` : line));
    return lines.slice(-7).join(" | ");
  };
  if (r.error) throw new Error(`cmux-autocloud: ${r.error.code ?? r.error.message}; stderr tail: ${head(r.stderr ?? "")}; stdout: ${tail(out).slice(0, 150)}`);
  const problem = autocloudTuiVerdict(out, word);
  if (r.status !== 0 || problem) throw new Error(`cmux-autocloud exit ${r.status}${problem ? `, ${problem}` : ""}; stdout: ${tail(out)}; stderr: ${head(r.stderr ?? "")}`);
  return `${Date.now() - started} ms: ${tail(out)}`;
}

export async function carrierDial(cmux: string, api: Pick<Api, "origin" | "bearer" | "team">, machine: string, deadlineMs = 45_000): Promise<{ connectMs: number; replyMs: number; retries: number; failed: string[]; phases: string[]; reply: string }> {
  const started = performance.now();
  // The dial's own state dir, so its connect log holds only this dial's lines (the device key is not kept there).
  const stateDir = mkdtempSync(path.join(tmpdir(), "cmux-carrier-"));
  carrierStateDirs.add(stateDir);
  const phases = () => {
    try {
      return dialPhases(readFileSync(path.join(stateDir, "carrier", "connect.log"), "utf8"));
    } catch {
      return [];
    }
  };
  // The team is the journey's own or none: an inherited CMUX_CLOUD_TEAM would send a header its API calls do not.
  const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
  const env = { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer, CMUX_TUI_STATE_DIR: stateDir };
  const args = ["carrier", "dial", "--machine", machine, "--deadline-ms", String(deadlineMs), ...(api.team ? ["--team", api.team] : [])];
  const child = spawn(cmux, args, { env, stdio: ["pipe", "pipe", "pipe"] });
  carrierDials.add(child);
  child.on("exit", () => carrierDials.delete(child));
  // A cmux that does not start, or a dial that exits before its stdin is written, fails this step, not the journey.
  let failed: Error | null = null;
  const failure = new Promise<never>((_, reject) => {
    child.on("error", (e) => reject((failed = new Error(`carrier dial: ${e.message}`))));
    child.stdin!.on("error", (e) => reject((failed = new Error(`carrier dial: stdin ${e.message}`))));
  });
  failure.catch(() => undefined);
  const lines = (stream: NodeJS.ReadableStream) => {
    let buffered = "";
    const waiting: Array<(line: string | null) => void> = [];
    const queued: Array<string | null> = [];
    const push = (line: string | null) => (waiting.length ? waiting.shift()!(line) : queued.push(line));
    stream.setEncoding("utf8");
    stream.on("data", (chunk: string) => {
      buffered += chunk;
      for (let at = buffered.indexOf("\n"); at >= 0; at = buffered.indexOf("\n")) {
        push(buffered.slice(0, at));
        buffered = buffered.slice(at + 1);
      }
    });
    stream.on("end", () => push(null));
    return () => new Promise<string | null>((resolve) => (queued.length ? resolve(queued.shift()!) : waiting.push(resolve)));
  };
  const err = lines(child.stderr!);
  const out = lines(child.stdout!);
  const within = <T,>(what: string, p: Promise<T>) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`carrier dial: no ${what} within ${deadlineMs + 15_000} ms`)), deadlineMs + 15_000);
    });
    return Promise.race([p, late, failure]).finally(() => clearTimeout(timer));
  };
  try {
    // stderr: the JSON status line, and a `cloud.connect route=carrier ... outcome=<ok|error_code> ms=N` line per
    // connection attempt. A failed attempt the dial retries is counted, not fatal; the ok attempt's ms is the connect time.
    let status: any = undefined;
    let connectMs = NaN;
    let retries = 0;
    const failed: string[] = [];
    // A dial that gives up still says which attempts failed and how.
    const attempts = (message: string) => new Error(failed.length ? `${message} (failed attempts: ${failed.join(", ")})` : message);
    while (status === undefined || !Number.isFinite(connectMs)) {
      const line = await within(status === undefined ? "status line" : "ok route line", err()).catch((e: Error) => {
        throw attempts(e.message);
      });
      if (line === null) throw attempts(`carrier dial: ${status === undefined ? "ended with no status line" : "ended with no ok route line"}`);
      const attempt = /^cloud\.connect route=carrier .*outcome=(\S+) ms=(\d+)/.exec(line);
      // The dial's status line comes first (cmux-tui spec/cli.md), so a route line before it is out of contract.
      if (attempt && status === undefined) throw new Error(`carrier dial: a route line before the status line: ${short(line)}`);
      if (attempt) {
        if (attempt[1] === "ok") connectMs = Number(attempt[2]);
        else {
          retries += 1;
          failed.push(`${attempt[1]} ${attempt[2]} ms`);
        }
        continue;
      }
      if (status !== undefined) throw new Error(`carrier dial: unexpected line ${short(line)}`);
      try {
        status = JSON.parse(line);
      } catch {
        throw new Error(`carrier dial: not a status line: ${short(line)}`);
      }
      if (status?.ok !== true) {
        // A dial that gives up writes its status line first, then the route line of every attempt it made.
        const next = () => within("route lines", err()).catch(() => null);
        for (let rest = await next(); rest !== null; rest = await next()) {
          const tried = /^cloud\.connect route=carrier .*outcome=(\S+) ms=(\d+)/.exec(rest);
          if (tried && tried[1] !== "ok") failed.push(`${tried[1]} ${tried[2]} ms`);
        }
        throw attempts(`carrier dial: ${short(status)}`);
      }
      if (status.route !== "carrier") throw new Error(`carrier dial: route ${status.route}, not carrier`);
    }
    child.stdin!.write('{"cmd":"identify","id":1}\n');
    // The daemon may push events first; the answer is the line with id 1, and it must be ok with the daemon's identity.
    for (;;) {
      const reply = await within("answer to identify", out());
      if (reply === null) throw new Error("carrier dial: the stream ended before the daemon answered");
      let answer: any;
      try {
        answer = JSON.parse(reply);
      } catch {
        throw new Error(`carrier dial: not a protocol line: ${reply.slice(0, 200)}`);
      }
      if (answer?.id !== 1) continue;
      if (answer.ok !== true || typeof answer.data?.app !== "string") throw new Error(`carrier dial: identify answered ${short(answer)}`);
      return { connectMs, replyMs: Math.round(performance.now() - started), retries, failed, phases: phases(), reply };
    }
  } catch (e) {
    // Every way a dial fails shows each attempt's phases, read before the dir goes.
    const tried = phases();
    throw tried.length ? new Error(`${(e as Error).message} (phases: ${tried.join("; ")})`) : e;
  } finally {
    if (!failed) child.stdin!.end();
    child.kill("SIGTERM");
    rmSync(stateDir, { recursive: true, force: true });
    carrierStateDirs.delete(stateDir);
  }
}

/** A `cmux.rd/1` frame on the dial's stdin and stdout: u8 type (1 control JSON, 2 datagram), u32 little-endian length, payload. */
export function rdFrame(type: 1 | 2, payload: Uint8Array): Buffer {
  const head = Buffer.alloc(5);
  head[0] = type;
  head.writeUInt32LE(payload.length, 1);
  return Buffer.concat([head, payload]);
}

/**
 * An empty viewer feedback datagram: the 16-byte header (cmux-rd-proto datagram.rs: version 1 in the high nibble, kind
 * 7 Feedback, the rest 0), then feedback.rs's payload with nothing acked, no recovery, no arrivals and no NACKs. The
 * host keeps a session alive for a bounded 90 s without feedback
 * (cmux-rd-host stream.rs REATTACH_GRACE_NS), so a viewer can reattach after
 * a full network drop before the abandoned session is ended.
 */
export const RD_FEEDBACK = Buffer.concat([Buffer.from([0x10, 7]), Buffer.alloc(14), Buffer.alloc(12)]);

/** The viewer's hello: the app's (RemoteRdHello.cloudDesktop), no token (the link's owner is the carrier's person). */
export const RD_HELLO = { t: "hello", user: "cloud-journey", install: "cloud-journey", class: "user", interactive: true, udp_port: null, max_datagram: 1200, service: "desktop", caps: [] as string[] };

/** The `cloud.desktop_link machine=vm_… <note>` lines of a dial's connect log (cmux-tui carrier/mod.rs). */
export function desktopLinkLines(log: string): string[] {
  return log.split("\n").filter((l) => l.startsWith("cloud.desktop_link "));
}

/** A desktop_link line's note: `answered`, `up`, `host_up`, `failed …`, `not_answered`, `host_down …`, `not_offered …`. */
export function desktopLinkNote(line: string): string {
  return line.replace(/^cloud\.desktop_link machine=\S+ ?/, "");
}

/** Addresses in a public log are left out: a candidate keeps its kind, never the runner's or the machine's address. */
export function maskAddresses(text: string): string {
  return text.replace(/\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/g, "<addr>").replace(/\[?\b[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){2,7}\]?(?::\d+)?/gi, "<addr>");
}

/** Up when a note says the link is up on either side; else why not, by the note that names it. */
export function desktopLinkVerdict(lines: string[]): { up: boolean; why: string } {
  const notes = lines.map(desktopLinkNote);
  const up = notes.filter((n) => /^(up|host_up)\b/.test(n));
  if (up.length) return { up: true, why: `the link came up (${up.join(", ")})` };
  if (!notes.length) return { up: false, why: "no cloud.desktop_link line: the platform sent no rd_link for this team (CLOUD_RD_LINK off), or the dial never reached the desktop" };
  if (notes.some((n) => n.startsWith("not_answered"))) return { up: false, why: "not_answered: the host's welcome has no link.udp (an image without cmux-rd 0.2.3 --link-stun)" };
  return { up: false, why: `the link did not come up: ${notes.join("; ")}` };
}

/** Every team id named in these values (`team_<id>`), once each, in order. */
export function teamIdsIn(...values: unknown[]): string[] {
  return [...new Set(values.flatMap((v) => JSON.stringify(v ?? null).match(/\bteam_[0-9a-z]{8,64}\b/g) ?? []))];
}

export type DesktopLinkRun = { status: unknown; controls: string[]; datagrams: number; lines: string[]; error: string | null; ms: number };

/**
 * `cmux carrier dial --service desktop` with this run as the viewer: once the dial's status line is ok, a hello and a
 * view-only start, then an empty feedback datagram every 500 ms after `started`, as the app's viewer keeps the session.
 * The dial splices the link in (rd_link.rs) and writes its notes to its own connect log. It stops 3 s after the first
 * final note (up, host_up or a failure, so both sides' up are read), when the host ends the session, or after holdMs.
 * Never throws for what the dial said: the caller reads the lines.
 */
export async function desktopLinkDial(cmux: string, api: Pick<Api, "origin" | "bearer" | "team">, machine: string, holdMs = 45_000, deadlineMs = 60_000): Promise<DesktopLinkRun> {
  const started = performance.now();
  const stateDir = mkdtempSync(path.join(tmpdir(), "cmux-desktop-link-"));
  carrierStateDirs.add(stateDir);
  const log = () => {
    try {
      return readFileSync(path.join(stateDir, "carrier", "connect.log"), "utf8");
    } catch {
      return "";
    }
  };
  const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
  const env = { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer, CMUX_TUI_STATE_DIR: stateDir };
  const args = ["carrier", "dial", "--machine", machine, "--service", "desktop", "--deadline-ms", String(deadlineMs), ...(api.team ? ["--team", api.team] : [])];
  const child = spawn(cmux, args, { env, stdio: ["pipe", "pipe", "pipe"] });
  carrierDials.add(child);
  let exited = false;
  let error: string | null = null;
  child.on("exit", () => {
    exited = true;
    carrierDials.delete(child);
  });
  child.on("error", (e) => {
    exited = true;
    error ??= `carrier dial: ${e.message}`;
  });
  child.stdin!.on("error", () => undefined);
  const write = (bytes: Buffer) => {
    if (!exited && child.stdin!.writable) child.stdin!.write(bytes);
  };
  let status: unknown = undefined;
  let errText = "";
  child.stderr!.setEncoding("utf8");
  child.stderr!.on("data", (chunk: string) => {
    errText += chunk;
    for (let at = errText.indexOf("\n"); at >= 0; at = errText.indexOf("\n")) {
      const line = errText.slice(0, at);
      errText = errText.slice(at + 1);
      if (status !== undefined) continue;
      try {
        status = JSON.parse(line);
      } catch {
        status = { ok: false, not_a_status_line: line.slice(0, 200) };
      }
    }
  });
  const controls: string[] = [];
  let datagrams = 0;
  let feedback: ReturnType<typeof setInterval> | undefined;
  let pending = Buffer.alloc(0);
  child.stdout!.on("data", (chunk: Buffer) => {
    pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
    while (pending.length >= 5) {
      const size = pending.readUInt32LE(1);
      if (pending.length < 5 + size) break;
      const type = pending[0];
      const payload = pending.subarray(5, 5 + size);
      pending = pending.subarray(5 + size);
      if (type !== 1) {
        datagrams += 1;
        continue;
      }
      let name = "?";
      try {
        const c = JSON.parse(payload.toString("utf8"));
        name = `${c.t}${typeof c.reason === "string" ? ` ${c.reason}` : ""}`;
      } catch { /* counted as "?" */ }
      controls.push(name.slice(0, 160));
      if (name === "started" && !feedback) feedback = setInterval(() => write(rdFrame(2, RD_FEEDBACK)), 500);
    }
  });
  try {
    const statusBy = Date.now() + deadlineMs + 15_000;
    while (status === undefined && !exited && Date.now() < statusBy) await sleep(100);
    if (status === undefined) error ??= exited ? "carrier dial: ended with no status line" : `carrier dial: no status line within ${deadlineMs + 15_000} ms`;
    else if ((status as any)?.ok !== true) error = `carrier dial: ${short(status)}`;
    else {
      write(rdFrame(1, Buffer.from(JSON.stringify(RD_HELLO))));
      write(rdFrame(1, Buffer.from(JSON.stringify({ t: "start", key: randomUUID(), mode: "view" }))));
      const until = Date.now() + holdMs;
      let settleBy = Infinity;
      while (!exited && Date.now() < Math.min(until, settleBy)) {
        await sleep(250);
        const notes = desktopLinkLines(log()).map(desktopLinkNote);
        if (settleBy === Infinity && notes.some((n) => /^(up|host_up|failed|not_answered|not_offered|not_started|host_down)\b/.test(n))) settleBy = Date.now() + 3_000;
        if (controls.some((c) => c.startsWith("ended") || c.startsWith("refused"))) break;
      }
      if (exited && !error) error = "carrier dial: ended while the desktop was open";
    }
    return { status, controls, datagrams, lines: desktopLinkLines(log()), error, ms: Math.round(performance.now() - started) };
  } finally {
    clearInterval(feedback);
    child.stdin!.end();
    child.kill("SIGTERM");
    rmSync(stateDir, { recursive: true, force: true });
    carrierStateDirs.delete(stateDir);
  }
}

/**
 * --cleanup-tag TAG: deletes the machines a journey run with this tag made (`cloud journey auto TAG` and its gateway,
 * by exact name, never another run's), each logged first. For a workflow's always() step: the run's own cleanup is
 * the first line, this the second when the run was cut off.
 */
async function cleanupTagMode(tag: string, backend: Backend, email: string | undefined, password: string | undefined, team: string | undefined, kept = false): Promise<number> {
  if (!/^jr-[0-9a-z]{1,16}$/.test(tag)) throw new Error(`--cleanup-tag ${JSON.stringify(tag.slice(0, 40))}: not a journey tag (jr-<base36>)`);
  if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
  const secrets = [password];
  const s = await passwordSignIn(STACK[backend.stack], email, password);
  secrets.push(s.access, s.refresh);
  const api = new Api(backend.api, team);
  api.bearer = s.access;
  const names = new Set([false, true].flatMap((long) => [autoMachineName(tag, long), `${autoMachineName(tag, long)} gateway`]));
  // --kept: also the machine a --keep run with this tag made (`cloud journey TAG`), once its operator is done with it.
  if (kept) names.add(`cloud journey ${tag}`).add(`cloud journey ${tag} gateway`);
  const rows = await listAllMachines((params) => api.read("cloud.machine.list", params));
  const mine = rows.filter((r) => names.has(r?.name) && r.status !== "deleted" && r.status !== "deleting");
  let failed = 0;
  for (const r of mine) {
    const id = String(r.id ?? r.machine_id ?? "");
    console.log(JSON.stringify({ deleting: id, name: r.name, status: r.status }));
    await api.deleteMachine(id, `${tag}-tag-cleanup-${id}`).catch((e: Error) => {
      failed += 1;
      console.log(scrub(JSON.stringify({ failed: id, error: String(e?.message ?? e).slice(0, 300) }), secrets));
    });
  }
  console.log(JSON.stringify({ tag, found: mine.length, deleted: mine.length - failed }));
  return failed ? 1 : 0;
}

/**
 * The run as one synthetic-probe result row (cmuxterm-hq tools/fleet-reconcilers/probes.py): ok only when a reply
 * was read back, with the existing ms from send to completed reply; otherwise fail with the first failed step.
 * Both legs carry create-to-streamed-first-text and cumulative phase marks; the row's `model` says which leg, and
 * cmuxterm-hq's cloud_journey_probe.py files each leg under its own probe, so a stub time never joins the real one.
 */
export function probeRow(probe: string, steps: Step[], run?: string, at = new Date(), context?: { backend: string; model: "real" | "stub"; run_attempt?: number }, extra: ProbeExtra = {}): Record<string, unknown> {
  const send = steps.find((s) => s.step === "send chat");
  const reply = steps.find((s) => s.step === "reply");
  const failed = steps.find((s) => s.status === "fail");
  const ready = readyMs(steps);
  const fields = context ? [...steps].reverse().find((s) => s.fields)?.fields : undefined;
  const { failure_facts, ...spare } = extra;
  const base = { probe, at: at.toISOString().replace(/\.\d+Z$/, "Z"), runner: "github-actions", ...(run ? { run } : {}), ...(ready === null ? {} : { ready_ms: ready }), ...context, ...fields, ...spare };
  if (reply?.status === "pass" && send) return { ...base, outcome: "ok", ms: send.ms + reply.ms };
  return { ...base, outcome: "fail", error: failed ? `${failed.step}: ${failed.detail}`.slice(0, 300) : "no reply step ran", ...(failure_facts ? { failure_facts } : {}) };
}

/**
 * What a row adds once create answered (probe.json is public: counts, reasons and relative times, never an id):
 * the claim answer's spare_fallback and spare_skips (cmux-platform#1418; null while the answer has neither), whether
 * the guest timeline showed a claimed spare, and on a failed run the facts read before anything was deleted.
 */
export type ProbeExtra = {
  spare_fallback?: string | null;
  spare_skips?: Record<string, number> | null;
  claimed_spare?: boolean | null;
  /** Whether the reserved first-home-chat ticket was consumed by the app-style start. */
  reserved_hit?: boolean;
  /** The claim answer's value.claim.behind (cmux-platform#1429): the spare taken was one image roll behind; null with no claim. */
  claimed_behind?: boolean | null;
  /** How the login reached the machine: the spare's copy on spare.ready (a receipt after the claim), or a copy after bind. */
  login_path?: "receipt" | "copy" | "launch";
  failure_facts?: FailureFacts;
};
export type FailureFacts = {
  machine: Record<string, string | number | boolean> | null;
  machine_error?: string;
  timeline: GuestTimelineFacts | null;
  timeline_error?: string;
};

/** A reason or state as a bare token, or null: no id, address, path or free text gets through. */
const TOKEN = /^[a-z][a-z0-9_]{0,39}$/;
/** A version or image tag (`0.164.0`, `cloud-native-auto-70e5c08f-43720622282-1`); never an id or address. */
const VERSION = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$/;
/** An id (`vm_01J...`, `team_8f...`): a prefix and 6 or more characters with a digit or a capital; `vm_unavailable` is a code. */
const ID_WORD = "\\b(?:vm|team|user|inst|install|ws|org|acct|sess|mach|img)_(?=[A-Za-z0-9_-]*[0-9A-Z])[A-Za-z0-9_-]{6,}";
const ID_SHAPE = new RegExp(`${ID_WORD}|[0-9a-f]{8}-[0-9a-f]{4}-|@|^\\d{1,3}(\\.\\d{1,3}){3}$`);
/** A key whose value names a machine, host, person or place, whatever its shape. */
const ID_KEY = /(^|_)(id|ids|target|host|hostname|machine|team|user|owner|url|addr|address|ip|name)$/i;
const publicToken = (v: unknown): string | null => (typeof v === "string" && TOKEN.test(v) && !ID_SHAPE.test(v) ? v : null);
const publicVersion = (v: unknown): string | null => (typeof v === "string" && VERSION.test(v) && !ID_SHAPE.test(v) ? v : null);

/**
 * The create answer's spare claim report (cmux-platform#1418), as counts by reason and a fallback reason, and whether
 * the spare it took was one image roll behind (value.claim.behind, cmux-platform#1429; null when it took none).
 */
export function spareFields(value: unknown): { spare_fallback: string | null; spare_skips: Record<string, number> | null; claimed_behind: boolean | null } {
  const v = (value ?? {}) as Record<string, unknown>;
  const raw = v.spare_skips;
  let skips: Record<string, number> | null = null;
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    skips = {};
    for (const [k, n] of Object.entries(raw as Record<string, unknown>)) {
      if (TOKEN.test(k) && Number.isSafeInteger(n) && (n as number) >= 0) skips[k] = n as number;
    }
  }
  const claim = v.claim && typeof v.claim === "object" && !Array.isArray(v.claim) ? (v.claim as Record<string, unknown>) : null;
  return { spare_fallback: publicToken(v.spare_fallback), spare_skips: skips, claimed_behind: claim ? claim.behind === true : null };
}

/**
 * One workflow notice per create with the claim's public fields, so every journey run's spare claim can be counted
 * from its run's annotations (the image-skip share on staging: spare_skips.image, and claims served one roll behind,
 * against claims served). Counts and reason tokens only, as probe.json.
 */
export function spareNotice(backend: string, phase: string, fields: ReturnType<typeof spareFields>): string {
  const skips = JSON.stringify(fields.spare_skips);
  return `::notice title=Cloud journey spare::backend=${backend} phase=${phase || "-"} fallback=${fields.spare_fallback} behind=${fields.claimed_behind} skips=${skips}`;
}

/** A cloud.machine.get answer's public facts: its status, readiness, versions and updater/flip state. No id or host. */
export function publicMachineFacts(m: unknown): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  const row = (m ?? {}) as Record<string, unknown>;
  const put = (key: string, v: unknown, version = false) => {
    if (typeof v === "boolean" || (typeof v === "number" && Number.isFinite(v))) out[key] = v;
    else if (typeof v === "string") {
      const t = version ? publicVersion(v) : publicToken(v);
      if (t !== null) out[key] = t;
    }
  };
  put("status", row.status);
  put("ready", row.ready);
  const image = (row.image ?? {}) as Record<string, unknown>;
  put("daemon_version", image.daemon_version ?? row.daemon_version, true);
  for (const k of ["version", "tag", "acpmux_version", "cmux_tui_version"]) put(`image_${k}`, image[k], true);
  // Whatever the row says about readiness, restarts and the updater's flip, at the top level or one object down.
  const facts = /ready|restart|updat|flip|health|daemon_state|state$/i;
  for (const [k, v] of Object.entries(row)) {
    if (k in out || !TOKEN.test(k) || ID_KEY.test(k)) continue;
    if (v && typeof v === "object" && !Array.isArray(v)) {
      if (/updat|flip|daemon|health/i.test(k)) for (const [k2, v2] of Object.entries(v as Record<string, unknown>)) if (TOKEN.test(k2) && !ID_KEY.test(k2)) put(`${k}_${k2}`, v2, /version/i.test(k2));
    } else if (facts.test(k)) put(k, v, /version/i.test(k));
  }
  return out;
}

/** An error for probe.json: no secret, id, address or URL; short. */
export function publicError(text: string, secrets: string[] = []): string {
  return scrub(text, secrets)
    .replace(/https?:\/\/\S+/g, "<url>")
    .replace(new RegExp(ID_WORD, "g"), "<id>")
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "<id>")
    .replace(/\b\d{1,3}(\.\d{1,3}){3}\b/g, "<addr>")
    .replace(/[0-9a-f]{16,}/gi, "<hex>")
    // A bare host name (a guest's stderr, an error body): any dotted name with a letter in its last label.
    .replace(/\b(?:[a-z0-9-]+\.)+[a-z][a-z0-9-]*\b/gi, "<host>")
    .slice(0, 200);
}

/** A promise that rejects after `ms`, so a read on a broken machine cannot hold the cleanup behind it. */
export function bounded<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`${what}: no answer in ${ms} ms`)), ms); });
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

/**
 * The machine's exec, which says so when its first command meets an unavailable machine (HTTP 503 vm_unavailable on
 * a machine create reported running), whichever step sends it: the `first exec` check now runs after the chat, so the
 * login or the agent start is the first to reach the machine.
 */
export function namesUnavailableFirstExec(exec: Exec): Exec {
  let reached = false;
  const unavailable = (text: string) => /vm_unavailable|HTTP 503/.test(text);
  const say = (text: string) => new Error(`the machine did not take its first exec, though create reported it running (the claimed machine is unavailable): ${text}`);
  return async (command, timeoutMs) => {
    if (reached) return exec(command, timeoutMs);
    let r: ExecResult;
    try {
      r = await exec(command, timeoutMs);
    } catch (error) {
      const text = String((error as Error)?.message ?? error);
      throw unavailable(text) ? say(text) : error;
    }
    if (r.code !== 0 && /vm_unavailable/.test(`${r.stdout}${r.stderr}`)) throw say(`exit ${r.code} ${`${r.stdout}${r.stderr}`.slice(-200)}`);
    reached = true;
    return r;
  };
}

/** How long a failure-facts read may take: the cleanup waits on it before it deletes the machine. */
const FACTS_READ_MS = 10_000;

/** The checks only the journey runs, never part of a person's chat: they run after the reply, outside J.firstText. */
/** The guest's size, measured on it: CPU count, memory and root disk, in the form sizeReadingProblem reads. */
export const SIZE_READ = "echo journey-ok; uname -m; echo cpu=$(nproc) mem_mib=$(free -m | awk '/^Mem:/{print $2}') disk_mib=$(df -BM --output=size / | tail -1 | tr -dc 0-9)";
export const COLD_CREATE_STEP = "cold create (asked size)";
export const JOURNEY_ONLY_STEPS = ["listed", DEFAULT_SIZE_STEP, "first exec", COLD_CREATE_STEP, "machine facts", "GitHub connection (team status)", "GitHub on the machine (stub)", "GitHub on the machine (live)", "GitHub by the agent (live)"] as const;

/** A Swift `static let NAME = #"""...."""#` raw string, with the closing delimiter's indentation stripped. */
export function swiftRawString(source: string, name: string): string {
  const m = new RegExp(`static let ${name} = #"""\\n([\\s\\S]*?)\\n([ \\t]*)"""#`).exec(source);
  if (!m) throw new Error(`no ${name} in the installer source`);
  const indent = m[2];
  return m[1].split("\n").map((line) => (line.startsWith(indent) ? line.slice(indent.length) : line.trimStart())).join("\n");
}

/** The clean-room provider key probe the journey runs on the chat machine after the chat. */
export const KEY_PROBE_PY = fileURLToPath(new URL("./cloud-key-probe.py", import.meta.url));
export const KEY_PROBE_STEP = "clean room: no provider key on the machine";
export type KeyFinding = { place: "env" | "cmdline" | "file"; where: string; what: string };
export type KeyProbe = { as_root: boolean; complete: boolean; gaps: string[]; findings: KeyFinding[]; shipped?: KeyFinding[]; scanned: Record<string, number>; unreadable: string[]; truncated: boolean; ms: number };

/** The probe sent as one exec: as root when sudo asks no password, so it reads every process and home. */
export function keyProbeCommand(source: string, args: string[] = []): string {
  if (source.includes("CMUX_KEY_PROBE")) throw new Error("the probe's source holds its own heredoc delimiter");
  const rest = args.map((a) => ` ${shq(a)}`).join("");
  return `if sudo -n true 2>/dev/null; then p="sudo -n python3"; else p=python3; fi; $p -I -${rest} <<'CMUX_KEY_PROBE'\n${source}\nCMUX_KEY_PROBE`;
}

/** The probe's answer from its `@@keyprobe ` line; throws when the probe printed none. */
export function parseKeyProbe(stdout: string): KeyProbe {
  const line = stdout.split("\n").find((l) => l.startsWith("@@keyprobe "));
  if (!line) throw new Error(`the probe printed no answer: ${stdout.slice(-300)}`);
  const p = JSON.parse(line.slice("@@keyprobe ".length));
  if (!Array.isArray(p?.findings) || typeof p?.complete !== "boolean" || !Array.isArray(p?.gaps)) throw new Error(`the probe's answer has no findings list or coverage: ${line.slice(0, 300)}`);
  return p as KeyProbe;
}

/**
 * The step's result: a finding fails a clean check and is reported otherwise; no finding passes only when the probe
 * read everything (`complete`), since a gap in what it read is "unknown", never "no key".
 */
export function keyProbeStatus(p: KeyProbe, clean: boolean): Status {
  if (p.findings.length || !p.complete) return clean ? "fail" : "skip";
  return "pass";
}

/** The findings, one `place where: what` each, then what the probe could read. Names and places only. */
export function keyProbeDetail(p: KeyProbe): string {
  const s = p.scanned ?? {};
  const cover =
    `${p.as_root ? "as root" : "not as root"}, ${s.processes ?? 0} processes, ${s.files ?? 0} files in ${p.ms} ms; ` +
    (p.complete ? "everything read" : `incomplete: ${p.gaps.join(", ")}`) +
    (p.shipped?.length ? `; ${p.shipped.length} key shape${p.shipped.length > 1 ? "s" : ""} in installed software, not counted` : "");
  if (!p.findings.length) return p.complete ? `no provider key (${cover})` : `no finding, but not everything was read, so unknown (${cover})`;
  const list = p.findings.map((f) => `${f.place} ${f.where}: ${f.what}`);
  return `${p.findings.length} finding${p.findings.length > 1 ? "s" : ""}: ${list.join("; ")} (${cover})`;
}

/** The model stub --model stub runs on the machine. */
/** The shared model stub (tests/fixtures/model-stub, #35332): Anthropic Messages and OpenAI Responses, scripted. */
export const MODEL_STUB_PY = fileURLToPath(new URL("../../tests/fixtures/model-stub/model_stub.py", import.meta.url));
/** GitHub on a Cloud machine through the team connection, run on the guest (the journey's GitHub steps). */
export const GITHUB_E2E_SH = fileURLToPath(new URL("./cloud-github-e2e.sh", import.meta.url));
/** Where the journey writes cloud-github-e2e.sh on the guest. */
export const GITHUB_E2E_GUEST = "/home/cmux/.cmux/cloud-github-e2e.sh";
export const GITHUB_STATUS_STEP = "GitHub connection (team status)";
export const GITHUB_AGENT_STEP = "GitHub by the agent (live)";

/** CMUX_JOURNEY_GITHUB_REPO as OWNER/REPO, or null when unset or not that shape. */
export function githubSandbox(value: string | undefined): string | null {
  const v = value?.trim() ?? "";
  return /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(v) ? v : null;
}

/** The `e2e: NAME ok|FAIL ...` lines of cloud-github-e2e.sh, one per cell, joined for a step's detail. */
export function e2eLines(stdout: string): string {
  return stdout.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("e2e:")).join("; ");
}

export type GithubConnectionFacts = {
  configured: boolean;
  allowed: boolean;
  connected: boolean;
  /** The GitHub account (user or org) the App is installed on: an account name, never a repository. */
  account: string | null;
  status: string | null;
  /** Repositories the installation selected, "all" when it has all of its account's, null when unknown. */
  selected: number | "all" | null;
  /** From the team's repository list (its first page): how many, and how many private. */
  listed: number | null;
  private_listed: number | null;
  /** Whether the sandbox repository is in the list (and private); null with no sandbox or no list. */
  sandbox_listed: boolean | null;
  sandbox_private: boolean | null;
};

const repoName = (r: unknown): string => (typeof r === "string" ? r : typeof (r as any)?.full_name === "string" ? (r as any).full_name : "");

/** Answers the sandbox lookup reads (GET /v1/integrations/github/repos?query=, then each `cursor`) before it says unknown. */
export const GITHUB_SANDBOX_PAGES = 5;

/** The sandbox's entry in the team's repository list, or null; complete when the list ended (no `cursor` left). */
export type GithubSandboxLookup = { repo: unknown | null; pages: number; complete: boolean };

/**
 * The sandbox in the team's repository list, wherever it sits: the API's `query` filter (a case-insensitive match on
 * full_name, which it keeps across its cursors) with the sandbox's name, following `cursor` for up to
 * GITHUB_SANDBOX_PAGES answers. Null when a read fails.
 */
export async function githubSandboxLookup(
  get: (route: string) => Promise<{ status: number; body: any }>,
  team: string | undefined,
  sandbox: string,
): Promise<GithubSandboxLookup | null> {
  const lower = sandbox.toLowerCase();
  let cursor: string | null = null;
  for (let pages = 1; pages <= GITHUB_SANDBOX_PAGES; pages++) {
    const q = new URLSearchParams({ ...(team ? { team } : {}), query: sandbox, ...(cursor ? { cursor } : {}) });
    const r = await get(`/v1/integrations/github/repos?${q}`);
    if (r.status !== 200 || !Array.isArray(r.body?.repos)) return null;
    const repo = r.body.repos.find((x: unknown) => repoName(x).toLowerCase() === lower);
    cursor = typeof r.body.cursor === "string" && r.body.cursor ? r.body.cursor : null;
    if (repo) return { repo, pages, complete: true };
    if (!cursor) return { repo: null, pages, complete: true };
  }
  return { repo: null, pages: GITHUB_SANDBOX_PAGES, complete: false };
}

/**
 * What GET /v1/integrations/github/status and GET /v1/integrations/github/repos say about the team's GitHub
 * connection, as counts and yes/no: no token and no repository name (the sandbox is matched, never listed).
 */
export function githubConnectionFacts(status: any, repos: any | null, sandbox?: string, lookup?: GithubSandboxLookup | null): GithubConnectionFacts {
  const c = status?.connection && typeof status.connection === "object" ? status.connection : null;
  const account = typeof c?.account === "string" && /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/.test(c.account) ? c.account : null;
  const list: any[] | null = Array.isArray(repos?.repos) ? repos.repos : null;
  const lower = sandbox?.toLowerCase();
  // The first page counts; the sandbox is matched there or in its own lookup (the list's later pages). A lookup that
  // stopped at its page cap without it is unknown, never "not listed".
  const onPage = lower && list ? list.find((r) => repoName(r).toLowerCase() === lower) : undefined;
  const hit: any = onPage ?? lookup?.repo ?? undefined;
  const known = Boolean(hit) || (lookup ? lookup.complete : list !== null && repos?.cursor == null);
  const picked = Array.isArray(c?.repos) ? c.repos : null;
  return {
    configured: status?.configured === true,
    allowed: status?.allowed !== false,
    connected: status?.configured === true && status?.allowed !== false && c?.status === "active",
    account,
    status: typeof c?.status === "string" ? c.status : null,
    selected: picked ? picked.length : c && c.repos === null ? "all" : null,
    listed: list ? list.length : null,
    private_listed: list ? list.filter((r) => r?.private !== false && typeof r === "object").length : null,
    sandbox_listed: lower && (list || lookup) && known ? Boolean(hit) : null,
    sandbox_private: hit && typeof hit === "object" ? hit.private !== false : null,
  };
}

export function githubConnectionDetail(f: GithubConnectionFacts): string {
  const yn = (b: boolean | null) => (b === null ? "?" : b ? "yes" : "no");
  return [
    `connected ${yn(f.connected)}`,
    `App configured ${yn(f.configured)}`,
    `policy allows ${yn(f.allowed)}`,
    `connection ${f.status ?? "none"}`,
    `installation account ${f.account ?? "none"}`,
    `repos selected ${f.selected ?? "?"}`,
    `listed ${f.listed ?? "?"} (private ${f.private_listed ?? "?"})`,
    ...(f.sandbox_listed === null ? [] : [`sandbox listed ${yn(f.sandbox_listed)}${f.sandbox_listed ? ` (private ${yn(f.sandbox_private)})` : ""}`]),
  ].join(", ");
}

/** Why the live GitHub cells cannot pass with this connection, or null when they can. */
export function githubConnectionBlocker(f: GithubConnectionFacts, sandbox: string): string | null {
  if (!f.configured) return "this deployment has no GitHub App configured";
  if (!f.allowed) return "the team's policy does not allow GitHub";
  if (!f.connected) return "the team has no active GitHub connection (install the cmux-cloud GitHub App and link it to this team)";
  if (f.sandbox_listed === false) return `the team's GitHub connection does not list ${sandbox} (add it on the App installation's page)`;
  if (f.sandbox_private === false) return `${sandbox} is public; the cells need a private sandbox repository`;
  return null;
}

/**
 * Stops a session's turn that is still running: `acp cancel`, then `acp wait` up to 60 s for the turn to end; a turn
 * still running after that has its session stopped. Says which, for the step's detail.
 */
export async function stopAgentTurn(exec: (cmd: string, timeoutMs?: number) => Promise<{ stdout: string }>, session: string): Promise<string> {
  const s = shq(session);
  const r = await exec(
    `${GUEST}"$c" acp cancel ${s} >/dev/null 2>&1; echo "@@cancel $?"; "$c" acp wait ${s} --timeout 60 >/dev/null 2>&1; w=$?; echo "@@wait $w"; ` +
      `if [ "$w" != 0 ]; then "$c" acp stop ${s} >/dev/null 2>&1; echo "@@stop $?"; fi`,
    90_000,
  ).catch(() => ({ stdout: "" }));
  const wait = /@@wait (\d+)/.exec(r.stdout)?.[1];
  if (wait === "0") return "the turn was cancelled and ended";
  const stop = /@@stop (\d+)/.exec(r.stdout)?.[1];
  return stop === "0" ? `the turn did not end after cancel (wait exit ${wait ?? "?"}); the session was stopped` : `the turn could not be confirmed stopped (wait exit ${wait ?? "?"}, stop exit ${stop ?? "?"})`;
}

/** What the journey asks the agent to do in the sandbox repository, and the branch and file it reads back. */
export function githubAgentAsk(sandbox: string, tag: string): { prompt: string; branch: string; file: string; line: string } {
  const safe = tag.replace(/[^A-Za-z0-9-]/g, "-").slice(0, 40);
  const branch = `cmux-agent-e2e/${safe}`;
  const file = `cmux-e2e/agent-${safe}.md`;
  const line = `cmux agent e2e ${safe}`;
  const prompt = [
    `In the GitHub repository ${sandbox}, using git and gh on this machine:`,
    `clone it into a new folder, create the branch ${branch}, add the file ${file} with the one line "${line}",`,
    `commit it, push the branch, and open a draft pull request from ${branch} into the default branch titled "cmux agent e2e ${safe}".`,
    "Change nothing else. Answer with the pull request URL only.",
  ].join(" ");
  return { prompt, branch, file, line };
}
/**
 * The gateway route's time by hop, from each timed call's Server-Timing (a `hop-s` line after its `hop-t` line; the
 * warm-up is dropped), as p50 ms: the Worker's `auth` and `worker-do`, the team object's `do-wait` and `do-gateway`,
 * then per call `object_hop` (worker-do less the object's spans: the hop into the object and back) and `edge`
 * (curl's TTFB less the Worker's spans: the edge and the network to the Worker), and `untimed`, the counted calls
 * without all four spans (the p50s cover only `calls`). Null when no call carried them.
 * Pure, for the tests.
 */
export const hopSpans = (out: string): Record<string, number> | null => {
  const calls: Array<{ ttfb: number; spans: Record<string, number> }> = [];
  for (const line of out.split("\n")) {
    if (line.startsWith("hop-t ")) calls.push({ ttfb: Number(line.split(" ")[2]) * 1000, spans: {} });
    else if (line.startsWith("hop-s ") && calls.length) {
      for (const entry of line.slice(6).split(",")) {
        const m = /^\s*([\w-]+)\s*;\s*dur=([\d.]+)/.exec(entry);
        if (m) calls[calls.length - 1]!.spans[m[1]!] = Number(m[2]);
      }
    }
  }
  const timed = calls.slice(1).filter((c) => ["auth", "worker-do", "do-wait", "do-gateway"].every((k) => k in c.spans));
  if (!timed.length) return null;
  const p50 = (xs: number[]) => Math.round([...xs].sort((x, y) => x - y)[Math.ceil(xs.length / 2) - 1]!);
  const of = (f: (c: { ttfb: number; spans: Record<string, number> }) => number) => p50(timed.map(f));
  return {
    calls: timed.length,
    untimed: calls.length - 1 - timed.length,
    auth: of((c) => c.spans.auth!),
    "worker-do": of((c) => c.spans["worker-do"]!),
    "do-wait": of((c) => c.spans["do-wait"]!),
    "do-gateway": of((c) => c.spans["do-gateway"]!),
    object_hop: of((c) => c.spans["worker-do"]! - c.spans["do-wait"]! - c.spans["do-gateway"]!),
    edge: of((c) => c.ttfb - c.spans.auth! - c.spans["worker-do"]!),
  };
};

/** The model plane every Cloud machine's agents read (web/services/coderouter/vmGuestEnv.ts). */
const VM_MODEL_PLANE_ENV = "/etc/cmux/model-plane.env";
/** Calls timed each way by the gateway hop cost. */
const HOP_SAMPLES = 20;

/**
 * Curl's `hop-t <status> <starttransfer> <total> <exit>` lines (seconds) after the warm-up, as ms percentiles. Every
 * timed call must answer 200 and curl must exit 0 (a transfer cut short can still report 200). Pure, for the tests. (The marker must not start with `@`: curl reads such a `-w` value as a file.)
 */
export const hopTimes = (out: string, n: number): { ttfb_p50: number; ttfb_p90: number; total_p50: number; total_p90: number } => {
  const rows = out.split("\n").filter((l) => l.startsWith("hop-t ")).map((l) => l.split(" "));
  const timed = rows.slice(1);
  if (timed.length !== n) throw new Error(`${timed.length} of ${n} timed calls answered: ${out.slice(-300)}`);
  const bad = timed.filter((r) => r[1] !== "200" || r[4] !== "0");
  if (bad.length) throw new Error(`${bad.length} of ${n} calls did not answer 200 whole (${bad.map((r) => `${r[1]} exit ${r[4] ?? "?"}`).join(", ")})`);
  const pct = (xs: number[], q: number) => {
    const s = [...xs].sort((x, y) => x - y);
    return Math.round(s[Math.min(s.length - 1, Math.ceil(q * s.length) - 1)]! * 1000);
  };
  const ttfb = timed.map((r) => Number(r[2]));
  const total = timed.map((r) => Number(r[3]));
  return { ttfb_p50: pct(ttfb, 0.5), ttfb_p90: pct(ttfb, 0.9), total_p50: pct(total, 0.5), total_p90: pct(total, 0.9) };
};
/**
 * The journey's stub script: one Bash call whose output (printf joins it, so neither the command nor an error that
 * quotes it carries it) the reply then repeats, so the reply shows the tool round trip. A prompt with the chaos leg's
 * counting marker gets the counting turn instead.
 */
export const JOURNEY_STUB_SCRIPT = {
  version: 1,
  steps: [{ shell: "printf '%s-%s\\n' {{nonce}} tool" }, { text: "Stub reply {{nonce}}. The tool printed {{result.0}}." }],
  // The chaos leg's counting turn of file reads (cloud-chaos.ts), played only for a prompt that carries its marker,
  // and the reserved home chat's read (journeyReadTurnScript).
  turns: [countingTurnScript(), feltTurnScript(), journeyReadTurnScript()],
};

/**
 * The reserved home chat's stub turn (`--home-chat reserved`): one Read of the file its prompt names
 * (journeyReadPrompt), in the chat's own folder, whose text is `<nonce>-tool`; then the reply that repeats it, as the
 * default turn's shell call does. A Read, not a shell call: the app's start (`agent-session-start`) runs the chat under
 * policy `ask`, where acpmux's tool gate holds every shell call for the person (acpmux hub/policy_gate.rs) and only the
 * person's app may answer it (hub/person.rs), so the default turn waited on a permission (prod run 45585084079). A Read
 * in the chat's own folder asks nobody, so the turn runs as a person's would.
 */
export function journeyReadTurnScript(): { match: string; steps: Array<Record<string, unknown>> } {
  return {
    match: "\\[journey-read /\\S+\\]",
    steps: [
      { tool: { name: "Read", input: { file_path: "{{prompt~\\[journey-read (/\\S+)\\]}}" } } },
      // Claude Code's Read numbers its lines: only the file's text is repeated.
      { text: "Stub reply {{nonce}}. The tool printed {{result.0~([0-9a-f]+-tool)}}." },
    ],
  };
}

/** The reserved home chat's prompt: the person's words, then the file the stub's turn reads (journeyReadTurnScript). */
export const journeyReadPrompt = (prompt: string, file: string) => `${prompt} [journey-read ${file}]`;

/**
 * The guest command that writes `<cwd>/.journey-<nonce>.txt` holding `<nonce>-tool` in the chat's own folder (`cwd`,
 * from `acp session info`) and prints `@@file <path>`.
 */
export function journeyReadFileCommand(cwd: string, nonce: string): string {
  const file = `${cwd}/.journey-${nonce}.txt`;
  return `f=${shq(file)}; printf '%s-tool\\n' ${shq(nonce)} > "$f" && echo "@@file $f"`;
}

/**
 * The journey's own test-login installer, next to this script. The app copies no login to a Cloud machine (its agents
 * reach models through the Cloud service's model route), so these programs are the journey's, not the app's.
 */
export const INSTALLER_SWIFT = fileURLToPath(new URL("./cloud-journey-login-installer.txt", import.meta.url));

/**
 * The journey's login programs: the guest check and the installer. `creatorTeamGuest` also allows a team guest, for a
 * run on a team machine the journey itself created.
 */
export function claudeLoginPrograms(installerSwift: string, creatorTeamGuest = false): { preflight: string; install: (payloadPath: string) => string } {
  return loginPrograms(installerSwift, "claude", creatorTeamGuest);
}

/** The same programs for either provider (claude or codex). */
export function loginPrograms(installerSwift: string, provider: "claude" | "codex", creatorTeamGuest = false): { preflight: string; install: (payloadPath: string) => string } {
  const preflight = swiftRawString(installerSwift, creatorTeamGuest ? "creatorTeamPreflight" : "preflight");
  const script = swiftRawString(installerSwift, "script");
  return {
    preflight,
    install: (payloadPath) =>
      "set -e\n. /etc/cmux/agent-auth.sh\ncmux_agent_drop_model_plane_env\n" +
      `python3 - ${shq(provider)} ${shq(payloadPath)} ${creatorTeamGuest ? "owner,team" : "owner"} <<'CMUX_CREDENTIAL_INSTALL'\n${script}\nCMUX_CREDENTIAL_INSTALL`,
  };
}

/** What the preflight checks, one by one, for a refusal's message: the kind record, the image's launchers, the exec user. */
export const PREFLIGHT_PROBE =
  `printf 'vm-kind=%s agent-auth.sh=%s user=%s' "$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]')" ` +
  `"$([ -f /etc/cmux/agent-auth.sh ] && echo yes || echo no)" "$(id -un)"`;

/**
 * Run the preflight until it passes or `budgetMs` runs out. On a VM API machine nothing writes /etc/cmux/vm-kind
 * at create: the guest's cmux-host writes it once it is bound (record_owner_kind), which can land after the
 * machine reads running and takes its first exec. A refusal that outlasts the budget names the failing check.
 */
export async function waitPreflight(exec: Exec, program: string, kinds: string, budgetMs = 90_000, pauseMs = 3_000, pause = sleep): Promise<{ waitedMs: number; tries: number }> {
  const t0 = Date.now();
  for (let tries = 1; ; tries++) {
    const pre = await exec(program);
    if (pre.code === 0) return { waitedMs: Date.now() - t0, tries };
    if (Date.now() - t0 + pauseMs >= budgetMs) {
      const seen = await exec(PREFLIGHT_PROBE).then((r) => r.stdout.trim(), (error) => `probe failed: ${(error as Error).message}`);
      throw new Error(`preflight exit ${pre.code} after ${tries} tries in ${Math.round((Date.now() - t0) / 1000)} s: not an ${kinds} machine with the image's launchers (${seen})`);
    }
    await pause(pauseMs);
  }
}

/**
 * Prints `vm-kind=<record>`: /etc/cmux/vm-kind, after one run of the image's sync (cmux-vm-kind-sync, root) when it
 * does not read owner yet. A claimed warm spare keeps the image's baked `team` until that sync's next tick (every 60 s,
 * cmux-devbox-boot VM_KIND_SYNC_INTERVAL); the backend's create-time write keeps any record already there
 * (guestVmKind.ts). While it reads team, the image's claude launcher (agent-auth.sh cmux_agent_auth_resolve,
 * shared-machine) runs team mode whatever the launch carries: its --settings puts the CodeRouter pair over
 * settings.json's endpoint and empties CLAUDE_CODE_OAUTH_TOKEN, so the launch credential and the stub are both lost
 * (run 45276109812 shard 30-0: the stub's turn answered by coderouter.cmux.internal). The app's start is refused there
 * (cmux-tui agent_start_host.rs); the journey's direct acpmux start is not, so it waits for owner as the app must.
 */
export const OWNER_KIND_PROGRAM =
  `k=$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]'); ` +
  `if [ "$k" != owner ] && [ -x /usr/local/bin/cmux-vm-kind-sync ]; then sudo -n /usr/local/bin/cmux-vm-kind-sync >/dev/null 2>&1; ` +
  `k=$(head -c 64 /etc/cmux/vm-kind 2>/dev/null | tr -d '[:space:]'); fi; echo "vm-kind=\${k:-none}"`;

/** Runs {@link OWNER_KIND_PROGRAM} until the record reads owner or `budgetMs` runs out (then throws, naming the record). */
export async function waitOwnerKind(exec: Exec, budgetMs = 90_000, pauseMs = 3_000, pause = sleep): Promise<{ waitedMs: number; tries: number; first: string }> {
  const t0 = Date.now();
  let first = "";
  for (let tries = 1; ; tries++) {
    const r = await exec(OWNER_KIND_PROGRAM);
    const kind = /vm-kind=(\S+)/.exec(r.stdout)?.[1] ?? `unread (exit ${r.code})`;
    if (!first) first = kind;
    if (kind === "owner") return { waitedMs: Date.now() - t0, tries, first };
    if (Date.now() - t0 + pauseMs >= budgetMs) {
      throw new Error(`/etc/cmux/vm-kind reads ${kind} after ${tries} tries in ${Math.round((Date.now() - t0) / 1000)} s: the image's launcher would run the agent in team mode (CodeRouter), off its launch credential and the stub`);
    }
    await pause(pauseMs);
  }
}

/** What the journey accepts as a login to install, per provider. */
export function validLogin(provider: "claude" | "codex", value: string): boolean {
  if (Buffer.byteLength(value) > 12_000) return false;
  if (provider === "claude") return /^sk-ant-oat01-[\x21-\x7e]{19,11987}$/.test(value);
  try {
    const auth = JSON.parse(value);
    const tokens = auth?.tokens;
    return (auth.OPENAI_API_KEY == null) && !!tokens && ["access_token", "refresh_token", "id_token"].every((k) => typeof tokens[k] === "string" && tokens[k].length > 0);
  } catch {
    return false;
  }
}

/**
 * A made-up Codex ChatGPT sign-in (auth.json) for --model stub: unsigned JWTs whose claims Codex reads (plan, account,
 * an expiry far ahead) and a fresh last_refresh, so Codex never tries to refresh it against OpenAI.
 */
export function stubCodexAuth(seed = randomBytes(16).toString("hex"), now = new Date()): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const exp = Math.floor(now.getTime() / 1000) + 30 * 86400;
  const claims = { email: "journey-stub@cmux.invalid", exp, "https://api.openai.com/auth": { chatgpt_plan_type: "pro", chatgpt_account_id: "acct_journeystub", chatgpt_user_id: `user_${seed.slice(0, 8)}` } };
  const jwt = (extra: object) => `${b64({ alg: "none", typ: "JWT" })}.${b64({ ...claims, ...extra })}.journeystub`;
  return JSON.stringify({ OPENAI_API_KEY: null, tokens: { id_token: jwt({}), access_token: jwt({ jti: `journeystub-${seed}` }), refresh_token: `journeystub-refresh-${seed}`, account_id: "acct_journeystub" }, last_refresh: now.toISOString() });
}

/**
 * --model stub, Codex: the Python program (argv: the stub's port, then config.toml, by default the work user's) that
 * points Codex at the stub. A model provider on the stub's /v1 that uses the ChatGPT sign-in, and:
 * - model "stub-model": a catalog model (the default) gets Code Mode, one JavaScript exec tool sent as an
 *   additional_tools input item the stub cannot answer; a model Codex does not know gets the plain exec_command tool;
 * - chatgpt_base_url on the stub, the apps, plugins and remote_plugin features off and analytics off, so the made-up
 *   sign-in never reaches chatgpt.com (whose 401s would also send Codex to refresh it at auth.openai.com).
 * An active profile's model and provider would win over these, so the root profile key goes (the [profiles.*] tables
 * stay). The image's other settings stay. TOML refuses a table defined twice, so the keys go into the [features] and
 * [analytics] tables the file already has, and a second run replaces its own provider table.
 */
export const CODEX_STUB_CONFIG = String.raw`import pathlib, re, sys
port = sys.argv[1]
p = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else '/home/cmux/.codex/config.toml')
lines = p.read_text().splitlines() if p.exists() else []
header = re.compile(r'\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$')
tables = {'features': {'apps': 'false', 'plugins': 'false', 'remote_plugin': 'false'}, 'analytics': {'enabled': 'false'}}
root = {'model': '"stub-model"', 'model_provider': '"journeystub"', 'chatgpt_base_url': '"http://127.0.0.1:' + port + '/backend-api/"'}
def assigns(line, keys):
    m = re.match(r'\s*([A-Za-z0-9_-]+)\s*=', line)
    return bool(m) and m.group(1) in keys
out, table, seen = [], None, set()
for line in lines:
    m = header.match(line)
    if m:
        table = m.group(1)
        if table == 'model_providers.journeystub':
            continue
        out.append(line)
        if table in tables and table not in seen:
            seen.add(table)
            out += [k + ' = ' + v for k, v in tables[table].items()]
        continue
    if table == 'model_providers.journeystub' or assigns(line, {**root, 'profile': ''} if table is None else tables.get(table, {})):
        continue
    out.append(line)
out = [k + ' = ' + v for k, v in root.items()] + out
for name in tables:
    if name not in seen:
        out += ['', '[' + name + ']'] + [k + ' = ' + v for k, v in tables[name].items()]
out += ['', '[model_providers.journeystub]', 'name = "journey stub"', 'base_url = "http://127.0.0.1:' + port + '/v1"',
        'wire_api = "responses"', 'requires_openai_auth = true']
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text('\n'.join(out) + '\n')
print('stub-ready')`;

/** The bearer a harness sends the model endpoint for a copied login: Claude's token, Codex's ChatGPT access token. */
export function loginBearer(provider: "claude" | "codex", value: string): string {
  return provider === "codex" ? (JSON.parse(value).tokens.access_token as string) : value;
}

/** The public placeholder a Cloud machine's model route sends (acpmux cloud_model_plane.rs PLACEHOLDER). */
export const MODEL_PLANE_PLACEHOLDER = "cmux-vm-edge-placeholder";

/**
 * What each stub-logged model request carried, by credential SHA-256: the journey's login, the machine's model-route
 * placeholder, none, or something else. So a red names the credential that outranked the login.
 */
export function credentialSeen(rows: { cred_sha256?: string }[], want: string): string {
  const placeholder = createHash("sha256").update(MODEL_PLANE_PLACEHOLDER).digest("hex");
  const counts = new Map<string, number>();
  for (const x of rows) {
    const what = x.cred_sha256 === want ? "the login" : x.cred_sha256 === placeholder ? "the model-route placeholder" : !x.cred_sha256 ? "no credential" : "another credential";
    counts.set(what, (counts.get(what) ?? 0) + 1);
  }
  const odd = rows.filter((x) => x.cred_sha256 !== want).map((x: any) =>
    `${x.path} model=${x.model ?? "-"} stream=${Boolean(x.stream)} tools=${(x.tools ?? []).length}${x.side ? " side" : ""} step=${x.step ?? "-"}`);
  return [...counts].map(([what, n]) => `${n} with ${what}`).join(", ") + (odd.length ? `; not the login: ${odd.slice(0, 4).join("; ")}` : "");
}

/**
 * The stub step's credential rule. With a login written onto the machine (`launch` false) every model request carries
 * it. With the agent's launch credential (cmux#40159) the credential is the chat agent's alone: every request that
 * offers tools (the chat's turns) must carry it, and a side request with no tools (a chat title: acpmux's
 * `_acpmux/complete` runs its own `claude -p`, which holds no session credential) carries it or the machine's
 * model-route placeholder, never anything else.
 */
export function judgeStubCredentials(rows: { cred_sha256?: string; tools?: string[]; side?: boolean }[], want: string, launch: boolean): { error?: string; detail: string } {
  const all = `${rows.length} model requests`;
  if (!launch) {
    return rows.every((x) => x.cred_sha256 === want)
      ? { detail: `${all}, each with the forwarded login (SHA-256 match)` }
      : { error: "a model request did not carry the login the journey passed", detail: "" };
  }
  const placeholder = createHash("sha256").update(MODEL_PLANE_PLACEHOLDER).digest("hex");
  const chat = rows.filter((x) => (x.tools ?? []).length > 0 && !x.side);
  const side = rows.filter((x) => !((x.tools ?? []).length > 0 && !x.side));
  if (!chat.length) return { error: "no chat turn offered tools", detail: "" };
  if (!chat.every((x) => x.cred_sha256 === want)) return { error: "a chat turn did not carry the login the journey passed", detail: "" };
  if (!side.every((x) => x.cred_sha256 === want || x.cred_sha256 === placeholder)) return { error: "a side request carried neither the login nor the machine's model route", detail: "" };
  const routed = side.filter((x) => x.cred_sha256 === placeholder).length;
  return { detail: `${all}: ${chat.length} chat turns, each with the launch credential (SHA-256 match)${side.length ? `; ${side.length} side requests, ${routed} of them on the machine's model route` : ""}` };
}

/**
 * Which Claude processes on the machine could send a credential: each one's command (cut short) and which provider
 * names its env sets (names only, never a value).
 */
export const CREDENTIAL_PROCESSES_PROGRAM =
  `n=0; for d in /proc/[0-9]*; do [ -O "$d" ] || continue; ` +
  `c=$(tr '\\0\\n' '  ' < "$d/cmdline" 2>/dev/null | cut -c1-100); ` +
  `printf '%s\\n' "$c" | grep -qE '(^|/)claude( |$)|claude-(agent|code)' || continue; ` +
  `echo "pid \${d#/proc/}: $c :: $(tr '\\0' '\\n' < "$d/environ" 2>/dev/null | grep -oE '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|CLAUDE_CODE_OAUTH_TOKEN)=' | tr -d = | tr '\\n' ' ')"; ` +
  `n=$((n + 1)); [ "$n" -ge 8 ] && break; done; true`;

/**
 * Whether the journey's Claude login goes with the agent's start as its launch credential (cmux#40159), never onto the
 * machine: the way the app sends a person's Cloud model connection, on the stub and on the real model alike. Staging
 * and production machines have no model route of their own (acpmux cloud_model_plane.rs where_resolves), so a copied
 * login proved a path no person's chat takes. A --preclaim-login run measures the spare.ready copy itself, so a
 * real-model one keeps it. Codex keeps the machine login and the stub's own provider
 * (CODEX_STUB_CONFIG), which a launch credential would replace with api.openai.com.
 */
export function startsOnLaunchCredential(o: { modelStub: boolean; provider?: string; login: string; gatewayAny: boolean; startVia: string; preclaimLogin?: boolean }): boolean {
  return o.provider === "claude" && Boolean(o.login) && !o.gatewayAny && o.startVia === "acp" && (o.modelStub || !o.preclaimLogin);
}

/**
 * How the login reaches the claimed machine. A --preclaim-login run whose spare carried no installed login (the warm
 * named none, its spare.ready never came, or the claim handed out another machine) used to copy the login after bind:
 * 4.3 s inside create -> first text (11-22 06:58Z marks) on a path no person's chat takes. It now starts the agent on the
 * launch credential, as the app does (cmux#40159), whenever that path could carry the login at all.
 */
export function loginPathAfterClaim(o: { receipt: boolean; launchCredential: boolean; launchOnMiss: boolean }): "receipt" | "launch" | "copy" {
  if (o.receipt) return "receipt";
  return o.launchCredential || o.launchOnMiss ? "launch" : "copy";
}

/**
 * The app's Cloud start, with the person's model connection as the agent's launch credential (cmux#40159: the machine
 * holds no login; acpmux agent_credentials.rs): `session/new` on the machine's acpmux socket with
 * `_meta.acpmux.credentials: {env: {NAME: value}}`, as the guest cmux-tui's `agent-session-start` relays it from the
 * owner's app. acpmux takes a credential only from its own unix socket with no caller token, which a program run
 * through the machine's exec is. The value goes on stdin (the heredoc), never on a command line.
 *
 * `prompt`: the chat's first prompt, sent on the same socket right after `session/new` answers, as the app's page
 * sends its first `session/prompt` on the link its start opened (RemoteAcpmuxWire.startChat keeps that client). The
 * program returns once acpmux accepted it (`_acpmux/prompt_accepted`, as `acp send --no-wait` waits) and prints
 * `@@prompted`; the turn runs on in the daemon. Without it the journey's send was a second exec and a fresh
 * `cmux-tui acp send` process (2.4 to 3.2 s on the 11-23 stub legs), a path no person's first send takes.
 */
export function launchCredentialStartProgram(session: string, agent: string, name: string, value: string, prompt?: string, traceId?: string): string {
  const slash = agent.indexOf("/");
  const meta: Record<string, unknown> = { name: session, harness: slash < 0 ? agent : agent.slice(0, slash), credentials: { env: { [name]: value } } };
  if (slash >= 0) meta.model = agent.slice(slash + 1);
  const params = JSON.stringify({ mcpServers: [], _meta: { acpmux: meta } });
  const first = prompt === undefined ? "None" : JSON.stringify(prompt);
  // The send's W3C trace id (cmux#55505 perf_trace.rs reads params._meta.traceId); only hex, so it is safe inline.
  const trace = traceId && /^[0-9a-f]{32}$/.test(traceId) ? JSON.stringify(traceId) : "None";
  return `python3 -I - <<'CMUX_JOURNEY_START'
import json, os, socket, sys, uuid
params = json.loads(${JSON.stringify(params)})
first = ${first}
trace = ${trace}
params['cwd'] = os.environ.get('HOME') or '/home/cmux'
home = params['cwd']
paths = [p for p in (os.environ.get('ACPMUX_SOCKET'), home + '/.cmux/acpmux/acpmux.sock', home + '/.acpmux/acpmux.sock') if p]
def call(f, s, i, method, p):
    s.sendall((json.dumps({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': p}) + '\\n').encode())
    while True:
        line = f.readline()
        if not line:
            raise RuntimeError(method + ': the daemon closed the connection')
        m = json.loads(line)
        if m.get('id') == i:
            if m.get('error'):
                raise RuntimeError(method + ': ' + json.dumps(m['error'])[:400])
            return m.get('result')
errors = []
for path in paths:
    if not os.path.exists(path):
        continue
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(110)
        s.connect(path)
        f = s.makefile('r')
        call(f, s, 1, 'initialize', {'protocolVersion': 1, 'clientCapabilities': {}, 'clientInfo': {'name': 'cloud-journey', 'version': '1'}})
        r = call(f, s, 2, 'session/new', params)
        sid = (r or {}).get('sessionId')
        print('@@session ' + str(sid), flush=True)
    except Exception as e:
        errors.append(path + ': ' + str(e))
        continue
    if first is None:
        sys.exit(0)
    # The session exists now: a failed prompt never starts a second session on another socket.
    try:
        pid = str(uuid.uuid4())
        meta = {'acpmux': {'steer': False, 'promptId': pid, 'resend': False}}
        if trace:
            meta['traceId'] = trace
        s.sendall((json.dumps({'jsonrpc': '2.0', 'id': 3, 'method': 'session/prompt', 'params': {'sessionId': sid, 'prompt': [{'type': 'text', 'text': first}], '_meta': meta}}) + '\\n').encode())
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError('session/prompt: the daemon closed the connection')
            m = json.loads(line)
            if m.get('method') == '_acpmux/prompt_accepted' and (m.get('params') or {}).get('promptId') == pid:
                break
            if m.get('id') == 3:
                if m.get('error'):
                    raise RuntimeError('session/prompt: ' + json.dumps(m['error'])[:400])
                break
        print('@@prompted', flush=True)
        sys.exit(0)
    except Exception as e:
        print('@@noprompt ' + str(e))
        sys.exit(2)
print('@@nostart ' + ('; '.join(errors) or 'no acpmux socket at ' + ', '.join(paths)))
sys.exit(1)
CMUX_JOURNEY_START`;
}

/** The guest's own cmux-tui (cloud_start_chat.rs GUEST_PRELUDE): the build the machine's acpmux runs. */
const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';

/** The exact command CloudMachineRoute uses to warm the reserved first home chat on a keyed spare. */
export const WARM_HOME_COMMAND =
  'c=/home/cmux/.cmux/bin/cmux-tui; [ -x "$c" ] || c=cmux-tui; ' +
  'if [ "$(id -u)" = 0 ] && id cmux >/dev/null 2>&1; then ' +
  'set -- setpriv --reuid=cmux --regid=cmux --init-groups env HOME=/home/cmux USER=cmux LOGNAME=cmux; ' +
  'else set --; fi; ' +
  '"$@" "$c" acp --json warm-home --wait 2>/dev/null; true';

/** The guest-side read of tickets consumed by an app-style home start. */
export const CLAIMED_MARKERS_COMMAND =
  'for f in "$HOME"/chats/.claimed-*; do [ -f "$f" ] && basename "$f"; done | sort';

/** Claimed marker names, excluding unrelated output and duplicate lines. */
export function parseClaimedMarkers(stdout: string): string[] {
  return [...new Set(stdout.split(/\r?\n/).map((line) => line.trim()).filter((line) => /^\.claimed-[^/\s]+$/.test(line)))].sort();
}

export type WarmHomeAnswer = { state: "ready" | "not_ready" | "unsupported"; reason: string };

/** Parse warm-home's optional JSON answer. Older guest images print nothing because the command is absent. */
export function parseWarmHomeAnswer(stdout: string): WarmHomeAnswer {
  let answer: any;
  for (const line of stdout.split(/\r?\n/).map((line) => line.trim()).reverse()) {
    if (!line.startsWith("{")) continue;
    try {
      answer = JSON.parse(line);
      break;
    } catch {
      // The command can include a non-JSON diagnostic before its answer.
    }
  }
  if (!answer || typeof answer !== "object") {
    return { state: "unsupported", reason: stdout.trim() ? "warm-home returned no JSON answer" : "warm-home is unavailable on this guest image" };
  }
  if (answer.accepted === true && answer.state === "ready") return { state: "ready", reason: "reserved home chat is ready" };
  const state = typeof answer.state === "string" ? answer.state : "unknown";
  return { state: "not_ready", reason: `warm-home answered state=${state}` };
}

/**
 * A guest command timed on the guest: its own run, apart from the exec route's trip to the machine and back, which a
 * person's app never takes (it talks to acpmux over the carrier). The time is printed on its own line after the
 * command, so a heredoc's terminator stays alone on its line.
 */
export function guestTimed(command: string): string {
  return `__cmux_t0=$(date +%s%N)\n${command}\necho "@@guest_ms $(( ($(date +%s%N) - __cmux_t0) / 1000000 ))"`;
}

/** The ms guestTimed printed, or null. */
export function guestMs(stdout: string): number | null {
  const m = /@@guest_ms (\d+)/.exec(stdout);
  return m ? Number(m[1]) : null;
}

/** "; on the guest N ms (the rest is the exec route)" for a step's detail, or "" with no time. */
export function guestDetail(ms: number | null): string {
  return ms === null ? "" : `; on the guest ${ms} ms (the rest is the exec route)`;
}

const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/**
 * The guest program that prints the `"model":"..."` of every message in Claude session `id`'s transcript. It
 * searches each Claude directory an agent can run with: CLAUDE_CONFIG_DIR as every running process has it (the
 * launcher's effective one, e.g. ~/.config/cmux/claude-team that agent-auth.sh's team and gateway modes set on a
 * shared machine), then this shell's CLAUDE_CONFIG_DIR, ~/.claude and ~/.config/cmux/claude-team.
 */
export function claudeTranscriptModelsProgram(id: string): string {
  return (
    `id=${shq(id)}; { for e in /proc/[0-9]*/environ; do tr '\\0' '\\n' 2>/dev/null < "$e" | sed -n 's/^CLAUDE_CONFIG_DIR=//p'; done; ` +
    `printf '%s\\n' "\${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude" "$HOME/.config/cmux/claude-team"; } 2>/dev/null | sort -u | ` +
    `while IFS= read -r d; do [ -n "$d" ] || continue; for f in "$d"/projects/*/"$id".jsonl; do ` +
    `[ -f "$f" ] && grep -ho '"model":"[^"]*"' "$f"; done; done | sort -u`
  );
}

/** The models a {@link claudeTranscriptModelsProgram} printout names, `<synthetic>` (Claude Code's own notices) left out. */
export function transcriptModels(stdout: string): string[] {
  return [...new Set([...stdout.matchAll(/"model":"([^"]+)"/g)].map((m) => m[1]!).filter((m) => m !== "<synthetic>"))];
}

/**
 * The models a claude session ran, read from what ran: `acp session info` only names its agentSessionId, and every
 * assistant message's `model` in that Claude transcript is the answer. Passes only when each one is `asked` (or a
 * dated `asked-...` id); the session record naming `asked` counts for nothing (a pooled agent on another model ran
 * under a record that named the asked one, cmux#40383).
 */
export async function sessionModelVerdict(exec: Exec, session: string, asked: string): Promise<string> {
  const r = await exec(`${GUEST}"$c" acp --json session info ${shq(session)} 2>&1`, 45_000);
  const asid = /"agentSessionId"\s*:\s*"([^"]+)"/.exec(r.stdout)?.[1];
  if (!asid) throw new Error(`asked ${asked}; acp session info names no agentSessionId: ${r.stdout.slice(-200)}`);
  const t = await exec(`${GUEST}${claudeTranscriptModelsProgram(asid)}`, 45_000);
  const ran = transcriptModels(t.stdout);
  if (!ran.length) throw new Error(`asked ${asked}; the session's Claude transcript (${asid}) names no model`);
  if (ran.some((m) => m !== asked && !m.startsWith(`${asked}-`))) throw new Error(`asked ${asked}; the agent ran ${ran.join(", ")}`);
  return `asked ${asked}; the agent ran ${ran.join(", ")} (its Claude transcript)`;
}

/** --machine: stop an earlier run's model stub and drop its endpoint from Claude Code's settings (and Codex's stub provider). */
export const REUSE_RESET =
  // Only the stub an earlier run recorded (its launch writes journey-model-stub.pid), and only while that pid still runs it.
  `p=$(cat /home/cmux/.cmux/journey-model-stub.pid 2>/dev/null); ` +
  `[ -n "$p" ] && grep -qa journey-model-stub.py "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null; ` +
  `rm -f /home/cmux/.cmux/journey-model-stub.*; ` +
  `python3 - <<'PY'\nimport json, pathlib\np = pathlib.Path('/home/cmux/.claude/settings.json')\nif p.exists() and not p.is_symlink():\n    c = json.loads(p.read_text())\n    if c.get('env', {}).pop('ANTHROPIC_BASE_URL', None) is not None:\n        p.write_text(json.dumps(c)); print('dropped the stub endpoint')\nPY`;

/** How long --keyed-start waits after the start before it reads the daemon again (over acpmux.service's RestartSec=3). */
export const KEYED_SETTLE_MS = 8_000;

/**
 * The app's keyed acpmux start (cmux-platform AcpmuxRoute.ts): a fresh one-run key K, 64 lowercase hex and a newline,
 * as the octet-stream body. K is a throwaway made here and pushed to `secrets` before anything can print.
 */
async function keyedAcpmuxStart(api: Api, machine: string, secrets: string[]): Promise<{ ok: true; personInstance: string } | { ok: false; detail: string }> {
  const key = randomBytes(32).toString("hex");
  secrets.push(key);
  const res = await fetch(`${api.origin}/v1/cloud/machines/${machine}/acpmux/keyed-start`, {
    method: "POST",
    headers: { authorization: `Bearer ${api.bearer}`, "content-type": "application/octet-stream", ...(api.team ? { "x-cmux-team": api.team } : {}) },
    body: `${key}\n`,
    signal: AbortSignal.timeout(120_000),
  });
  const body: any = await res.json().catch(() => ({}));
  const instance = body?.value?.personInstance ?? body?.personInstance;
  if (res.status !== 200 || typeof instance !== "string") return { ok: false, detail: `HTTP ${res.status} ${short(body?.error ?? body)}` };
  return { ok: true, personInstance: instance };
}

/** Why the daemon `acp --json daemon status` describes is not the keyed one the start made, or null. */
export function keyedHoldProblem(personInstance: string, status: any): string | null {
  if (!status || status.running === false || status.pid === undefined) return `no daemon serves after the keyed start: ${short(status)}`;
  if (status.personKey !== true) return `an unkeyed daemon took the socket after the keyed start (acpmux.service restarted and took over): ${short(status)}`;
  if (status.personInstance !== undefined && status.personInstance !== personInstance) return `another keyed daemon (${String(status.personInstance)}) serves, not the one this start made (${personInstance})`;
  return null;
}

/** The ids of `cloud list-machines --json` rows that are not deleted. */
export function machineIds(rows: any[]): string[] {
  return rows.filter((m) => m && m.status !== "deleted").map((m) => String(m.id ?? m.machine_id ?? "")).filter(Boolean);
}

/**
 * How old a journey's own machine must be before a later run may sweep it: well past the longest job that runs a
 * journey (up to 90 min; cloud-journey.test.ts checks every timeout-minutes in a workflow that runs it to be at most
 * half of this), so a journey that is still running never loses its machine. A long run (--resume-matrix,
 * --wake-echo) names its machines `cloud journey auto jr-<tag> long…` and gets LONG_JOURNEY_MS instead.
 */
export const STALE_JOURNEY_MS = 3 * 3_600_000;
/**
 * The bound for a long run's machines (the resume matrix's 3600 s cell runs up to 330 min, wake-echo up to 150; the
 * test checks those workflows against this). It applied to every journey machine from #54761, so a short run's leaks
 * sat 11 h: the staging test team's 300-machine cap filled with 5 h old ones (cloud.quota.vm_limit, 2026-11-25,
 * backend run 45572634999) while every sweep deleted 0. Installs keep it too (a long run still uses its install).
 */
export const LONG_JOURNEY_MS = 11 * 3_600_000;
/** The machine name of a run that deletes its machine at the end: ` long` marks a run that may outlast STALE_JOURNEY_MS. */
export function autoMachineName(tag: string, long: boolean): string {
  return `cloud journey auto ${tag}${long ? " long" : ""}`;
}
/** And idle this long: a machine with activity since then is in use, whatever its age (a hand run has no timeout). */
export const IDLE_JOURNEY_MS = 60 * 60_000;
export interface StaleMachine { id: string; name: string; status: string; created: string }

/**
 * The machines earlier journey runs meant to delete and left behind (killed or timed out before their cleanup):
 * named `cloud journey auto jr-<tag>`, or that name with any suffix (` gateway`, ` cold`, ` move B`: every machine a
 * run makes under its auto name; the old suffix list missed the ` move B` machines of 2026-11-23's runs, which helped fill the
 * staging test team to its 300-machine cap, cloud.quota.vm_limit on 2026-11-25), a name only a run that deletes its
 * machine gives, whose tag (`Date.now().toString(36)`, the run's start) is more than `maxAgeMs` old (`longMs` for a
 * long run's `jr-<tag> long…`), with no activity
 * in the last IDLE_JOURNEY_MS (`last_active_at`, when the row has it), and not deleted.
 * Ownership is the name, never age or state: a --keep run's `cloud journey jr-<tag>`, any other name, and a tag that
 * does not read as a time are never picked.
 */
export function staleJourneyMachines(rows: any[], nowMs: number, maxAgeMs = STALE_JOURNEY_MS, longMs = LONG_JOURNEY_MS): StaleMachine[] {
  const out: StaleMachine[] = [];
  for (const r of rows) {
    if (!r || r.status === "deleted" || r.status === "deleting") continue;
    const name = typeof r.name === "string" ? r.name : "";
    // A start bench's machines (runStartBench) are the sweep's too: only a run that deletes them names them so.
    // So are the Auto mode journey's (auto-journey.ts `auto journey aj-<tag>`): it always deletes its machine.
    const m = /^cloud journey auto jr-([0-9a-z]+)( long)?(?: \S.*)?$/.exec(name) ?? /^cloud start bench jr-([0-9a-z]+) (?:source|(?:spare|cold|snapshot) \d+)$/.exec(name) ?? /^auto journey aj-([0-9a-z]+)$/.exec(name);
    if (!m) continue;
    const started = parseInt(m[1], 36);
    // A real tag is a millisecond time after 2020 and not in the future.
    if (!Number.isFinite(started) || started < Date.UTC(2020, 0, 1) || started > nowMs) continue;
    if (nowMs - started <= (m[2] ? longMs : maxAgeMs)) continue;
    if (typeof r.last_active_at === "number" && nowMs - r.last_active_at <= IDLE_JOURNEY_MS) continue;
    const id = String(r.id ?? r.machine_id ?? "");
    const created = typeof r.created_at === "number" ? new Date(r.created_at).toISOString() : new Date(started).toISOString();
    if (id) out.push({ id, name, status: String(r.status ?? "?"), created });
  }
  return out;
}

/**
 * The installs earlier journey runs registered and never revoked: kind cli, named `cloud journey jr-<tag>` (the
 * name only the journey's install token step gives), not revoked, whose tag is more than `maxAgeMs` old. A run
 * revokes its own at cleanup; one killed first leaves it live, and a user's live installs are never pruned (only
 * revoked ones past MAX_REVOKED_INSTALLS, backend/apps/api/src/domains/user.ts). Before any run revoked, they filled
 * the staging account's state: install.register answered owner.state_full, 1500285 of 1500000 bytes (2026-11-16).
 * Ownership is the name, as for machines: any other name, and a tag that does not read as a time, are never picked.
 */
export function staleJourneyInstalls(installs: any[], nowMs: number, maxAgeMs = LONG_JOURNEY_MS): string[] {
  const out: string[] = [];
  for (const i of installs) {
    if (!i || i.revoked_at !== null || i.kind !== "cli") continue;
    // The Auto mode journey's install (`auto journey aj-<tag>`, revoked at its cleanup) is the sweep's too.
    const m = /^(?:cloud journey (jr-([0-9a-z]+))|auto journey (aj-([0-9a-z]+)))$/.exec(typeof i.name === "string" ? i.name : "");
    if (!m) continue;
    const started = parseInt(m[2] ?? m[4], 36);
    if (!Number.isFinite(started) || started < Date.UTC(2020, 0, 1) || started > nowMs) continue;
    if (nowMs - started <= maxAgeMs) continue;
    if (typeof i.id === "string" && i.id) out.push(i.id);
  }
  return out;
}

/** The most time one run spends revoking leaked installs; the next run takes the rest. */
export const INSTALL_SWEEP_BUDGET_MS = 60_000;

/** Every page of cloud.machine.list (`next_cursor`), at most `maxPages` pages. */
export async function listAllMachines(read: (params: Record<string, unknown>) => Promise<any>, maxPages = 20): Promise<any[]> {
  const rows: any[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < maxPages; page++) {
    const v = await read(cursor === null ? { limit: 100 } : { limit: 100, cursor });
    rows.push(...(v?.machines ?? v?.items ?? (Array.isArray(v) ? v : [])));
    cursor = typeof v?.next_cursor === "string" && v.next_cursor ? v.next_cursor : null;
    if (cursor === null) return rows;
  }
  throw new Error(`more than ${maxPages} pages of machines`);
}

/**
 * The "listed" step's verdict: `id`'s row in every page of cloud.machine.list (`next_cursor`). A list that ends
 * without the machine and without a cursor (a page cap: the shared agent account holds more machines than one page,
 * run 45174448964 read 49 of 52) is confirmed by cloud.machine.get, and the detail names the cap; a machine neither
 * read finds fails.
 */
export async function listedMachine(
  id: string,
  list: (params: Record<string, unknown>) => Promise<any>,
  get: (id: string) => Promise<any>,
  maxPages = 20,
): Promise<{ row: any; detail: string }> {
  const rows = await listAllMachines(list, maxPages);
  const row = rows.find((r) => r?.id === id);
  if (row) return { row, detail: `${rows.length} machines` };
  const got = await get(id).catch((e: Error) => { throw new Error(`${id} missing from ${rows.length} machines, and cloud.machine.get: ${e.message}`); });
  if (!got || (got.id !== undefined && got.id !== id) || got.status === "deleted") {
    throw new Error(`${id} missing from ${rows.length} machines, and cloud.machine.get reads ${got?.status ?? "nothing"}`);
  }
  return { row: got, detail: `${rows.length} machines listed, no next_cursor (a page cap); cloud.machine.get reads it ${got.status ?? "?"}` };
}

/** The ids in `after` that `before` lacks. */
export function newMachineIds(before: string[], after: string[]): string[] {
  const seen = new Set(before);
  return [...new Set(after.filter((id) => !seen.has(id)))];
}

/**
 * --app-cli PATH: the commands a person runs, through a NEXT build's own CLI (cmux#35086). The `cloud`
 * verbs go to that app's control socket (--socket PATH or CMUX_SOCKET_PATH), so the app must be running
 * and signed in; its build decides the backend, which each step names from the answer when it says.
 */
async function appCliJourney(cli: string, socket: string | undefined, J: Journey, agent: string, prompt: string): Promise<void> {
  const env = { ...process.env, ...(socket ? { CMUX_SOCKET_PATH: socket } : {}) };
  const run = (words: string[], timeoutMs = 120_000) => {
    const done = spawnSync(cli, words, { env, encoding: "utf8", timeout: timeoutMs });
    if (done.error) throw new Error(`${cli} ${words.slice(0, 2).join(" ")}: ${done.error.message}`);
    let json: any = {};
    try {
      json = JSON.parse(done.stdout || "{}");
      json = json?.result ?? json;
    } catch {
      json = {};
    }
    return { code: done.status ?? 1, stdout: done.stdout ?? "", stderr: done.stderr ?? "", json };
  };
  const must = (name: string, r: ReturnType<typeof run>) => {
    if (r.code !== 0) throw new Error(`\`cmux ${name}\` exit ${r.code}: ${(r.stderr || r.stdout).trim().slice(-400)}`);
    return r;
  };
  const where = (j: any) => j?.api_base_url ?? j?.backend ?? j?.api ?? j?.origin ?? j?.host ?? "app";
  // The backend refuses a create with a name ("can't create a machine with a size, idle pause, name or
  // bootstrap yet"), so the create takes no flags, and a `pending` answer (no id) names nothing this run
  // could match. Only the id the create answered is ever deleted; after a `pending` answer the machines
  // that appeared since the create are named for a person to check, never deleted (another create in the
  // same account may be one of them).
  // null when the list could not be read (exit code, or the app's list not loaded yet): never diffed as empty.
  const listIds = (): string[] | null => {
    const r = run(["cloud", "list-machines", "--json"], 60_000);
    if (r.code !== 0 || r.json?.loaded === false) return null;
    return machineIds(r.json?.machines ?? r.json?.items ?? (Array.isArray(r.json) ? r.json : []));
  };
  let before: string[] | null = null;
  let createRan = false;
  let machine: string | null = null;
  try {
    await J.step("app cli: signed in (cloud list-machines)", async () => {
      const r = must("cloud list-machines", run(["cloud", "list-machines", "--json"], 60_000));
      if (r.json?.account?.signed_in !== true) throw new Error("the app is not signed in (account.signed_in is not true)");
      return { value: null, detail: `${(r.json.machines ?? []).length} machines; ${where(r.json.account)}` };
    });
    await J.step("app cli: vm token create", async () => {
      const r = must("vm token create", run(["vm", "token", "create", "--ttl", "30m", "--json"], 60_000));
      return { value: null, detail: `issuer ${where(r.json)}` };
    });
    machine = await J.step("app cli: cloud new-machine", async () => {
      before = listIds();
      createRan = true;
      const r = must("cloud new-machine", run(["cloud", "new-machine", "--json"], 600_000));
      const id = r.json?.machine_id ?? r.json?.machine?.id ?? r.json?.id;
      if (!id) throw new Error(`no machine id in ${short(r.json)}${r.json?.status === "creating" ? " (pending: the create goes on; this run deletes nothing it did not get an id for)" : ""}`);
      return { value: String(id), detail: `${id} via ${where(r.json)}` };
    });
    const target = `machine:${machine}`;
    await J.step("app cli: cloud machine-status", async () => {
      const r = must("cloud machine-status", run(["cloud", "machine-status", "--target", target, "--json"], 60_000));
      const id = r.json?.machine_id ?? r.json?.machine?.id ?? r.json?.id;
      if (id && id !== machine) throw new Error(`answered for ${id}, not ${machine}`);
      return { value: null, detail: `status ${r.json?.status ?? r.json?.machine?.status ?? "?"} via ${where(r.json)}` };
    });
    await J.step("app cli: cloud exec", async () => {
      const r = must("cloud exec", run(["cloud", "exec", "--target", target, "--command", "echo ok", "--json"], 120_000));
      if (!/\bok\b/.test(r.stdout)) throw new Error(`no ok in ${r.stdout.slice(-200)}`);
      return { value: null, detail: "ok" };
    });
    await J.step("app cli: cloud start-session", async () => {
      const r = must("cloud start-session", run(["cloud", "start-session", "--target", target, "--agent", agent, "--json"], 600_000));
      return { value: null, detail: `session ${r.json?.session_id ?? "?"}` };
    });
    await J.step("app cli: cloud start-chat --wait", async () => {
      const r = must("cloud start-chat", run(["cloud", "start-chat", "--target", target, "--prompt", prompt, "--agent", agent, "--wait", "--timeout", "600", "--json"], 700_000));
      const reply = String(r.json?.reply ?? "");
      if (!reply.trim()) throw new Error(`no reply in ${short(r.json)}`);
      // The CLI's own start marks (cmux-tui start_stages.rs), named as this journey's create_marks_ms.
      const stages = r.json?.stages && typeof r.json.stages === "object" ? ` stages ${JSON.stringify(r.json.stages)}` : "";
      return { value: null, detail: `${reply.slice(0, 280)}${stages}` };
    });
  } finally {
    if (!machine && createRan) {
      const prior = before as string[] | null; // set inside the create step's closure
      await J.step("app cli: no machine id to delete", async () => {
        const after = listIds();
        if (!prior || !after) throw new Error(`the machine list could not be read ${prior ? "after" : "before"} the create; check the account's machines by hand`);
        const fresh = newMachineIds(prior, after);
        throw new Error(fresh.length
          ? `machines new since the create, not deleted (another create may own one): ${fresh.join(", ")}`
          : "no machine is new since the create");
      }).catch(() => undefined);
    }
    if (machine) {
      const id = machine;
      await J.step("app cli: cloud kill-machine", async () => {
        must("cloud kill-machine", run(["cloud", "kill-machine", "--target", `machine:${id}`, "--confirm", "--json"], 120_000));
        return { value: null, detail: id };
      }).catch(() => undefined);
    }
  }
}

/**
 * --machines: the agent test account's machines, one JSON line each, with whether a leaked journey machine may be
 * deleted by the operator's rule (cmux-vm.yml action journey-machines-staging). A journey whose cleanup delete got
 * mutation.indeterminate leaves its `cloud journey jr-*` machine behind, and five of them fill the account's quota.
 * The rule: delete only `cloud journey jr-*` machines (the run's own, or its `gateway`) that are paused or failed, or
 * older than 24 h and not in use; never `cloud journey kept jr-*` (a --keep run's) and never anything else. When the
 * row leaves any doubt, the answer is no, with the reason.
 */
export const JOURNEY_MACHINE_NAME = /^cloud journey jr-[a-z0-9]+( gateway)?$/;
/** A strict machine id (cloud-machine-ops.ts MachineId). */
export const MACHINE_ID = /^vm_[a-z0-9]{20}$/;
const HOUR_MS = 3_600_000;
/** A journey runs well under this (its jobs time out at 45 min), so a younger paused machine may be one in flight. */
const JOURNEY_IN_FLIGHT_MS = HOUR_MS;
/** Activity this recent means the machine is in use. */
const IN_USE_MS = 45 * 60_000;
const OLD_MS = 24 * HOUR_MS;

export function journeyMachineEligible(m: any, now = Date.now()): { eligible: boolean; reason: string } {
  const no = (reason: string) => ({ eligible: false, reason });
  const name = typeof m?.name === "string" ? m.name : "";
  if (!MACHINE_ID.test(String(m?.id ?? ""))) return no("not a machine id");
  if (!JOURNEY_MACHINE_NAME.test(name)) return no(name.startsWith("cloud journey kept ") ? "a kept journey machine" : "not a leaked journey machine's name");
  const created = m?.created_at;
  if (!Number.isSafeInteger(created) || created <= 0 || created > now) return no("no creation time");
  const age = now - created;
  const status = String(m?.status ?? "");
  if (status === "paused" || status === "failed") {
    return age > JOURNEY_IN_FLIGHT_MS ? { eligible: true, reason: status } : no(`${status} but made under 1 h ago: a journey may still be running`);
  }
  if (status !== "running" && status !== "provisioning") return no(`status ${status || "missing"}`);
  if (age <= OLD_MS) return no(`${status} and made under 24 h ago`);
  const last = m?.last_active_at;
  if (last !== null && last !== undefined) {
    if (!Number.isSafeInteger(last) || last <= 0) return no("an unreadable last activity");
    if (now - last <= IN_USE_MS) return no("active in the last 45 min");
  }
  return { eligible: true, reason: `${status}, older than 24 h, ${last ? "idle over 45 min" : "no activity recorded"}` };
}

/**
 * At most this many ids in one run. Each delete is bounded at 5 min (its mutation.indeterminate retries, 180 s, and
 * its read back, 120 s), so 5 fit the workflow job's 35 min with sign-in, the list and the log reads.
 */
export const MAX_DELETE_IDS = 5;

/** One id to delete and the GitHub Actions job whose journey made it and failed to delete it. */
export type DeleteEntry = { id: string; job: string };

/** --delete-ids: `vm_<20>@<job id>` entries, comma or space separated, checked before anything signs in. */
export function parseDeleteEntries(text: string): DeleteEntry[] {
  const raw = [...new Set(text.split(/[\s,]+/).filter(Boolean))];
  if (!raw.length) throw new Error("--delete-ids: no machine ids");
  const bad = raw.filter((e) => !/^vm_[a-z0-9]{20}@[1-9][0-9]{0,19}$/.test(e));
  if (bad.length) throw new Error(`--delete-ids: not vm_<20 lowercase letters or digits>@<GitHub Actions job id>: ${bad.map((b) => JSON.stringify(b.slice(0, 60))).join(", ")}`);
  const entries = raw.map((e) => { const [id, job] = e.split("@"); return { id: id!, job: job! }; });
  const ids = entries.map((e) => e.id);
  const twice = ids.filter((id, i) => ids.indexOf(id) !== i);
  if (twice.length) throw new Error(`--delete-ids: an id given twice: ${twice.join(", ")}`);
  if (entries.length > MAX_DELETE_IDS) throw new Error(`--delete-ids: ${entries.length} ids; at most ${MAX_DELETE_IDS} in one run`);
  return entries;
}

/**
 * The one job whose journey log is trusted as a leak's proof: cmux-vm.yml's deploy-staging (where the journey
 * leaked, job 128746706182), which runs the staging journey through cloud-journey-ci.sh. That script passes only
 * --backend, --out, --cmux or --skip sync, --model and --team, never --keep or --machine (checked 2026-11-09): only
 * hand runs pass --keep, so a machine this job made is never a kept one. A --keep run also never logs a cleanup
 * delete (cleanup returns before it), so the FAIL line is a second proof.
 *
 * The log is trusted only when the job ran this repo's own code on a protected branch: a run of a pull request
 * (a fork's above all), a merge queue or a workflow_run runs code a contributor wrote, which can print any line.
 * So the run's event must be push or workflow_dispatch (deploy-staging's only triggers), its head repository this
 * repo and its head branch feat-cmux-next or main. backend.yml, cloud-journey-pr.yml and cloudflare-relay.yml run
 * the journey on pull requests too, so none of their jobs counts. The jobs API does not say which environment a job
 * ran in; the job name and workflow stand for it (deploy-staging always runs in cmux-vm-staging).
 */
export const PROOF_WORKFLOW = ".github/workflows/cmux-vm.yml";
export const PROOF_JOB = "deploy-staging";
export const PROOF_EVENTS = new Set(["push", "workflow_dispatch"]);
export const PROOF_BRANCHES = new Set(["feat-cmux-next", "main"]);
export const JOURNEY_REPO = "manaflow-ai/cmux";

/**
 * Whether a job's log proves this machine leaked: one journey in it (from its `health` step to the next) logged
 * `PASS create machine <ms> ms :: <id> ...` and then `FAIL delete (cleanup) ...`. Null when proven, else why not.
 * A job runs several journeys (baseline and after a deploy, the test team and the product team), so the create
 * and the failed cleanup must be in the same one.
 */
export function leakProof(log: string, id: string): string | null {
  const lines = log.split("\n").map((l) => l.replace(/\r$/, "").replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z /, ""));
  let inJourney = false;
  let created = false;
  let seenCreate = false;
  for (const line of lines) {
    if (/^(PASS|FAIL) health \d+ ms ::/.test(line)) { inJourney = true; created = false; continue; }
    if (!inJourney) continue;
    const c = /^PASS create machine \d+ ms :: (vm_[a-z0-9]{20})( |$)/.exec(line);
    if (c) { created = c[1] === id; seenCreate ||= created; continue; }
    if (created && /^FAIL delete \(cleanup\) \d+ ms ::/.test(line)) return null;
  }
  return seenCreate ? `the job's journey made ${id} but logged no failed cleanup delete for it` : `the job's log has no journey that made ${id}`;
}

type GhGet = (url: string, headers: Record<string, string>) => Promise<{ status: number; location: string | null; text: string }>;

const ghGet: GhGet = async (url, headers) => {
  const res = await fetch(url, { headers, redirect: "manual", signal: AbortSignal.timeout(60_000) });
  const text = await res.text();
  return { status: res.status, location: res.headers.get("location"), text: text.slice(0, 64 * 1024 * 1024) };
};

/**
 * The GitHub side of the proof: the job is PROOF_JOB of PROOF_WORKFLOW in a trusted run of JOURNEY_REPO (PROOF_EVENTS,
 * its own head repository, PROOF_BRANCHES), and its log has leakProof's two lines. Null when proven, else why not. The log's download link is fetched without the token.
 */
export async function provenLeak(entry: DeleteEntry, token: string, get: GhGet = ghGet): Promise<string | null> {
  const api = `https://api.github.com/repos/${JOURNEY_REPO}/actions`;
  const auth = { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28" };
  const json = async (url: string) => {
    const r = await get(url, auth);
    if (r.status !== 200) throw new Error(`GET ${url.slice(api.length)}: HTTP ${r.status}`);
    return JSON.parse(r.text);
  };
  try {
    const job = await json(`${api}/jobs/${entry.job}`);
    if (String(job?.id) !== entry.job || !Number.isSafeInteger(job?.run_id)) return `job ${entry.job}: not a job of ${JOURNEY_REPO}`;
    if (job.name !== PROOF_JOB) return `job ${entry.job}: ${short(job.name)} is not ${PROOF_JOB}`;
    const run = await json(`${api}/runs/${job.run_id}`);
    if (run?.id !== job.run_id) return `job ${entry.job}: its run did not read back`;
    if (run?.repository?.full_name !== JOURNEY_REPO) return `job ${entry.job}: its run is not in ${JOURNEY_REPO}`;
    if (run?.head_repository?.full_name !== JOURNEY_REPO) return `job ${entry.job}: its run ran code from ${short(run?.head_repository?.full_name)}, not ${JOURNEY_REPO}`;
    if (!PROOF_EVENTS.has(String(run?.event))) return `job ${entry.job}: its run's event ${short(run?.event)} runs code a contributor may have written`;
    if (!PROOF_BRANCHES.has(String(run?.head_branch)) || job.head_branch !== run.head_branch) return `job ${entry.job}: branch ${short(run?.head_branch)} is not feat-cmux-next or main`;
    const workflow = String(run?.path ?? "").replace(/@.*$/, "");
    if (workflow !== PROOF_WORKFLOW) return `job ${entry.job}: workflow ${workflow || "?"} is not ${PROOF_WORKFLOW}`;
    const link = await get(`${api}/jobs/${entry.job}/logs`, auth);
    let log = link.text;
    if (link.status === 302 && link.location) {
      const blob = await get(link.location, {});
      if (blob.status !== 200) return `job ${entry.job}: its log download answered HTTP ${blob.status}`;
      log = blob.text;
    } else if (link.status !== 200) return `job ${entry.job}: its log answered HTTP ${link.status}`;
    const why = leakProof(log, entry.id);
    return why ? `job ${entry.job}: ${why}` : null;
  } catch (e) {
    return `job ${entry.job}: ${(e as Error).message}`;
  }
}

const iso = (ms: unknown) => (Number.isSafeInteger(ms) && (ms as number) > 0 ? new Date(ms as number).toISOString() : null);

/** One --machines line: what the list gives, and the rule's answer. */
export function machineLine(m: any, scope: string, now = Date.now()): Record<string, unknown> {
  const { eligible, reason } = journeyMachineEligible(m, now);
  const created = Number.isSafeInteger(m?.created_at) ? m.created_at : null;
  // A delete needs the job that made it (DeleteEntry); this tool cannot search logs, so it says where to look.
  const findJob = eligible
    ? `the cmux-vm.yml deploy-staging job (a push or dispatch on feat-cmux-next or main) running at ${iso(created)} whose log has "PASS create machine ... :: ${m.id}" and "FAIL delete (cleanup)"; pass ${m.id}@<job id>. No such job (another workflow's journey): this tool cannot delete it`
    : null;
  return {
    scope,
    id: m?.id ?? null,
    name: m?.name ?? null,
    status: m?.status ?? null,
    created: iso(m?.created_at),
    age_h: created ? Math.round(((now - created) / HOUR_MS) * 10) / 10 : null,
    last_active: iso(m?.last_active_at),
    pause_reason: m?.pause_reason ?? null,
    error: m?.error?.code ?? null,
    eligible,
    reason,
    ...(findJob ? { find_job: findJob } : {}),
  };
}

/**
 * A team (null: the account's own) and its API, as the journey calls it. `get` and `remove` give up after
 * `timeoutMs` (the request's own AbortSignal timeout), so a delete's deadline holds across its requests.
 */
export type MachineScope = { scope: string; list(): Promise<any[]>; get(id: string, timeoutMs: number): Promise<any | null>; remove(id: string, key: string, timeoutMs: number): Promise<Answer> };
export type DeleteDeps = { now(): number; sleep(ms: number): Promise<void>; log(line: string): void; retryMs?: number; readBackMs?: number };

/**
 * Delete each id only when a scope's live list has it and the rule allows it. Every id is checked first and one
 * refusal deletes nothing; right before each delete the machine is read again and checked again. Each delete is
 * logged before it is sent, retried under the same idempotency key while the API answers mutation.indeterminate
 * (bounded), then read back until it is gone or deleting (bounded). Returns the ids it could not delete, with why.
 *
 * Each id's whole delete (the read before it, the deletes and their pauses, the read back and its pauses) ends
 * within retryMs + readBackMs (5 min): every request and every pause is cut to the time left, and the deadline is
 * checked before each one, so a slow answer cannot carry it past the bound (the workflow's timeout counts on it).
 */
export async function deleteJourneyMachines(ids: string[], scopes: MachineScope[], runTag: string, deps: DeleteDeps): Promise<{ deleted: string[]; failed: Array<{ id: string; reason: string }> }> {
  const retryMs = deps.retryMs ?? 180_000;
  const readBackMs = deps.readBackMs ?? 120_000;
  const where = new Map<string, MachineScope>();
  const refused: Array<{ id: string; reason: string }> = [];
  const rows = new Map<string, any>();
  for (const s of scopes) for (const m of await s.list()) if (m?.id && !where.has(m.id)) { where.set(m.id, s); rows.set(m.id, m); }
  for (const id of ids) {
    const m = rows.get(id);
    if (!m) { refused.push({ id, reason: "not in the account's machine list" }); continue; }
    const e = journeyMachineEligible(m, deps.now());
    if (!e.eligible) refused.push({ id, reason: `not eligible: ${e.reason} (${m.name ?? "no name"}, ${m.status})` });
  }
  for (const r of refused) deps.log(JSON.stringify({ refused: r.id, reason: r.reason }));
  if (refused.length) return { deleted: [], failed: refused };
  const deleted: string[] = [];
  const failed: Array<{ id: string; reason: string }> = [];
  for (const id of ids) {
    const s = where.get(id)!;
    const fail = (reason: string) => { failed.push({ id, reason }); deps.log(JSON.stringify({ failed: id, reason })); };
    const t0 = deps.now();
    const retryEnd = t0 + retryMs;
    const deadline = retryEnd + readBackMs;
    // Whole milliseconds left before `until`: a request or a pause starts only when at least one is.
    const left = (until: number) => Math.floor(until - deps.now());
    // A request's timeout: its usual one, never past `until`; 0 when no whole millisecond is left (skip it).
    const cut = (until: number, usual: number) => Math.max(0, Math.min(usual, left(until)));
    let m: any;
    const first = cut(retryEnd, 30_000);
    if (first < 1) { fail("read before delete: no time left"); continue; }
    try { m = await s.get(id, first); } catch (e) { fail(`read before delete: ${(e as Error).message}`); continue; }
    const e = m ? journeyMachineEligible(m, deps.now()) : { eligible: false, reason: "gone from the account" };
    if (!m || !e.eligible) { fail(`not eligible at delete time: ${e.reason}`); continue; }
    deps.log(JSON.stringify({ before_delete: id, scope: s.scope, name: m.name, status: m.status, created: iso(m.created_at), last_active: iso(m.last_active_at) }));
    const key = `${runTag}-delete-${id}`;
    const cutOff = (message: string): Answer => ({ status: 0, body: { ok: false, error: { code: "transport", message, retryable: true } } });
    let answer: Answer = cutOff("no delete sent: the read before it used the time");
    for (let attempt = 1; ; attempt++) {
      const budget = cut(retryEnd, 60_000);
      if (budget < 1) break;
      try { answer = await s.remove(id, key, budget); } catch (e) { answer = cutOff((e as Error).message); }
      const again = opRetryable(answer.body) || answer.status === 0;
      const pause = Math.min(5_000 * attempt, 30_000, left(retryEnd));
      if (!again || pause <= 0) break;
      deps.log(JSON.stringify({ retry_delete: id, attempt, error: answer.body?.error?.code ?? null }));
      await deps.sleep(pause);
    }
    const accepted = answer.status === 200 && answer.body?.ok === true;
    const unsure = !accepted && (opRetryable(answer.body) || answer.status === 0);
    // A refusal is final. An answer still cut off after the retries may have deleted it: read back before saying no.
    if (!accepted && !unsure) {
      fail(`delete: HTTP ${answer.status} ${short(answer.body?.error ?? answer.body)}`);
      continue;
    }
    let gone = "";
    for (;;) {
      const budget = cut(deadline, 30_000);
      if (budget < 1) break;
      try {
        const back = await s.get(id, budget);
        if (!back || back.status === "deleting" || back.status === "deleted") { gone = back ? back.status : "gone"; break; }
      } catch { /* read again */ }
      const pause = Math.min(3_000, left(deadline));
      if (pause <= 0) break;
      await deps.sleep(pause);
    }
    if (!gone) {
      fail(`${accepted ? "deleted" : `delete: HTTP ${answer.status} ${short(answer.body?.error ?? answer.body)} after the retries`}, but read back still not gone or deleting by its ${(retryMs + readBackMs) / 1000} s deadline`);
      continue;
    }
    deleted.push(id);
    deps.log(JSON.stringify({ deleted: id, read_back: gone, ...(accepted ? {} : { after: answer.body?.error?.code ?? "transport" }) }));
  }
  return { deleted, failed };
}

/**
 * --fresh-account: a new person's first sign-up, made for this run on the dev Stack project (staging, dev, preview,
 * local), so the journey walks what a teammate who has never used cmux gets, with no stored test account. Stack takes
 * only a whitelisted verification callback; the local handler's is one, and nothing reads the mail. Production's Stack
 * project is refused: a fresh production account is a real person's sign-up, not a test's.
 */
export function freshAccountIdentity(now = Date.now(), random = Math.random): { email: string; password: string } {
  const nonce = `${now}-${Math.floor(random() * 1e9).toString(36)}`;
  return { email: `cmux-journey+fresh-${nonce}@example.com`, password: `Jf-${nonce}-${Math.floor(random() * 1e12).toString(36)}!` };
}

export async function freshAccountSignUp(stackName: StackName, identity = freshAccountIdentity()): Promise<{ email: string; password: string; access: string; refresh: string }> {
  if (stackName !== "dev") throw new Error("--fresh-account signs up on the dev Stack project only (staging, dev, preview, local), never production's");
  const stack = STACK[stackName];
  const r = await http("POST", `${STACK_API}/api/v1/auth/password/sign-up`, { ...identity, verification_callback_url: "http://localhost:3000/handler/email-verification" }, {
    "x-stack-access-type": "client",
    "x-stack-project-id": stack.project,
    "x-stack-publishable-client-key": stack.clientKey,
  });
  if (r.status !== 200 || typeof r.body.access_token !== "string") throw new Error(`Stack sign-up HTTP ${r.status} ${String(r.body.code ?? short(r.body))}`);
  return { ...identity, access: r.body.access_token, refresh: String(r.body.refresh_token ?? "") };
}

/** The agent test account's Stack access token lasts about an hour (the first resume matrix run read 401 from
 * 56 to 70 min after its sign-in); the resume matrix signs in again past this age, before a sample starts. */
export const RESIGN_AFTER_MS = 30 * 60_000;

/** The Stack password sign-in the journey uses: the agent test account's access token. */
export async function passwordSignIn(stack: (typeof STACK)[StackName], email: string, password: string): Promise<{ access: string; refresh: string }> {
  const r = await http("POST", `${STACK_API}/api/v1/auth/password/sign-in`, { email, password }, {
    "x-stack-access-type": "client",
    "x-stack-project-id": stack.project,
    ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
  });
  if (r.status !== 200 || typeof r.body.access_token !== "string") {
    const code = String(r.body.code ?? "");
    // A pair from another Stack project (the repository's dev pair against prod) fails this way (cmux#35703).
    const hint = code === "EMAIL_PASSWORD_MISMATCH" ? `: CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD is not an account of Stack project ${stack.project.slice(0, 8)}; use that backend's own test account, or --sign-in oidc in a trusted job` : "";
    throw new Error(`Stack sign-in HTTP ${r.status} ${code}${hint}`);
  }
  return { access: r.body.access_token, refresh: String(r.body.refresh_token ?? "") };
}

async function machinesMode(argv: string[], backend: Backend, email: string | undefined, password: string | undefined, team: string | undefined): Promise<number> {
  const idsArg = argv.includes("--delete-ids") ? argValue("--delete-ids", argv) ?? "" : null;
  // The ids, and each one's proof that a CI journey made it and failed to delete it, are checked before anything
  // signs in. One without its proof deletes nothing.
  const entries = idsArg === null ? null : parseDeleteEntries(idsArg);
  if (entries) {
    const token = process.env.GITHUB_TOKEN ?? "";
    if (!token) throw new Error("--delete-ids needs GITHUB_TOKEN (actions: read on manaflow-ai/cmux) to read each id's journey job");
    let unproven = 0;
    for (const e of entries) {
      const why = await provenLeak(e, token);
      console.log(JSON.stringify(why ? { refused: e.id, job: e.job, reason: why } : { proven: e.id, job: e.job }));
      if (why) unproven++;
    }
    if (unproven) {
      console.log(JSON.stringify({ deleted: 0, not_deleted: entries.length, reason: `${unproven} id(s) without a CI journey's proof of a leak` }));
      return 1;
    }
  }
  const ids = entries?.map((e) => e.id) ?? null;
  const alsoTeams = (argValue("--also-team", argv) ?? "").split(/[\s,]+/).filter(Boolean);
  const secrets: string[] = password ? [password] : [];
  const say = (line: string) => console.log(scrub(line, secrets));
  const signIn = argValue("--sign-in", argv) ?? "password";
  let bearer: string;
  if (signIn === "oidc") bearer = (await oidcSignIn(backend.api, process.env, secrets)).token;
  else {
    if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
    const s = await passwordSignIn(STACK[backend.stack], email, password);
    secrets.push(s.access, s.refresh);
    bearer = s.access;
  }
  const scopes: MachineScope[] = [...new Set([team ?? "", ...alsoTeams])].map((t) => {
    const api = new Api(backend.api, t || undefined);
    api.bearer = bearer;
    return {
      scope: t || "personal",
      list: () => listAllMachines((params) => api.read("cloud.machine.list", params), 50),
      get: async (id, timeoutMs) => {
        try { return await api.read("cloud.machine.get", { machine: id }, timeoutMs); } catch (e) {
          if (/HTTP 404|not[ _.-]?found/i.test(String((e as Error).message))) return null;
          throw e;
        }
      },
      remove: (id, key, timeoutMs) => api.raw("POST", "/v1/ops", { op: "cloud.machine.delete", params: { machine: id }, idempotency_key: key }, timeoutMs),
    };
  });
  const now = Date.now();
  let count = 0;
  for (const s of scopes) {
    for (const m of await s.list()) {
      if (m?.status === "deleted") continue;
      count++;
      say(JSON.stringify(machineLine(m, s.scope, now)));
    }
  }
  say(JSON.stringify({ backend: backend.name, scopes: scopes.map((s) => s.scope), machines: count }));
  if (!ids) return 0;
  const result = await deleteJourneyMachines(ids, scopes, `journey-machines-${Date.now().toString(36)}`, { now: Date.now, sleep, log: say });
  say(JSON.stringify({ deleted: result.deleted.length, not_deleted: result.failed.length }));
  return result.failed.length ? 1 : 0;
}

/** `--delete-kept ID`: one machine a `--keep` run of this account made (`cloud journey jr-...`), read back first. */
async function deleteKeptMode(id: string, backend: Backend, email: string | undefined, password: string | undefined, team: string | undefined, signIn: string): Promise<number> {
  if (!/^vm_[a-z0-9]{20}$/.test(id)) throw new Error(`--delete-kept: not vm_<20 lowercase letters or digits>: ${JSON.stringify(id.slice(0, 60))}`);
  const secrets: string[] = password ? [password] : [];
  const api = new Api(backend.api, team);
  if (signIn === "oidc") api.bearer = (await oidcSignIn(backend.api, process.env, secrets)).token;
  else {
    if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
    api.bearer = (await passwordSignIn(STACK[backend.stack], email, password)).access;
  }
  const m = await api.read("cloud.machine.get", { machine: id });
  const name = String(m?.name ?? "");
  if (!/^cloud journey jr-[a-z0-9]+$/.test(name)) {
    console.log(JSON.stringify({ refused: id, reason: `named ${JSON.stringify(name.slice(0, 60))}, not a --keep journey's machine` }));
    return 1;
  }
  await api.deleteMachine(id, `journey-delete-kept-${id}`);
  console.log(JSON.stringify({ deleted: id, name }));
  return 0;
}

/** The request every --surge run sends: two machines for five minutes, the smallest burst the ops accept. */
export const SURGE_PROOF_REQUEST = { count: 2, ttl_seconds: 300 } as const;

/** A cloud.surge.create receipt's slots, compared field by field in index order (a replay must repeat them exactly). */
export function sameSurgeSlots(a: unknown, b: unknown): boolean {
  const slots = (v: any) => (Array.isArray(v?.slots) ? v.slots : null);
  const x = slots(a), y = slots(b);
  if (!x || !y || x.length !== y.length) return false;
  const key = (s: any) => JSON.stringify([s?.index, s?.status, s?.machine_id, s?.provider, s?.reason, s?.retryable]);
  return x.every((s: any, i: number) => key(s) === key(y[i]));
}

/** Every machine id a surge receipt's slots named, once each. */
export function surgeMachineIds(...receipts: unknown[]): string[] {
  const ids = new Set<string>();
  for (const r of receipts) for (const s of (r as any)?.slots ?? []) if (typeof s?.machine_id === "string") ids.add(s.machine_id);
  return [...ids];
}

/**
 * `--surge`: the proof run of cmux-platform#1594's Cloud Surge ops (hq docs/rfd/0025-cloud-surge.md, "Proof before
 * enabling"). Signs in as a person (create refuses agent and install tokens), reads the team user.ensure names,
 * previews SURGE_PROOF_REQUEST, creates it under one key, replays that key, sends the key with count 1, and deletes
 * every machine any receipt named, pass or fail. journey.json and summary.md hold the preview, each answer in full and
 * each delete's result.
 */
async function surgeMode(backend: Backend, outDir: string | null, email: string | undefined, password: string | undefined, team: string | undefined, signIn: string): Promise<number> {
  const tag = `jr-${Date.now().toString(36)}`;
  // One key for this run: the platform keys a batch by user and key and keeps it for its ledger window, so a key
  // shared across runs would replay an earlier run's batch instead of creating one.
  const key = `${tag}-surge`;
  const J = new Journey(backend, outDir, { tag, mode: "surge", team: team ?? "(personal)", key, request: JSON.stringify(SURGE_PROOF_REQUEST) });
  if (password) J.secrets.push(password);
  const api = new Api(backend.api, team);
  const create = (params: unknown) => api.raw("POST", "/v1/ops", { op: "cloud.surge.create", params, idempotency_key: key }, 120_000);
  const answer = (r: Answer) => scrub(JSON.stringify({ http: r.status, ...r.body }), J.secrets);
  const receipts: unknown[] = [];
  const deleted = new Set<string>();
  const cleanup = async () => {
    for (const id of surgeMachineIds(...receipts)) {
      if (deleted.has(id)) continue;
      deleted.add(id);
      await J.step(`surge delete ${id}`, async () => {
        const v = await api.deleteMachine(id, `${key}-delete-${id}`);
        return { value: null, detail: scrub(JSON.stringify(v ?? null), J.secrets) };
      }).catch(() => undefined);
    }
  };
  const onSignal = (signal: string) => void cleanup().finally(() => { J.flush(); process.exit(signal === "SIGINT" ? 130 : 143); });
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  try {
    await J.step("health", async () => {
      const r = await http("GET", `${backend.api}/v1/health`, undefined, {});
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body)}`);
      return { value: null, detail: `commit ${r.body.commit ?? r.body.version ?? "?"}` };
    });
    api.bearer = await J.step("sign in (agent test account)", async () => {
      if (signIn === "oidc") {
        const s = await oidcSignIn(backend.api, process.env, J.secrets);
        return { value: s.token, detail: `GitHub OIDC, user ${s.user}` };
      }
      if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      J.secrets.push(s.access, s.refresh);
      return { value: s.access, detail: "Stack password session" };
    });
    await J.step("user.ensure (acting team)", async () => {
      const v = await api.op("user.ensure", {}, `${tag}-ensure`);
      const acting = team ?? (typeof v?.personal_team === "string" ? v.personal_team : null);
      J.meta.team = acting ?? "(not named)";
      return { value: v, detail: `user ${v?.id ?? v?.user?.id ?? "?"}, acting team ${acting ?? "?"} (${team ? "--team" : "personal_team"})` };
    });
    await J.step("cloud.surge.preview", async () => {
      const v = await api.read("cloud.surge.preview", SURGE_PROOF_REQUEST);
      const detail = scrub(JSON.stringify(v), J.secrets);
      if (v?.available !== true) throw new Error(`not available: ${detail}`);
      return { value: v, detail };
    }).catch(() => undefined);
    const first = await J.step("cloud.surge.create", async () => {
      const t0 = Date.now();
      const r = await create(SURGE_PROOF_REQUEST);
      if (r.body?.value) receipts.push(r.body.value);
      const detail = `receipt in ${Date.now() - t0} ms: ${answer(r)}`;
      if (r.status !== 200 || r.body?.ok !== true) throw new Error(detail);
      if (r.body.replayed !== false) throw new Error(`a fresh key answered replayed=${r.body.replayed}: ${detail}`);
      if (r.body.value?.slots?.length !== SURGE_PROOF_REQUEST.count) throw new Error(`expected ${SURGE_PROOF_REQUEST.count} slots: ${detail}`);
      return { value: r.body.value, detail };
    }).catch(() => null);
    if (!first) {
      J.skip("cloud.surge.create replay", "create did not answer a receipt");
      J.skip("cloud.surge.create conflict", "create did not answer a receipt");
    } else {
      await J.step("cloud.surge.create replay", async () => {
        const t0 = Date.now();
        const r = await create(SURGE_PROOF_REQUEST);
        if (r.body?.value) receipts.push(r.body.value);
        const detail = `receipt in ${Date.now() - t0} ms: ${answer(r)}`;
        if (r.status !== 200 || r.body?.ok !== true) throw new Error(detail);
        if (r.body.replayed !== true) throw new Error(`replayed=${r.body.replayed}: ${detail}`);
        if (!sameSurgeSlots(first, r.body.value)) throw new Error(`slots differ from the first receipt: ${detail}`);
        return { value: null, detail: `replayed with identical slots; ${detail}` };
      }).catch(() => undefined);
      await J.step("cloud.surge.create conflict", async () => {
        const r = await create({ ...SURGE_PROOF_REQUEST, count: 1 });
        if (r.body?.value) receipts.push(r.body.value);
        const detail = answer(r);
        if (r.body?.ok !== false || r.body?.error?.code !== "idempotency.conflict") throw new Error(`expected idempotency.conflict: ${detail}`);
        return { value: null, detail };
      }).catch(() => undefined);
    }
  } catch {
    // The failed step is recorded; cleanup still runs.
  } finally {
    await cleanup();
    if (!surgeMachineIds(...receipts).length) J.skip("surge delete", "no slot named a machine_id");
    J.flush();
  }
  const failed = J.steps.filter((s) => s.status === "fail").length;
  console.log(`\n${failed ? "FAIL" : "PASS"} surge proof on ${backend.name}: ${J.steps.length - failed} recorded, ${failed} failed`);
  return failed ? 1 : 0;
}

/**
 * Steps that passed on the version before a deploy and fail after it: the deploy's own reds. A step that
 * was already red before (a known backend bug) is not the deploy's fault and never triggers a rollback.
 * With no baseline (the first run, or it could not sign in), every failed step counts.
 */
export function newReds(before: Step[] | null, after: Step[]): Step[] {
  const passed = new Set((before ?? []).filter((s) => s.status === "pass").map((s) => s.step));
  return after.filter((s) => s.status === "fail" && (before === null || passed.has(s.step)));
}

/**
 * Whether every new red is the platform turning the journey away for capacity (no machine to give, or a rate limit),
 * not the deploy breaking a step: such a red never rolls a deploy back (`--compare` exits 4). A machine that was
 * given and then failed (vm_unavailable on its first exec, a crash) is not capacity: a bad build does that.
 */
export const CAPACITY_RED = /\b429\b|rate.?limit|too many requests|no (?:machine|spare|capacity)s? (?:is |are )?available|out of capacity|at capacity|insufficient capacity|no_capacity/i;
export function capacityOnly(reds: Step[]): boolean {
  return reds.length > 0 && reds.every((s) => CAPACITY_RED.test(s.detail));
}

function argValue(flag: string, argv: string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0]);
    return 0;
  }
  // --compare BEFORE.json AFTER.json: exit 3 when the deploy made a step red (newReds), 4 when every such red is
  // capacity (capacityOnly: never a rollback), 0 otherwise.
  const compare = argv.indexOf("--compare");
  if (compare >= 0) {
    const load = (f: string | undefined): Step[] | null => {
      try { return f ? (JSON.parse(readFileSync(f, "utf8")).steps as Step[]) : null; } catch { return null; }
    };
    const before = load(argv[compare + 1]);
    const after = load(argv[compare + 2]) ?? [];
    const reds = newReds(before, after);
    for (const r of reds) console.log(`NEW RED ${r.step}: ${r.detail.slice(0, 300)}`);
    console.log(reds.length ? `${reds.length} step(s) red after the deploy that were green before it` : "no new reds");
    if (capacityOnly(reds)) {
      console.log("every new red is capacity (no machine available or rate limited): not the deploy's, no rollback");
      return 4;
    }
    return reds.length ? 3 : 0;
  }
  const backendArg = argValue("--backend", argv) ?? (argValue("--api", argv) ? "custom" : "staging");
  const backendName = normalizeBackendName(backendArg, argValue("--api", argv));
  // Publish a failure envelope before credential/config reads or network work. A hard timeout or
  // early exception still leaves an attributable real/stub row, replaced after a completed journey.
  const probeOut = argValue("--probe-out", argv);
  const probeName = argValue("--probe", argv) ?? `cloud-chat-replies-${backendName === "prod" ? "production" : backendName}`;
  const probeModel: "stub" | "real" = argValue("--model", argv) === "stub" ||
    (Boolean(argValue("--gateway", argv)) && (argValue("--gateway-upstream", argv) ?? "stub") === "stub") ? "stub" : "real";
  const probeContext = { backend: backendName, model: probeModel, run_attempt: Number(process.env.GITHUB_RUN_ATTEMPT ?? 1) };
  const probeRun = process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : undefined;
  if (probeOut) {
    mkdirSync(path.dirname(probeOut), { recursive: true });
    writeFileSync(probeOut, `${JSON.stringify(probeRow(probeName, [], probeRun, new Date(), probeContext))}\n`);
  }
  const backend = resolveBackend(backendArg, argValue("--api", argv), argValue("--stack", argv), Number(argValue("--local-port", argv) ?? 8787));
  const outArg = argValue("--out", argv);
  const outDir = outArg ? path.resolve(outArg) : null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const credFile = argValue("--credentials", argv);
  const creds: Record<string, string> = { ...(credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {}) };
  let email = process.env.CMUX_STAGING_STACK_EMAIL ?? process.env.CMUX_DOGFOOD_STACK_EMAIL ??
    creds.CMUX_STAGING_STACK_EMAIL ?? creds.CMUX_DOGFOOD_STACK_EMAIL ?? creds.CMUX_UITEST_STACK_EMAIL;
  let password = process.env.CMUX_STAGING_STACK_PASSWORD ?? process.env.CMUX_DOGFOOD_STACK_PASSWORD ??
    creds.CMUX_STAGING_STACK_PASSWORD ?? creds.CMUX_DOGFOOD_STACK_PASSWORD ?? creds.CMUX_UITEST_STACK_PASSWORD;
  const team = argValue("--team", argv) ?? process.env.CMUX_JOURNEY_TEAM ?? undefined;
  const signIn = argValue("--sign-in", argv) ?? "password";
  if (signIn !== "password" && signIn !== "oidc") throw new Error(`--sign-in ${signIn}: password or oidc`);
  const freshAccount = argv.includes("--fresh-account");
  if (freshAccount && signIn !== "password") throw new Error("--fresh-account signs up and in with a password: drop --sign-in oidc");
  // When the password sign-in ran: the resume matrix signs in again once it is RESIGN_AFTER_MS old.
  let signedInAt = 0;
  // --machines (list) and --delete-ids (delete exact ids): the operator's leaked-machine cleanup, no journey.
  if (argv.includes("--machines") || argv.includes("--delete-ids")) return machinesMode(argv, backend, email, password, team);
  // --delete-kept ID: delete one machine a --keep run of this account made (named `cloud journey jr-...`), and nothing else.
  const kept = argValue("--delete-kept", argv);
  if (kept !== undefined) return deleteKeptMode(kept, backend, email, password, team, signIn);
  if (argv.includes("--surge")) return surgeMode(backend, outDir, email, password, team, signIn);
  const cleanupTag = argValue("--cleanup-tag", argv);
  if (cleanupTag !== undefined) return cleanupTagMode(cleanupTag, backend, email, password, team, argv.includes("--kept"));
  const agent = argValue("--agent", argv) ?? "claude";
  const prompt = argValue("--prompt", argv) ?? "Reply with one short sentence that names the planet you are on.";
  const chatBudget = Number(argValue("--chat-timeout", argv) ?? 300) * 1000;
  const cmux = argValue("--cmux", argv);
  const preclaim = argv.includes("--preclaim");
  const preclaimClaims = Number(argValue("--claims", argv) ?? 10);
  // --ensure-bench N (with --preclaim): time acp ensure on one fresh machine instead of the burst (runEnsureBench).
  // PRECLAIM_ENSURE_BENCH=N does the same, so the dispatch sets it from its env without changing the burst's command line.
  const ensureBench = argValue("--ensure-bench", argv) ?? (process.env.PRECLAIM_ENSURE_BENCH || undefined);
  // --start-bench N (with --preclaim): create-to-first-command per start path (runStartBench, cloud-start-bench.ts) instead
  // of the burst; PRECLAIM_START_BENCH=N does the same from the dispatch's env.
  const startBench = argValue("--start-bench", argv) ?? (process.env.PRECLAIM_START_BENCH || undefined);
  // --spare-wait SECONDS (0..900): each preclaim claim, and a single run's --preclaim-login, first waits, at most this long,
  // for the warm to name a ready spare.
  const preclaimSpareWait = Number(argValue("--spare-wait", argv) ?? 0);
  if (!Number.isInteger(preclaimSpareWait) || preclaimSpareWait < 0 || preclaimSpareWait > 900) throw new Error("--spare-wait must be 0..900 seconds");
  // --machine ID: run on that existing machine and keep it (no create, pause, resume or delete).
  const reuse = argValue("--machine", argv);
  const keyedStart = argv.includes("--keyed-start");
  // --preclaim-login PATH: the app's part on a warm spare before create (prepareSpareLogin, with the cmux-tui at PATH
  // for warm-spare); after the claim a login receipt for the machine makes the login step only the post-bind check.
  const preclaimLoginCmux = argValue("--preclaim-login", argv);
  // --desktop-link: the desktop's UDP link readback instead of the chat (needs --cmux for the dial).
  const desktopLink = argv.includes("--desktop-link");
  // --autocloud-tui PATH: after the carrier dial, a chat through cmux-autocloud --machine (RFD 0139), needs --cmux.
  const autocloudTui = argValue("--autocloud-tui", argv);
  if (autocloudTui && !cmux) throw new Error("--autocloud-tui needs --cmux PATH: cmux-autocloud dials with that cmux");
  if (desktopLink && !cmux) throw new Error("--desktop-link needs --cmux PATH: the readback is the CLI's own dial");
  const keep = argv.includes("--keep") || Boolean(reuse);
  const seed = argValue("--seed", argv) ?? "auto";
  if (seed !== "none" && seed !== "auto") throw new Error(`--seed ${seed}: none or auto`);
  // --chaos: after the carrier dial, the chaos leg (cloud-chaos.ts) on this machine; --chaos-probe-out FILE writes it
  // as one synthetic-probe row (--chaos-probe NAME, default cloud-carrier-chaos-<backend>).
  const chaos = argv.includes("--chaos");
  // --resume-matrix 5,30,300,900,3600: after the chaos leg, this machine paused and woken --resume-n times (default 20)
  // per pause length and per arm (--resume-arms, default direct,platform,send), each wake timed from its event to the
  // resume's answer, the guest running, the relay registered and the reply's first byte (cloud-resume-matrix.ts).
  const resumePauses = (argValue("--resume-matrix", argv) ?? "").split(",").filter(Boolean).map(Number);
  if (resumePauses.some((x) => !Number.isFinite(x) || x < 0 || x > 21_600)) throw new Error("--resume-matrix takes pause seconds 0..21600, comma separated");
  const resumeN = Number(argValue("--resume-n", argv) ?? 20);
  if (!Number.isInteger(resumeN) || resumeN < 1) throw new Error("--resume-n must be a positive integer");
  const resumeArms = (argValue("--resume-arms", argv) ?? RESUME_ARMS.join(",")).split(",").filter(Boolean) as ResumeArm[];
  if (resumeArms.some((a) => !RESUME_ARMS.includes(a))) throw new Error(`--resume-arms: ${RESUME_ARMS.join(", ")}`);
  // --provider NAME (repeatable): a ProviderAdapter (resume-slo-provider.ts) as one more arm in the same cells, `provider:NAME`.
  // Morph needs MORPH_API_KEY and MORPH_SNAPSHOT_ID; without them its cells read "skipped: no MORPH_API_KEY".
  const resumeProviders = argv.flatMap((a, i) => (a === "--provider" && argv[i + 1] ? [argv[i + 1]!] : []));
  // --resume-fill PCT: a guest holder keeps PCT% of MemTotal resident through the pauses and walks it after each wake
  // (the page-in, hq#17877's resume-memory-probe.sh measure, now beside the matrix's points).
  // --wake-echo N: right after the machine runs, N platform pause/wake cycles timed to the first echo of a typed
  // character (cloud-wake-echo.ts), then the machine is deleted; nothing else of the journey runs.
  const wakeEchoN = Number(argValue("--wake-echo", argv) ?? 0);
  const wakeEchoHoldMs = Number(argValue("--wake-echo-hold", argv) ?? 5) * 1000;
  const wakeEchoDeadline = argValue("--wake-echo-deadline", argv);
  const resumeFill = Number(argValue("--resume-fill", argv) ?? 0);
  if (!Number.isFinite(resumeFill) || resumeFill < 0 || resumeFill > 80) throw new Error("--resume-fill must be 0..80 percent");
  // --resume-deadline EPOCH_S: the matrix takes no sample it cannot finish by then (each pause length its even share of
  // what is left), so a CI step's timeout never kills it before it writes its table. --resume-fail-streak K: an arm
  // that fails K samples in a row leaves its cell, and a cell whose last K samples failed ends (default 3).
  const resumeDeadlineS = argValue("--resume-deadline", argv);
  const resumeDeadlineAt = resumeDeadlineS === undefined ? undefined : Number(resumeDeadlineS) * 1000;
  if (resumeDeadlineAt !== undefined && !Number.isFinite(resumeDeadlineAt)) throw new Error("--resume-deadline takes epoch seconds");
  const resumeFailStreak = Number(argValue("--resume-fail-streak", argv) ?? FAIL_STREAK);
  if (!Number.isInteger(resumeFailStreak) || resumeFailStreak < 1) throw new Error("--resume-fail-streak must be a positive integer");
  // --start-via app: the app's own start (agent-session-start over the carrier dial) instead of `acp ensure`.
  const startVia = argValue("--start-via", argv) ?? "acp";
  if (startVia !== "acp" && startVia !== "app") throw new Error(`--start-via ${startVia}: acp or app`);
  if (startVia === "app" && !cmux) throw new Error("--start-via app needs --cmux PATH: the app's start goes over the carrier dial");
  // --home-chat reserved measures the app's first home chat, after a reserved ticket was warmed on a keyed spare.
  const homeChat = argValue("--home-chat", argv) ?? "none";
  if (homeChat !== "none" && homeChat !== "reserved") throw new Error(`--home-chat ${homeChat}: none or reserved`);
  if (homeChat === "reserved" && !cmux) throw new Error("--home-chat reserved needs --cmux PATH: the app-style start goes over the carrier dial");
  const only =new Set((argValue("--skip", argv) ?? "").split(",").filter(Boolean));
  if (reuse) only.add("pause");
  // --model stub: the model endpoint is the only stand-in (the shared model stub on the machine). The login the
  // journey passes is then a made-up setup-token shape: the stub checks it arrived, and no real credential exists.
  const modelStub = argValue("--model", argv) === "stub";
  const gatewayCmux = argValue("--gateway", argv);
  const gatewayLocal = argValue("--gateway-local", argv);
  const gatewayUpstream = argValue("--gateway-upstream", argv) ?? "stub";
  if (gatewayCmux && gatewayLocal) throw new Error("--gateway and --gateway-local: pick one");
  if (gatewayLocal && gatewayUpstream === "stub") throw new Error("--gateway-local needs --gateway-upstream URL (the person's proxy, reachable from this computer)");
  const gatewayAny = Boolean(gatewayCmux || gatewayLocal);
  // The clean room fails on a finding when the chat machine is meant to hold no key; otherwise it reports.
  const keysClean = gatewayAny || argv.includes("--keys-clean");
  const keysProbeOut = argValue("--keys-probe-out", argv);
  // With the gateway and the stub, the stub's nonce reply is checked as --model stub does, but it runs on the gateway.
  const gatewayStub = Boolean(gatewayCmux) && gatewayUpstream === "stub";
  const nonce = randomBytes(6).toString("hex");
  const claudeLogin = modelStub
    ? `sk-ant-oat01-journeystub-${randomBytes(24).toString("hex")}`
    : (process.env.CLAUDE_CODE_OAUTH_TOKEN || creds.CLAUDE_CODE_OAUTH_TOKEN || "").trim();
  // Codex's login is its auth.json (a ChatGPT sign-in), as the app copies it; CODEX_AUTH_JSON for a real run.
  const codexLogin = modelStub ? stubCodexAuth() : (process.env.CODEX_AUTH_JSON || creds.CODEX_AUTH_JSON || "").trim();
  // `claude/claude-sonnet-5-5` is the claude harness on that model (`acp ensure -m`): the same login and lifecycle legs.
  const harness = agent.split("/")[0];
  const provider: "claude" | "codex" | undefined = harness === "claude" || harness === "codex" ? harness : undefined;
  const askedModel = agent.includes("/") ? agent.slice(agent.indexOf("/") + 1) : "";
  const login = provider === "codex" ? codexLogin : provider === "claude" ? claudeLogin : "";
  const loginStep = provider === "codex" ? "pass Codex login" : "pass Claude login";
  let launchCredential = homeChat === "reserved" ? false : startsOnLaunchCredential({ modelStub, provider, login, gatewayAny, startVia, preclaimLogin: Boolean(preclaimLoginCmux) });
  // A --preclaim-login run whose claimed machine got no login on spare.ready takes this path (loginPathAfterClaim).
  const launchOnMiss = homeChat === "reserved" ? false : startsOnLaunchCredential({ modelStub, provider, login, gatewayAny, startVia, preclaimLogin: false });
  const tag =`jr-${Date.now().toString(36)}`;
  // This run's send as one trace (cloud-start-trace.ts mintSendTrace): on the create, the carrier ticket and the prompt.
  const sendTrace = mintSendTrace();
  console.log(`send trace id ${sendTrace.id}`);
  // A run that deletes its machine at the end names it "cloud journey auto jr-...": only those names are the sweep's
  // (the run meant to delete them). A --keep run keeps the plain "cloud journey jr-..." name, as every run used before
  // the sweep existed, and the sweep never matches it, so a kept machine is never deleted.
  const machineName = keep ? `cloud journey ${tag}` : autoMachineName(tag, resumePauses.length > 0 || wakeEchoN > 0);
  const J = new Journey(backend, outDir, { tag, team: team ?? "(personal)", agent, exec: cmux ? `cmux CLI ${cmux}` : "client session", model: modelStub ? "stub (on the machine)" : "real" }, preclaim);
  if (password) J.secrets.push(password);
  if (claudeLogin) J.secrets.push(claudeLogin);
  if (codexLogin) {
    J.secrets.push(codexLogin);
    try {
      const t = JSON.parse(codexLogin).tokens ?? {};
      for (const k of ["access_token", "refresh_token", "id_token"]) if (typeof t[k] === "string" && t[k]) J.secrets.push(t[k]);
    } catch { /* validLogin names a malformed login */ }
  }
  const appCli = argValue("--app-cli", argv);
  if (appCli) {
    J.meta.exec = `app CLI ${appCli}`;
    await appCliJourney(appCli, argValue("--socket", argv), J, agent, prompt).catch(() => undefined);
    const failedApp = J.steps.filter((s) => s.status === "fail").length;
    console.log(`\n${failedApp ? "FAIL" : "PASS"} app CLI journey: ${J.steps.length - failedApp} passed, ${failedApp} failed`);
    return failedApp ? 1 : 0;
  }
  const api = new Api(backend.api, team);
  let machine: string | null = null;
  let gatewayMachine: string | null = null;
  // The team's gateway mode before this run changed it, the API that set it, and the local gateway this run started.
  let gatewayModeBefore: string | null = null;
  let gatewayMachineBefore: string | null = null;
  let gatewayApi: Api | null = null;
  let localGateway: ReturnType<typeof spawn> | null = null;
  let localGatewayDir: string | null = null;
  let deleted = false;
  let firstTextObserver: Promise<void> | undefined;
  /** A check the app does not run before the first text: the journey runs it after, outside the timed window. */
  let afterFirstText: (() => Promise<void>) | undefined;
  let createAnsweredAt: number | null = null;
  let createSentAt: number | null = null;
  // The chat machine's exec once the run has one, for the failure facts below.
  let machineExec: Exec | null = null;
  let guestFinalRead = false;
  const guestDiagnosticsAbort = new AbortController();
  const readGuestDiagnostics = async (phase: "journey-facts" | "before-cleanup") => {
    if (phase === "before-cleanup") {
      if (guestFinalRead) return;
      guestFinalRead = true;
    }
    const observation = await collectGuestDiagnostics(machineExec, phase, 18_000, guestDiagnosticsAbort.signal);
    J.guestDiagnostics.push(observation);
    try {
      J.record({ step: `guest updater (${phase})`, status: "skip", ms: observation.duration_ms,
        detail: `${observation.status}; updater=${observation.updater.look.outcome}; first_ready=${observation.updater.first_ready.outcome}; full evidence: guest-updater.json` });
    } catch { console.warn("Guest updater evidence could not be written; continuing cleanup"); }
  };
  // The journey-only checks, once the machine runs: after the reply, or after the failure that cut the chat off.
  let runJourneyOnly: (() => Promise<void>) | null = null;
  // What probe.json adds once create answered: the claim's spare report, claimed_spare and the failure facts.
  const probeExtra: ProbeExtra = {};
  let factsRead = false;
  // --preclaim-login's warm-spare state dir, removed by the cleanup.
  let preclaimStateDir: string | null = null;
  // Where the steps after create start: only a failure from there on reads the machine's facts.
  let afterCreate = -1;
  // On any failed step after create, what the machine says, read before anything is deleted (the app probe's rule):
  // its cloud.machine.get row and the guest's carrier timeline, each bounded and scrubbed of ids and secrets. A read
  // that fails is recorded as such, never thrown.
  const readFailureFacts = async () => {
    const id = machine ?? reuse;
    if (factsRead || !id || afterCreate < 0 || !api.bearer || !J.steps.slice(afterCreate).some((s) => s.status === "fail")) return;
    factsRead = true;
    const t0 = Date.now();
    const facts: FailureFacts = { machine: null, timeline: null };
    const why = (e: unknown) => publicError(String((e as Error)?.message ?? e), J.secrets);
    try {
      facts.machine = publicMachineFacts(await bounded(api.read("cloud.machine.get", { machine: id }, FACTS_READ_MS), FACTS_READ_MS + 2_000, "cloud.machine.get"));
    } catch (e) {
      facts.machine_error = why(e);
    }
    if (!machineExec) facts.timeline_error = "not read: the run failed before it had an exec route to the machine";
    else {
      try {
        const before = Date.now();
        const r = await bounded(machineExec(GUEST_CARRIER_TIMELINE, FACTS_READ_MS), FACTS_READ_MS + 5_000, "guest carrier timeline");
        const after = Date.now();
        if (r.code !== 0) throw new Error(`exit ${r.code} ${r.stderr.slice(-120)}`);
        const timeline = guestTimelineFacts(r.stdout, createAnsweredAt ?? before, before, after, createSentAt ?? createAnsweredAt ?? before);
        if (createAnsweredAt === null) timeline.claimed_spare = null;
        else if (probeExtra.claimed_spare == null) probeExtra.claimed_spare = timeline.claimed_spare;
        facts.timeline = timeline;
      } catch (e) {
        facts.timeline_error = why(e);
      }
    }
    probeExtra.failure_facts = facts;
    J.record({ step: "failure facts", status: "skip", ms: Date.now() - t0, detail: `read before any delete: ${JSON.stringify(facts)}` });
  };
  // The send's Chrome trace (Perfetto): printed and saved on a green or red run, once, never a step, so tracing can
  // never fail the journey. CMUX_JOURNEY_SEND_TRACE_SETTLE_MS=0 (the fake's runs, cloud-journey-fake.ts) skips the
  // settle: no platform spans land there.
  let sendTraceSaved = false;
  const saveSendTraceOnce = async () => {
    if (reuse || sendTraceSaved) return;
    sendTraceSaved = true;
    const settle = process.env.CMUX_JOURNEY_SEND_TRACE_SETTLE_MS === "0" ? async () => {} : sleep;
    await saveSendTrace(api, sendTrace.id, firstTextEpoch(J.firstText, createSentAt), outDir, Date.now, settle)
      .catch((e) => console.log(`send trace ${sendTrace.id}: ${String((e as Error)?.message ?? e).slice(0, 200)}`));
  };
  // This run's install (install token step), revoked at cleanup.
  let journeyInstall: string | null = null;
  // Delete what this run made, pass, fail or cancel. A create whose reply was lost leaves `machine`
  // null, so the run's own machine is also found by its name (`cloud journey <tag>`).
  const cleanup = sharedCleanup(async () => {
    await readGuestDiagnostics("before-cleanup");
    await readFailureFacts();
    if (preclaimStateDir) {
      rmSync(preclaimStateDir, { recursive: true, force: true });
      preclaimStateDir = null;
    }
    if (localGateway?.pid) {
      // Only the process this run started, by its own pid.
      try { process.kill(localGateway.pid, "SIGTERM"); } catch {}
      localGateway = null;
    }
    if (localGatewayDir) {
      // The gateway's log (machine ids, paths and statuses; never a token) stays with the run's evidence.
      try { if (outDir) writeFileSync(path.join(outDir, "gateway.log"), scrub(readFileSync(path.join(localGatewayDir, "gateway.log"), "utf8"), J.secrets)); } catch {}
      rmSync(localGatewayDir, { recursive: true, force: true });
      localGatewayDir = null;
    }
    // The team's gateway mode comes back even with --keep: the gateway this run used is gone (or about to be).
    if (gatewayModeBefore && gatewayApi) {
      const before = gatewayModeBefore;
      const beforeMachine = gatewayMachineBefore;
      gatewayModeBefore = null;
      await J.step("team gateway mode restored (cleanup)", async () => {
        const r = await gatewayApi!.raw("PUT", "/v1/cloud/inference-gateway", { mode: before, machine: beforeMachine });
        if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
        return { value: null, detail: before };
      }).catch(() => undefined);
    }
    if (keep || !api.bearer) return;
    // This run's own install, so it never adds to the account's live installs (a sweep takes a killed run's).
    if (journeyInstall) {
      const own: string = journeyInstall;
      journeyInstall = null;
      const t0 = Date.now();
      await api.op("install.revoke", { install: own }, `${tag}-install-revoke`).then(
        () => J.record({ step: "revoke install (cleanup)", status: "pass", ms: Date.now() - t0, detail: own }),
        (e) => J.record({ step: "revoke install (cleanup)", status: "skip", ms: Date.now() - t0, detail: `${own}: ${String((e as Error)?.message ?? e).slice(0, 300)}` }));
    }
    if (gatewayMachine) {
      const g: string = gatewayMachine;
      await J.step("delete gateway machine (cleanup)", async () => {
        await api.deleteMachine(g, `${tag}-gw-delete`);
        return { value: null, detail: g };
      }).catch(() => undefined);
    }
    if (deleted) return;
    let id = machine;
    if (!id) {
      // Every page: the machine may sit past the first (a shared account's list).
      const rows = await listAllMachines((params) => api.read("cloud.machine.list", params, 30_000)).catch(() => [] as any[]);
      id = rows.find((r) => r?.name === machineName && r.status !== "deleted")?.id ?? null;
    }
    if (!id) return;
    const target: string = id;
    await J.step("delete (cleanup)", async () => {
      await api.deleteMachine(target, `${tag}-cleanup-delete`);
      return { value: null, detail: target };
    }).catch(() => undefined);
  });
  // The cmuxterm-hq probes.py row: ok with send-to-reply ms, or fail naming the first failed step (or none reached).
  const writeProbe = () => {
    if (probeOut) writeFileSync(probeOut, `${JSON.stringify(probeRow(probeName, J.steps, probeRun, new Date(), probeContext, probeExtra))}\n`);
  };
  // A job cancel or timeout sends SIGTERM, which skips `finally`: clean up, write results, exit.
  const onSignal = (signal: string) => {
    // The runner kills the job about 10 s after a cancel; the facts reads (up to 27 s) would lose the delete. A
    // cancel deletes first and reads no facts.
    factsRead = true;
    guestFinalRead = true;
    guestDiagnosticsAbort.abort();
    for (const dial of carrierDials) dial.kill("SIGTERM");
    for (const dir of carrierStateDirs) rmSync(dir, { recursive: true, force: true });
    void cleanup().finally(() => {
      J.flush();
      writeProbe();
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  try {
    await J.step("health", async () => {
      const r = await http("GET", `${backend.api}/v1/health`, undefined, {});
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body)}`);
      return { value: null, detail: `commit ${r.body.commit ?? r.body.version ?? "?"}` };
    });
    if (freshAccount) {
      // The new person's sign-up, then the same password sign-in the stored test account takes.
      const made = await J.step("sign up (fresh account)", async () => {
        const a = await freshAccountSignUp(backend.stack);
        J.secrets.push(a.password, a.access, a.refresh);
        return { value: a, detail: `${a.email} on Stack project ${STACK[backend.stack].project.slice(0, 8)}` };
      });
      email = made.email;
      password = made.password;
    }
    if (signIn === "oidc") {
      api.bearer = await J.step("sign in (agent test account)", async () => {
        const s = await oidcSignIn(backend.api, process.env, J.secrets);
        return { value: s.token, detail: `GitHub OIDC, user ${s.user}, session ends ${s.expiresAt}` };
      });
    } else if (!email || !password) {
      await J.step("sign in (agent test account)", async () => {
        throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
      });
    }
    const stack = STACK[backend.stack];
    if (signIn === "password") api.bearer = await J.step("sign in (agent test account)", async () => {
      signedInAt = Date.now();
      const s = await passwordSignIn(stack, email!, password!);
      J.secrets.push(s.access, s.refresh);
      return { value: s.access, detail: `Stack project ${stack.project.slice(0, 8)}` };
    });
    // A run longer than the Stack session (12 wake-echo cycles at a 300 s hold, the resume matrix) signs in again
    // once the session is RESIGN_AFTER_MS old: run 45510772491's 300 s shards got 401 on cycle 10 of 12, 55 min in.
    const resignIfOld = async (): Promise<boolean> => {
      if (signIn !== "password" || !email || !password || Date.now() - signedInAt < RESIGN_AFTER_MS) return false;
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      J.secrets.push(s.access, s.refresh);
      signedInAt = Date.now();
      api.bearer = s.access;
      return true;
    };
    const user = await J.step("user.ensure", async () => {
      const v = await api.op("user.ensure", {}, `${tag}-ensure`);
      return { value: v, detail: `user ${v.id ?? v.user?.id ?? "?"}` };
    });
    if (!keep) {
      // Installs that killed runs left live fill the account's state until install.register is refused
      // (owner.state_full). Revoked ones past 100 are pruned, so revoking frees the space. Never fails the journey.
      const name = "sweep leaked journey installs";
      const t0 = Date.now();
      const err = (e: unknown) => String((e as Error)?.message ?? e).slice(0, 300);
      try {
        const v = await api.read("install.list", {});
        const stale = staleJourneyInstalls(Array.isArray(v?.installs) ? v.installs : [], Date.now());
        const failed: string[] = [];
        let revoked = 0;
        for (const id of stale) {
          if (Date.now() - t0 > INSTALL_SWEEP_BUDGET_MS) break;
          await api.op("install.revoke", { install: id }, `${tag}-sweep-install-${id}`).then(() => revoked++, (e) => failed.push(`${id}: ${err(e)}`));
        }
        const detail = `${revoked} of ${stale.length} leaked revoked (${v?.installs?.length ?? 0} installs)${failed.length ? `; failed ${failed.slice(0, 3).join("; ")}` : ""}`;
        J.record({ step: name, status: failed.length ? "skip" : "pass", ms: Date.now() - t0, detail });
      } catch (e) {
        J.record({ step: name, status: "skip", ms: Date.now() - t0, detail: `list failed: ${err(e)}` });
      }
    }
    const install = await J.step("install token", async () => {
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
      const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
      const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `cloud journey ${tag}`, device_name: "cloud journey", platform: "linux" }, `${tag}-install`);
      const userId = inst.user ?? user.id ?? user.user?.id;
      const ch = await http("POST", `${backend.api}/v1/auth/challenge`, { user: userId, install: inst.id }, {});
      if (ch.status !== 200) throw new Error(`challenge HTTP ${ch.status} ${short(ch.body)}`);
      const tok = await http("POST", `${backend.api}/v1/auth/token`, { user: userId, install: inst.id, nonce: ch.body.nonce, signature: await sign(pair.privateKey, `${ch.body.message_prefix}${ch.body.nonce}`) }, {});
      if (tok.status !== 200 || typeof tok.body.access_token !== "string") throw new Error(`token HTTP ${tok.status} ${short(tok.body)}`);
      J.secrets.push(tok.body.access_token);
      return { value: { id: inst.id as string, token: tok.body.access_token as string, team: typeof inst.team === "string" ? inst.team : undefined, key: pair.privateKey }, detail: `install ${inst.id}` };
    });
    journeyInstall = install.id;
    // The NEXT app mints its install token for its active Stack team (a challenge that names the team), which
    // heals a team TeamDO never mirrored from Stack. On production that mint ran past the app's 25 s limit
    // (cmuxterm-hq run 43577358598, 2026-11-14) while the unscoped mint above passed. --team, else the account's
    // first shared team; recorded, never fatal, so the rest of the journey still runs. user.teams.list heals an
    // unmirrored team itself before the mint sees it, so only --team exercises the mint's own heal (review F2 on
    // cmux#42958); the step says which it was. A list that failed or came back incomplete fails the step instead
    // of skipping it as "no shared team".
    const found: { team?: string; why?: string } = team ? { team } : await api.read("user.teams.list", {}).then(
      (v: any) => {
        const shared = Array.isArray(v?.teams) ? v.teams.find((t: any) => t?.kind !== "personal" && typeof t?.id === "string")?.id : undefined;
        return shared ? { team: shared as string } : { why: v?.incomplete ? "user.teams.list came back incomplete with no shared team" : "" };
      },
      (error: unknown) => ({ why: `user.teams.list failed: ${String((error as Error)?.message ?? error).slice(0, 300)}` }),
    );
    const scopedTeam = found.team;
    const via = team ? "--team" : "user.teams.list (which heals the team before the mint)";
    if (!scopedTeam && !found.why) J.skip("team-scoped install token", "the account has no shared team (pass --team to name one)");
    else if (!scopedTeam) await J.step("team-scoped install token", async () => { throw new Error(found.why); }).catch(() => undefined);
    else await J.step("team-scoped install token", async () => {
      const userId = user.id ?? user.user?.id;
      const ch = await http("POST", `${backend.api}/v1/auth/challenge`, { user: userId, install: install.id, team: scopedTeam }, {});
      if (ch.status !== 200) throw new Error(`challenge HTTP ${ch.status} ${short(ch.body)}`);
      const t0 = Date.now();
      // 25 s: the app's own limit on this request.
      const tok = await http("POST", `${backend.api}/v1/auth/token`, { user: userId, install: install.id, nonce: ch.body.nonce, signature: await sign(install.key, `${ch.body.message_prefix}${ch.body.nonce}`) }, {}, 25_000);
      const ms = Date.now() - t0;
      if (tok.status !== 200 || typeof tok.body.access_token !== "string") throw new Error(`token HTTP ${tok.status} after ${ms} ms ${short(tok.body.error ?? tok.body)}`);
      J.secrets.push(tok.body.access_token);
      if (tok.body.team !== scopedTeam) throw new Error(`token names team ${tok.body.team}, asked for ${scopedTeam}`);
      return { value: null, detail: `team ${scopedTeam} via ${via}, minted in ${ms} ms` };
    }).catch(() => undefined);
    const installApi = new Api(backend.api, team);
    installApi.bearer = install.token;

    if (preclaim) {
      const userId = String(user?.id ?? user?.user?.id ?? "");
      const accountTeam = team ?? String(user?.personal_team ?? user?.team ?? "");
      const account = `${userId}/${accountTeam}`;
      if (!userId) throw new Error("preclaim: user.ensure returned no user id");
      if (startBench !== undefined) {
        const n = Number(startBench);
        if (!Number.isInteger(n) || n < 1 || n > 10) throw new Error("--start-bench must be 1..10");
        if (!cmux) throw new Error("--start-bench needs --cmux PATH for the warm the app sends (the spare path)");
        return await J.step("start bench", async () => {
          const samples = await runStartBench({ api, journey: J, backend: backend.name, tag, n, cmux, install, account, accountTeam, stack, login: claudeLogin, outDir, privateRowsPath: process.env.PRECLAIM_PRIVATE_ROWS });
          const failed = samples.filter((s) => !s.ok).length;
          return { value: 0, detail: `${samples.length} starts, ${failed} failed; table in start-bench.md` };
        });
      }
      if (ensureBench !== undefined) {
        const n = Number(ensureBench);
        if (!Number.isInteger(n) || n < 1 || n > 10) throw new Error("--ensure-bench must be 1..10");
        if (!validLogin("claude", claudeLogin)) throw new Error("--ensure-bench needs a valid Claude setup-token login");
        return await J.step("ensure bench", async () => {
          const runs = await runEnsureBench({ api, journey: J, backend: backend.name, tag, n, login: claudeLogin, programs: loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), "claude", Boolean(team)), ownerScope: team ? "owner or team" : "owner", outDir, privateRowsPath: process.env.PRECLAIM_PRIVATE_ROWS });
          const crossed = runs.filter((r) => r.ms !== null && r.ms > 120_000).length;
          return { value: 0, detail: `${runs.length} ensures; crossed 120 s: ${crossed}; max ${Math.max(0, ...runs.map((r) => r.ms ?? 0))} ms; exec probes in ensure-bench.md` };
        });
      }
      const status = await J.step("preclaim burst", async () => {
        const value = await runPreclaimBurst({
          backend,
          api,
          cmux: cmux!,
          install,
          account,
          login: claudeLogin,
          claims: preclaimClaims,
          tag,
          journey: J,
          outDir,
          privateRowsPath: process.env.PRECLAIM_PRIVATE_ROWS,
          team,
          user,
          spareWaitMs: preclaimSpareWait * 1000,
        });
        if (value !== 0) throw new Error("preclaim verification failed");
        return { value, detail: `claims ${preclaimClaims}` };
      });
      return status;
    }

    if (gatewayAny) {
      gatewayApi = installApi;
      await J.step("team in gateway mode", async () => {
        const g = await installApi.raw("GET", "/v1/cloud/inference-gateway");
        if (g.status !== 200) throw new Error(`GET HTTP ${g.status} ${short(g.body?.error ?? g.body)}`);
        const before = String(g.body?.gateway?.mode ?? "off");
        const beforeMachine = typeof g.body?.gateway?.machine === "string" ? g.body.gateway.machine : null;
        const r = await installApi.raw("PUT", "/v1/cloud/inference-gateway", { mode: "gateway", machine: null });
        if (r.status !== 200) throw new Error(`PUT HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
        gatewayModeBefore = before;
        gatewayMachineBefore = beforeMachine;
        return { value: null, detail: `was ${before}; set before the chat machine is made, so its edge route goes to the gateway` };
      });
    }
    if (!keep) {
      // Machines that killed or timed-out runs left behind hold the account's quota (cloud.quota.exceeded at create).
      // A sweep error never fails the journey: the step is recorded as skipped with the error, and create goes on.
      const name = "sweep leaked journey machines";
      const t0 = Date.now();
      const err = (e: unknown) => String((e as Error)?.message ?? e).slice(0, 300);
      try {
        const rows = await listAllMachines((params) => api.read("cloud.machine.list", params));
        const stale = staleJourneyMachines(rows, Date.now());
        const failed: string[] = [];
        for (const m of stale) {
          // Each row is logged before its delete, so a wrong pick can be traced to the machine it took.
          console.log(`sweep: deleting ${m.id} "${m.name}" status ${m.status} created ${m.created}`);
          await api.deleteMachine(m.id, `${tag}-sweep-${m.id}`).catch((e) => failed.push(`${m.id}: ${err(e)}`));
        }
        const detail = `${stale.length - failed.length} of ${stale.length} leaked deleted (${rows.length} machines)${stale.length ? `: ${stale.map((m) => m.id).join(", ")}` : ""}${failed.length ? `; failed ${failed.join("; ")}` : ""}`;
        J.record({ step: name, status: failed.length ? "skip" : "pass", ms: Date.now() - t0, detail });
      } catch (e) {
        J.record({ step: name, status: "skip", ms: Date.now() - t0, detail: `list failed: ${err(e)}` });
      }
    }
    // The app's part on a warm spare (SpareReady), before create and so outside the first-text window: the login is
    // copied on spare.ready. Anything short of a spare with the login installed starts the agent on its launch credential.
    let prepared: PreparedSpare | null = null;
    if (preclaimLoginCmux && !reuse) {
      const t0 = Date.now();
      const name = "preclaim login (spare.ready)";
      if (provider !== "claude" || !login || gatewayAny || only.has("login") || only.has("chat")) {
        J.skip(name, provider !== "claude" ? `agent ${agent}: the spare copy is Claude's` : gatewayAny ? "--gateway: the chat machine gets no login" : !login ? "no login to copy" : "--skip");
      } else {
        try {
          if (!validLogin("claude", login)) throw new Error("CLAUDE_CODE_OAUTH_TOKEN is not a `claude setup-token` login");
          preclaimStateDir = mkdtempSync(path.join(tmpdir(), "cmux-preclaim-login-"));
          const scopeTeam = team ?? install.team ?? String(user?.personal_team ?? user?.team ?? "");
          // The platform the app sends a warm to: client-config's platform_origin, as the burst does. The API host
          // forwards no /v1/machines/reservations and answers an empty 404, so every production run from 11-18 to 11-20
          // skipped this step and measured a cold create.
          const platform = clientPlatformOrigin((await api.raw("GET", "/v1/client-config", undefined, 30_000)).body);
          const scope = { platform, team: scopeTeam, install: install.id, credential: createHash("sha256").update(login).digest("hex") };
          const account = `${String(user?.id ?? user?.user?.id ?? "")}/${team ?? String(user?.personal_team ?? user?.team ?? "")}`;
          // --spare-wait: the app warms when it opens, long before a person's first chat; one warm 2 s before create
          // finds an empty pool every time (11-22 06:50Z: "warm-spare named no spare"). So warm and wait, bounded, before
          // create, outside the create -> first text window, as the burst does.
          const wireTeam = scopeTeam || api.team;
          const { prepared: got, wait } = await waitForReadySpare(() => prepareSpareLogin({
            api, cmux: preclaimLoginCmux!, stateDir: preclaimStateDir!, installToken: install.token,
            request: { platform, account, scope, currentScope: scope }, wireTeam,
            programs: loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), "claude", Boolean(team)), login,
            ownerScope: team ? "owner or team" : "owner", index: 0, journey: J, readyBudgetMs: 120_000,
          }), preclaimSpareWait * 1000, { ready: (ms) => waitForAnySpareReady({ ...api, team: wireTeam }, ms) });
          prepared = got;
          const waited = wait ? `; waited ${wait.waited_ms} ms over ${wait.attempts} warm(s)${wait.cold_after_wait ? ", bound ran out" : wait.ready_by === "claim_path" ? ", the claim path's spare ready" : ""}` : "";
          J.record({ step: name, status: prepared.spare ? "pass" : "skip", ms: Date.now() - t0, detail: (prepared.spare ? `a spare warmed; the login copied on its spare.ready and reported installed${prepared.generation ? "" : " (no copy generation: no receipt to read)"}` : "warm-spare named no spare: the login goes with the agent's start") + waited });
        } catch (e) {
          prepared = null;
          J.record({ step: name, status: "skip", ms: Date.now() - t0, detail: `the login goes with the agent's start: ${String((e as Error)?.message ?? e).slice(0, 300)}` });
        }
      }
    }
    if (homeChat === "reserved") {
      const t0 = Date.now();
      const name = "home chat warmed ahead (warm-home)";
      if (!prepared?.spare) {
        J.record({ step: name, status: "skip", ms: 0, detail: "no keyed spare was ready for the reserved home chat" });
      } else {
        try {
          const warm = await directExec(api, prepared.spare, J)(WARM_HOME_COMMAND, 60_000);
          const answer = parseWarmHomeAnswer(warm.stdout);
          J.record({ step: name, status: answer.state === "ready" ? "pass" : "skip", ms: Date.now() - t0, detail: answer.reason });
        } catch (error) {
          J.record({ step: name, status: "skip", ms: Date.now() - t0, detail: `warm-home could not run: ${String((error as Error)?.message ?? error).slice(0, 300)}` });
        }
      }
    }
    const created = reuse
      ? await J.step("use machine", async () => {
          afterCreate = J.steps.length;
          const m = await api.read("cloud.machine.get", { machine: reuse });
          if (m.status === "paused") await api.op("cloud.machine.start", { machine: reuse }, `${tag}-wake`);
          return { value: m, detail: `${reuse} status ${m.status}${m.status === "paused" ? " (started)" : ""}, kept` };
        })
      : await J.step("create machine", async () => {
          J.firstText.mark("create");
          createSentAt = Date.now();
          const v = await api.op("cloud.machine.create", { name: machineName, size: CHAT_START_SIZE, ...(seed === "none" ? { seed: "none" } : {}) }, `${tag}-create`, sendTrace.headers);
          machine = v.machine.id as string;
          createAnsweredAt = Date.now();
          afterCreate = J.steps.length;
          J.firstText.mark("created");
          // The claim's report (cmux-platform#1418): null until the answer carries it; claimed_spare once the guest says.
          const spare = spareFields(v);
          Object.assign(probeExtra, spare, { claimed_spare: null });
          if (process.env.GITHUB_ACTIONS === "true") console.log(spareNotice(backendName, process.env.JOURNEY_PHASE ?? "", spare));
          return { value: v.machine, detail: `${machine} status ${v.machine.status}` };
        });
    const bound = await J.step("running (status)", async () => {
      const m = await waitMachine(api, created.id, (x) => x.status === "running" && Boolean(x.host), 300_000);
      J.firstText.mark("running");
      return { value: m, detail: `host ${m.host}, daemon ${m.image?.daemon_version ?? "?"}` };
    });
    const exec = namesUnavailableFirstExec(cmux ? cliExec(cmux, api, created.id) : directExec(api, created.id, J));
    machineExec = exec;
    if (wakeEchoN > 0) {
      const row = async () => (await api.read("cloud.machine.get", { machine: created.id }, 30_000).catch(() => null)) as Record<string, any> | null;
      const log = (line: string) => console.log(scrub(line, J.secrets));
      let cycles: WakeCycle[] = [];
      const meta: Record<string, unknown> = { backend: backend.name, machine: created.id, asked: wakeEchoN };
      const write = () => {
        if (!outDir) return;
        writeFileSync(path.join(outDir, "wake-echo.json"), `${scrub(JSON.stringify({ ...meta, summary: wakeEchoSummary(cycles), cycles }, null, 2), J.secrets)}\n`);
        writeFileSync(path.join(outDir, "wake-echo.md"), wakeEchoMarkdown(cycles, meta));
      };
      let k = 0;
      try {
        await J.step("wake-echo machine size", async () => {
          const m = await row();
          const g = await exec("echo \"nproc $(nproc) $(grep MemTotal /proc/meminfo)\"", 30_000);
          meta.size = { platform: m?.size ?? null, guest: g.stdout.trim() };
          log(`wake-echo size: ${JSON.stringify(meta.size)}`);
          return { value: null, detail: JSON.stringify(meta.size) };
        });
        // No idle pause: the platform's own pause raced a cycle's (run 45475656502 #10: start refused, machine pausing).
        await J.step("wake-echo idle policy off", async () => {
          await api.op("cloud.machine.idle_policy.set", { machine: created.id, idle_seconds: 0 }, `${tag}-we-idle`);
          return { value: null, detail: "idle_seconds 0" };
        });
        const netHost = new URL(backend.api).hostname;
        const setup = await J.step("wake-echo probe setup", async () => ({ value: await setupProbe({ exec, guest: GUEST, netHost, netPort: 443, log }), detail: "daemon socket, terminal and dry run ok" }));
        meta.probe = { daemon: setup.daemon, version: setup.version, protocol: setup.protocol, dry_run: setup.dry_run };
        cycles = await runWakeEcho({
          exec, guest: GUEST, netHost, netPort: 443, holdMs: wakeEchoHoldMs, log,
          deadlineAt: wakeEchoDeadline === undefined ? undefined : Number(wakeEchoDeadline) * 1000,
          status: async () => String((await row())?.status ?? "unread"),
          pause: async () => {
            await resignIfOld();
            const t0 = Date.now();
            await api.op("cloud.machine.pause", { machine: created.id }, `${tag}-we-pause-${k++}`);
            return awaitPaused(async () => String((await row())?.status ?? "unread"), t0, 180_000);
          },
          wake: () => startWithRetry(
            (key) => api.raw("POST", "/v1/ops", { op: "cloud.machine.start", params: { machine: created.id }, idempotency_key: key }, 180_000),
            () => `${tag}-we-start-${k++}`,
            async () => String((await row())?.status ?? "unread"),
            180_000,
            (ms) => new Promise<void>((r) => setTimeout(r, ms)),
          ),
          onCycle: (all) => { cycles = all; write(); },
          onStop: (why) => { meta.stopped = why; },
        }, wakeEchoN);
      } catch (e) {
        J.record({ step: "wake-echo", status: "fail", ms: 0, detail: String((e as Error).message ?? e) });
        meta.setup_error = String((e as Error).message ?? e);
      }
      write();
      const sum = wakeEchoSummary(cycles);
      const table = wakeEchoMarkdown(cycles, meta);
      console.log(table);
      if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n## Wake to first echo (${backend.name}, ${created.id})\n\n${table}${meta.setup_error ? `\nSetup failed: ${meta.setup_error}\n` : ""}`);
      // Green only when every asked cycle ran and echoed: a stop (failure streak, deadline) or any failure is red.
      const whole = !meta.setup_error && !meta.stopped && sum.cycles === wakeEchoN && sum.echoed === wakeEchoN;
      if (!meta.setup_error) J.record({ step: "wake-echo", status: whole ? "pass" : "fail", ms: 0, detail: `${sum.echoed} of ${wakeEchoN} asked echoed (${sum.cycles} ran)${meta.stopped ? `; stopped: ${meta.stopped}` : ""}${sum.failed ? `; failures ${JSON.stringify(sum.causes)}` : ""}` });
      return whole ? 0 : 1;
    }
    if (reuse) {
      // A kept machine still has the last run's model stub and its endpoint in Claude Code's settings, which the
      // login installer refuses: put both back as a fresh machine has them.
      await J.step("reset kept machine", async () => {
        const r = await exec(REUSE_RESET);
        if (r.code !== 0) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
        return { value: null, detail: r.stdout.trim() || "clean" };
      });
    }
    // The checks only the journey makes (JOURNEY_ONLY_STEPS): none is part of what a person's chat waits on, so they
    // run after the reply, outside J.firstText's create-to-first-text window (they cost about 6 s at p50 inside it).
    // A run cut off before the reply runs them after the failure, before cleanup, so each still passes or fails.
    // `first exec` was the first to meet a claimed machine answering vm_unavailable; namesUnavailableFirstExec now
    // says so for whichever step reaches the machine first.
    let journeyOnlyStarted = false;
    let githubScriptOnGuest = false;
    const journeyOnly = async () => {
      if (journeyOnlyStarted) return;
      journeyOnlyStarted = true;
      await J.step("listed", async () => {
        const { row, detail } = await listedMachine(
          created.id,
          (params) => api.read("cloud.machine.list", params, 30_000),
          (id) => api.read("cloud.machine.get", { machine: id }, 30_000),
        );
        // The size the platform recorded: the one the VM read back at create, not the one asked for.
        const size = row.size ? ` size=${row.size.cpu ?? "?"}/${row.size.memory_mb ?? "?"}/${row.size.disk_mb ?? "?"}` : "";
        return { value: null, detail: `${detail}${size}` };
      });
      // A new machine made at the default size is recorded at it: 2 vCPU / 4096 MB / 20480 MB, the size the platform
      // keeps spares at. Read after the create answered and the machine ran (event order); the read has its own deadline.
      if (!reuse) await J.step(DEFAULT_SIZE_STEP, async () => {
        const m = await Promise.race([
          api.read("cloud.machine.get", { machine: created.id }),
          new Promise<never>((_, reject) => setTimeout(() => reject(new Error("cloud.machine.get: no answer in 30 s")), 30_000).unref?.()),
        ]);
        const why = defaultSizeProblem(m?.size);
        if (why) throw new Error(why);
        return { value: null, detail: `${created.id} size ${m.size.cpu}/${m.size.memory_mb}/${m.size.disk_mb}` };
      });
      await J.step("first exec", async () => {
        // The machine's real size, measured on it (cpu, memory and root disk), beside what the platform recorded (the
        // "listed" step): the size a create asks for is not always the size it boots at (cmux-platform#1504).
        const r = await exec(SIZE_READ);
        if (r.code !== 0 || !r.stdout.includes("journey-ok")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
        return { value: null, detail: r.stdout.trim().split("\n").join(" ") };
      });
      // A chat opened with a folder: how long git_seed takes to ready the repository on this machine, cloned from
      // GitHub and borrowed from a warm mirror (cloud-journey-repo-seed.ts). Opt-in: each run pulls the repo once.
      const seedRuns = repoSeedRuns(process.env.CMUX_JOURNEY_REPO_SEED_RUNS);
      for (let run = 1; run <= seedRuns; run++) {
        await J.step(seedRuns > 1 ? `${REPO_SEED_STEP} ${run}/${seedRuns}` : REPO_SEED_STEP, async () => {
          // Clone and borrow as two execs, each with the exec route's whole 300 s (cloud-journey-repo-seed.ts).
          const s = repoSeedScripts(`/tmp/cmux-seed-probe-${process.pid}-${run}`);
          const c = await exec(s.clone, 300_000);
          let r = c;
          let out = c.stdout;
          try {
            if (parseRepoSeed(c.stdout).clone?.code === "0") {
              r = await exec(s.borrow, 300_000);
              out += `\n${r.stdout}`;
            }
          } finally {
            await exec(s.cleanup, 60_000).catch(() => undefined);
          }
          console.log(out.split("\n").filter((l) => l.startsWith("@@seed")).join("\n"));
          const { ok, detail } = repoSeedDetail(parseRepoSeed(out));
          if (!ok) throw new Error(`exit ${r.code} ${detail} ${r.stderr.slice(-200)}`);
          return { value: null, detail };
        });
      }
      // A person's own create that no spare serves: the create above asks the chat start size and claims a ready spare,
      // so without this cell no run shows that a cold create boots at the size it asked for (cmux-platform#1513: every
      // image create asks the VM API for the size it was admitted at). One machine at COLD_CREATE_SIZE, its size read on
      // the guest as above, then deleted. `--skip cold` leaves it out.
      if (only.has("cold") || reuse) J.skip(COLD_CREATE_STEP, reuse ? "--machine" : "--skip cold");
      else {
        await J.step(COLD_CREATE_STEP, async () => {
          const v = await api.op("cloud.machine.create", { name: `${machineName} cold`, size: COLD_CREATE_SIZE }, `${tag}-cold-create`);
          const id = v.machine.id as string;
          const spare = spareFields(v);
          try {
            const m = await waitMachine(api, id, (x) => x.status === "running" && Boolean(x.host), 300_000);
            const r = await directExec(api, id, J)(SIZE_READ);
            if (r.code !== 0 || !r.stdout.includes("journey-ok")) throw new Error(`${id}: exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
            const reading = r.stdout.trim().split("\n").slice(2).join(" ");
            const listed = m.size ? ` listed size=${m.size.cpu ?? "?"}/${m.size.memory_mb ?? "?"}/${m.size.disk_mb ?? "?"}` : "";
            const asked = `asked ${COLD_CREATE_SIZE.cpu}/${COLD_CREATE_SIZE.memory_mb}/${COLD_CREATE_SIZE.disk_mb}`;
            const why = sizeReadingProblem(r.stdout, COLD_CREATE_SIZE);
            if (why) throw new Error(`${id} ${asked}: ${why}${listed}`);
            return { value: null, detail: `${id} ${asked}: ${reading}${listed}; spare fallback ${spare.spare_fallback ?? "none"}` };
          } finally {
            await api.deleteMachine(id, `${tag}-cold-delete`).catch((e) => console.log(`cold create: delete ${id} failed: ${String((e as Error)?.message ?? e).slice(0, 200)}`));
          }
          // Recorded as failed, and the run fails on it, but the checks after it still run.
        }).catch(() => undefined);
      }
      // What the machine booted and what its agents reach their model with, so a reply that fails ("Not logged in")
      // names the image, the daemon and the model plane in the same log: the image the platform recorded, acpmux's and
      // cmux-tui's versions, and each model-plane file's CMUX_CODEROUTER_URL origin (a URL, no credential) and which
      // CMUX_CLAUDE_TEAM_* names it sets (names only). Never fails the journey.
      const factsAt = Date.now();
      try {
        const image = (bound as { image?: Record<string, unknown> } | null)?.image ?? (created as { image?: Record<string, unknown> }).image ?? {};
        const r = await exec([
          `echo "acpmux=$(acpmux --version 2>/dev/null | head -1) cmux-tui=$(cmux-tui --version 2>/dev/null | head -1)"`,
          `for f in /etc/cmux/model-plane.env "$HOME/.config/cmux/model-plane.env"; do if [ -f "$f" ]; then u=$(sed -n 's/^\\(export \\)\\{0,1\\}CMUX_CODEROUTER_URL=//p' "$f" | tr -d "\\"'" | sed -E 's#^(https?://[^/]+).*#\\1#' | head -1); t=$(grep -oE '^(export )?CMUX_CLAUDE_TEAM_[A-Z_]+' "$f" | sed 's/^export //' | tr '\\n' ','); echo "$f: CMUX_CODEROUTER_URL=\${u:-unset} team=\${t:-none}"; else echo "$f: absent"; fi; done`,
        ].join("; "));
        const facts = r.stdout.trim().split("\n").join(" | ");
        const imageFacts = JSON.stringify(image).slice(0, 300);
        J.record({ step: "machine facts", status: "pass", ms: Date.now() - factsAt, detail: `image ${imageFacts}; ${facts}`.slice(0, 600) });
      } catch (e) {
        J.record({ step: "machine facts", status: "skip", ms: Date.now() - factsAt, detail: `read failed: ${String((e as Error)?.message ?? e).slice(0, 300)}` });
      }

      await readGuestDiagnostics("journey-facts");
      // GitHub through the team's connection with no setup on the machine (HQ docs/design/remote-integrations.md).
      // First, from here, what the app's Set Up GitHub reads: the team's connection (GET /v1/integrations/github/status)
      // and its repository list (GET /v1/integrations/github/repos), counts only. Then
      // scripts/cmux-next/cloud-github-e2e.sh on the guest. The stub run (a stand-in minter and GitHub MCP server) checks
      // the wiring on every image whose acpmux has `github-mcp`; CMUX_JOURNEY_GITHUB_REPO=OWNER/REPO, a dedicated sandbox
      // repository the team's connection lists, adds the live cells (clone, branch, commit, push, a draft PR, its comments
      // and checks read, cleanup) and, with a real model, "GitHub by the agent (live)" after the chat. `--skip github`
      // leaves all of them out.
      if (!only.has("github")) {
        const sandbox = githubSandbox(process.env.CMUX_JOURNEY_GITHUB_REPO);
        const ghTeam = api.team ?? (typeof user?.personal_team === "string" ? user.personal_team : undefined);
        const statusAt = Date.now();
        try {
          const q = ghTeam ? `?team=${encodeURIComponent(ghTeam)}` : "";
          const s = await api.raw("GET", `/v1/integrations/github/status${q}`, undefined, 20_000);
          if (s.status !== 200) throw new Error(`status: HTTP ${s.status} ${short(s.body?.error ?? s.body)}`);
          const active = s.body?.connection?.status === "active";
          const listed = active ? await api.raw("GET", `/v1/integrations/github/repos${q}`, undefined, 20_000) : null;
          // The first page is bounded: the sandbox is looked up by name, across the list's cursors, when it is not on it.
          const first = listed?.status === 200 ? listed.body : null;
          const onFirst = sandbox && Array.isArray(first?.repos) && first.repos.some((r: unknown) => repoName(r).toLowerCase() === sandbox.toLowerCase());
          const lookup = active && sandbox && !onFirst ? await githubSandboxLookup((route) => api.raw("GET", route, undefined, 20_000), ghTeam, sandbox) : null;
          const facts = githubConnectionFacts(s.body, first, sandbox ?? undefined, lookup);
          const bad = sandbox ? githubConnectionBlocker(facts, sandbox) : null;
          const looked = lookup ? `; sandbox looked up in ${lookup.pages} page(s)${lookup.complete ? "" : " (list not ended)"}` : "";
          const detail = `${githubConnectionDetail(facts)}${listed && listed.status !== 200 ? `; repos: HTTP ${listed.status}` : ""}${looked}${bad ? `; ${bad}` : ""}`;
          J.record({ step: GITHUB_STATUS_STEP, status: bad ? "fail" : "pass", ms: Date.now() - statusAt, detail });
        } catch (e) {
          // A read the hourly stub run cannot make is recorded, never red; with a sandbox named it is the live cells' blocker.
          J.record({ step: GITHUB_STATUS_STEP, status: sandbox ? "fail" : "skip", ms: Date.now() - statusAt, detail: String((e as Error)?.message ?? e).slice(0, 300) });
        }
        const file = GITHUB_E2E_GUEST;
        const wrote = await api.raw("POST", `/v1/cloud/machines/${created.id}/fs/write`, { path: file, dataBase64: readFileSync(GITHUB_E2E_SH).toString("base64"), mode: 0o755 });
        githubScriptOnGuest = wrote.status >= 200 && wrote.status < 300 && wrote.body?.ok !== false;
        const has = githubScriptOnGuest
          ? await exec(`${GUEST}a="$c acp"; command -v acpmux >/dev/null && a=acpmux; : | timeout 20 $a github-mcp >/dev/null 2>&1; echo "@@has $?"`)
          : null;
        if (!has || !/@@has 0/.test(has.stdout)) {
          J.skip("GitHub on the machine (stub)", has ? "this image's acpmux has no github-mcp yet (it predates the change)" : `fs/write: HTTP ${wrote.status}`);
        } else {
          await J.step("GitHub on the machine (stub)", async () => {
            const r = await exec(`${GUEST}sh ${shq(file)} --stub 2>&1`, 180_000);
            if (r.code !== 0) throw new Error(`exit ${r.code} ${r.stdout.slice(-400)}`);
            return { value: null, detail: e2eLines(r.stdout) };
            // Its FAIL stays on the record, as the live cell's does, but no longer ends the machine's later steps
            // (connect, the carrier dial, the cmux-autocloud chat).
          }).catch(() => undefined);
        }
        // The live cells need only the script on the machine: an image with no github-mcp fails the mcp_call cell alone.
        if (!sandbox) J.skip("GitHub on the machine (live)", process.env.CMUX_JOURNEY_GITHUB_REPO?.trim() ? "CMUX_JOURNEY_GITHUB_REPO must be OWNER/REPO" : "CMUX_JOURNEY_GITHUB_REPO is not set");
        else if (!githubScriptOnGuest) J.skip("GitHub on the machine (live)", `fs/write: HTTP ${wrote.status}`);
        else await J.step("GitHub on the machine (live)", async () => {
          const r = await exec(`${GUEST}sh ${shq(file)} ${shq(sandbox)} 2>&1`, 300_000);
          if (r.code !== 0) throw new Error(`exit ${r.code} ${e2eLines(r.stdout) || r.stdout.slice(-600)}`);
          return { value: null, detail: e2eLines(r.stdout) };
        }).catch(() => undefined);
      }
    };
    runJourneyOnly = journeyOnly;

    if (desktopLink) {
      // A readback run ends here, before any login or first text: it keeps its old order, the checks first.
      await journeyOnly();
      // The team the platform decides rd_link for: --team, else the account's personal team (user.ensure).
      const acting = team ?? (typeof user?.personal_team === "string" ? user.personal_team : null);
      const named = teamIdsIn(user, created, bound);
      console.log(`desktop link: team ${acting ?? "?"} (team ids named by user.ensure and the machine: ${named.join(", ") || "none"})`);
      J.record({ step: "desktop link: account team", status: acting ? "pass" : "skip", ms: 0, detail: `${acting ?? "not named"}; named: ${named.join(", ") || "none"}` });
      await J.step("desktop link (carrier dial --service desktop)", async () => {
        let run: DesktopLinkRun | null = null;
        // A desktop that is not up yet (a refused or failed dial with no link note) gets two more tries.
        for (let attempt = 1; attempt <= 3; attempt++) {
          run = await desktopLinkDial(cmux!, api, created.id);
          if (run.lines.length || !run.error) break;
          console.log(`desktop link: attempt ${attempt}: ${run.error}`);
          if (attempt < 3) await sleep(10_000);
        }
        const r = run!;
        const lines = r.lines.map(maskAddresses);
        for (const l of lines) console.log(l);
        const verdict = desktopLinkVerdict(r.lines);
        if (outDir) {
          writeFileSync(path.join(outDir, "desktop-link.json"), `${JSON.stringify({
            api: backend.api,
            backend: backend.name,
            machine: created.id,
            team: acting,
            team_ids_named: named,
            status: r.status,
            error: r.error,
            controls: r.controls.slice(0, 20),
            datagrams: r.datagrams,
            ms: r.ms,
            lines,
            up: verdict.up,
            why: verdict.why,
            // rd_link.rs logs `up` with no candidate pair: which path won (direct or STUN srflx) is not in the CLI's log.
            path: "not logged by cmux carrier dial (its `up` note names no candidate pair)",
          }, null, 2)}\n`);
        }
        if (!verdict.up) throw new Error(`${verdict.why}${r.error ? ` (${r.error})` : ""}; controls ${r.controls.slice(0, 8).join(", ") || "none"}`);
        return { value: null, detail: `${verdict.why}; ${lines.length} desktop_link lines, ${r.datagrams} datagrams, controls ${r.controls.slice(0, 8).join(", ")}, ${r.ms} ms` };
      }).catch(() => undefined);
      // The host's side, if its journal says more about the link (cmux-agent-rd.service); never fails the run.
      const t0 = Date.now();
      const journal = await exec(`{ sudo -n journalctl -u cmux-agent-rd.service --no-pager -o cat --since '15 min ago' 2>/dev/null || journalctl -u cmux-agent-rd.service --no-pager -o cat --since '15 min ago' 2>&1; } | grep -iE 'link|stun|srflx|candidate|udp' | tail -n 20`).catch((e: Error) => ({ code: -1, stdout: "", stderr: e.message }));
      const hostLines = maskAddresses(journal.stdout.trim()).split("\n").filter(Boolean);
      for (const l of hostLines) console.log(`host: ${l}`);
      J.record({ step: "desktop link: host journal", status: "skip", ms: Date.now() - t0, detail: hostLines.join("; ").slice(0, 900) || `no link lines (exit ${journal.code} ${journal.stderr.slice(-200)})` });
      // The readback is the whole run: the machine is deleted by the cleanup below.
      throw new Error("desktop link readback done");
    }

    if (keyedStart) {
      await J.step("keyed acpmux start holds", async () => {
        const status = async () => {
          const r = await exec(`${GUEST}"$c" acp --json daemon status 2>&1`);
          try { return JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))); } catch { return { raw: r.stdout.slice(-200) }; }
        };
        const r = await keyedAcpmuxStart(api, created.id, J.secrets);
        if (!r.ok) throw new Error(`keyed-start: ${r.detail}`);
        // acpmux.service is Restart=always with RestartSec=3: a unit the prepare step did not stop is back by now.
        await sleep(KEYED_SETTLE_MS);
        const after = await status();
        const why = keyedHoldProblem(r.personInstance, after);
        if (why) throw new Error(why);
        return { value: null, detail: `the keyed daemon still serves ${KEYED_SETTLE_MS / 1000} s later (pid ${after.pid ?? "?"})` };
      });
    }

    const gwLog = "/home/cmux/.cache/cmux/inference-gateway.log";
    const gwStubLog = "/home/cmux/.cmux/gateway-proxy-stub.log";
    let gwExec: Exec | null = null;
    // The stub's URL on the gateway machine (--gateway with the stub), for the hop cost.
    let gwStubUrl: string | null = null;
    if (gatewayCmux) {
      const g = await J.step("gateway machine", async () => {
        const v = await api.op("cloud.machine.create", { name: `${machineName} gateway`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-gw-create`);
        gatewayMachine = v.machine.id as string;
        const m = await waitMachine(api, gatewayMachine, (x) => x.status === "running" && Boolean(x.host), 300_000);
        return { value: m, detail: `${gatewayMachine}, daemon ${m.image?.daemon_version ?? "?"}` };
      });
      gwExec = directExec(api, g.id, J);
      let upstream = gatewayUpstream;
      if (gatewayStub) {
        // The person's own proxy, as they would run it on their gateway machine: here the shared model stub.
        upstream = await J.step("the person's proxy on the gateway machine (stub)", async () => {
          const file = "/home/cmux/.cmux/gateway-proxy-stub.py";
          const script = "/home/cmux/.cmux/gateway-proxy-stub.json";
          const ready = "/home/cmux/.cmux/gateway-proxy-stub.ready";
          for (const [p, data] of [[file, readFileSync(MODEL_STUB_PY)], [script, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
            const w = await api.raw("POST", `/v1/cloud/machines/${g.id}/fs/write`, { path: p, dataBase64: data.toString("base64"), mode: 0o644 });
            if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${p}: HTTP ${w.status} ${short(w.body?.error?.code ?? "")}`);
          }
          const r = await gwExec!(
            `mkdir -p /home/cmux/.cmux; rm -f ${shq(gwStubLog)} ${shq(ready)}; (nohup python3 ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(nonce)} --log ${shq(gwStubLog)} --ready-file ${shq(ready)} >${shq(gwStubLog)}.out 2>&1 &); ` +
              `for i in $(seq 50); do [ -s ${shq(ready)} ] && break; sleep 0.2; done; ` +
              `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${shq(ready)} 2>/dev/null); ` +
              `[ -n "$port" ] && echo "@@port $port" || { echo stub-down; tail -5 ${shq(gwStubLog)}.out; exit 1; }`,
          );
          const port = /@@port (\d+)/.exec(r.stdout)?.[1];
          if (!port) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)}`);
          return { value: `http://127.0.0.1:${port}`, detail: `the model stub at 127.0.0.1:${port} on the gateway machine, nonce ${nonce}` };
        });
        gwStubUrl = upstream;
      }
      await J.step("cmux inference setup (gateway machine)", async () => {
        const dir = mkdtempSync(path.join(tmpdir(), "cmux-gw-"));
        const tokenFile = path.join(dir, "token");
        writeFileSync(tokenFile, install.token, { mode: 0o600 });
        try {
          const args = ["inference", "setup", "--machine", created.id, "--gateway-machine", g.id, "--upstream", upstream, "--path", "gateway", "--api", backend.api, "--token-file", tokenFile];
          if (team) args.push("--team", team);
          const r = spawnSync(gatewayCmux, args, { encoding: "utf8", timeout: 600_000, env: { PATH: process.env.PATH ?? "", HOME: dir } });
          const out = scrub(`${r.stdout ?? ""}${r.stderr ?? ""}`, J.secrets);
          if (r.status !== 0 || !out.includes("Path: gateway")) throw new Error(`exit ${r.status}: ${headTail(out)}`);
          return { value: null, detail: out.trim().split("\n").filter((l) => l.startsWith("Path:") || l.startsWith("This machine")).join(" ").slice(0, 300) };
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      });
    }

    if (gatewayLocal) {
      await J.step("cmux inference gateway (this computer)", async () => {
        const dir = mkdtempSync(path.join(tmpdir(), "cmux-gw-local-"));
        localGatewayDir = dir;
        const tokenFile = path.join(dir, "token");
        writeFileSync(tokenFile, install.token, { mode: 0o600 });
        const log = path.join(dir, "gateway.log");
        const args = ["inference", "gateway", "--api", backend.api, "--upstream", gatewayUpstream, "--token-file", tokenFile];
        if (team) args.push("--team", team);
        const out = openSync(log, "a");
        const child = spawn(gatewayLocal, args, { stdio: ["ignore", out, out], env: { PATH: process.env.PATH ?? "", HOME: dir } });
        localGateway = child;
        closeSync(out);
        const t0 = Date.now();
        while (Date.now() - t0 < 60_000) {
          const g = await installApi.raw("GET", "/v1/cloud/inference-gateway");
          if (g.body?.gateway?.online === true) return { value: null, detail: `online in ${Math.round((Date.now() - t0) / 1000)} s, in front of ${gatewayUpstream}` };
          if (child.exitCode !== null) break;
          await sleep(1_000);
        }
        throw new Error(`the gateway did not come online: ${scrub(readFileSync(log, "utf8"), J.secrets).slice(-600)}`);
      });
      await J.step("cmux inference setup (this computer's gateway)", async () => {
        const dir = mkdtempSync(path.join(tmpdir(), "cmux-gw-"));
        const tokenFile = path.join(dir, "token");
        writeFileSync(tokenFile, install.token, { mode: 0o600 });
        try {
          const args = ["inference", "setup", "--machine", created.id, "--path", "gateway", "--api", backend.api, "--token-file", tokenFile];
          if (team) args.push("--team", team);
          const r = spawnSync(gatewayLocal, args, { encoding: "utf8", timeout: 600_000, env: { PATH: process.env.PATH ?? "", HOME: dir } });
          const out = scrub(`${r.stdout ?? ""}${r.stderr ?? ""}`, J.secrets);
          if (r.status !== 0 || !out.includes("Path: gateway")) throw new Error(`exit ${r.status}: ${headTail(out)}`);
          return { value: null, detail: out.trim().split("\n").filter((l) => l.startsWith("Path:") || l.startsWith("This machine")).join(" ").slice(0, 300) };
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      });
    }

    J.firstText.mark("login");
    if (gatewayAny) {
      J.skip(loginStep, "--gateway: the chat machine gets no login; its model calls go to the team's gateway");
    } else if (!provider || only.has("chat") || only.has("login")) {
      J.skip(loginStep, !provider ? `agent ${agent}` : "--skip");
    } else if (!login) {
      J.skip(loginStep, provider === "codex" ? "no CODEX_AUTH_JSON: the reply needs the person's Codex login on the machine" : "no CLAUDE_CODE_OAUTH_TOKEN: the reply needs the person's Claude login on the machine");
    } else if (loginPathAfterClaim({ receipt: Boolean(prepared?.spare === created.id && preclaimLoginCmux && preclaimStateDir && await spareLoginReceipt(preclaimLoginCmux, api, preclaimStateDir, install.token, prepared!, created.id)), launchCredential, launchOnMiss }) === "receipt") {
      // The claim handed out the spare whose login was copied on spare.ready, and its receipt says installed. The app
      // reads that receipt from its own ledger (spare_warm.rs login_receipt, no machine call) and starts the agent;
      // it runs no launcher check on the machine. So the journey's check that the launcher sees the login (one
      // machine exec, ~1.6 s in stub leg 45298742268) runs after first text, outside create_to_first_text_ms.
      probeExtra.login_path = "receipt";
      await J.step(loginStep, async () => ({ value: null, detail: "the person's own login, copied on spare.ready (receipt installed); the launcher check runs after first text" }));
      const loginProvider = provider;
      afterFirstText = async () => {
        await J.step("login seen by the launcher", async () => {
          const own = await exec(`. /etc/cmux/agent-auth.sh >/dev/null 2>&1 && HOME=/home/cmux cmux_agent_has_own_login ${loginProvider} && echo own-login`);
          if (!own.stdout.includes("own-login")) throw new Error(`the receipt says installed, but the image's launcher does not see an own ${loginProvider} login`);
          return { value: null, detail: "the launcher picks the login copied on spare.ready" };
        });
      };
    } else if (launchCredential || launchOnMiss) {
      launchCredential = true;
      // cmux#40159: a Cloud chat runs on the person's model connection, given to that chat's agent when it starts; the
      // machine holds no login. The login goes with the agent's start below (launchCredentialStartProgram). A login
      // written onto the machine is outranked there by the machine's model route (acpmux cloud_model_plane.rs fills
      // ANTHROPIC_API_KEY with its placeholder for every spawn), so the stub step could not prove which one Claude used.
      probeExtra.login_path = "launch";
      await J.step(loginStep, async () => {
        if (!validLogin(provider, login)) throw new Error("CLAUDE_CODE_OAUTH_TOKEN is not a `claude setup-token` login");
        return { value: null, detail: "the person's model connection, given to the agent at its start (cmux#40159)" };
      });
      // Whether the machine also holds a login of its own is a report, not a step the app takes: one machine exec,
      // read after first text so it stays outside create_to_first_text_ms.
      const loginProvider = provider;
      afterFirstText = async () => {
        await J.step("machine's own login", async () => {
          const own = await exec(`. /etc/cmux/agent-auth.sh >/dev/null 2>&1 && HOME=/home/cmux cmux_agent_has_own_login ${loginProvider} && echo own-login`);
          return { value: null, detail: own.stdout.includes("own-login") ? "the machine also holds a Claude login of its own" : "the machine holds none" };
        });
      };
    } else {
      probeExtra.login_path = "copy";
      // The journey's own login install on a Worker machines client: preflight (which also makes and checks the staging
      // folder as the work user), stage (fs/write as root puts the file in 0644), install, each through the routes the app uses.
      await J.step(loginStep, async () => {
        if (!validLogin(provider, login)) throw new Error(provider === "codex" ? "CODEX_AUTH_JSON is not a Codex ChatGPT sign-in (auth.json with tokens)" : "CLAUDE_CODE_OAUTH_TOKEN is not a `claude setup-token` login");
        // On a team machine the journey is its creator and copies as a DEV or nightly build does (Release copies
        // only to an owner machine).
        const programs = loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), provider, Boolean(team));
        const pre = await waitPreflight(exec, programs.preflight, team ? "owner or team" : "owner");
        const folder = "/home/cmux/.cmux/credential-transfer"; // made and checked by the preflight that just passed
        const file = `${folder}/${randomUUID().toUpperCase()}.json`;
        try {
          const w = await api.raw("POST", `/v1/cloud/machines/${created.id}/fs/write`, { path: file, dataBase64: Buffer.from(login).toString("base64"), mode: 0o644 });
          if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write: HTTP ${w.status} ${short(w.body?.error?.code ?? "")}`);
          const done = await exec(programs.install(file));
          if (done.code !== 0) throw new Error(`installer exit ${done.code}`); // its output is never shown: it may name the token
        } catch (error) {
          // As the transfer does: a failed delivery leaves no second readable copy on the machine.
          await exec(`rm -f -- ${shq(file)}`).catch(() => null);
          throw error;
        }
        const own = await exec(`. /etc/cmux/agent-auth.sh >/dev/null 2>&1 && HOME=/home/cmux cmux_agent_has_own_login ${provider} && echo own-login`);
        if (!own.stdout.includes("own-login")) throw new Error(`installed, but the image's launcher does not see an own ${provider} login`);
        const waited = pre.tries > 1 ? ` (preflight passed on try ${pre.tries}, after ${Math.round(pre.waitedMs / 1000)} s)` : "";
        return { value: null, detail: `the person's own login, written by the app's installer; the launcher picks it${waited}` };
      });
    }

    J.firstText.mark("login_ready");
    if (provider === "codex") {
      // Codex spawns codex-code-mode-host from beside its real executable for each tool call; an image whose codex came
      // from a release tarball (codex alone) started every chat and failed every tool call (2026-11-25). The stub's
      // plain exec_command turn never spawns the host, so the journey checks the file itself.
      await J.step("Codex has its code-mode host", async () => {
        const r = await exec(
          `p=$(bash -lc 'command -v codex' 2>/dev/null </dev/null); [ -n "$p" ] || p=/opt/cmux/current/bin/codex; ` +
            `r=$(readlink -f "$p"); h="$(dirname "$r")/codex-code-mode-host"; ` +
            `if [ -x "$h" ]; then echo "@@host $h"; else echo "@@missing $r"; fi`,
        );
        const host = /@@host (\S+)/.exec(r.stdout)?.[1];
        if (!host) throw new Error(`failed to spawn code-mode host: no codex-code-mode-host beside ${/@@missing (\S*)/.exec(r.stdout)?.[1] || "codex"} (exit ${r.code} ${r.stderr.slice(-200)})`);
        return { value: null, detail: host };
      });
    }
    if (gatewayStub && provider === "codex" && !only.has("chat")) {
      // The stub lists no models, and with the image's default model slug Codex sends it no tools (codex-cli 0.164
      // against the stub: tools=0 with the default, 9 with "stub-model"), so the turn gets the stub's side reply
      // (gateway-e2e runs 7 and 8). Name the stub's model, as the --model stub path does; the provider stays the
      // image's `cmux` (edge, placeholder key), so the call still goes through the gateway.
      await J.step("Codex names the stub's model", async () => {
        const r = await exec(
          `bash -lc true >/dev/null 2>&1 </dev/null; f=/home/cmux/.codex/config.toml; ` +
            `python3 -I - "$f" <<'PY'\nimport pathlib, re, sys\np = pathlib.Path(sys.argv[1])\nlines = p.read_text().splitlines() if p.exists() else []\n` +
            `head = next((i for i, l in enumerate(lines) if re.match(r"\\s*\\[", l)), len(lines))\n` +
            `lines = [l for i, l in enumerate(lines) if i >= head or not re.match(r"\\s*model\\s*=", l)]\n` +
            `p.write_text("\\n".join(['model = "stub-model"'] + lines) + "\\n")\nPY\n` +
            `grep -q '^model = "stub-model"' "$f" && grep -q '^model_provider = "cmux"' "$f" && echo model-set`,
        );
        if (!r.stdout.includes("model-set")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
        return { value: null, detail: 'model = "stub-model"; model_provider stays "cmux" (the edge, the placeholder key)' };
      });
    }
    const stubLog = "/home/cmux/.cmux/journey-model-stub.log";
    if (modelStub && provider && !only.has("chat")) {
      // The stub listens on the machine's loopback only; the harness's own settings point it there, after the login
      // copy (whose installer refuses a custom endpoint), so the forwarded login is sent nowhere but the stub:
      // Claude Code's settings.json ANTHROPIC_BASE_URL, or a Codex model provider that uses the ChatGPT sign-in (CODEX_STUB_CONFIG).
      await J.step("model stub on the machine", async () => {
        const file = "/home/cmux/.cmux/journey-model-stub.py";
        const script = "/home/cmux/.cmux/journey-model-stub.json";
        const ready = "/home/cmux/.cmux/journey-model-stub.ready";
        const pidFile = "/home/cmux/.cmux/journey-model-stub.pid";
        for (const [path, data] of [[file, readFileSync(MODEL_STUB_PY)], [script, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
          const w = await api.raw("POST", `/v1/cloud/machines/${created.id}/fs/write`, { path, dataBase64: data.toString("base64"), mode: 0o644 });
          if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${path}: HTTP ${w.status} ${short(w.body?.error?.code ?? "")}`);
        }
        // Port 0: the stub binds a free port and writes it to the ready file.
        const point = provider === "codex"
          ? `python3 - "$port" <<'PY'\n${CODEX_STUB_CONFIG}\nPY`
          : `python3 - "$port" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\nc = json.loads(p.read_text()) if p.exists() else {}\nc.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\np.write_text(json.dumps(c))\nd = pathlib.Path('/home/cmux/.config/cmux/agent-auth')\nd.mkdir(parents=True, exist_ok=True)\n(d / 'claude').write_text('own\\n')\nprint('stub-ready')\nPY`;
        const r = await exec(
          `rm -f ${shq(stubLog)} ${shq(ready)} ${shq(pidFile)}; (nohup python3 ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(nonce)} --log ${shq(stubLog)} --ready-file ${shq(ready)} >${shq(stubLog)}.out 2>&1 & echo $! >${shq(pidFile)}); ` +
            `for i in $(seq 50); do [ -s ${shq(ready)} ] && break; sleep 0.2; done; ` +
            `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${shq(ready)} 2>/dev/null); ` +
            `[ -n "$port" ] && curl -fsS -m 2 "http://127.0.0.1:$port/__stub/info" | grep -q ${shq(nonce)} || { echo stub-down; tail -5 ${shq(stubLog)}.out; exit 1; }; ` +
            `echo "@@port $port"; ` + point,
        );
        if (!r.stdout.includes("stub-ready")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
        const port = /@@port (\d+)/.exec(r.stdout)?.[1];
        return { value: null, detail: `the shared model stub at 127.0.0.1:${port}, nonce ${nonce}, one shell tool round trip (${provider})` };
      });
    }
    let session = `journey-${tag}`;
    let claimedBefore: Set<string> | null = null;
    // One turn's reply: the session's last message once `acp wait` says the turn ended, or the turn's own error.
    const awaitReply = async (): Promise<string> => {
      const t0 = Date.now();
      let last = "";
      while (Date.now() - t0 < chatBudget) {
        const r = await exec(`${GUEST}"$c" acp wait ${shq(session)} --timeout 20 >/dev/null 2>&1; echo "@@wait $?"; "$c" acp last ${shq(session)} 2>&1; echo "@@lastexit $?"`, 45_000);
        const wait = /@@wait (\d+)/.exec(r.stdout)?.[1];
        last = r.stdout.replace(/@@wait \d+\n?/, "").replace(/@@lastexit \d+\s*$/, "").trim();
        if (wait === "0" && last) return last;
        if (wait === "2") throw new Error(`the agent waits on a permission: ${last.slice(-200)}`);
        if (wait && wait !== "3" && wait !== "0") {
          throw new Error(`acp wait exit ${wait}: ${await failedTurnWhy(exec, session, last)}`);
        }
      }
      throw new Error(`no reply within ${chatBudget / 1000} s; last: ${last.slice(-300)}`);
    };
    const send = async (text: string): Promise<number | null> => {
      const r = await exec(guestTimed(`${GUEST}printf '%s' ${shq(text)} | "$c" acp send --no-wait ${shq(session)} - 2>&1; echo "@@exit $?"`), 60_000);
      if (!/@@exit 0/.test(r.stdout)) throw new Error(r.stdout.slice(-400) || r.stderr.slice(-400));
      return guestMs(r.stdout);
    };
    // The model requests the stub logged for real turns (streamed, not a title or topic side request).
    const stubTurns = async (): Promise<any[]> => {
      const r = await exec(`cat ${shq(stubLog)} 2>/dev/null`);
      return r.stdout.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .filter((x: any) => x && x.method === "POST" && x.stream && !x.side);
    };
    // A later turn in the same session. With the stub, a request's step is the number of tool results already in the
    // conversation: the first request of this turn at step >= 1 proves the session still holds turn 1 (its tool
    // result), where a fresh conversation would start at step 0.
    // `send --no-wait` returns once the prompt is queued, so `acp wait` right after it can still see the session idle
    // and `acp last` would read the previous turn's reply. Each later turn's prompt starts with its own marker, and its
    // reply is read only once `acp history` lists a turn with that prompt (the turn started; history keeps a prompt's
    // first 120 characters). `acp wait --match` cannot see it: it leaves the person's own prompts out.
    let turns = 0;
    const turnStarted = async (marker: string) => {
      const t0 = Date.now();
      while (Date.now() - t0 < chatBudget) {
        const r = await exec(`${GUEST}"$c" acp --json history ${shq(session)} --limit 5 2>&1`, 45_000);
        let listed: any[] = [];
        try { listed = JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))).turns ?? []; } catch { /* not yet readable */ }
        if (listed.some((t: any) => typeof t?.prompt === "string" && t.prompt.startsWith(marker))) return;
        await sleep(2_000);
      }
      throw new Error(`the turn's prompt did not reach the session within ${chatBudget / 1000} s`);
    };
    const laterTurn = async (text: string): Promise<{ value: null; detail: string }> => {
      const before = modelStub ? (await stubTurns()).length : 0;
      const marker = `[journey turn ${tag}-${++turns}]`;
      await send(`${marker} ${text}`);
      await turnStarted(marker);
      const last = await awaitReply();
      if (!modelStub) return { value: null, detail: last.slice(0, 280) };
      if (!last.includes(`Stub reply ${nonce}.`)) throw new Error(`the reply does not carry the stub's nonce ${nonce}: ${last.slice(-200)}`);
      const fresh = (await stubTurns()).slice(before);
      if (!fresh.length) throw new Error("the reply came back but the stub logged no model request for this turn");
      if (!(fresh[0].step >= 1)) throw new Error(`this turn's first model request is at step ${fresh[0].step}: the session lost the earlier turns`);
      return { value: null, detail: `${last.slice(0, 120)} (model request at step ${fresh[0].step}: the earlier turns came along)` };
    };
    // An agent with no login to pass (OpenCode on its free Zen models) gets the later turns with --lifecycle.
    const lifecycle = (provider || argv.includes("--lifecycle")) && !gatewayAny && !only.has("chat") && !only.has("lifecycle") && startVia !== "app" && homeChat !== "reserved";
    if (homeChat === "reserved") {
      try {
        const before = await exec(`${GUEST}${CLAIMED_MARKERS_COMMAND}`);
        if (before.code === 0) claimedBefore = new Set(parseClaimedMarkers(before.stdout));
        else J.record({ step: "reserved home marker baseline", status: "skip", ms: 0, detail: `could not read ~/chats/.claimed-* before start (exit ${before.code})` });
      } catch (error) {
        J.record({ step: "reserved home marker baseline", status: "skip", ms: 0, detail: `could not read ~/chats/.claimed-* before start: ${String((error as Error)?.message ?? error).slice(0, 240)}` });
      }
    }
    const recordReservedMarker = async () => {
      const markerStarted = Date.now();
      try {
        if (claimedBefore === null) {
          probeExtra.reserved_hit = false;
          J.record({ step: "reserved home marker", status: "skip", ms: Date.now() - markerStarted, detail: "reserved_hit=false (marker baseline was unavailable)", fields: { reserved_hit: false } });
        } else {
          const after = await exec(`${GUEST}${CLAIMED_MARKERS_COMMAND}`);
          if (after.code !== 0) {
            probeExtra.reserved_hit = false;
            J.record({ step: "reserved home marker", status: "skip", ms: Date.now() - markerStarted, detail: `reserved_hit=false (marker read exit ${after.code})`, fields: { reserved_hit: false } });
          } else {
            const hit = parseClaimedMarkers(after.stdout).some((marker) => !claimedBefore!.has(marker));
            probeExtra.reserved_hit = hit;
            J.record({ step: "reserved home marker", status: "pass", ms: Date.now() - markerStarted, detail: `reserved_hit=${hit}`, fields: { reserved_hit: hit } });
          }
        }
      } catch (error) {
        probeExtra.reserved_hit = false;
        J.record({ step: "reserved home marker", status: "skip", ms: Date.now() - markerStarted, detail: `reserved_hit=false (marker read failed: ${String((error as Error)?.message ?? error).slice(0, 240)})`, fields: { reserved_hit: false } });
      }
      probeExtra.reserved_hit ??= false;
    };
    if (only.has("chat")) {
      J.skip("start agent", "--skip chat");
      await journeyOnly();
    } else if (homeChat === "reserved") {
      J.firstText.mark("session_start");
      let reservedChat: ChatClient | null = null;
      let started = false;
      await J.step(`start agent (${agent})`, async () => {
        const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
        reservedChat = new ChatClient({
          cmux: cmux!, machine: created.id, team: api.team, exec, guest: GUEST, session, tag, harness: agent,
          // The reserved home start deliberately carries no model credentials. The login was copied to the keyed spare.
          env: { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer },
          log: (line) => console.log(scrub(line, J.secrets)),
        });
        await reservedChat.openTab(agent);
        // Attached before the send, as the app is: a bare start leaves the tab unattached and the send is refused.
        const reply = await reservedChat.startAttached(agent);
        const outcome = appStartDetail(reply);
        if (!outcome.ok) throw new Error(outcome.detail);
        session = String(reply?.data?.session ?? "");
        if (!session) throw new Error(`started with no session: ${JSON.stringify(reply).slice(0, 200)}`);
        J.firstText.mark("session_ready");
        started = true;
        return { value: null, detail: `${outcome.detail}; no cwd or model credential on the start` };
      }).catch(() => undefined);
      if (!started) {
        reservedChat?.stop();
        J.skip("send chat", "reserved home start did not produce a session");
        J.skip("reply", "reserved home start did not produce a session");
        await recordReservedMarker();
      } else {
        firstTextObserver = observeFirstText(exec, session, chatBudget, J.firstText, (s) => J.record(s));
        try {
          // The stub's turn reads a file in the chat's own folder (journeyReadTurnScript): the chat runs under policy
          // `ask`, where a shell call waits for the person.
          let sendText = prompt;
          if (modelStub || gatewayStub) {
            sendText = await J.step("stub file in the chat's folder", async () => {
              const info = await exec(`${GUEST}"$c" acp session info ${shq(session)} --fields cwd 2>&1`, 45_000);
              const cwd = /^(?:cwd\t)?(\/\S*)$/m.exec(info.stdout)?.[1] ?? "";
              if (!cwd) throw new Error(`no cwd for ${session}: ${info.stdout.trim().slice(-200)}`);
              const w = await exec(journeyReadFileCommand(cwd, nonce), 45_000);
              const file = /@@file (\S+)/.exec(w.stdout)?.[1];
              if (!file) throw new Error(`exit ${w.code} ${w.stdout.slice(-200)} ${w.stderr.slice(-200)}`);
              return { value: journeyReadPrompt(prompt, file), detail: `${file} (a Read asks nobody under policy ask)` };
            });
          }
          await J.step("send chat", async () => {
            J.firstText.mark("send");
            await reservedChat!.prompt(sendText, undefined, Date.now() + chatBudget);
            J.firstText.mark("sent");
            return { value: null, detail: `${prompt.slice(0, 80)} (sent over the app's carrier chat)` };
          });
          await J.step("reply", async () => {
            const last = await awaitReply();
            if ((modelStub || gatewayStub) && !last.includes(`Stub reply ${nonce}. The tool printed ${nonce}-tool`)) {
              throw new Error(`the reply does not carry the stub's read of ${nonce}-tool: ${last.slice(-200)}`);
            }
            return { value: last, detail: last.slice(0, 280) };
          });
        } finally {
          reservedChat?.stop();
        }
        await firstTextObserver;
        await recordReservedMarker();
      }
    } else if (startVia === "app") {
      // The Cloud picker's start, as the app sends it: a chat tab on the machine, then agent-session-start with the
      // harness and the owner word. A started session passes; a refusal fails the step with its code and data.harness.
      await J.step(`start agent (${agent})`, async () => {
        const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
        const chat = new ChatClient({
          cmux: cmux!, machine: created.id, team: api.team, exec, guest: GUEST, session, tag, harness: agent,
          env: { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer },
          log: (line) => console.log(scrub(line, J.secrets)),
        });
        try {
          await chat.openTab(agent);
          const outcome = appStartDetail(await chat.start(agent));
          if (!outcome.ok) throw new Error(outcome.detail);
          return { value: null, detail: outcome.detail };
        } finally {
          chat.stop();
        }
      }).catch(() => undefined);
      for (const step of ["send chat", "reply"]) J.skip(step, "--start-via app: the cell judges the app's start");
    } else {
      // An owner machine's agents run on what their launch carries only once its kind record reads owner (OWNER_KIND_PROGRAM).
      if (provider && !team && !gatewayAny) {
        await J.step("machine kind owner", async () => {
          const k = await waitOwnerKind(exec);
          return { value: null, detail: k.tries === 1 ? "/etc/cmux/vm-kind reads owner" : `/etc/cmux/vm-kind read ${k.first}, owner after ${Math.round(k.waitedMs / 1000)} s (${k.tries} tries)` };
        });
      }
      J.firstText.mark("session_start");
      let promptedWithStart = false;
      await J.step(`start agent (${agent})`, async () => {
        if (launchCredential) {
          // The first prompt follows session/new on the same acpmux link, as the app's first send does.
          const r = await exec(guestTimed(`${GUEST}${launchCredentialStartProgram(session, agent, "CLAUDE_CODE_OAUTH_TOKEN", login, prompt, sendTrace.id)}`), 120_000);
          const id = /@@session (\S+)/.exec(r.stdout)?.[1];
          if (!id) throw new Error(scrub(r.stdout.slice(-400) || r.stderr.slice(-400), [login]));
          J.firstText.mark("session_ready");
          if (r.code !== 0 || !/@@prompted/.test(r.stdout)) throw new Error(`session ${session} started, but its first prompt was not taken: ${scrub(r.stdout.slice(-400) || r.stderr.slice(-400), [login])}`);
          promptedWithStart = true;
          // One exec carries both: send and sent fall at its return, after session_ready, as the trace's spans read them.
          J.firstText.mark("send");
          J.firstText.mark("sent");
          return { value: null, detail: `session ${session}, on the person's model connection (its launch credential); its first prompt went with the start${guestDetail(guestMs(r.stdout))}` };
        }
        const r = await exec(guestTimed(`${GUEST}"$c" acp ensure ${shq(session)} -m ${shq(agent)} --json 2>&1; echo "@@exit $?"`), 120_000);
        if (!/@@exit 0/.test(r.stdout)) throw new Error(r.stdout.slice(-400) || r.stderr.slice(-400));
        J.firstText.mark("session_ready");
        J.firstText.guest("harness_spawn", guestMs(r.stdout));
        return { value: null, detail: `session ${session}${guestDetail(guestMs(r.stdout))}` };
      });
      firstTextObserver = observeFirstText(exec, session, chatBudget, J.firstText, (s) => J.record(s));
      await J.step("send chat", async () => {
        if (promptedWithStart) return { value: null, detail: `${prompt.slice(0, 80)} (went with the agent's start, on its link)` };
        J.firstText.mark("send");
        const onGuest = await send(prompt);
        J.firstText.mark("sent");
        J.firstText.guest("request_sent", onGuest);
        return { value: null, detail: `${prompt.slice(0, 80)}${guestDetail(onGuest)}` };
      });
      await J.step("reply", async () => {
        const last = await awaitReply().catch(async (e: Error) => {
          // Through a gateway, or any Codex chat (the model-plane route a Codex chat with no login of its own takes):
          // say what the machine's Codex had to reach its model with, never only "no reply" (cloud chat matrix, 11-10).
          if (!gwExec && !gatewayLocal && provider !== "codex") throw e;
          // Through a gateway, what the chat machine's Codex had to reach the edge with: the model-plane files, the
          // machine kind and Codex's auth choice, the provider its config names, and whether a login shell and the
          // daemon carry the edge's base URL and key (the base URL as edge, other or unset; the key as set or not).
          const probe = [
            `ls /etc/cmux/model-plane.env "$HOME/.config/cmux/model-plane.env" /etc/profile.d/cmux-agents.sh 2>&1 | tr '\\n' ' '`,
            `echo "kind=$(cat /etc/cmux/vm-kind 2>/dev/null) codex-auth=$(cat "$HOME/.config/cmux/agent-auth/codex" 2>/dev/null)"`,
            `grep -nE '^(model_provider|profile) *=|^\\[model_providers' "$HOME/.codex/config.toml" 2>&1 | tr '\\n' ' '`,
            `bash -lc 'case "\${OPENAI_BASE_URL-}" in https://coderouter.cmux.internal*) b=edge ;; "") b=unset ;; *) b=other ;; esac; echo "login-shell: base=$b key=\${OPENAI_API_KEY:+set}"' 2>&1 | tail -1`,
            // acpmux reads the login shell with a 3 s limit and caches only the names of secret values: how long the
            // shell takes here, and what the daemon's login-env cache says (names and age only), show which side lost it.
            `s=$(date +%s%N); bash -l -i -c true >/dev/null 2>&1 < /dev/null; echo "login-shell-ms=$(( ($(date +%s%N) - s) / 1000000 ))"`,
            `for f in "$HOME/.acpmux/login-env.json" "$HOME/.cmux/acpmux/login-env.json"; do [ -f "$f" ] && python3 -I -c 'import json,sys,time; d=json.load(open(sys.argv[1])); print(sys.argv[1], "age_s=%s" % (int(time.time()) - int(d.get("savedAt") or 0)), "secret_names=%s" % ",".join(d.get("secretNames") or []))' "$f" 2>&1; done`,
            `grep -hoE '(login shell env|login env|imported login shell environment)[^"]{0,160}' "$HOME"/.acpmux/daemon.log "$HOME"/.cmux/acpmux/daemon.log 2>/dev/null | tail -3`,
            `for p in $(pgrep -u "$(id -u)" -f 'cmux-tui|acpmux' | head -3); do echo "pid $p: $(tr '\\0' '\\n' < /proc/$p/environ 2>/dev/null | grep -E '^OPENAI_(BASE_URL|API_KEY)=' | sed 's/=.*/=set/' | tr '\\n' ' ')"; done`,
            // The model plane itself, from the machine: status and time only, one bounded request each (a hung edge
            // reads as 000 after 15 s), with the machine's own base URL and key, never printed.
            `bash -lc 'm=$(grep -m1 -E "^model *=" "$HOME/.codex/config.toml" | cut -d\\" -f2); echo "codex model: \${m:-unset}"; for p in models responses; do if [ "$p" = models ]; then a=(); else a=(-H "content-type: application/json" -d "{\\"model\\":\\"\${m:-gpt-5}\\",\\"input\\":\\"ping\\"}"); fi; echo "edge $p: $(curl -sS -m 15 -o /dev/null -w "%{http_code} %{time_total}s" -H "authorization: Bearer \${OPENAI_API_KEY}" "\${a[@]}" "\${OPENAI_BASE_URL%/}/$p" 2>&1 | tail -c 160)"; done' 2>&1 | tail -3`,
            // Which codex the chat runs, and what the image's auth rules (agent-auth.sh) would pick for it here.
            `echo "codex: $(command -v codex) launcher=$([ -x /etc/cmux/codex ] && echo yes || echo no) running=$(ps -o args= -u "$(id -u)" | grep -E '(^|/)codex( |$)' | grep -v grep | head -1 | cut -c1-120)"`,
            `bash -lc '[ -f /etc/cmux/agent-auth.sh ] && . /etc/cmux/agent-auth.sh && cmux_agent_auth_resolve codex && echo "agent-auth codex: $cmux_agent_auth_mode ($cmux_agent_auth_reason)"' 2>&1 | tail -1`,
            // The session's own account of the turn: its last error or retry line (no prompt or reply text).
            `${GUEST}"$c" acp tail ${shq(session)} 2>&1 | grep -oE '"kind":"(turn_error|retry|error|status)"[^}]{0,300}' | tail -3`,
          ].join("; ");
          const d = await exec(probe).catch(() => null);
          throw new Error(`${e.message} (the chat machine: ${(d?.stdout ?? "unread").replace(/\n/g, "; ").slice(0, 1500)})`);
        });
        // The stub repeats the Bash output in its reply, so this also proves the tool ran and its output came back.
        if ((modelStub || gatewayStub) && !last.includes(`Stub reply ${nonce}. The tool printed ${nonce}-tool`)) {
          // Through the gateway, what the stub was sent: each request's path, whether it streamed, the tools it
          // offered and whether its body could be read (a side reply means no tools, or a body it could not parse).
          const rows = gatewayStub && gwExec ? (await gwExec(`cat ${shq(gwStubLog)} 2>/dev/null`).catch(() => null))?.stdout ?? "" : "";
          const seen = rows.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean)
            .map((x: any) => `${x.method} ${x.path} stream=${x.stream} tools=${(x.tools ?? []).length}${x.side ? " side" : ""}${x.unread_body !== undefined ? ` unread_body=${x.unread_body} encoding=${x.encoding || "none"}` : ""}`);
          throw new Error(`the reply does not carry the stub's nonce ${nonce} and the tool output: ${last.slice(-200)}${seen.length ? ` (the stub saw: ${seen.slice(-8).join("; ")})` : ""}`);
        }
        return { value: last, detail: last.slice(0, 280) };
      });
      await firstTextObserver;
      if (homeChat === "reserved") await recordReservedMarker();
      await afterFirstText?.();
      await journeyOnly();
      // `--agent claude/MODEL`: the session must run the model asked for. Read from what ran: the `model` of every
      // assistant message in the session's Claude transcript, never the reply's own words (a model gets them wrong
      // about itself) and never `acp session info`, whose record names the model asked for and lists every model
      // the harness offers (so it named the asked model even when a pooled agent ran another one: a second chat
      // on one machine asked claude-sonnet-5-5 and ran claude-haiku-5-5, and this step passed, 2026-11-10).
      if (askedModel && !modelStub && harness === "claude") {
        await J.step("session model", async () => ({ value: null, detail: await sessionModelVerdict(exec, session, askedModel) }));
        // Production 2026-11-10: a second chat on the same machine ran the model of the chat before it (acpmux served it
        // the pooled agent spawned on that model, cmux#40383). A chat on another model must run that model.
        await J.step("second chat's model (same machine)", async () => {
          const other = askedModel.includes("haiku") ? "claude-sonnet-5-5" : "claude-haiku-5-5";
          const second = `${session}-m2`;
          const r = await exec(`${GUEST}"$c" acp ensure ${shq(second)} -m ${shq(`${harness}/${other}`)} --json 2>&1; echo "@@exit $?"`, 120_000);
          if (!/@@exit 0\s*$/.test(r.stdout)) throw new Error(`acp ensure -m ${harness}/${other}: ${r.stdout.slice(-400)}`);
          // One turn, so its transcript names the model that answered it.
          const sent = await exec(`${GUEST}printf '%s' 'Reply with the word ok.' | "$c" acp send --no-wait ${shq(second)} - 2>&1; echo "@@exit $?"`, 60_000);
          if (!/@@exit 0\s*$/.test(sent.stdout)) throw new Error(`acp send to ${second}: ${sent.stdout.slice(-400)}`);
          const waited = await exec(`${GUEST}"$c" acp wait ${shq(second)} --timeout 120 >/dev/null 2>&1; echo "@@wait $?"`, 150_000);
          const wait = /@@wait (\d+)/.exec(waited.stdout)?.[1];
          if (wait !== "0") throw new Error(`the second chat's turn did not end cleanly (acp wait exit ${wait ?? "none"})`);
          return { value: null, detail: await sessionModelVerdict(exec, second, other) };
        });
      }
      if (modelStub && provider) {
        await J.step("stub: forwarded login and a tool round trip", async () => {
          const r = await exec(`cat ${shq(stubLog)} 2>/dev/null`);
          const rows = r.stdout.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
          // Every model request the harness made: streamed or not, count_tokens and title side requests too.
          const route = provider === "codex" ? "/v1/responses" : "/v1/messages";
          const turns = rows.filter((x: any) => x.method === "POST" && String(x.path).startsWith(route));
          const want = createHash("sha256").update(loginBearer(provider, login)).digest("hex");
          if (!turns.some((x: any) => x.stream && !x.side)) throw new Error(`${agent} sent the stub no streamed ${route} turn`);
          const judged = judgeStubCredentials(turns, want, launchCredential);
          if (judged.error) {
            const procs = (await exec(CREDENTIAL_PROCESSES_PROGRAM).catch(() => null))?.stdout.replace(/\n/g, "; ").slice(0, 900) ?? "unread";
            throw new Error(`${judged.error} (the forwarded credential did not reach ${agent}): ${credentialSeen(turns, want)} (processes: ${procs})`);
          }
          if (!turns.some((x: any) => x.step === 1 && x.tool_results >= 1)) throw new Error("no tool round trip: no request came back with the shell call's result");
          return { value: null, detail: `${judged.detail}; the shell call ran and its output came back` };
        });
      }
      if (gwExec || gatewayLocal) {
        await J.step("gateway: the call went through it", async () => {
          const route = provider === "claude" ? "/v1/messages" : "/v1/responses";
          const r = gwExec
            ? await gwExec(`cat ${shq(gwLog)} 2>/dev/null`)
            : { stdout: localGatewayDir ? readFileSync(path.join(localGatewayDir, "gateway.log"), "utf8") : "" };
          const line = r.stdout.split("\n").find((l) => l.includes(`${created.id} POST ${route}`) && / -> 200 /.test(l));
          if (!line) throw new Error(`no ${route} call from ${created.id} answered 200 in the gateway's log: ${r.stdout.slice(-400)}`);
          if (gatewayStub) {
            const s = await gwExec!(`cat ${shq(gwStubLog)} 2>/dev/null`);
            const rows = s.stdout.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
            if (!rows.some((x: any) => x.method === "POST" && String(x.path).startsWith(route) && x.stream)) throw new Error("the proxy on the gateway machine logged no streamed model request");
          }
          return { value: null, detail: `chat machine -> edge -> cmux -> ${gwExec ? "gateway machine" : "this computer's gateway"} -> proxy: ${line.replace(/^.*?: /, "").slice(0, 160)}` };
        });
        await J.step("the chat machine holds no login", async () => {
          const r = await exec(
            `H=/home/cmux; for f in "$H/.codex/auth.json" "$H/.claude/.credentials.json"; do [ -e "$f" ] && echo "has $f"; done; ` +
              `grep -qs CLAUDE_CODE_OAUTH_TOKEN "$H/.claude/settings.json" && echo "has CLAUDE_CODE_OAUTH_TOKEN"; ` +
              // Credential files only (JSON, TOML, env): Codex's bundled plugin docs under ~/.codex/.tmp mention
              // refresh tokens in prose (gateway-e2e run 42388544286).
              `grep -rlsE --include='*.json' --include='*.toml' --include='*.env' --exclude-dir=.tmp '"refresh_token"|sk-ant-oat' "$H/.codex" "$H/.claude" "$H/.config/cmux" 2>/dev/null | sed 's/^/has /'; echo "@@done"`,
          );
          if (!r.stdout.includes("@@done")) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
          const found = r.stdout.split("\n").filter((l) => l.startsWith("has "));
          if (found.length) throw new Error(`the chat machine holds a login: ${found.join(", ")}`);
          return { value: null, detail: "no ~/.codex/auth.json, no ~/.claude/.credentials.json, no OAuth or refresh token in the harness folders" };
        });
        if (gwExec && gwStubUrl) {
          const stubUrl: string = gwStubUrl;
          // What the gateway route costs a call (cmuxterm-hq#7415 F1): GET /v1/models, which the stub answers without
          // moving its script, from the chat machine through edge -> Worker -> team object -> gateway socket -> stub,
          // and from the gateway machine straight to the stub. One warm-up call each is not counted.
          await J.step("gateway: hop cost", async () => {
            const n = HOP_SAMPLES;
            // Each call's Server-Timing (cmux-platform InferenceGateway: the Worker's and the team object's spans) follows
            // its timing line as `hop-s <value>`; the stub sends none.
            const loop = (auth: string, url: string) =>
              `h=$(mktemp); for i in $(seq 0 ${n}); do curl -sS -o /dev/null -D "$h" -m 30 ${auth} -w 'hop-t %{http_code} %{time_starttransfer} %{time_total}' ${url}; echo " $?"; ` +
              `tr -d '\\r' < "$h" | awk 'tolower($0) ~ /^server-timing:/ { sub(/^[^:]*:[ \\t]*/, ""); print "hop-s " $0 }'; done; rm -f "$h"`;
            const via = await exec(`. ${VM_MODEL_PLANE_ENV} && ${loop(`-H "Authorization: Bearer $OPENAI_API_KEY"`, `"$OPENAI_BASE_URL/models"`)}`, 300_000);
            const direct = await gwExec!(loop("", shq(`${stubUrl}/v1/models`)), 300_000);
            const a = hopTimes(via.stdout, n);
            const b = hopTimes(direct.stdout, n);
            const result = { samples: n, gateway_path: a, direct: b, added_ms: { ttfb_p50: a.ttfb_p50 - b.ttfb_p50, total_p50: a.total_p50 - b.total_p50 }, by_hop_p50: hopSpans(via.stdout) };
            if (outDir) writeFileSync(path.join(outDir, "gateway-hop.json"), `${JSON.stringify(result, null, 2)}\n`);
            return {
              value: null,
              // The whole result, so the run's summary keeps it (the job uploads no artifact).
              detail: `the route adds ${result.added_ms.ttfb_p50} ms TTFB at p50` +
                (result.by_hop_p50
                  ? `, the team object's own hop ${result.by_hop_p50.object_hop} ms` +
                    (result.by_hop_p50.untimed ? ` (over ${result.by_hop_p50.calls} calls; ${result.by_hop_p50.untimed} came back without Server-Timing)` : "")
                  : " (no Server-Timing came back)") +
                `; ${JSON.stringify(result)}`,
            };
          });
        }
      }
      if (!lifecycle) {
        J.skip("turn 2 (same session)", only.has("lifecycle") ? "--skip lifecycle" : `agent ${agent}`);
        J.skip("daemon restart keeps the session", only.has("lifecycle") ? "--skip lifecycle" : `agent ${agent}`);
      } else {
        await J.step("turn 2 (same session)", async () => laterTurn("Say it once more, in one short sentence."));
        // A link loss as the guest sees it: its agent daemon dies (SIGKILL, no clean shutdown) and acpmux.service
        // (Restart=always) brings it back. The session must still be listed and take a turn, with no new `acp ensure`.
        await J.step("daemon restart keeps the session", async () => {
          const pidOf = async () => {
            const r = await exec(`${GUEST}"$c" acp --json daemon status 2>&1`);
            try { return JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))).pid as number | undefined; } catch { return undefined; }
          };
          const old = await pidOf();
          if (!old) throw new Error("acp daemon status names no pid");
          const k = await exec(`kill -KILL ${old} 2>&1; echo "@@kill $?"`);
          if (!/@@kill 0/.test(k.stdout)) throw new Error(`kill ${old}: ${k.stdout.slice(-200)}`);
          const t0 = Date.now();
          let now: number | undefined;
          while (Date.now() - t0 < 60_000) {
            await sleep(2_000);
            now = await pidOf();
            if (now && now !== old) break;
          }
          if (!now || now === old) throw new Error(`no new daemon within 60 s of killing pid ${old}`);
          const back = Math.round((Date.now() - t0) / 100) / 10;
          const ls = await exec(`${GUEST}"$c" acp ls --json 2>&1`);
          if (!ls.stdout.includes(session)) throw new Error(`the new daemon (pid ${now}) does not list ${session}: ${ls.stdout.slice(-200)}`);
          const turn = await laterTurn("Are you still there? Answer in one short sentence.");
          return { value: null, detail: `daemon ${old} killed, ${now} serves after ${back} s; ${turn.detail}` };
        });
      }
      // The agent itself does the GitHub cells, as a person would ask it in the chat: clone, branch, commit, push and a
      // draft PR in the sandbox repository. The journey reads them back on the machine (cloud-github-e2e.sh --agent-pr),
      // then closes the PR and deletes the branch whatever the turn said. A real model only: the stub answers no prompt.
      const sandbox = githubSandbox(process.env.CMUX_JOURNEY_GITHUB_REPO);
      if (only.has("github")) J.skip(GITHUB_AGENT_STEP, "--skip github");
      else if (!sandbox) J.skip(GITHUB_AGENT_STEP, "CMUX_JOURNEY_GITHUB_REPO is not set");
      else if (modelStub || gatewayStub) J.skip(GITHUB_AGENT_STEP, "the stub model answers no prompt (the real model runs this cell)");
      else if (!githubScriptOnGuest) J.skip(GITHUB_AGENT_STEP, "cloud-github-e2e.sh is not on the machine");
      else await J.step(GITHUB_AGENT_STEP, async () => {
        const ask = githubAgentAsk(sandbox, tag);
        let said = "";
        let turnError = "";
        try {
          said = (await laterTurn(ask.prompt)).detail;
        } catch (e) {
          turnError = String((e as Error)?.message ?? e).slice(0, 300);
          // A turn cut off by the journey's wait keeps running: stop it before the read back closes the PR and deletes
          // the branch, or the agent could push or open a PR after the cleanup.
          turnError += `; ${await stopAgentTurn(exec, session)}`;
        }
        const r = await exec(`${GUEST}sh ${shq(GITHUB_E2E_GUEST)} --agent-pr ${shq(sandbox)} ${shq(ask.branch)} ${shq(ask.file)} ${shq(ask.line)} 2>&1`, 180_000);
        const cells = e2eLines(r.stdout) || r.stdout.slice(-400);
        if (turnError) throw new Error(`the agent's turn: ${turnError}; read back: ${cells}`);
        if (r.code !== 0) throw new Error(`read back exit ${r.code}: ${cells}; the agent said: ${said.slice(0, 160)}`);
        return { value: null, detail: `${cells}; the agent said: ${said.slice(0, 160)}` };
      }).catch(() => undefined);
    }

    // After the chat, while its processes still run: where a provider key sits on the chat machine.
    if (only.has("keys")) {
      J.skip(KEY_PROBE_STEP, "--skip keys");
    } else {
      const t0 = Date.now();
      const mode = gatewayAny ? "gateway" : only.has("login") || !login || !provider ? "no login passed" : "login copy";
      try {
        // The walk gets 240 s of the exec route's 300 s; a walk cut short reads as incomplete, never clean.
        const r = await exec(keyProbeCommand(readFileSync(KEY_PROBE_PY, "utf8"), ["--budget-s", "240"]), 290_000);
        const probe = parseKeyProbe(r.stdout);
        if (keysProbeOut) appendFileSync(keysProbeOut, `${JSON.stringify({ tag, backend: backend.name, mode, machine: created.id, at: new Date().toISOString(), ...probe })}\n`);
        const detail = keyProbeDetail(probe);
        const status = keyProbeStatus(probe, keysClean);
        J.record({ step: KEY_PROBE_STEP, status, ms: Date.now() - t0, detail: status === "skip" ? `report only (${mode}; --keys-clean fails it): ${detail}` : `${mode}: ${detail}` });
      } catch (e) {
        J.record({ step: KEY_PROBE_STEP, status: keysClean ? "fail" : "skip", ms: Date.now() - t0, detail: `the probe did not run: ${(e as Error).message}` });
      }
    }

    // The carrier is the only way into a Cloud machine (cmux-platform#1007 deletes the Native link_token and the relay
    // chat), so the journey connects with the carrier dial and nothing else.
    await J.step("connect (connect_info)", async () => {
      const info = await installApi.read("cloud.machine.connect_info", { machine: created.id });
      return { value: null, detail: `host ${info.host} state ${info.state} epoch ${info.epoch}` };
    });
    if (cmux) {
      await J.step("connect (carrier dial)", async () => {
        const d = await carrierDial(cmux, api, created.id);
        return { value: null, detail: dialDetail(d) };
      });
      if (autocloudTui) {
        await J.step("autocloud TUI chat (cmux-autocloud --machine)", async () => ({ value: null, detail: autocloudTuiChat(autocloudTui, cmux, api, created.id, agent, modelStub ? null : "pong") }));
      }
    } else {
      // Without a cmux binary (the production journeys) the dial cannot run; its platform half still can: the
      // ticket, grant and daemon key it asks for, checked by the dial's own rules.
      await J.step("connect (carrier ticket)", async () => {
        const r = await api.raw("POST", `/v1/cloud/machines/${created.id}/carrier`, { noise_key: randomBytes(32).toString("base64url") }, 60_000, sendTrace.headers);
        const problem = carrierTicketProblem(r.status, r.body);
        if (problem) throw new Error(`carrier ticket: ${problem}`);
        return { value: null, detail: `${r.body.value.relay}, ticket until ${r.body.value.expires_at}, grant and daemon key present` };
      });
      J.skip("connect (carrier dial)", "--cmux is required for a carrier dial");
    }
    if (createAnsweredAt !== null) {
      await J.step("guest carrier timeline", async () => {
        const before = Date.now();
        const r = await exec(GUEST_CARRIER_TIMELINE);
        const after = Date.now();
        if (r.code !== 0) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
        probeExtra.claimed_spare = guestTimelineFacts(r.stdout, createAnsweredAt!, before, after, createSentAt ?? createAnsweredAt!).claimed_spare;
        return { value: null, detail: guestTimeline(r.stdout, createAnsweredAt!, before, after, createSentAt ?? createAnsweredAt!) };
      });
    }

    // --chaos: faults injected into this machine's carrier mid-turn, each a step (cloud-chaos.ts).
    if (chaos) {
      if (!cmux || !lifecycle) J.skip("chaos", !cmux ? "--cmux is required for the chaos leg" : "the chaos leg needs a chat session");
      else {
        const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
        const results = await runChaos({
          cmux, machine: created.id, team: api.team, exec, guest: GUEST, session, tag, harness: agent,
          // The machine holds no login with a launch credential: the chaos chats start on it, as the journey's own did.
          credentials: launchCredential ? { env: { CLAUDE_CODE_OAUTH_TOKEN: login } } : undefined,
          env: { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer },
          log: (line) => console.log(scrub(line, J.secrets)),
        }).catch((e: Error) => [{ fault: "chaos leg", outcome: "fail" as const, felt_ms: null, recover_ms: null, carrier: "", turn: "", detail: e.message }]);
        for (const r of results) {
          J.record({ step: `chaos: ${r.fault}`, status: r.outcome === "ok" ? "pass" : r.outcome === "fail" ? "fail" : "skip", ms: r.felt_ms ?? 0, detail: r.detail });
        }
        if (outDir) writeFileSync(path.join(outDir, "chaos.json"), `${JSON.stringify({ backend: backend.name, machine: created.id, results }, null, 2)}\n`);
        const chaosOut = argValue("--chaos-probe-out", argv);
        if (chaosOut) writeFileSync(chaosOut, `${JSON.stringify(chaosProbeRow(argValue("--chaos-probe", argv) ?? `cloud-carrier-chaos-${backend.name}`, results, process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : undefined))}\n`);
      }
    }

    // --resume-matrix: the machine paused and woken through every arm, interleaved (cloud-resume-matrix.ts).
    if (resumePauses.length) {
      if (!cmux || !lifecycle) J.skip("resume matrix", !cmux ? "--cmux is required for the resume matrix" : "the resume matrix needs a chat session");
      else {
        const { CMUX_CLOUD_TEAM: _inherited, ...inherited } = process.env;
        let k = 0;
        let idleArmed = false;
        const platformStart = async (): Promise<{ serverTiming?: Record<string, number>; serverTimingHeader: string | null }> => {
          const r = await api.raw("POST", "/v1/ops", { op: "cloud.machine.start", params: { machine: created.id }, idempotency_key: `${tag}-rm-start-${k++}` }, 180_000);
          if (r.status !== 200 || r.body?.ok !== true) throw new Error(`cloud.machine.start: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
          const h = r.headers?.get("server-timing") ?? null;
          return { serverTiming: parseServerTiming(h), serverTimingHeader: h };
        };
        // The resume arm: the person's resume route, served by cmux-platform at client-config's platform_origin
        // (cloud-resume-matrix.ts resumeRouteCall); the API host has no /v1/machines and answered an empty 404.
        let resumePlatform: string | null = null;
        const resumeRoute = async () => {
          resumePlatform ??= clientPlatformOrigin((await api.raw("GET", "/v1/client-config", undefined, 30_000)).body);
          return resumeRouteCall(resumePlatform, created.id, { authorization: `Bearer ${await routeToken()}`, ...(api.team ? { "x-cmux-team": api.team } : {}) }, http);
        };
        // cmux-platform's /v1/machines takes a cmux access token with a team claim (machines/Auth.ts), not the Stack
        // session (run 45432577860: 401 "a cmux access token with a team claim is required"). The journey's install
        // signs a fresh one every 5 min, since the matrix outlives an install token.
        let routeMinted: { token: string; at: number } | null = null;
        const routeToken = async () => {
          if (routeMinted && Date.now() - routeMinted.at < 5 * 60_000) return routeMinted.token;
          const userId = user.id ?? user.user?.id;
          const ch = await http("POST", `${backend.api}/v1/auth/challenge`, { user: userId, install: install.id, ...(api.team ? { team: api.team } : {}) }, {});
          if (ch.status !== 200) throw new Error(`resume route token: challenge HTTP ${ch.status} ${short(ch.body)}`);
          const tok = await http("POST", `${backend.api}/v1/auth/token`, { user: userId, install: install.id, nonce: ch.body.nonce, signature: await sign(install.key, `${ch.body.message_prefix}${ch.body.nonce}`) }, {}, 25_000);
          if (tok.status !== 200 || typeof tok.body.access_token !== "string") throw new Error(`resume route token: HTTP ${tok.status} ${short(tok.body.error ?? tok.body)}`);
          J.secrets.push(tok.body.access_token);
          routeMinted = { token: tok.body.access_token, at: Date.now() };
          return routeMinted.token;
        };
        // The CLI processes the matrix starts (its chat dial, each exec) read the token from here, so a new sign-in
        // reaches every one started after it.
        const matrixEnv: Record<string, string | undefined> = { ...inherited, CMUX_CLOUD_API_URL: api.origin, CMUX_CLOUD_ACCESS_TOKEN: api.bearer };
        // Written after every sample and stop, so a run cut short (a step timeout, a cancel) still uploads what it had.
        let sofar: ResumeSample[] = [];
        let stops: ResumeStop[] = [];
        const row = async () => (await api.read("cloud.machine.get", { machine: created.id }, 30_000).catch(() => null)) as Record<string, any> | null;
        const first = await row();
        // The machine's provider as the API names it; staging's machines are VM API machines, with no client sessions.
        const provider = String(first?.provider ?? first?.platform ?? first?.transport ?? "unnamed (cloud.machine.get names none)");
        const writeMatrix = () => {
          if (!outDir) return;
          const scrubbed = (x: unknown) => scrub(JSON.stringify(x, null, 2), J.secrets);
          writeFileSync(path.join(outDir, "resume-matrix.json"), `${scrubbed({ backend: backend.name, machine: created.id, provider, samples: sofar, stops })}\n`);
          writeFileSync(path.join(outDir, "resume-matrix.md"), resumeMarkdown(sofar, stops, [provider]));
        };
        const samples = await runResumeMatrix({
          ctx: {
            cmux, machine: created.id, team: api.team, exec, guest: GUEST, session, tag, harness: agent,
            credentials: launchCredential ? { env: { CLAUDE_CODE_OAUTH_TOKEN: login } } : undefined,
            env: matrixEnv,
            log: (line) => console.log(scrub(line, J.secrets)),
          },
          refreshAuth: async () => {
            if (await resignIfOld()) matrixEnv.CMUX_CLOUD_ACCESS_TOKEN = api.bearer;
          },
          pause: async () => {
            await api.op("cloud.machine.pause", { machine: created.id }, `${tag}-rm-pause-${k++}`);
            await waitMachine(api, created.id, (x) => x.status === "paused", 180_000);
          },
          // The send arm: cmux's own idle pause (the aggressive policy's 60 s window after the turn ends), never a
          // person's, which no send wakes (cmux-platform CloudDO.ts PERSON_PAUSED). The policy is set once.
          autoPause: async () => {
            if (!idleArmed) {
              idleArmed = true;
              // Staging's default already is `aggressive` (CLOUD_PAUSE_POLICY_DEFAULT); a refusal here leaves that default.
              // idle_seconds is required (CloudMachineIdlePolicySet; run 45432577860 was refused without it): 60 s, the
              // aggressive policy's window.
              await api.op("cloud.machine.idle_policy.set", { machine: created.id, idle_seconds: 60, pause_policy: "aggressive" }, `${tag}-rm-idle-policy`)
                .catch((e: Error) => console.log(scrub(`resume matrix: pause_policy aggressive not set (${e.message}); the deployment's default stands`, J.secrets)));
            }
            const m = await waitMachine(api, created.id, (x) => x.status === "paused", AUTO_PAUSE_WAIT_MS).catch((e: Error) => {
              throw new Error(`cmux did not pause the machine by itself within ${AUTO_PAUSE_WAIT_MS / 1000} s (the aggressive policy's idle window; the team's cloud.idlePause must be on): ${e.message}`);
            });
            if (!m?.pause_reason) throw new Error(`the machine read paused with no pause_reason (a person's pause, which no send wakes): ${short(machineStopFields(m))}`);
          },
          platformResume: platformStart,
          resumeRoute,
          platformSync: () => syncRunning(
            async () => String((await row())?.status ?? "unread"),
            platformStart,
            () => waitMachine(api, created.id, (x) => x.status === "running", 180_000),
          ),
          clientSession: async (ttl) => {
            const r = await api.raw("POST", `/v1/cloud/machines/${created.id}/client-session`, { ttl_seconds: ttl });
            const v = r.body?.value ?? r.body;
            if (r.status !== 200 || typeof v?.token !== "string") throw new Error(`client-session: HTTP ${r.status} ${short(r.body?.error ?? r.body)}`);
            J.secrets.push(v.token);
            return { token: v.token, vm_id: String(v.vm_id), api_base_url: String(v.api_base_url) };
          },
          status: async () => String((await row())?.status ?? "unread"),
          provider,
          fillPct: resumeFill,
          deadlineAt: resumeDeadlineAt,
          failStreak: resumeFailStreak,
          onSample: (_s, all) => { sofar = all; writeMatrix(); },
          onStop: (_x, all) => { stops = all; writeMatrix(); },
        }, resumePauses, resumeN, resumeArms).catch((e: Error) => {
          J.record({ step: "resume matrix", status: "fail", ms: 0, detail: e.message });
          stops = [...stops, { pause_s: resumePauses[0] ?? 0, after: sofar.length, reason: `the matrix failed: ${e.message}` }];
          return sofar;
        });
        // --provider arms run in the same cells (same pauses, same n) after the machine's own arms; a provider with no
        // credentials is a skip in its cells, never a failure.
        for (const name of resumeProviders) {
          const r = await runProviderArm(name, process.env, resumePauses, resumeN, { deadlineAt: resumeDeadlineAt, failStreak: resumeFailStreak, log: (line) => console.log(scrub(line, J.secrets)) });
          samples.push(...r.samples);
          stops = [...stops, ...r.stops];
        }
        sofar = samples;
        for (const x of stops) J.record({ step: `resume matrix: ${x.pause_s} s${x.arm ? ` ${x.arm}` : ""} ${x.reason.startsWith("skipped") ? "skipped" : "stopped early"}`, status: x.reason.startsWith("skipped") ? "skip" : "fail", ms: 0, detail: x.reason });
        const table = resumeMarkdown(samples, stops, [provider]);
        for (const s of samples.filter((x) => x.error)) J.record({ step: `resume matrix: ${s.pause_s} s ${s.arm} #${s.i}`, status: "fail", ms: s.first_byte_ms ?? 0, detail: s.error });
        if (samples.length) J.record({ step: "resume matrix", status: samples.some((x) => x.error) ? "fail" : "pass", ms: 0, detail: `${samples.length} samples` });
        console.log(table);
        writeMatrix();
        if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n## Resume matrix (${backend.name}, ${created.id})\n\n${table}`);
      }
    }

    // POST /v1/handoffs {sessionId, machine} (backend/apps/api/src/handoffs/routes.ts). Production leaves the
    // hand-off bindings unbound until it ships there and answers 404: that is a SKIP, not a red.
    // A transport error is recorded as this step's failure; the journey goes on to its next steps.
    const handoff = await api.raw("POST", "/v1/handoffs", { sessionId: session, machine: created.id }).catch((error: Error) => error);
    if (!(handoff instanceof Error) && handoff.status === 404) J.skip("handoff record", "hand-off is not deployed on this backend (404)");
    else await J.step("handoff record", async () => {
      if (handoff instanceof Error) throw new Error(`/v1/handoffs: ${handoff.message}`);
      if (handoff.status >= 300) throw new Error(`/v1/handoffs: HTTP ${handoff.status} ${short(handoff.body.error ?? handoff.body)}`);
      return { value: null, detail: `HTTP ${handoff.status} ${short(handoff.body.value?.id ?? handoff.body.id ?? handoff.body)}` };
    }).catch(() => undefined);
    J.skip("handoff (agent move)", "headless agent move requires a local session daemon socket; the Cloud guest session has no local source socket");

    // One VM per agent: the person's second chat from the same Mac workspace gets a machine of its own.
    if (cmux) await J.step("second chat gets its own VM", async () => {
      const value = await secondChatPlan(cmux, `${user.id ?? user.user?.id ?? "user"}/`, { id: created.id, title: String(created.name ?? created.title ?? created.id) });
      return { value: null, detail: value };
    }).catch(() => undefined);
    else J.skip("second chat gets its own VM", "--cmux is required for the app's start-chat plan");
    // --idle-pause SECONDS: the pause a person never asks for. The machine's idle policy is set short, nothing is sent,
    // and the platform must pause it on its own from the VM's activity reports (team policy cloud.idlePause); then
    // the person's next message, with no start asked, must wake it and get a reply.
    // --idle-pause default: no idle policy is set, so the deployment's own default (staging CLOUD_IDLE_PAUSE_SECONDS)
    // must pause it; the step reports the seconds from the last turn's end (this step starts right after it) to paused.
    const idleArg = argValue("--idle-pause", argv);
    const idleDefault = idleArg === "default";
    const idlePauseS = idleDefault ? 0 : Number(idleArg ?? 0);
    if ((idleDefault || idlePauseS > 0) && !only.has("pause")) {
      const idleSet = Date.now();
      // The short idle pause needs the team policy cloud.idlePause, false by default (cmux-platform protocol/policy.ts):
      // a new person's team never pauses an idle machine before the 24 h backstop. A --fresh-account run's team is its
      // own, so the journey turns it on there and says the default was off; any other team's policy is left alone.
      const POST_CHAT_HOLD_S = 600;
      const teamIdle = await J.step("team idle pause policy", async () => {
        const got = await api.read("team.policy.get", {});
        const on = got?.policy?.values?.["cloud.idlePause"]?.value === true;
        if (on) return { value: true, detail: "cloud.idlePause on" };
        // A fresh team starts with it on (cmux#51850, Leo 2026-11-23: "well, if this is the whole point of the product,
        // then obviously, yes."): the journey never turns it on for a new team, so an off here is kink K8 back.
        if (freshAccount) throw new Error("a brand-new team's cloud.idlePause is off: new teams should start with it on (K8, cmux#51850)");
        throw new Error("team policy cloud.idlePause is off for this team (a team made before new teams started with it on): turn it on for this team or run --fresh-account");
      }).catch(() => false);
      if (teamIdle) await J.step("paused after idle", async () => {
        if (!idleDefault) await api.op("cloud.machine.idle_policy.set", { machine: created.id, idle_seconds: idlePauseS }, `${tag}-idle`);
        // The deadline covers the post-chat hold (staging CLOUD_POST_CHAT_WARM_SECONDS=600 keeps a machine up after a
        // chat turn whatever its idle policy) plus the alarm's re-check, so a pause the platform owes is never missed.
        // --idle-pause default sets no policy, so the deadline reads the machine's own (staging's default is 1800 s):
        // a wait sized from 0 s timed out at 900 s before the default could ever pause it (k8-defaultf, 2026-11-24).
        const policyS = idleDefault ? await machineIdleSeconds(api, created.id) : idlePauseS;
        const m = await waitMachine(api, created.id, (x) => x.status === "paused", idlePauseDeadlineMs(policyS, POST_CHAT_HOLD_S)).catch(async (error) => {
          // A pause that never came: name what held the machine (the idle clock's start, the report's open sessions and
          // workload), so the failure says why instead of only "still running" (two walks on 2026-11-24 could not tell).
          throw new Error(`${(error as Error).message}; ${await idleHeldBy(api, created.id)}`);
        });
        const took = Math.round((Date.now() - idleSet) / 1000);
        return { value: m, detail: idleDefault ? `paused ${took} s after the turn ended, at the deployment's default idle pause` : `paused ${took} s after a ${idlePauseS} s idle policy was set` };
      });
      if (teamIdle) await J.step("resume by a message", async () => {
        const t0 = Date.now();
        if (lifecycle) {
          const turn = await laterTurn("Back after an idle pause: answer in one short sentence.");
          return { value: null, detail: `reply ${Math.round((Date.now() - t0) / 1000)} s after the message: ${turn.detail}` };
        }
        const r = await exec("echo woke");
        if (r.code !== 0 || !r.stdout.includes("woke")) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
        const m = await api.read("cloud.machine.get", { machine: created.id });
        return { value: null, detail: `exec answered ${Math.round((Date.now() - t0) / 1000)} s after it was sent; status ${m?.status}` };
      });
    } else J.skip("paused after idle", idleDefault || idlePauseS > 0 ? "--skip pause" : "--idle-pause SECONDS|default is not set");
    if (!only.has("pause")) {
      await J.step("pause", async () => {
        await api.op("cloud.machine.pause", { machine: created.id }, `${tag}-pause`);
        const m = await waitMachine(api, created.id, (x) => x.status === "paused", 180_000);
        return { value: m, detail: `status ${m.status}` };
      });
      await J.step("resume", async () => {
        await api.op("cloud.machine.start", { machine: created.id }, `${tag}-start`);
        const m = await waitMachine(api, created.id, (x) => x.status === "running", 180_000);
        return { value: m, detail: `status ${m.status}` };
      });
      await J.step("exec after resume", async () => {
        const r = await exec("echo resumed");
        if (r.code !== 0 || !r.stdout.includes("resumed")) throw new Error(`exit ${r.code} ${r.stderr.slice(-200)}`);
        return { value: null, detail: "ok" };
      });
      if (cmux) {
        await J.step("carrier dial after resume", async () => {
          const d = await carrierDial(cmux, api, created.id);
          return { value: null, detail: dialDetail(d) };
        });
      } else {
        J.skip("carrier dial after resume", "--cmux is required for a carrier dial");
      }
      if (lifecycle) await J.step("turn after resume", async () => laterTurn("Back after a pause: answer in one short sentence."));
      else J.skip("turn after resume", only.has("lifecycle") ? "--skip lifecycle" : `agent ${agent}`);
    }
    // The start's waterfall (cmux-platform /v1/cloud/start-traces): the platform's own hops for this create, keyed by
    // its idempotency key, plus the agent's start and first token this run measured; then the last day's p50/p95.
    if (!reuse) await J.step("start trace", async () => {
      // The create carried the send's trace id (x-cmux-start-trace); a platform that keys by the idempotency key still reads.
      const spans = clientSpans(J.firstText.fields().create_marks_ms, createSentAt);
      let got = await readStartTrace((m, r, b, t) => api.raw(m, r, b, t), sendTrace.id, spans, created.id);
      if ("missing" in got) got = await readStartTrace((m, r, b, t) => api.raw(m, r, b, t), `${tag}-create`, spans, created.id);
      if ("missing" in got) return { value: null, detail: got.missing };
      if (outDir) {
        writeFileSync(path.join(outDir, "start-trace.json"), `${JSON.stringify(got, null, 2)}\n`);
        appendFileSync(path.join(outDir, "start-trace.md"), traceMarkdown(got.trace, got.list));
      }
      const slow = got.list ? slowestHop(got.list) : null;
      const hops = Object.entries(hopDurations(got.trace)).map(([h, ms]) => `${h} ${ms}`).join(", ");
      return { value: null, detail: `${got.trace.trace} ${got.trace.path ?? "?"} ${got.trace.total_ms} ms: ${hops}${slow ? `; slowest 24 h p50 ${slow.hop} ${slow.p50_ms} ms (p95 ${slow.p95_ms ?? "-"})` : ""}` };
    }).catch(() => undefined);
    await saveSendTraceOnce();
    // A step that failed without ending the run (the key probe, a chaos fault, the handoff record): its facts first.
    await readGuestDiagnostics("before-cleanup");
    await readFailureFacts();
    if (!keep) {
      await J.step("delete", async () => {
        await api.deleteMachine(created.id, `${tag}-delete`);
        deleted = true;
        const m = await waitMachine(api, created.id, (x) => x.status === "deleted" || x.status === "deleting", 120_000, true).catch(() => null);
        return { value: null, detail: `${created.id} ${m?.status ?? "gone"}` };
      });
    }
  } catch {
    // The failed step is recorded. What the machine says, then the journey-only checks the failure cut off; cleanup below.
    await readFailureFacts();
    // A red run is the one whose trace matters most: save it before cleanup deletes the machine.
    await saveSendTraceOnce();
    await runJourneyOnly?.().catch(() => undefined);
  } finally {
    await finishJourney(cleanup, firstTextObserver, onSignal);
  }
  const failed = J.steps.filter((s) => s.status === "fail");
  writeProbe();
  // snappy-bench/v1 (cloud-start-trace.ts): this fresh chat's send to first token, its parts, and the same model and
  // prompt straight through the Messages API with the same login (the floor). A real-model run that made its machine.
  const snappy = !modelStub && !reuse ? snappyRun({ steps: J.steps, run: probeRun }) : null;
  if (snappy) {
    const model = agent.startsWith("claude/") ? agent.slice("claude/".length) : "claude-opus-5-5";
    const floor = agent.startsWith("claude") ? await modelFloor(process.env, model, prompt) : null;
    const report = snappyReport([snappy], floor, { sha: process.env.GITHUB_SHA ?? null, host: process.env.RUNNER_NAME ?? "local", platform: "linux", model, runUrl: probeRun ?? null });
    if (outDir) writeFileSync(path.join(outDir, "snappy-bench.json"), `${JSON.stringify(report)}\n`);
    process.on("exit", () => console.log(scrub(JSON.stringify(report), J.secrets)));
  }
  console.log(`\n${failed.length ? "FAIL" : "PASS"} ${backend.name}: ${J.steps.filter((s) => s.status === "pass").length} passed, ${failed.length} failed, ${J.steps.filter((s) => s.status === "skip").length} skipped, ${(J.steps.reduce((n, s) => n + s.ms, 0) / 1000).toFixed(1)} s`);
  return failed.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
