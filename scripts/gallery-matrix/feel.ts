#!/usr/bin/env bun
// Feel check: a simulated cursor clicks, hovers and drags its way around each gallery state, the
// way a person pokes at a new build, and grades what it feels like with numbers (Leo, 2026-11-22:
// "these should be doable via automation. the "feel" and "vibes" thing. you can simulate cursors
// clicking around."). A play (webviews/src/gallery/play.ts) measures the steps someone scripted;
// this crawl needs no script: it finds every visible control a cursor could reach and drives
// Playwright's trusted mouse to it along a path (moves, not teleports), so an unscripted control
// is graded too.
//
// For each action it measures, in the page:
//   - response: input to the first visible change (a DOM mutation, a focus move, a layout shift, a
//     scroll). Over RESPONSE_FAIL_MS it fails; the INP "good" bound is 200 ms.
//   - dead click: a click on an enabled control that changed nothing at all within the settle cap
//     (no mutation, focus, scroll, shift or navigation). A cursor:pointer that does nothing.
//   - pop-in: content that appears in a later wave, POP_IN_MS or more after the first response
//     (a spinner then a list, a menu then its rows). One transition moves everything together
//     (rulebook ui-state-transition: "no layout jump, no pop-in after an animation").
//   - layout jump: a layout shift after the first response's wave (the action's own expansion is
//     its first frame; a second move is a jump), and any layout shift on a hover (hovering never
//     moves layout).
//   - long frames: Long Animation Frames during the action, reported with the response.
// Chromium only: its Long Animation Frames, layout-shift and Event Timing entries are the
// measurements; rAF guesses on a software-rendered WebKit measure the machine, not the page.
//
// A finding counts only when a second, fresh render of the state shows it again. feel-baseline.json
// names known findings per state (`entry#variant`) by key with why; a finding not on it fails, a
// listed one this run no longer saw is printed so its line can go. Numbers are in feel.json either way.
//
//   CMUX_GALLERY_IN_VM=1 bun feel.ts --manifest m.json --gallery-dir ../../webviews/dist/gallery
import { chromium, type Browser, type Page } from "playwright";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { type MatrixCase, type Scalar, parseManifest, stageUrlForTest as queryUrl, withTimeout } from "./runner";

export const RESPONSE_FAIL_MS = 200;
export const RESPONSE_WARN_MS = 100;
/** A later wave this long after the first response is pop-in. */
export const POP_IN_MS = 100;
/** Mutations closer together than this are one wave (about three frames). */
export const WAVE_GAP_MS = 50;
/** Shift below this is subpixel rounding. */
export const SHIFT_EPSILON = 0.001;
/** A pop-in smaller than this (px²) is a caret or a ring, not content. */
export const POP_IN_MIN_AREA = 64;
/** The settle: quiet this long after the last change, or the cap. */
export const QUIET_MS = 300;
export const SETTLE_CAP_MS = 2500;
export const DEFAULT_ACTIONS_PER_STATE = 10;
export const FEEL_BASELINE_PATH = join(import.meta.dir, "feel-baseline.json");

export type FeelAction = "click" | "hover" | "drag";
export type Change = { t: number; kind: "add" | "attr" | "text" | "remove" | "focus" | "scroll" | "shift" | "nav"; label?: string; area?: number };
export type ShiftEntry = { t: number; value: number; sources: string[] };
/** What the page saw from one action: times are ms from the input. */
export type ActionMeasure = {
  action: FeelAction;
  target: string;
  changes: Change[];
  shifts: ShiftEntry[];
  longFrames: number[];
  settleMs: number;
  /** The action never settled within the cap (an endless animation or poll): its waves are not judged. */
  capped: boolean;
};
export type Finding = { kind: "dead-click" | "slow-response" | "pop-in" | "layout-jump" | "hover-shift"; key: string; detail: string };
export type ActionReport = {
  action: FeelAction;
  target: string;
  responseMs: number | null;
  waves: number;
  shift: number;
  lateShift: number;
  longestFrameMs: number;
  settleMs: number;
  findings: Finding[];
};

// ---- Pure rules (feel.test.ts) ----

