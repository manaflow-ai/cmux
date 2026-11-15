// The Add Machine card's checklist and UI state (ported from AddMachineFlowTests and
// HostChecklistSummaryTests when the card moved to the server-cards page).
import { describe, expect, test } from "bun:test";
import { Checklist, KNOWN_STEPS, parseHostLine } from "../src/pages/server-cards/add-machine/checklist";
import {
  badgeKey,
  buttonKey,
  buttons,
  defaultName,
  details,
  foldRun,
  peerTarget,
  phaseOf,
  stepKey,
} from "../src/pages/server-cards/add-machine/model";
import type { HostCandidate } from "../src/pages/server-cards/add-machine/types";

const step = (name: string, state: string, detail = "", fix?: string) =>
  JSON.stringify({ step: name, state, detail, ...(fix !== undefined ? { fix } : {}) });
const report = (ok: boolean, steps: string[]) =>
  `{"report":{"name":"hb","host":"huge-blue","ok":${ok},"steps":[${steps.join(",")}]}}`;
const rowStatus = (list: Checklist, name: string) => list.row(name)?.status;

describe("host lines", () => {
  test("step lines parse, an empty fix is no fix, noise is ignored", () => {
    expect(parseHostLine(step("peer-back", "warn", "no route back", "add a key on the host"))).toEqual({
      step: { step: "peer-back", state: "warn", detail: "no route back", fix: "add a key on the host" },
    });
    expect(parseHostLine('{"step":"daemon","state":"fixed","detail":"started","fix":""}')).toEqual({
      step: { step: "daemon", state: "fixed", detail: "started" },
    });
    expect(parseHostLine("")).toBeUndefined();
    expect(parseHostLine("connecting to huge-blue…")).toBeUndefined();
    expect(parseHostLine('{"event":"progress"}')).toBeUndefined();
    expect(parseHostLine('{"step":"reach"')).toBeUndefined();
  });

  test("an unknown state reads as a warning; the report keeps its steps", () => {
    expect(parseHostLine(step("reach", "maybe"))).toEqual({ step: { step: "reach", state: "warn", detail: "" } });
    const line = parseHostLine(report(false, [step("reach", "ok"), step("daemon", "fail", "no answer", "start it")]));
    expect(line && "report" in line && line.report.steps.map((each) => each.step)).toEqual(["reach", "daemon"]);
  });
});

