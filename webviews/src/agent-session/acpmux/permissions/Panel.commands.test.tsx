import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React from "react";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { PermissionPanel } from "./Panel";
import type { PermissionClientState, PermissionGroup } from "./protocol";

const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "HTMLElement", "HTMLDivElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  HTMLDivElement: dom.window.HTMLDivElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const group: PermissionGroup = {
  groupId: "group-1",
  sessionId: "session-1",
  turnId: "turn-1",
  revision: 4,
  state: "pending",
  decision: null,
  decisions: ["allow_once", "allow_chat", "deny"],
  items: [{ permissionId: "permission-1", state: "pending", request: { toolCall: { title: "Write file" } } }],
};

function makeState(overrides: Partial<PermissionClientState> = {}): PermissionClientState {
  return {
    supported: true,
    ready: true,
    groups: [group],
    chatAllowance: false,
    loading: false,
    busy: false,
    ...overrides,
  };
}

async function mounted(state: PermissionClientState, calls: { decision?: string[] }) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root.render(
      createElement(PermissionPanel, {
        state,
        onRespond: (_id: string, _revision: number, decision: string) => calls.decision?.push(decision),
        onRetry: () => calls.decision?.push("retry"),
        onRevoke: () => calls.decision?.push("revoke"),
        onRefresh: () => calls.decision?.push("refresh"),
      }),
    ),
  );
  return root;
}

test("registered permission commands answer the focused pending group and expand details", async () => {
  const calls: { decision?: string[] } = { decision: [] };
  const root = await mounted(makeState(), calls);
  try {
    await act(async () => dom.window.dispatchEvent(new dom.window.Event("cmux-acpmux-permissionAllowOnce")));
    expect(calls.decision).toEqual(["allow_once"]);
    await act(async () => dom.window.dispatchEvent(new dom.window.Event("cmux-acpmux-permissionExpand")));
    expect(dom.window.document.querySelector("details")?.open).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

test("permission commands refuse collecting, uncertain, and stale owner state", async () => {
  for (const state of [
    makeState({ groups: [{ ...group, state: "collecting" }] }),
    makeState({ uncertain: true }),
    makeState({ ready: false }),
  ]) {
    const calls: { decision?: string[] } = { decision: [] };
    const root = await mounted(state, calls);
    try {
      await act(async () => dom.window.dispatchEvent(new dom.window.Event("cmux-acpmux-permissionDeny")));
      expect(calls.decision).toEqual([]);
    } finally {
      await act(async () => root.unmount());
    }
  }
});
