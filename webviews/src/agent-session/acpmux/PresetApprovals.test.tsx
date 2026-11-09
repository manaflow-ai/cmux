// The home's Unattended runs card (PresetApprovals.tsx): nothing without presets or the method, a
// two-step Approve that sends the shown digest, a one-click Revoke, a changed preset read again.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PresetApprovals } from "./PresetApprovals";
import type { PresetApprovalsClient } from "./presetApprovalsModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const NOW = Date.UTC(2026, 10, 9, 6, 0, 0);
const needs = (over: Record<string, unknown> = {}) => ({
  name: "agent-lane",
  harness: "claude",
  model: "claude-opus-5-5",
  effort: "medium",
  policy: "approve-all",
  description: "Fleet lanes that run without asking",
  digest: "digest-1",
  blocked: null,
  approval: null,
  runs: 0,
  lastRun: null,
  asks: [{ at: NOW - 5 * 60_000, host: "gcp-agent-lane-1", from: "claude-sr2-coord" }],
  ...over,
});
const approved = needs({
  name: "review-lane",
  digest: "digest-r",
  approval: { by: "leoli", host: "cosmic-gray", at: NOW - 60 * 60_000 },
  runs: 3,
  lastRun: { at: NOW - 10 * 60_000, host: "gcp-agent-lane-2", sessionId: "s1", from: "coord" },
  asks: [],
});
const machines = ["gcp-agent-lane-1", "gcp-agent-lane-2"];

type Call = { name: string; approve: boolean; digest?: string };
function fakeClient(
  replies: (() => Promise<unknown>)[],
  approve: (call: Call) => Promise<unknown> = async (call) =>
    needs({ approval: call.approve ? approved.approval : null }),
) {
  const calls: Call[] = [];
  let reads = 0;
  const client: PresetApprovalsClient = {
    presetApprovals: () => replies[Math.min(reads++, replies.length - 1)]!(),
    presetApprove: (name, approveIt, digest) => {
      const call = { name, approve: approveIt, ...(digest === undefined ? {} : { digest }) };
      calls.push(call);
      return approve(call);
    },
  };
  return { client, calls, reads: () => reads };
}

async function render(client: PresetApprovalsClient) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<PresetApprovals client={client} now={NOW} />);
  });
  await act(async () => {});
  return container;
}

const button = (container: HTMLElement, text: string) =>
  [...container.querySelectorAll("button")].find((b) => b.textContent === text);
async function click(element: Element | undefined) {
  expect(element).toBeDefined();
  await act(async () => (element as HTMLElement).click());
  await act(async () => {});
}

test("renders nothing when acpmux lists no presets", async () => {
  const { client } = fakeClient([async () => ({ presets: [], machines })]);
  const container = await render(client);
  expect(container.innerHTML).toBe("");
});

test("renders nothing when acpmux has no such method", async () => {
  const { client } = fakeClient([
    async () => Promise.reject(Object.assign(new Error("Method not found"), { code: -32601 })),
  ]);
  const container = await render(client);
  expect(container.innerHTML).toBe("");
});

test("a preset waiting on approval says what it runs, where, and who tried it", async () => {
  const { client } = fakeClient([async () => ({ presets: [needs()], machines })]);
  const container = await render(client);
  const text = container.textContent ?? "";
  expect(text).toContain("Unattended runs");
  expect(text).toContain("agent-lane");
  expect(text).toContain("Fleet lanes that run without asking");
  expect(text).toContain("Claude Code · claude-opus-5-5 · medium · runs every command without asking");
  expect(text).toContain("On fleet agent machines: gcp-agent-lane-1, gcp-agent-lane-2");
  expect(text).toContain("claude-sr2-coord tried it on gcp-agent-lane-1");
});