/** Groups change times into waves: a gap over WAVE_GAP_MS starts a new one. */
export function waves(changes: Change[]): Change[][] {
  const sorted = [...changes].sort((a, b) => a.t - b.t);
  const out: Change[][] = [];
  for (const change of sorted) {
    const last = out[out.length - 1];
    if (last && change.t - last[last.length - 1]!.t <= WAVE_GAP_MS) last.push(change);
    else out.push([change]);
  }
  return out;
}

const round1 = (value: number) => Math.round(value * 10) / 10;

/** The verdict on one action. */
export function judgeAction(measure: ActionMeasure): ActionReport {
  const findings: Finding[] = [];
  const groups = waves(measure.changes);
  const first = groups[0]?.[0]?.t ?? null;
  const responseMs = first === null ? null : Math.max(0, first);
  const shift = measure.shifts.reduce((sum, entry) => sum + entry.value, 0);
  const firstWaveEnd = groups[0] ? groups[0][groups[0].length - 1]!.t : 0;
  const late = measure.shifts.filter((entry) => first !== null && entry.t > firstWaveEnd + WAVE_GAP_MS);
  const lateShift = late.reduce((sum, entry) => sum + entry.value, 0);
  const target = measure.target;

  if (measure.action === "click" && responseMs === null)
    findings.push({ kind: "dead-click", key: `dead-click ${target}`, detail: `click on ${target} changed nothing in ${round1(measure.settleMs)} ms` });
  if (responseMs !== null && responseMs > RESPONSE_FAIL_MS && measure.action !== "hover")
    findings.push({ kind: "slow-response", key: `slow-response ${measure.action} ${target}`, detail: `${measure.action} ${target}: first visible change after ${round1(responseMs)} ms (limit ${RESPONSE_FAIL_MS} ms)` });
  if (!measure.capped && measure.action !== "hover" && first !== null) {
    for (const group of groups.slice(1)) {
      const lateMs = group[0]!.t - first;
      if (lateMs < POP_IN_MS) continue;
      const added = group.filter((change) => change.kind === "add" && (change.area ?? 0) >= POP_IN_MIN_AREA);
      if (!added.length) continue;
      const labels = [...new Set(added.map((change) => change.label ?? "?"))].slice(0, 3);
      findings.push({ kind: "pop-in", key: `pop-in ${measure.action} ${target}`, detail: `${measure.action} ${target}: ${labels.join(", ")} appeared ${round1(lateMs)} ms after the first response` });
      break;
    }
    if (measure.action === "click" && lateShift > SHIFT_EPSILON) {
      const sources = [...new Set(late.flatMap((entry) => entry.sources))].slice(0, 3);
      findings.push({ kind: "layout-jump", key: `layout-jump ${target}`, detail: `click ${target}: layout shift ${lateShift.toFixed(4)} after its first wave (${sources.join(", ") || "no source"})` });
    }
  }
  if (measure.action === "hover" && shift > SHIFT_EPSILON) {
    const sources = [...new Set(measure.shifts.flatMap((entry) => entry.sources))].slice(0, 3);
    findings.push({ kind: "hover-shift", key: `hover-shift ${target}`, detail: `hover ${target}: layout shift ${shift.toFixed(4)} (${sources.join(", ") || "no source"})` });
  }
  return {
    action: measure.action,
    target,
    responseMs: responseMs === null ? null : round1(responseMs),
    waves: groups.length,
    shift: Number(shift.toFixed(4)),
    lateShift: Number(lateShift.toFixed(4)),
    longestFrameMs: round1(Math.max(0, ...measure.longFrames)),
    settleMs: round1(measure.settleMs),
    findings,
  };
}

export type StateReport = { state: string; id: string; actions: ActionReport[]; error?: string };
export type FeelBaseline = { states: Record<string, Record<string, string>> };

/** Findings seen on every run of a state (a finding one run alone shows is the runner's noise). */
export function stableFindings(runs: StateReport[][]): Map<string, Finding[]> {
  const byRun = runs.map((run) => {
    const map = new Map<string, Map<string, Finding>>();
    for (const report of run) {
      const keys = map.get(report.state) ?? new Map<string, Finding>();
      for (const action of report.actions) for (const finding of action.findings) keys.set(finding.key, finding);
      map.set(report.state, keys);
    }
    return map;
  });
  const out = new Map<string, Finding[]>();
  const [head, ...rest] = byRun;
  for (const [state, keys] of head ?? new Map()) {
    const kept = [...keys.values()].filter((finding) => rest.every((run) => !run.has(state) || run.get(state)!.has(finding.key)));
    if (kept.length) out.set(state, kept);
  }
  return out;
}