describe("checklist", () => {
  test("fills in live and marks the next step running", () => {
    const list = new Checklist();
    expect(list.rows.map((row) => row.step)).toEqual([...KNOWN_STEPS]);
    expect(list.rows.every((row) => row.status.kind === "pending")).toBe(true);
    list.start();
    expect(rowStatus(list, "reach")).toEqual({ kind: "running" });
    list.apply({ step: "reach", state: "ok", detail: "ssh ok" });
    expect(rowStatus(list, "reach")).toEqual({ kind: "done", state: "ok" });
    expect(list.row("reach")?.detail).toBe("ssh ok");
    expect(rowStatus(list, "install")).toEqual({ kind: "running" });
    expect(rowStatus(list, "daemon")).toEqual({ kind: "pending" });
    list.apply({ step: "install", state: "fixed", detail: "" });
    expect(rowStatus(list, "daemon")).toEqual({ kind: "running" });
  });

  test("an unknown future step shows by its raw name after the last line", () => {
    const list = new Checklist();
    list.start();
    list.apply({ step: "reach", state: "ok", detail: "" });
    list.apply({ step: "firewall", state: "warn", detail: "port 22 filtered" });
    expect(list.rows.map((row) => row.step)).toEqual([
      "reach",
      "firewall",
      "install",
      "daemon",
      "update",
      "harness",
      "peer",
      "peer-back",
      "identity",
      "approvals",
    ]);
    expect(rowStatus(list, "firewall")).toEqual({ kind: "done", state: "warn" });
    expect(stepKey("firewall")).toBeUndefined();
    expect(rowStatus(list, "install")).toEqual({ kind: "running" });
  });

  test("update follows the daemon; approvals is the last row and named", () => {
    expect(KNOWN_STEPS.indexOf("update")).toBe(KNOWN_STEPS.indexOf("daemon") + 1);
    expect(KNOWN_STEPS.at(-1)).toBe("approvals");
    expect(stepKey("update")).toBe("addMachine.step.update");
    expect(stepKey("approvals")).toBe("addMachine.step.approvals");
    const list = new Checklist();
    list.start();
    list.apply({ step: "identity", state: "ok", detail: "" });
    list.apply({ step: "approvals", state: "fixed", detail: "" });
    expect(list.rows.filter((row) => row.step === "approvals").length).toBe(1);
  });

  test("the report skips what it did not run and a stop fails the running step", () => {
    const list = new Checklist();
    list.start();
    const reach = { step: "reach", state: "fail" as const, detail: "no route", fix: "Turn on Tailscale" };
    list.apply(reach);
    list.finish({ name: "hb", host: "hb", ok: false, steps: [reach] });
    expect(list.failing?.step).toBe("reach");
    expect(list.failing?.fix).toBe("Turn on Tailscale");
    expect(list.rows.slice(1).every((row) => row.status.kind === "done" && row.status.state === "skip")).toBe(true);

    const stopped = new Checklist();
    stopped.start();
    stopped.apply({ step: "reach", state: "ok", detail: "" });
    stopped.stop("cmux-tui: unknown subcommand host");
    expect(stopped.failing?.step).toBe("install");
    expect(stopped.failing?.detail).toBe("cmux-tui: unknown subcommand host");
    expect(rowStatus(stopped, "daemon")).toEqual({ kind: "pending" });
  });

  test("a joined check starts empty and a stop with nothing open adds a Check it row", () => {
    const list = new Checklist();
    list.start([]);
    list.stop("sign in to check");
    expect(list.rows).toEqual([{ step: "check", status: { kind: "done", state: "fail" }, detail: "sign in to check" }]);
  });

  test("a run going well is one line; a warning or a failure opens the list", () => {
    const list = new Checklist();
    list.start(["reach", "install", "daemon"]);
    expect(list.summary).toEqual({ done: 0, total: 3, current: "reach" });
    expect(list.needsPerson).toBe(false);
    list.apply({ step: "reach", state: "ok", detail: "ssh ok" });
    list.apply({ step: "install", state: "fixed", detail: "installed" });
    expect(list.summary).toEqual({ done: 2, total: 3, current: "daemon" });
    list.apply({ step: "daemon", state: "skip", detail: "not asked" });
    expect(list.summary).toEqual({ done: 3, total: 3 });
    expect(list.needsPerson).toBe(false);
    const warned = new Checklist();
    warned.start(["reach", "approvals"]);
    warned.apply({ step: "approvals", state: "warn", detail: "not enrolled" });
    expect(warned.needsPerson).toBe(true);
  });
});

describe("a run's events", () => {
  test("fold into the checklist: install runs again, a stop names why", () => {
    const { checklist, installing } = foldRun([
      { kind: "start" },
      { kind: "line", line: step("reach", "ok") },
      { kind: "line", line: report(false, [step("reach", "ok"), step("install", "fail", "wrong platform")]) },
      { kind: "install" },
    ]);
    expect(installing).toBe(true);
    expect(rowStatus(checklist, "install")).toEqual({ kind: "running" });
    const stopped = foldRun([{ kind: "start" }, { kind: "stop", detail: "The app could not connect" }]);
    expect(stopped.checklist.failing).toMatchObject({ step: "reach", detail: "The app could not connect" });
    const joined = foldRun([{ kind: "start", joined: true }]);
    expect(joined.checklist.rows).toEqual([]);
  });
});

