// l10n-allow-file: deterministic native panel fixture labels.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import {
  nativeSessionInfoDrawn,
  runNativeSessionInfoAction,
  setNativeSessionInfoHost,
} from "../src/agent-session/acpmux/session-info/native/host";
import {
  NativeSessionInfo,
  type NativeSessionInfoProps,
} from "../src/agent-session/acpmux/session-info/native/NativeSessionInfo";
import type { NativeSessionInfo as Model } from "../src/agent-session/acpmux/session-info/native/model";
import {
  resetSessionInfoState,
  sessionInfoState,
  SESSION_INFO_WIDTH,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { resetSectionOrderForTests } from "../src/agent-session/acpmux/session-info/sectionOrder";

const global = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const frames = new Map<number, FrameRequestCallback>();
const sent: (Model | null)[] = [];
let frameId = 0;
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  const replacements = {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frames.set(++frameId, callback);
      return frameId;
    },
    cancelAnimationFrame: (id: number) => frames.delete(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, global[key]);
  Object.assign(global, replacements);
  sent.length = 0;
  resetSessionInfoState();
  resetSectionOrderForTests();
  setNativeHost(async (method, params) => {
    if (method === "pane.sessionInfo") sent.push(params.info as Model | null);
    return {};
  });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(async () => {
  await act(async () => root.unmount());
  setNativeHost(undefined);
  setNativeSessionInfoHost(false);
  resetSessionInfoState();
  resetSectionOrderForTests();
  frames.clear();
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete global[key];
    else global[key] = value;
  }
  saved.clear();
});

const props = (): NativeSessionInfoProps => ({
  shown: true,
  width: 300,
  top: 28,
  side: 0,
  label: "Session Info",
  summary: { sessionId: "fixture", cwd: "/tmp/project", usage: { used: 100, size: 1000 } },
  links: [],
  artifacts: 0,
  documents: [],
  rows: [],
  agents: [],
  waiting: new Set(),
  statuses: {},
  processes: [],
  listed: true,
  transcriptTasks: [],
  sessions: [],
  workflows: [],
});

async function render(input: NativeSessionInfoProps) {
  await act(async () => root.render(<NativeSessionInfo {...input} />));
}

async function flushFrame() {
  await act(async () => {
    const pending = [...frames.values()];
    frames.clear();
    for (const callback of pending) callback(0);
  });
}

const model = () => sent.at(-1)!;

test("native expandable sections start collapsed while machine details stay visible", async () => {
  await render(props());
  await flushFrame();
  const sections = model()!.sections;
  expect(sections.find((section) => section.id === "environment")!.rows.length).toBeGreaterThan(0);
  const expandable = sections.filter((section) => section.foldable);
  expect(expandable.length).toBeGreaterThan(0);
  expect(expandable.every((section) => !section.open)).toBe(true);
});

test("a panel over the chat says so, a popover with no foot too, so the App gives it its glass", async () => {
  const input = props();
  await render({ ...input, overChat: true });
  await flushFrame();
  expect(model()).toMatchObject({ open: true, overChat: true });
  expect(model()!.foot).toBeUndefined();
  await render({ ...input, overChat: false });
  await flushFrame();
  expect(model()!.overChat).toBeUndefined();
});

test("the page posts the latest geometry once per frame and withdraws it when hidden", async () => {
  const input = props();
  await render(input);
  await render({ ...input, width: 340, foot: 120 });
  await flushFrame();
  expect(sent).toHaveLength(1);
  expect(model()).toMatchObject({ open: true, width: 340, top: 28, foot: 120 });
  expect(model()!.title).toBeUndefined();
  expect(dom.window.document.querySelector(".acpmux-session-info")).toBeNull();
  await render({ ...input, shown: false });
  await flushFrame();
  expect(model()).toMatchObject({ open: false, sections: [] });
});

test("native folds and drags use the current section model and saved page state", async () => {
  await render(props());
  await flushFrame();
  expect(model()!.sections.find((section) => section.id === "context")!.open).toBe(false);
  await act(async () => runNativeSessionInfoAction("fold:context:1"));
  await flushFrame();
  expect(model()!.sections.find((section) => section.id === "context")!.open).toBe(true);
  await act(async () => runNativeSessionInfoAction("move:context:environment"));
  await flushFrame();
  expect(model()!.sections[0]!.id).toBe("context");
});

test("the scoped breadcrumb uses the current page handler", async () => {
  let returned = 0;
  await render({ ...props(), title: "Subagent · Research", backLabel: "Back to parent", onBack: () => returned++ });
  await flushFrame();
  expect(model()).toMatchObject({ title: "Subagent · Research", backLabel: "Back to parent" });
  await act(async () => runNativeSessionInfoAction(model()!.back));
  expect(returned).toBe(1);
});