export type FeelVerdict = { fresh: { state: string; finding: Finding }[]; known: { state: string; finding: Finding }[]; mended: { state: string; key: string }[] };

export function judgeFeel(ran: Iterable<string>, findings: Map<string, Finding[]>, baseline: FeelBaseline): FeelVerdict {
  const fresh: FeelVerdict["fresh"] = [];
  const known: FeelVerdict["known"] = [];
  for (const [state, list] of [...findings].sort(([a], [b]) => a.localeCompare(b)))
    for (const finding of list) (baseline.states[state]?.[finding.key] !== undefined ? known : fresh).push({ state, finding });
  const mended: FeelVerdict["mended"] = [];
  for (const state of new Set(ran)) {
    const seen = new Set((findings.get(state) ?? []).map((finding) => finding.key));
    for (const key of Object.keys(baseline.states[state] ?? {})) if (!seen.has(key)) mended.push({ state, key });
  }
  return { fresh, known, mended };
}

export function readFeelBaseline(path: string): FeelBaseline {
  if (!existsSync(path)) return { states: {} };
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<FeelBaseline>;
  const states = parsed.states ?? {};
  for (const [state, keys] of Object.entries(states))
    for (const [key, why] of Object.entries(keys))
      if (typeof why !== "string" || why.trim().length < 12) throw new Error(`feel-baseline.json: ${state} ${key}: a listed finding needs a written reason`);
  return { states };
}

const pct = (values: number[], q: number) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};

export function feelSummary(reports: StateReport[], verdict: FeelVerdict): string {
  const actions = reports.flatMap((report) => report.actions);
  const responses = actions.map((action) => action.responseMs).filter((ms): ms is number => ms !== null);
  const count = (kind: Finding["kind"]) => verdict.fresh.filter(({ finding }) => finding.kind === kind).length + verdict.known.filter(({ finding }) => finding.kind === kind).length;
  const lines = [
    `Feel check: ${reports.length} states, ${actions.length} cursor actions (${actions.filter((a) => a.action === "click").length} clicks, ${actions.filter((a) => a.action === "hover").length} hovers, ${actions.filter((a) => a.action === "drag").length} drags).`,
    `Response p50 ${pct(responses, 0.5)} ms, p95 ${pct(responses, 0.95)} ms, max ${Math.max(0, ...responses)} ms; longest frame ${Math.max(0, ...actions.map((a) => a.longestFrameMs))} ms.`,
    `Findings on every run: ${count("dead-click")} dead click(s), ${count("slow-response")} slow response(s), ${count("pop-in")} pop-in(s), ${count("layout-jump")} layout jump(s), ${count("hover-shift")} hover shift(s); ${verdict.fresh.length} new, ${verdict.known.length} on feel-baseline.json.`,
  ];
  const errored = reports.filter((report) => report.error);
  if (errored.length) lines.push(`${errored.length} state(s) could not be crawled: ${errored.slice(0, 5).map((r) => `${r.state} (${r.error})`).join("; ")}`);
  if (verdict.fresh.length) {
    lines.push("", "New (fix the feel, or list it in scripts/gallery-matrix/feel-baseline.json with why):");
    for (const { state, finding } of verdict.fresh) lines.push(`- ${state}: ${finding.detail}`);
  }
  if (verdict.mended.length) {
    lines.push("", "Not seen now; remove from feel-baseline.json:");
    for (const { state, key } of verdict.mended) lines.push(`- ${state}: ${key}`);
  }
  return lines.join("\n");
}

// ---- The page probe ----

type Candidate = { id: string; label: string; action: FeelAction; x: number; y: number; vertical?: boolean };

