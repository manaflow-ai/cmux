// l10n-allow-file: test fixtures (sample people, models and paths), not shipped UI.
// History > Team (teamAudit/): the `_acpmux/team_audit` read for each range and grouping, acpmux's
// answer read defensively (the audit, or why there is none), the formatters, the CSV download's
// answer, and the tab showing only while the `team-audit` experiment is on.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { teamAudit } from "../src/agent-session/acpmux/teamAudit/teamAudit.experiment";
import {
  auditHasMachineTime,
  auditHasRows,
  auditRowLabel,
  auditTokensIn,
  formatHitRate,
  readTeamAudit,
  readTeamAuditSaved,
  TEAM_AUDIT_GROUPS,
  teamAuditParams,
} from "../src/agent-session/acpmux/teamAudit/teamAuditModel";
import { experimentById } from "../src/experiments/registry";
import { settleReact } from "./support/domTeardown";

const NOW = Date.UTC(2026, 10, 9, 15, 30);

const totals = (over: Record<string, unknown> = {}) => ({
  inputTokens: 100,
  outputTokens: 50,
  cacheReadTokens: 800,
  cacheWriteTokens: 100,
  cacheHitRate: 0.8,
  turns: 2,
  toolCalls: 3,
  wallMs: 15_000,
  sessions: 1,
  ...over,
});

const answer = (over: Record<string, unknown> = {}) => ({
  status: "ok",
  audit: {
    team: "team_a",
    scope: "team",
    range: { since: "2026-10-11", until: "2026-11-09" },
    groupBy: "person",
    totals: totals({ machineMs: 3_600_000 }),
    rows: [
      { ...totals({ machineMs: 3_600_000 }), key: "user_a" },
      { ...totals({ turns: 0, cacheHitRate: null, machineMs: 60_000 }), key: "user_b" },
      // Not a row: no key.
      { ...totals(), key: "" },
    ],
    ...over,
  },
});

test("asks for whole UTC days ending today, the grouping and the format", () => {
  expect(teamAuditParams("7d", "model", NOW)).toEqual({
    since: "2026-11-03",
    until: "2026-11-09",
    groupBy: "model",
    format: "json",
  });
  expect(teamAuditParams("30d", "person", NOW, "csv")).toMatchObject({ since: "2026-10-11", format: "csv" });
  expect(teamAuditParams("90d", "day", NOW).since).toBe("2026-08-12");
  expect(TEAM_AUDIT_GROUPS).toEqual(["person", "repo", "model", "harness", "machine", "day"]);
});

test("reads the audit defensively, and every other answer as its reason", () => {
  const ready = readTeamAudit(answer());
  expect(ready.kind).toBe("ready");
  if (ready.kind !== "ready") return;
  expect(ready.reply.scope).toBe("team");
  expect(ready.reply.rows.map((row) => row.key)).toEqual(["user_a", "user_b"]);
  expect(ready.reply.rows[1]!.cacheHitRate).toBeNull();
  expect(ready.reply.totals.machineMs).toBe(3_600_000);
  expect(auditHasMachineTime(ready.reply)).toBe(true);
  expect(auditHasRows(ready.reply)).toBe(true);

  const self = readTeamAudit(answer({ scope: "self", rows: [], totals: { inputTokens: -4, cacheHitRate: 7 } }));
  expect(self).toMatchObject({ kind: "ready", reply: { scope: "self", rows: [] } });
  if (self.kind === "ready") {
    expect(self.reply.totals).toMatchObject({ inputTokens: 0, cacheHitRate: null });
    expect(self.reply.totals).not.toHaveProperty("machineMs");
    expect(auditHasRows(self.reply)).toBe(false);
    expect(auditHasMachineTime(self.reply)).toBe(false);
  }

  expect(readTeamAudit({ status: "signedOut" })).toEqual({ kind: "signedOut" });
  expect(readTeamAudit({ status: "off" })).toEqual({ kind: "off" });
  expect(readTeamAudit({ status: "notShared" })).toEqual({ kind: "notShared" });
  expect(readTeamAudit({ status: "failed", message: "cmux-platform refused (503)" })).toEqual({
    kind: "failed",
    message: "cmux-platform refused (503)",
  });
  expect(readTeamAudit({ status: "ok" })).toEqual({ kind: "failed" });
  expect(readTeamAudit(null)).toEqual({ kind: "failed" });
});

test("a CSV download answers its file or why it wrote none", () => {
  expect(readTeamAuditSaved({ status: "saved", path: "/Users/a/Downloads/x.csv" })).toEqual({
    kind: "saved",
    path: "/Users/a/Downloads/x.csv",
  });
  expect(readTeamAuditSaved({ status: "saved" })).toEqual({ kind: "failed" });
  expect(readTeamAuditSaved({ status: "off" })).toEqual({ kind: "off" });
});