test("child agents retain the parent harness when they do not name their own", async () => {
  const input = props();
  await render({
    ...input,
    summary: { ...input.summary, sessionId: "fixture", harness: "claude" },
    agents: [{ id: "child", parent: null, name: "Research", state: "running", startedAt: 1 }],
  });
  await flushFrame();
  expect(model()!.sections.find((section) => section.id === "subagents")!.rows[0]!.harness).toBe("claude");
});

test("a stale post cannot acknowledge a newer reveal, while equivalent requests retain acknowledgment", async () => {
  const answers: (() => void)[] = [];
  let acknowledged = 0;
  setNativeHost((method, params) => {
    if (method !== "pane.sessionInfo" || !params.info) return Promise.resolve({});
    sent.push(params.info as Model);
    return new Promise((resolve) => answers.push(() => resolve({})));
  });
  const input = props();
  await render({ ...input, revealed: { section: "context", at: 1 }, onRevealed: () => acknowledged++ });
  await flushFrame();
  const revealed = { section: "context" as const, at: 2 };
  await render({ ...input, revealed, onRevealed: () => acknowledged++ });
  await act(async () => answers[0]!());
  expect(acknowledged).toBe(0);
  await flushFrame();
  await render({ ...input, width: 340, revealed, onRevealed: () => acknowledged++ });
  await act(async () => answers[1]!());
  expect(acknowledged).toBe(1);
});

test("Stop gives pending and retry feedback without submitting a double click twice", async () => {
  let attempts = 0;
  let refuse: (error: Error) => void = () => {};
  const input = {
    ...props(),
    processes: [{ id: "fixture/build", command: "bun build", startedAt: 1, state: "running" }],
    onStopProcess: () => {
      attempts++;
      return new Promise((_resolve, reject) => {
        refuse = reject;
      });
    },
  };
  const stop = () =>
    model()!
      .sections.find((section) => section.id === "tasks")!
      .rows.flatMap((row) => row.buttons ?? [])
      .find((button) => button.action === "tasks.stop:fixture/build")!;
  await render(input);
  await flushFrame();
  const action = stop().action;
  await act(async () => {
    runNativeSessionInfoAction(action);
    runNativeSessionInfoAction(action);
  });
  await flushFrame();
  expect(attempts).toBe(1);
  expect(stop().disabled).toBe(true);
  const pendingLabel = stop().label;
  await act(async () => refuse(new Error("Stop refused")));
  await flushFrame();
  expect(stop().disabled).not.toBe(true);
  expect(stop().label).not.toBe(pendingLabel);
  await act(async () => runNativeSessionInfoAction(stop().action));
  expect(attempts).toBe(2);
});

test("a refused source open is visible in the next native model", async () => {
  await render({
    ...props(),
    made: { outputs: [], pullRequests: [], scheduled: [], sources: [{ kind: "file", label: "src/main.ts" }] },
    onOpenSourceFile: () => Promise.reject(new Error("Could not open file")),
  });
  await flushFrame();
  const source = () => model()!.sections.find((section) => section.id === "sources")!.rows[0]!;
  await act(async () => runNativeSessionInfoAction(source().action));
  await flushFrame();
  expect(source()).toMatchObject({ tone: "failed", subtitle: "Could not open file" });
});

test("native edge reset uses the same saved default width as the web edge", async () => {
  await render(props());
  await flushFrame();
  await act(async () => runNativeSessionInfoAction("width:500"));
  expect(sessionInfoState().width).toBe(500);
  await act(async () => runNativeSessionInfoAction("width:reset"));
  expect(sessionInfoState().width).toBe(SESSION_INFO_WIDTH.fallback);
});

test("a failed latest post restores web fallback even after an equivalent render", async () => {
  let rejectPost: (error: Error) => void = () => {};
  setNativeSessionInfoHost(true);
  setNativeHost((method, params) => {
    if (method !== "pane.sessionInfo" || !params.info) return Promise.resolve({});
    return new Promise((_resolve, reject) => {
      rejectPost = reject;
    });
  });
  const input = props();
  await render(input);
  await flushFrame();
  await render({ ...input });
  await flushFrame();
  await act(async () => rejectPost(new Error("Host unavailable")));
  expect(nativeSessionInfoDrawn()).toBe(false);
});

test("an older failed post cannot withdraw a newer native model", async () => {
  const rejects: ((error: Error) => void)[] = [];
  setNativeSessionInfoHost(true);
  setNativeHost((method, params) => {
    if (method !== "pane.sessionInfo" || !params.info) return Promise.resolve({});
    return new Promise((_resolve, reject) => rejects.push(reject));
  });
  const input = props();
  await render(input);
  await flushFrame();
  await render({ ...input, width: 360 });
  await flushFrame();
  await act(async () => rejects[0]!(new Error("Old request failed")));
  expect(nativeSessionInfoDrawn()).toBe(true);
  await act(async () => rejects[1]!(new Error("Latest request failed")));
  expect(nativeSessionInfoDrawn()).toBe(false);
});