/** Installed before the stage loads: records every change with its time, for the runner to read per action. */
function installProbe(): void {
  type W = Window & { __feel?: unknown };
  const changes: { t: number; kind: string; label?: string; node?: Element }[] = [];
  const shifts: { t: number; value: number; sources: string[] }[] = [];
  const frames: { t: number; duration: number }[] = [];
  let cursor: HTMLElement | null = null;
  const describe = (node: Element | null | undefined): string => {
    if (!node) return "?";
    const el = node as HTMLElement;
    const test = el.getAttribute?.("data-testid");
    if (test) return `[data-testid=${test}]`;
    const role = el.getAttribute?.("role");
    const name = (el.getAttribute?.("aria-label") || el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 32);
    const cls = typeof el.className === "string" ? el.className.split(/\s+/).filter(Boolean)[0] : undefined;
    return `${el.tagName?.toLowerCase() ?? "node"}${role ? `[role=${role}]` : ""}${cls ? `.${cls}` : ""}${name ? ` "${name}"` : ""}`;
  };
  const mine = (node: Node | null) => !!cursor && !!node && (node === cursor || cursor.contains(node));
  const observer = new MutationObserver((records) => {
    const t = performance.now();
    for (const record of records) {
      if (mine(record.target)) continue;
      // The crawler's own bookkeeping is not the page's response.
      if (record.type === "attributes" && record.attributeName === "data-feel-id") continue;
      if (record.type === "childList") {
        for (const node of record.addedNodes) if (node.nodeType === 1 && !mine(node)) changes.push({ t, kind: "add", node: node as Element });
        else if (node.nodeType === 3 && node.textContent?.trim()) changes.push({ t, kind: "text", node: record.target as Element });
        if (record.removedNodes.length) changes.push({ t, kind: "remove" });
      } else if (record.type === "characterData") changes.push({ t, kind: "text", node: record.target.parentElement ?? undefined });
      else changes.push({ t, kind: "attr", node: record.target as Element });
    }
  });
  const start = () => observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  if (document.documentElement) start();
  else document.addEventListener("readystatechange", start, { once: true });
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as unknown as { startTime: number; value: number; sources?: { node?: Node }[] }[])
        shifts.push({ t: entry.startTime, value: entry.value, sources: (entry.sources ?? []).map((source) => describe(source.node as Element)) });
    }).observe({ type: "layout-shift", buffered: true });
  } catch {}
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) frames.push({ t: entry.startTime, duration: entry.duration });
    }).observe({ type: "long-animation-frame", buffered: true });
  } catch {}
  document.addEventListener("focusin", (event) => changes.push({ t: performance.now(), kind: "focus", label: describe(event.target as Element) }), true);
  document.addEventListener("scroll", () => changes.push({ t: performance.now(), kind: "scroll" }), true);
  let inputAt = 0;
  for (const type of ["pointerdown", "pointerover"]) document.addEventListener(type, (event) => { if (!inputAt) inputAt = event.timeStamp; }, true);
  (window as W).__feel = {
    showCursor() {
      if (cursor || !document.body) return;
      cursor = document.createElement("div");
      cursor.setAttribute("aria-hidden", "true");
      cursor.style.cssText = "position:fixed;left:0;top:0;width:14px;height:14px;margin:-7px 0 0 -7px;border-radius:7px;background:rgba(255,64,64,.75);box-shadow:0 0 0 2px #fff;pointer-events:none;z-index:2147483647;contain:strict";
      document.body.appendChild(cursor);
      document.addEventListener("pointermove", (event) => { cursor!.style.transform = `translate(${event.clientX}px,${event.clientY}px)`; }, true);
    },
    mark() {
      inputAt = 0;
      return { changes: changes.length, shifts: shifts.length, frames: frames.length, at: performance.now() };
    },
    candidates(limit: number) {
      const selector = "button, a[href], summary, select, input[type=checkbox], input[type=radio], [role=button], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox], [role=tab], [role=switch], [role=checkbox], [role=option], [role=link], [role=treeitem], [role=row][tabindex], [draggable=true], [role=separator], [role=slider], input[type=range]";
      const out: { id: string; label: string; action: string; x: number; y: number; vertical?: boolean }[] = [];
      const seen = new Set<Element>();
      let n = 0;
      for (const el of document.querySelectorAll(selector)) {
        if (out.length >= limit) break;
        if (mine(el) || [...seen].some((other) => other.contains(el))) continue;
        const html = el as HTMLElement;
        if (html.matches(":disabled, [aria-disabled=true], [inert] *")) continue;
        const rect = html.getBoundingClientRect();
        if (rect.width < 4 || rect.height < 4) continue;
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) continue;
        const hit = document.elementFromPoint(x, y);
        if (!hit || (hit !== html && !html.contains(hit))) continue;
        seen.add(el);
        const id = `f${n++}`;
        html.setAttribute("data-feel-id", id);
        const drag = html.matches("[draggable=true], [role=separator], [role=slider], input[type=range]");
        const vertical = drag && (html.getAttribute("aria-orientation") === "horizontal" ? true : rect.height < rect.width && html.matches("[role=separator]"));
        out.push({ id, label: describe(html), action: drag ? "drag" : "click", x, y, vertical });
      }
      return out;
    },
    where(id: string) {
      const el = document.querySelector(`[data-feel-id="${id}"]`);
      if (!el) return null;
      const rect = el.getBoundingClientRect();
      return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    },
    read(mark: { changes: number; shifts: number; frames: number; at: number }) {
      const origin = inputAt || mark.at;
      const area = (node?: Element) => {
        if (!node || !node.isConnected) return 0;
        const rect = node.getBoundingClientRect();
        return rect.width * rect.height;
      };
      return {
        changes: changes.slice(mark.changes).map((change) => ({ t: change.t - origin, kind: change.kind, label: change.label ?? (change.kind === "add" ? describe(change.node) : undefined), area: change.kind === "add" ? area(change.node) : undefined })),
        shifts: shifts.slice(mark.shifts).filter((shift) => shift.t >= mark.at).map((shift) => ({ ...shift, t: shift.t - origin })),
        longFrames: frames.slice(mark.frames).filter((frame) => frame.t + frame.duration >= mark.at).map((frame) => frame.duration),
      };
    },
    quiet(quietMs: number, capMs: number) {
      return new Promise<{ settleMs: number; capped: boolean }>((done) => {
        const began = performance.now();
        let seen = changes.length + shifts.length;
        let last = began;
        const tick = () => {
          const now = performance.now();
          const count = changes.length + shifts.length;
          if (count !== seen) { seen = count; last = now; }
          if (now - last >= quietMs) return done({ settleMs: last - began, capped: false });
          if (now - began >= capMs) return done({ settleMs: now - began, capped: true });
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      });
    },
  };
}