test("Approve takes a second click, which sends the shown digest, then reads again", async () => {
  const { client, calls, reads } = fakeClient([
    async () => ({ presets: [needs()], machines }),
    async () => ({ presets: [needs({ approval: approved.approval, runs: 0 })], machines }),
  ]);
  const container = await render(client);
  await click(button(container, "Approve"));
  expect(calls).toEqual([]);
  const consequence = container.querySelector(".acpmux-presets-consequence")!.textContent!;
  expect(consequence).toContain("will not ask before each command");
  expect(consequence).toContain("Any edit to the preset withdraws this approval.");
  expect(consequence).toContain("Claude Code's own guards still apply.");
  await click(button(container, "Approve unattended runs"));
  expect(calls).toEqual([{ name: "agent-lane", approve: true, digest: "digest-1" }]);
  expect(reads()).toBe(2);
  expect(container.textContent).toContain("Approved by leoli on cosmic-gray");
  expect(button(container, "Revoke")).toBeDefined();
});

test("Cancel leaves the confirmation without sending", async () => {
  const { client, calls } = fakeClient([async () => ({ presets: [needs()], machines })]);
  const container = await render(client);
  await click(button(container, "Approve"));
  await click(button(container, "Cancel"));
  expect(calls).toEqual([]);
  expect(button(container, "Approve")).toBeDefined();
});

test("an approved preset shows its runs and revokes in one click", async () => {
  const { client, calls } = fakeClient([async () => ({ presets: [approved], machines })], async () => ({
    ...approved,
    approval: null,
  }));
  const container = await render(client);
  expect(container.textContent).toContain("Approved by leoli on cosmic-gray · Runs: 3 · Last run 10m ago");
  await click(button(container, "Revoke"));
  expect(calls).toEqual([{ name: "review-lane", approve: false }]);
});

test("a blocked preset says why and offers no button", async () => {
  const { client } = fakeClient([async () => ({ presets: [needs({ blocked: "preset.env" })], machines })]);
  const container = await render(client);
  expect(container.textContent).toContain("it sets environment variables for the agent");
  expect(container.querySelectorAll("button").length).toBe(0);
});

test("a preset changed since the read is read again, its new contents shown, and confirmed afresh", async () => {
  const { client, calls, reads } = fakeClient(
    [
      async () => ({ presets: [needs()], machines }),
      async () => ({ presets: [needs({ digest: "digest-2", description: "Now with a wider policy" })], machines }),
    ],
    async () =>
      Promise.reject(
        Object.assign(new Error("changed"), {
          data: { reason: "preset_approval.changed" },
          reason: "preset_approval.changed",
        }),
      ),
  );
  const container = await render(client);
  await click(button(container, "Approve"));
  await click(button(container, "Approve unattended runs"));
  expect(calls).toEqual([{ name: "agent-lane", approve: true, digest: "digest-1" }]);
  expect(reads()).toBe(2);
  expect(container.textContent).toContain("Now with a wider policy");
  expect(container.querySelector("[role=alert]")!.textContent).toContain("The preset changed since this card read it.");
  // The confirmation starts over, and the next approval sends the new digest.
  expect(button(container, "Approve unattended runs")).toBeUndefined();
  await click(button(container, "Approve"));
  await click(button(container, "Approve unattended runs"));
  expect(calls.at(-1)).toEqual({ name: "agent-lane", approve: true, digest: "digest-2" });
});

test("a refusal names its reason on the row", async () => {
  const { client } = fakeClient([async () => ({ presets: [needs()], machines })], async () =>
    Promise.reject(Object.assign(new Error("no"), { data: { reason: "permission.person_required" } })),
  );
  const container = await render(client);
  await click(button(container, "Approve"));
  await click(button(container, "Approve unattended runs"));
  expect(container.querySelector("[role=alert]")!.textContent).toBe("Only you can approve this, from the cmux app.");
});

test("a switch away and back reads nothing; nothing polls", async () => {
  const { client, reads } = fakeClient([async () => ({ presets: [needs()], machines })]);
  await render(client);
  expect(reads()).toBe(1);
  await act(async () => {
    dom!.window.document.dispatchEvent(new dom!.window.Event("visibilitychange"));
  });
  expect(reads()).toBe(1);
});
