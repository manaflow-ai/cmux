// An answered permission leaves the chat with its turn (dogfood run 5). After "Allow once" the
// panel kept a strip above the composer, "ACP requests only · Isolation unverified" and
// "Allow once", for the rest of the chat, turns after the one that asked included. Codex and
// Claude keep an answered approval with its turn. The receipt now shows while the turn that
// asked still runs, and the panel leaves once that turn ends.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PermissionClientState, PermissionGroup } from "../src/agent-session/acpmux/permissions/protocol";

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

afterAll(() => {
  act(() => root?.unmount());
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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

test("an answered permission shows while its turn runs, and leaves the chat once the turn ends", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  root = createRoot(host);
  const show = (state: PermissionClientState, working: boolean) =>
    act(async () =>
      root!.render(
        <PermissionPanel
          state={state}
          working={working}
          onRespond={() => {}}
          onRetry={() => {}}
          onRevoke={() => {}}
          onRefresh={() => {}}
        />,
      ),
    );
  const panel = () => host.querySelector(".acpmux-permission-panel")?.textContent ?? null;

  await show(listed([edit("pending", null)]), true);
  expect(panel()).toContain("Always");

  // Answered, the turn still running: the receipt says what was chosen.
  await show(listed([edit("resolved", "allow_once")]), true);
  expect(panel()).toContain("Allow once");

  // The turn ended: nothing stays above the composer.
  await show(listed([edit("resolved", "allow_once")]), false);
  expect(panel()).toBeNull();

  // The next turn asks nothing: the old receipt does not come back.
  await show(listed([edit("resolved", "allow_once")]), true);
  expect(panel()).toBeNull();
});