// ---- The crawl ----

type Probe = {
  showCursor(): void;
  mark(): { changes: number; shifts: number; frames: number; at: number };
  candidates(limit: number): Candidate[];
  where(id: string): { x: number; y: number } | null;
  read(mark: ReturnType<Probe["mark"]>): Pick<ActionMeasure, "changes" | "shifts" | "longFrames">;
  quiet(quietMs: number, capMs: number): Promise<{ settleMs: number; capped: boolean }>;
};
const probe = (page: Page) => ({
  mark: () => page.evaluate(() => ((window as unknown as { __feel: Probe }).__feel).mark()),
  read: (mark: ReturnType<Probe["mark"]>) => page.evaluate((m) => ((window as unknown as { __feel: Probe }).__feel).read(m), mark),
  quiet: () => page.evaluate(([q, c]) => ((window as unknown as { __feel: Probe }).__feel).quiet(q!, c!), [QUIET_MS, SETTLE_CAP_MS]),
  candidates: (limit: number) => page.evaluate((n) => ((window as unknown as { __feel: Probe }).__feel).candidates(n), limit),
  where: (id: string) => page.evaluate((i) => ((window as unknown as { __feel: Probe }).__feel).where(i), id),
  showCursor: () => page.evaluate(() => ((window as unknown as { __feel: Probe }).__feel).showCursor()),
});

/** The state's key, whatever theme, width or locale showed it (health.ts `stateKey`). */
export const feelStateKey = (item: { params?: Record<string, unknown> }): string => `${String(item.params?.entry ?? "")}#${String(item.params?.variant ?? "")}`;