test("formats tokens in as Costs does, hit rates as percents, days as dates and the own machine by label", () => {
  expect(auditTokensIn(totals())).toBe(200);
  expect(formatHitRate(0.8, "en")).toBe("80%");
  expect(formatHitRate(null, "en")).toBe("–");
  expect(auditRowLabel("day", { ...totals(), key: "2026-11-09" }, "en")).toBe("Mon, Nov 9");
  expect(auditRowLabel("machine", { ...totals(), key: "local:user_a", label: "local" })).toBe("local");
  expect(auditRowLabel("model", { ...totals(), key: "model-large" })).toBe("model-large");
});

test("the experiment is registered and ships off", () => {
  expect(experimentById("team-audit")).toBe(teamAudit);
  expect(teamAudit.defaultArm).toBe("off");
});

// ---- Rendered

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
  "cmuxExperiments",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/history/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) if (name !== "cmuxExperiments") scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  host = dom.window.document.getElementById("root")!;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

test("Team's table shows each row's measures, and Download CSV asks for the file and says where it went", async () => {
  const { TeamAuditScreen } = await import("../src/agent-session/acpmux/teamAudit/TeamAuditScreen");
  const calls: Record<string, unknown>[] = [];
  const load = async (params: Record<string, unknown>) => {
    calls.push(params);
    return params.format === "csv" ? { status: "saved", path: "/Users/a/Downloads/spend.csv" } : answer();
  };
  const root: Root = createRoot(host);
  await act(async () => root.render(<TeamAuditScreen load={load} now={NOW} />));
  await settle();
  expect(calls[0]).toMatchObject({ groupBy: "person", since: "2026-10-11", until: "2026-11-09", format: "json" });
  const rows = [...host.querySelectorAll("tbody tr")].map((row) =>
    [...row.querySelectorAll("th,td")].map((cell) => cell.textContent),
  );
  expect(rows).toHaveLength(2);
  expect(rows[0]![0]).toBe("user_a");
  expect(rows[0]).toContain("80%");
  expect(rows[1]).toContain("–");
  const button = [...host.querySelectorAll("button")].find((each) => each.textContent === "Download CSV")!;
  await act(async () => button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  await settle();
  expect(calls.at(-1)).toMatchObject({ format: "csv", groupBy: "person" });
  expect(host.textContent).toContain("/Users/a/Downloads/spend.csv");
  await act(async () => root.unmount());
});

test("switching the grouping keeps the last rows under their own heading until the new reply comes", async () => {
  const { TeamAuditScreen } = await import("../src/agent-session/acpmux/teamAudit/TeamAuditScreen");
  let release: (value: unknown) => void = () => undefined;
  const load = (params: Record<string, unknown>) =>
    params.groupBy === "day" ? new Promise((resolve) => (release = resolve)) : Promise.resolve(answer());
  const root: Root = createRoot(host);
  await act(async () => root.render(<TeamAuditScreen load={load} now={NOW} />));
  await settle();
  const heading = () => host.querySelector("thead .tma-key")?.textContent;
  const keys = () => [...host.querySelectorAll("tbody .tma-key")].map((cell) => cell.textContent);
  expect(heading()).toBe("Person");
  const trigger = host.querySelector<HTMLElement>(".cst-controls [aria-haspopup=menu]")!;
  await act(async () => trigger.click());
  await settle();
  const day = [...dom.window.document.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find(
    (item) => item.textContent?.trim() === "Day",
  )!;
  await act(async () => day.click());
  await settle();
  // The day read is still out: the person rows stay, still labelled as people.
  expect(host.querySelector(".tma")!.hasAttribute("data-loading")).toBe(true);
  expect(heading()).toBe("Person");
  expect(keys()).toEqual(["user_a", "user_b"]);
  await act(async () => release(answer({ groupBy: "day", rows: [{ ...totals(), key: "2026-11-09" }] })));
  await settle();
  expect(heading()).toBe("Day");
  expect(keys()).toEqual(["Mon, Nov 9"]);
  await act(async () => root.unmount());
});

test("Download CSV waits for the picked grouping's reply, then saves that reply's own days and grouping", async () => {
  const { TeamAuditScreen } = await import("../src/agent-session/acpmux/teamAudit/TeamAuditScreen");
  const calls: Record<string, unknown>[] = [];
  let release: (value: unknown) => void = () => undefined;
  const load = (params: Record<string, unknown>) => {
    calls.push(params);
    if (params.format === "csv") return Promise.resolve({ status: "saved", path: "/Users/a/Downloads/spend.csv" });
    return params.groupBy === "day" ? new Promise((resolve) => (release = resolve)) : Promise.resolve(answer());
  };
  const root: Root = createRoot(host);
  await act(async () => root.render(<TeamAuditScreen load={load} now={NOW} />));
  await settle();
  const button = () =>
    [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === "Download CSV")!;
  expect(button().disabled).toBe(false);
  const trigger = host.querySelector<HTMLElement>(".cst-controls [aria-haspopup=menu]")!;
  await act(async () => trigger.click());
  await settle();
  const day = [...dom.window.document.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find(
    (item) => item.textContent?.trim() === "Day",
  )!;
  await act(async () => day.click());
  await settle();
  // The person rows are still on screen while Day loads: Download would save the wrong table, so it waits.
  expect(button().disabled).toBe(true);
  await act(async () => button().dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  expect(calls.some((call) => call.format === "csv")).toBe(false);
  await act(async () =>
    release(
      answer({
        groupBy: "day",
        range: { since: "2026-10-12", until: "2026-11-08" },
        rows: [{ ...totals(), key: "2026-11-08" }],
      }),
    ),
  );
  await settle();
  expect(button().disabled).toBe(false);
  await act(async () => button().dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  await settle();
  expect(calls.at(-1)).toEqual({ since: "2026-10-12", until: "2026-11-08", groupBy: "day", format: "csv" });
  await act(async () => root.unmount());
});

test("a Download clicked with a new grouping, before its read starts, saves nothing", async () => {
  const { TeamAuditScreen } = await import("../src/agent-session/acpmux/teamAudit/TeamAuditScreen");
  const calls: Record<string, unknown>[] = [];
  const load = (params: Record<string, unknown>) => {
    calls.push(params);
    if (params.format === "csv") return Promise.resolve({ status: "saved", path: "/Users/a/Downloads/spend.csv" });
    return params.groupBy === "day" ? new Promise(() => {}) : Promise.resolve(answer());
  };
  const root: Root = createRoot(host);
  await act(async () => root.render(<TeamAuditScreen load={load} now={NOW} />));
  await settle();
  const button = () =>
    [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === "Download CSV")!;
  const trigger = host.querySelector<HTMLElement>(".cst-controls [aria-haspopup=menu]")!;
  await act(async () => trigger.click());
  await settle();
  const day = [...dom.window.document.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find(
    (item) => item.textContent?.trim() === "Day",
  )!;
  const stale = button();
  expect(stale.disabled).toBe(false);
  // One act: the pick and the click land before React renders or runs the read's effect, so the
  // click goes to the handler of the render that still shows the person reply.
  act(() => {
    day.click();
    stale.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  await settle();
  expect(calls.filter((call) => call.format === "csv")).toEqual([]);
  expect(button().disabled).toBe(true);
  await act(async () => root.unmount());
});

test("Team says why there is nothing: not in a sharing team, off, signed out", async () => {
  const { TeamAuditScreen } = await import("../src/agent-session/acpmux/teamAudit/TeamAuditScreen");
  for (const [status, words] of [
    ["notShared", "Only members of a team that shares usage"],
    ["off", "isn't on for your team yet"],
    ["signedOut", "Sign in to cmux"],
  ] as const) {
    const root: Root = createRoot(host);
    await act(async () => root.render(<TeamAuditScreen load={async () => ({ status })} now={NOW} />));
    await settle();
    expect(host.textContent).toContain(words);
    expect(host.querySelector("table")).toBeNull();
    await act(async () => root.unmount());
  }
});

test("History shows the Team tab only while the experiment is on", async () => {
  const { HistoryScreen } = await import("../src/agent-session/acpmux/newtab/HistoryScreen");
  const props = {
    load: async () => ({ chats: [], nextCursor: null }),
    onOpen: () => undefined,
    ledger: { load: async () => ({}), openSession: () => undefined },
    team: { load: async () => answer() },
  };
  const shown = props as unknown as ComponentProps<typeof HistoryScreen>;
  const tabs = () => [...host.querySelectorAll("[role=tab]")].map((tab) => tab.textContent);
  const root: Root = createRoot(host);
  await act(async () => root.render(<HistoryScreen {...shown} />));
  expect(tabs()).not.toContain("Team");
  await act(async () => root.unmount());
  scope.cmuxExperiments = { "team-audit": "on" };
  const again: Root = createRoot(host);
  await act(async () => again.render(<HistoryScreen {...shown} initialTab="team" />));
  await settle();
  expect(tabs()).toContain("Team");
  expect(host.querySelector(".tma")).not.toBeNull();
  await act(async () => again.unmount());
  delete scope.cmuxExperiments;
});
