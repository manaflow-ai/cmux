// An answered permission leaves the panel at once. The panel used to keep a receipt over the
// composer ("▶ Allow once") until the turn ended, which repeated what the transcript already says:
// the call is back in its place, and a single card's answer reads on its row or as a one-line
// receipt (record.ts).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { groupsHoldStack } from "../src/agent-session/acpmux/permissions/askRows";
import type { PermissionClientState, PermissionGroup } from "../src/agent-session/acpmux/permissions/protocol";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // The panel draws an edit's diff card, whose registered elements read DOM constructors at import.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document|Element|Node|MutationObserver)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  for (const key of added) delete scope[key];
  await teardownDom(saved, { scope });
});

const edit = (state: PermissionGroup["state"], decision: PermissionGroup["decision"]): PermissionGroup => ({
  groupId: "group-1",
  sessionId: "session-1",
  turnId: "turn-2",
  revision: 1,
  state,
  items: [
    {
      permissionId: "permission-1",
      request: { toolCall: { title: "Edit upload.sh", kind: "edit" } },
      state: state === "pending" ? "pending" : "resolved",
    },
  ],
  decisions: ["allow_once", "allow_chat", "deny"],
  decision,
});
const listed = (groups: PermissionGroup[]): PermissionClientState => ({
  supported: true,
  ready: true,
  groups,
  chatAllowance: false,
  loading: false,
  busy: false,
});

test("an answered permission leaves the panel at once, with no receipt over the composer", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  root = createRoot(host);
  const show = (state: PermissionClientState) =>
    act(async () =>
      root!.render(
        <PermissionPanel
          state={state}
          onRespond={() => {}}
          onRetry={() => {}}
          onRevoke={() => {}}
          onRefresh={() => {}}
        />,
      ),
    );
  const panel = () => host.querySelector(".acpmux-permission-panel")?.textContent ?? null;

  await show(listed([edit("pending", null)]));
  expect(panel()).toContain("Always");

  for (const decision of ["allow_once", "allow_chat", "deny"] as const) {
    await show(listed([edit("resolved", decision)]));
    expect(panel()).toBeNull();
  }
  await show(listed([edit("cancelled", null)]));
  expect(panel()).toBeNull();
});

test("an answered group holds no place in the asks stack over the composer", () => {
  expect(groupsHoldStack(listed([edit("pending", null)]))).toBe(true);
  expect(groupsHoldStack(listed([edit("collecting", null)]))).toBe(true);
  expect(groupsHoldStack(listed([edit("resolved", "allow_once")]))).toBe(false);
  expect(groupsHoldStack(listed([edit("cancelled", null)]))).toBe(false);
  expect(groupsHoldStack({ ...listed([edit("resolved", "deny")]), error: "The answer did not reach the host." })).toBe(
    true,
  );
  expect(groupsHoldStack(undefined)).toBe(false);
});

test("Revoke still revokes after Always, when the answered panel draws nothing", async () => {
  const { createRoot } = await import("react-dom/client");
  const { usePermissionUpkeep } = await import("../src/agent-session/acpmux/permissions/upkeep");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  let revoked = 0;
  const actions = { onRetry: () => {}, onRevoke: () => void revoked++, onRefresh: () => {} };
  const state = { ...listed([edit("resolved", "allow_chat")]), chatAllowance: true };
  // As the pane mounts it: the upkeep always, the panel only while it holds the stack.
  function Pane() {
    const still = usePermissionUpkeep(state, actions);
    return groupsHoldStack(state, still) ? (
      <PermissionPanel state={state} onRespond={() => {}} {...actions} still={still} />
    ) : null;
  }
  root ??= createRoot(host);
  await act(async () => root!.render(<Pane />));
  expect(host.querySelector(".acpmux-permission-panel")).toBeNull();
  await act(async () => {
    window.dispatchEvent(new window.CustomEvent("cmux-acpmux-permissionRevoke"));
  });
  expect(revoked).toBe(1);
});