describe("the footer", () => {
  const add = { kind: "add" } as const;
  const check = { kind: "check", host: "hb", machineID: "ssh-hb" } as const;
  const joined = { kind: "checkJoined", id: "m_1", name: "lane" } as const;
  const actions = (list: { action: string; key?: string; enabled: boolean }[]) =>
    list.map((each) => `${each.action}${each.key ? `:${each.key}` : ""}${each.enabled ? "" : ":off"}`);

  test("each phase of each mode has its buttons, Escape first and Return last", () => {
    expect(actions(buttons("pick", add, false))).toEqual(["cancel:escape", "add:return:off"]);
    expect(actions(buttons("pick", add, true))).toEqual(["cancel:escape", "add:return"]);
    expect(actions(buttons("running", add, true))).toEqual(["cancel:escape", "add:return:off"]);
    expect(actions(buttons("ready", add, true))).toEqual(["done:escape", "openWorkspace:return:off"]);
    expect(actions(buttons("ready", add, true, "ssh-1"))).toEqual(["done:escape", "openWorkspace:return"]);
    expect(actions(buttons("failed", add, true))).toEqual(["copyDetails", "changeHost", "tryAgain:return"]);
    expect(actions(buttons("running", check, true))).toEqual(["cancel:escape", "fix:return:off"]);
    expect(actions(buttons("ready", check, true))).toEqual(["done:return"]);
    expect(actions(buttons("failed", check, true))).toEqual(["copyDetails", "fix:return"]);
    expect(actions(buttons("running", joined, true))).toEqual(["cancel:escape"]);
    expect(actions(buttons("failed", joined, true))).toEqual(["copyDetails", "done:return"]);
  });

  test("Change Host is only offered for a failed add; Add and Fix read as running", () => {
    expect(buttons("failed", check, true).some((each) => each.action === "changeHost")).toBe(false);
    expect(buttonKey("changeHost", "failed")).toBe("addMachine.changeHost");
    expect(buttonKey("add", "running")).toBe("addMachine.adding");
    expect(buttonKey("fix", "running")).toBe("addMachine.checking");
    expect(buttonKey("fix", "failed")).toBe("addMachine.fix");
  });

  test("no run is the pick layout, else the run's outcome", () => {
    expect(phaseOf(undefined)).toBe("pick");
    expect(phaseOf({ id: 1, host: "h", name: "n", events: [], outcome: "failed" })).toBe("failed");
  });
});

describe("candidates", () => {
  const candidate = (patch: Partial<HostCandidate>): HostCandidate => ({
    id: "hb",
    name: "huge-blue",
    os: "linux",
    online: true,
    alreadyPeer: false,
    inApp: false,
    destination: "huge-blue.tail1234.ts.net",
    pickable: true,
    ...patch,
  });

  test("added, offline, agent peers and ssh off say why, in the order a person fixes them", () => {
    expect(badgeKey(candidate({ inApp: true, online: false }))).toBe("addMachine.candidate.added");
    expect(badgeKey(candidate({ online: false, alreadyPeer: true }))).toBe("addMachine.candidate.offline");
    expect(badgeKey(candidate({ alreadyPeer: true }))).toBe("addMachine.candidate.agentPeer");
    expect(badgeKey(candidate({ sshOK: false }))).toBe("addMachine.candidate.sshOff");
    expect(badgeKey(candidate({}))).toBeUndefined();
  });

  test("a picked peer names the machine while the field still holds it", () => {
    const peer = candidate({ alreadyPeer: true, peer: " lane-3 ", destination: "leo@lane-3" });
    expect(peerTarget(peer, "leo@lane-3", { host: "leo@lane-3" })).toBe(peer);
    expect(defaultName(peer, "lane-3x")).toBe("lane-3");
    expect(peerTarget(peer, "leo@other", { host: "leo@other" })).toBeUndefined();
    expect(peerTarget(peer, "leo@lane-3", null)).toBeUndefined();
    expect(defaultName(undefined, "other")).toBe("other");
  });
});

test("Copy Details is the host, the name and one line per step with its fix", () => {
  const list = new Checklist();
  list.start(["reach", "install"]);
  list.apply({ step: "reach", state: "fail", detail: "no route", fix: "Turn on Tailscale" });
  expect(details("leo@hb", "hb", list.rows)).toBe(
    "host: leo@hb\nname: hb\nreach: fail - no route (fix: Turn on Tailscale)\ninstall: running",
  );
});
