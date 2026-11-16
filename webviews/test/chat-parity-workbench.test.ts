import { expect, test } from "bun:test";
import type { GalleryEntry } from "../src/gallery/format";
import { SCENARIOS, scenarioFrame, selectedScenario } from "../src/gallery/parity/scenarios";
import turnStates from "../src/gallery/parity/turnStates.gallery";
import { GALLERY_NOW } from "../src/gallery/clock";
import { WORKED, WORKING, turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import fullConversation from "../src/gallery/parity/fullConversation.gallery";
import { turnFiles } from "../src/agent-session/acpmux/diff";
import { stackMaterialsSnapshot, STACK_QUESTION } from "../src/gallery/parity/stackMaterials.gallery";
import { waitingAsks } from "../src/agent-session/acpmux/conversation/turns";
import { hatQuestions, hatShows } from "../src/agent-session/acpmux/question/hatModel";
import { startedSessions } from "../src/agent-session/acpmux/started/startedSessions";
import {
  createLinger,
  stepLinger,
  lingeringTrayItems,
  trayItemEnd,
} from "../src/agent-session/acpmux/subagents/trayLinger";
import { trayItems, finishedTrayItems, trayItemKey } from "../src/agent-session/acpmux/subagents/runningTray";
import { withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";

import { backgroundWorkSnapshot } from "../src/gallery/parity/backgroundWork.gallery";
import { transcriptBackgroundTasks } from "../src/agent-session/acpmux/summary/sessionSummary";
import { backgroundCommands } from "../src/agent-session/acpmux/session-info/processes";

test("every curated scenario resolves to a real seeded chat fixture", async () => {
  const entries = new Map<string, GalleryEntry>();
  for (const scenario of SCENARIOS) {
    let entry = entries.get(scenario.source);
    if (!entry) {
      const module = (await import(`../${scenario.source}`)) as { default: GalleryEntry };
      entry = module.default;
      entries.set(scenario.source, entry);
    }
    expect(entry.id).toBe(scenario.entry);
    if (scenario.entry === "agent-pane.question-prompt-reference") {
      expect(entry.host).toBe("component");
      expect("pane" in entry && entry.pane).toBe(true);
    } else expect(entry.host).toBe("agent-pane");
    expect(entry.variants[scenario.variant]).toBeDefined();
  }
  expect(new Set(SCENARIOS.map((scenario) => scenario.id)).size).toBe(SCENARIOS.length);
});

test("frame links reproduce the seed, dimensions, appearance and optional lifecycle", () => {
  for (const scenario of SCENARIOS) {
    const url = new URL(scenarioFrame(scenario, "light", 420), "http://localhost");
    expect(url.pathname).toBe("/gallery/frame.html");
    expect(url.searchParams.get("source")).toBe(scenario.source);
    expect(url.searchParams.get("variant")).toBe(scenario.variant);
    expect(url.searchParams.get("width")).toBe("420");
    expect(url.searchParams.get("theme")).toBe("Apple System Colors Light");
    expect(url.searchParams.get("script")).toBe(scenario.script ?? null);
    expect(url.searchParams.get("loop")).toBe(scenario.script ? "0" : null);
  }
  expect(selectedScenario("missing").id).toBe("full-conversation");
  expect(selectedScenario(null).id).toBe("full-conversation");
  expect(SCENARIOS[0]?.id).toBe("full-conversation");
  expect(
    SCENARIOS.filter((scenario) => scenario.group === "Work headers")
      .slice(0, 2)
      .map((scenario) => scenario.id),
  ).toEqual(["working", "completed"]);
  expect(selectedScenario("chief-task").id).toBe("chief-task");
});

test("focused work fixtures project real visible work headers and freeze at the final answer", () => {
  for (const [name, variant] of Object.entries(turnStates.variants)) {
    const snapshot = variant.snapshot;
    const project = (now: number) =>
      turnViewFrom(snapshot.rows, new Set(), {
        working: snapshot.isWorking,
        agentFamily: "codex",
        now,
      });
    const header = project(GALLERY_NOW).rows.find((row) => row.kind === (name === "working" ? WORKING : WORKED));
    expect(header).toBeDefined();
    if (name !== "working") expect(header?.durationMs).toBe(15_000);
    if (name === "final-answer-streaming") {
      expect(header?.foldOpen).toBe(false);
      expect(project(GALLERY_NOW + 60_000).rows.find((row) => row.kind === WORKED)?.durationMs).toBe(15_000);
      expect(snapshot.rows.find((row) => row.assistantPhase === "final_answer")?.streaming).toBe(true);
    }
    if (name === "stopped") expect(header?.status).toBe("cancelled");
    expect(variant.play).toBeDefined();
  }
});

test("the full conversation combines real turn, file, Chief, subagent and live-work states", () => {
  const snapshot = fullConversation.variants.tour!.snapshot;
  expect(new Set(snapshot.rows.map((row) => row.id)).size).toBe(snapshot.rows.length);
  const calls = snapshot.rows.flatMap((row) => row.items?.flatMap((item) => (item.tool ? [item.tool] : [])) ?? []);
  expect(new Set(calls.map((call) => call.id)).size).toBe(calls.length);
  const files = turnFiles(snapshot.rows);
  expect(files).toHaveLength(9);
  expect(files.reduce((total, file) => total + file.additions, 0)).toBe(129);
  expect(files.reduce((total, file) => total + file.deletions, 0)).toBe(5);
  expect(snapshot.rows.find((row) => row.id === "tour-chief-message")?.from).toBe("chief");
  expect(snapshot.rows.find((row) => row.id === "tour-review-group")?.subagents?.[0]?.result).toContain(
    "corner tests pass",
  );
  const projected = turnViewFrom(withSubagentLines(snapshot.rows), new Set(), {
    working: snapshot.isWorking,
    agentFamily: "codex",
    now: GALLERY_NOW,
  });
  expect(projected.rows.find((row) => row.id === "worked-tour-normal-prompt")?.durationMs).toBe(24_000);
  expect(projected.rows.find((row) => row.id === "tour-first-final")?.text).toContain("**Finding:**");
  expect(projected.rows.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(true);
  expect(projected.rows.some((row) => row.kind === WORKING)).toBe(true);
  expect(
    projected.rows.some(
      (row) => row.kind === "subagentDone" && row.subagents?.[0]?.id === "tour-settings-corner-review",
    ),
  ).toBe(true);
  expect(fullConversation.variants.tour!.play).toBeDefined();
});

test("the stacked-material screenshot keeps every panel and all five tray entries", () => {
  const snapshot = stackMaterialsSnapshot;
  const view = turnViewFrom(snapshot.rows, new Set());
  expect(waitingAsks(view).map((row) => row.nextStep?.ask.question)).toEqual([STACK_QUESTION]);
  const questions = hatQuestions({
    sessionId: snapshot.sessionId,
    nextStepOwner: snapshot.sessionId,
    rows: view.rows,
    sessions: snapshot.sessions,
    asks: [],
  });
  expect(hatShows(questions)).toBe(true);
  expect(questions[0]?.prompt).toBe(STACK_QUESTION);
  const children = startedSessions(snapshot.sessions, snapshot.sessionId);
  const agents = snapshot.rows.flatMap((row) => row.subagents ?? []);
  expect(trayItems(agents, [], children, false).map((item) => item.kind)).toEqual(["session", "session"]);
  const ended = finishedTrayItems(agents, children);
  const linger = stepLinger(createLinger(), {
    live: trayItems(agents, [], children, false).map(trayItemKey),
    ended: ended.map((item) => ({ key: trayItemKey(item), endedAt: trayItemEnd(item) })),
    hold: false,
    now: GALLERY_NOW,
  });
  expect(lingeringTrayItems(ended, linger.kept, linger.ends)).toHaveLength(3);
  expect(snapshot.summary?.goal?.status).toBe("running");
  const scenario = selectedScenario("stack-materials");
  expect(new URL(scenarioFrame(scenario, "dark", 920), "http://localhost").searchParams.get("background")).toBe("busy");
});

test("background scenarios contain one wait, four completed commands, and optional agent logos", () => {
  for (const mixed of [false, true]) {
    const snapshot = backgroundWorkSnapshot(mixed);
    const commands = backgroundCommands([], transcriptBackgroundTasks(snapshot.rows), false);
    expect(commands.filter((command) => command.state === "running").map((command) => command.command)).toEqual([
      "sleep 300",
    ]);
    const ended = commands
      .filter((command) => command.state === "completed")
      .map((command) => ({ kind: "command" as const, id: command.id, command }));
    const agents = snapshot.rows.flatMap((row) => row.subagents ?? []);
    const live = trayItems(agents, commands, [], snapshot.isWorking);
    expect(live).toHaveLength(mixed ? 3 : 1);
    const state = createLinger();
    const initial = backgroundWorkSnapshot(mixed, false);
    const initialCommands = backgroundCommands([], transcriptBackgroundTasks(initial.rows), false);
    stepLinger(state, {
      live: trayItems(agents, initialCommands, [], true).map(trayItemKey),
      ended: [],
      hold: false,
      now: GALLERY_NOW - 1000,
    });
    const linger = stepLinger(state, {
      live: live.map(trayItemKey),
      ended: ended.map((item) => ({ key: trayItemKey(item), endedAt: trayItemEnd(item) })),
      hold: false,
      now: GALLERY_NOW,
    });
    expect(lingeringTrayItems(ended, linger.kept, linger.ends)).toHaveLength(4);
    expect(agents.map((agent) => agent.harness)).toEqual(mixed ? ["claude", "codex"] : []);
  }
});