/** One case per state: the feel of a control does not change with its theme or locale. */
export function onePerState(cases: MatrixCase[]): MatrixCase[] {
  const seen = new Set<string>();
  return cases.filter((item) => {
    const key = feelStateKey(item);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

async function openState(page: Page, url: string): Promise<boolean> {
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined || !document.querySelector("script[src*='gallery-frame']"), null, { timeout: 20_000 }).catch(() => undefined);
  return (await page.evaluate(() => document.documentElement.dataset.galleryReady ?? null)) === "1";
}

async function crawlState(browser: Browser, baseUrl: string, item: MatrixCase, actionsPerState: number, videoDir?: string): Promise<StateReport> {
  const params: Record<string, Scalar> = item.params ?? {};
  const width = Number(params.width ?? 1280);
  const height = Number(params.height ?? 800);
  const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, timezoneId: "UTC", colorScheme: params.colorScheme === "light" ? "light" : "dark", ...(videoDir ? { recordVideo: { dir: videoDir, size: { width, height } } } : {}) });
  const report: StateReport = { state: feelStateKey(item), id: item.id, actions: [] };
  try {
    const page = await context.newPage();
    await page.addInitScript(installProbe);
    // The crawl never leaves the gallery: a link out is the page's business, not this check's.
    await page.route((url) => !url.toString().startsWith(baseUrl), (route) => route.abort());
    const target = /^https?:\/\//.test(item.path_or_url) ? item.path_or_url : `${baseUrl}/${item.path_or_url.replace(/^\/+/, "")}`;
    const url = queryUrl(target, params);
    if (!(await openState(page, url))) return { ...report, error: "never reported ready" };
    const p = probe(page);
    if (videoDir) await p.showCursor();
    const candidates = await p.candidates(actionsPerState);
    let cursor = { x: 2, y: 2 };
    await page.mouse.move(cursor.x, cursor.y);
    // The simulated cursor travels: about one move event per 16 px, as a hand's pointer does.
    const travel = async (to: { x: number; y: number }) => {
      const steps = Math.max(2, Math.min(30, Math.round(Math.hypot(to.x - cursor.x, to.y - cursor.y) / 16)));
      await page.mouse.move(to.x, to.y, { steps });
      cursor = to;
    };
    for (const candidate of candidates) {
      const at = await p.where(candidate.id);
      if (!at) continue; // an earlier action took it away
      // Hover: travel to it and rest; hovering must not move layout.
      let mark = await p.mark();
      await travel(at);
      let settled = await p.quiet();
      report.actions.push(judgeAction({ action: "hover", target: candidate.label, ...(await p.read(mark)), ...settled }));
      // Click or drag where it is now (a hover may have moved it, which the hover already graded).
      const now = (await p.where(candidate.id)) ?? at;
      const before = page.url();
      mark = await p.mark();
      if (candidate.action === "drag") {
        await page.mouse.move(now.x, now.y);
        await page.mouse.down();
        const to = candidate.vertical ? { x: now.x, y: now.y + 40 } : { x: now.x + 40, y: now.y };
        await page.mouse.move(to.x, to.y, { steps: 6 });
        await page.mouse.up();
        cursor = to;
      } else {
        await page.mouse.click(now.x, now.y);
      }
      settled = await p.quiet().catch(() => ({ settleMs: 0, capped: false }));
      const navigated = page.url() !== before;
      const read = navigated ? { changes: [{ t: 0, kind: "nav" as const }], shifts: [], longFrames: [] } : await p.read(mark);
      report.actions.push(judgeAction({ action: candidate.action, target: candidate.label, ...read, ...settled }));
      // Put the state back: close what the click opened; reload when it left the page.
      if (navigated) {
        if (!(await openState(page, url))) break;
        if (videoDir) await p.showCursor();
        await p.candidates(actionsPerState);
      } else {
        await page.keyboard.press("Escape");
        await p.quiet();
      }
    }
  } catch (error) {
    report.error = error instanceof Error ? error.message.split("\n")[0] : String(error);
  } finally {
    await context.close().catch(() => undefined);
  }
  return report;
}

