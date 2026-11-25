// l10n-allow-file: synthetic pane identities and names, never shipped UI.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useShownSubagent } = await import("../src/agent-session/acpmux/subagents/subagentShown");
const { agentTone } = await import("../src/agent-session/acpmux/subagents/agentTones");
const { workflowPaneId } = await import("../src/agent-session/acpmux/summary/workflowTranscript");
const { BACKGROUND_PANE } = await import("../src/agent-session/acpmux/backgroundTasks/backgroundPane");

const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
const call = async (method: string, params: Record<string, unknown>) => {
  calls.push({ method, params });
};
type Props = { ownPane: boolean; id?: string; title?: string };
const Probe = ({ ownPane, id, title }: Props) => {
  useShownSubagent(call, ownPane, id, title);
  return null;
};
let root: ReturnType<typeof createRoot> | undefined;
const show = async (props: Props) => {
  root ??= createRoot(document.getElementById("root")!);
  await act(async () => root!.render(createElement(Probe, props)));
};
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  calls.length = 0;
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const workflow = workflowPaneId({ sessionId: "chat", runId: "workflow-run", agentId: "review" });

test("switching a child pane to a workflow clears its tint before workflow rows are named", async () => {
  await show({ ownPane: true, id: "agent-1", title: "Reviewer" });
  expect(calls.at(-1)).toEqual({
    method: "chat.subagentShown",
    params: { subagent: "agent-1", title: "Reviewer", tone: agentTone("agent-1") },
  });
  await show({ ownPane: true, id: workflow });
  expect(calls.at(-1)).toEqual({ method: "chat.subagentShown", params: { subagent: workflow } });
  expect(calls).toHaveLength(2);
  await show({ ownPane: true, id: workflow, title: "Workflow reviewer" });
  expect(calls.at(-1)).toEqual({
    method: "chat.subagentShown",
    params: { subagent: workflow, title: "Workflow reviewer" },
  });
  await show({ ownPane: true, id: "agent-2", title: "Builder" });
  expect(calls.at(-1)?.params.tone).toBe(agentTone("agent-2"));
  await show({ ownPane: true });
  expect(calls.at(-1)).toEqual({ method: "chat.subagentShown", params: {} });
});

test("a newly opened child keeps its initial identity until its name arrives", async () => {
  await show({ ownPane: true });
  await show({ ownPane: true, id: "agent-1" });
  expect(calls).toHaveLength(0);
  await show({ ownPane: true, id: "agent-1", title: "Reviewer" });
  expect(calls).toHaveLength(1);
  await show({ ownPane: true, id: "agent-1", title: "Reviewer" });
  expect(calls).toHaveLength(1);
});

test("the parent and Background tasks panes do not publish subagent identity", async () => {
  await show({ ownPane: false, id: "agent-1", title: "Reviewer" });
  await show({ ownPane: false, id: BACKGROUND_PANE, title: "Background tasks" });
  expect(calls).toHaveLength(0);
});