async function serveDirectory(root: string): Promise<{ baseUrl: string; close: () => void }> {
  const types: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".wasm": "application/wasm", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".webp": "image/webp", ".jpg": "image/jpeg" };
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const requested = decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "") || "index.html";
      const file = resolve(root, requested);
      if (!file.startsWith(resolve(root))) return new Response("forbidden", { status: 403 });
      try { return new Response(await readFile(file), { headers: { "content-type": types[extname(file)] ?? "application/octet-stream" } }); } catch { return new Response("not found", { status: 404 }); }
    },
  });
  return { baseUrl: `http://127.0.0.1:${server.port}`, close: () => server.stop() };
}

async function crawlAll(cases: MatrixCase[], galleryDir: string, concurrency: number, actionsPerState: number, videoDir?: string): Promise<StateReport[]> {
  const server = await serveDirectory(resolve(galleryDir));
  const launch = () => chromium.launch({ headless: true, timeout: 30_000, ...(process.env.CMUX_CHROME_HEADLESS_SHELL ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL } : { channel: "chrome" }) });
  const reports: StateReport[] = new Array(cases.length);
  let next = 0;
  try {
    await Promise.all(
      Array.from({ length: Math.min(concurrency, cases.length) }, async () => {
        let browser = await launch();
        try {
          while (next < cases.length) {
            const index = next++;
            const item = cases[index]!;
            const started = Date.now();
            try {
              reports[index] = await withTimeout(crawlState(browser, server.baseUrl, item, actionsPerState, videoDir), 90_000, `feel ${item.id}`);
            } catch (error) {
              reports[index] = { state: feelStateKey(item), id: item.id, actions: [], error: error instanceof Error ? error.message : String(error) };
              await browser.close().catch(() => undefined);
              browser = await launch();
            }
            const found = reports[index]!.actions.reduce((sum, action) => sum + action.findings.length, 0);
            console.log(`feel ${reports[index]!.state}: ${reports[index]!.actions.length} actions, ${found} finding(s), ${Date.now() - started} ms${reports[index]!.error ? ` (${reports[index]!.error})` : ""}`);
          }
        } finally {
          await browser.close().catch(() => undefined);
        }
      }),
    );
  } finally {
    server.close();
  }
  return reports;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      manifest: { type: "string" },
      "gallery-dir": { type: "string" },
      "output-dir": { type: "string", default: "gallery-feel-output" },
      baseline: { type: "string", default: FEEL_BASELINE_PATH },
      "max-states": { type: "string", default: "0" },
      actions: { type: "string", default: String(DEFAULT_ACTIONS_PER_STATE) },
      concurrency: { type: "string", default: "4" },
      video: { type: "boolean", default: false },
      "report-only": { type: "boolean", default: false },
    },
  });
  if (!values.manifest || !values["gallery-dir"]) throw new Error("--manifest and --gallery-dir are required");
  // Same rule as runner.ts: browsers run only in a VM or on CI, never on a developer laptop.
  if (process.env.CMUX_GALLERY_IN_VM !== "1") throw new Error("the feel check runs only on CI or a VM (CMUX_GALLERY_IN_VM=1)");
  const max = Number(values["max-states"]);
  let cases = onePerState(parseManifest(JSON.parse(await readFile(values.manifest, "utf8"))));
  if (max > 0) cases = cases.slice(0, max);
  const outputDir = resolve(values["output-dir"]);
  await mkdir(outputDir, { recursive: true });
  const videoDir = values.video ? join(outputDir, "video") : undefined;
  const actions = Number(values.actions);
  const concurrency = Number(values.concurrency);
  const first = await crawlAll(cases, values["gallery-dir"], concurrency, actions, videoDir);
  // A finding counts only when a fresh render shows it again, one state at a time on a quiet runner.
  const flagged = cases.filter((_, index) => first[index]!.actions.some((action) => action.findings.length));
  const again = flagged.length ? await crawlAll(flagged, values["gallery-dir"], 1, actions) : [];
  const stable = stableFindings([first, again]);
  const verdict = judgeFeel(first.filter((report) => !report.error).map((report) => report.state), stable, readFeelBaseline(values.baseline));
  const text = feelSummary(first, verdict);
  await writeFile(join(outputDir, "feel.json"), `${JSON.stringify({ verdict, states: first, retried: again }, null, 2)}\n`);
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${text}\n`);
  if (verdict.fresh.length && !values["report-only"]) process.exitCode = 1;
}

if (import.meta.main) await main();
