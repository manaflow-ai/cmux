// An edit's approval shows the change it asks for (dogfood run 5). The Tool permissions card
// named the edit ("Edit upload.sh") and offered Allow once, but what the edit changes sat behind
// Expand details as raw JSON. Claude and Codex show the proposed diff on the approval. The card
// now draws each file's change, as the transcript draws an edit, without opening anything.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PermissionClientState, PermissionGroup } from "../src/agent-session/acpmux/permissions/protocol";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "customElements",
  "MutationObserver",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // Pierre's registered elements (the diff card) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
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

const path = "/Users/you/src/uploader/src/upload.sh";
const before = "#!/bin/sh\nfile=$1; url=$2; attempt=0\nexit 1\n";
const after = "#!/bin/sh\n# retried uploads\nfile=$1; url=$2; attempt=0\nexit 1\n";
const group: PermissionGroup = {
  groupId: "group-1",
  sessionId: "session-1",
  turnId: "turn-2",
  revision: 1,
  state: "pending",
  items: [
    {
      permissionId: "permission-1",
      request: {
        toolCall: {
          title: "Edit upload.sh",
          kind: "edit",
          locations: [{ path }],
          rawInput: { file_path: path, old_string: "#!/bin/sh\n", new_string: "#!/bin/sh\n# retried uploads\n" },
          content: [{ type: "diff", path, oldText: before, newText: after }],
        },
      },
      state: "pending",
    },
  ],
  decisions: ["allow_once", "allow_chat", "deny"],
  decision: null,
};
const state: PermissionClientState = {
  supported: true,
  ready: true,
  groups: [group],
  chatAllowance: false,
  loading: false,
  busy: false,
};

test("a pending edit's approval shows the file's change without Expand details", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <PermissionPanel
        state={state}
        working
        onRespond={() => {}}
        onRetry={() => {}}
        onRevoke={() => {}}
        onRefresh={() => {}}
      />,
    ),
  );
  const card = host.querySelector(".acpmux-ask")!;
  // Drawn, not folded: no closed <details> above it.
  const shown = [...card.querySelectorAll<HTMLElement>(".cv-edit-diff")].filter(
    (diff) => !diff.closest("details:not([open])"),
  );
  expect(
    shown.map((diff) => ({
      name: diff.querySelector(".cv-edit-diff__name")?.textContent,
      added: diff.querySelector(".cv-edit-diff__add")?.textContent,
      removed: diff.querySelector(".cv-edit-diff__del")?.textContent,
    })),
  ).toEqual([{ name: "upload.sh", added: "+1", removed: "-0" }]);
});

test("a long edit awaiting approval shows whole, never cut to a preview", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  await act(async () => root?.unmount());
  const long = Array.from({ length: 30 }, (_, index) => `echo step ${index + 1}`).join("\n") + "\n";
  const item = group.items[0]!;
  const longGroup: PermissionGroup = {
    ...group,
    groupId: "group-long",
    items: [
      {
        ...item,
        permissionId: "permission-long",
        request: {
          toolCall: {
            title: "Edit upload.sh",
            kind: "edit",
            locations: [{ path }],
            content: [{ type: "diff", path, oldText: before, newText: before + long }],
          },
        },
      },
    ],
  };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <PermissionPanel
        state={{ ...state, groups: [longGroup] }}
        working
        onRespond={() => {}}
        onRetry={() => {}}
        onRevoke={() => {}}
        onRefresh={() => {}}
      />,
    ),
  );
  const diff = host.querySelector(".acpmux-ask .cv-edit-diff")!;
  expect(Boolean(diff)).toBe(true);
  expect(diff.querySelector(".cv-edit-diff__body")?.hasAttribute("data-preview")).toBe(false);
  expect([...diff.querySelectorAll("button")].some((node) => node.textContent?.startsWith("Show all"))).toBe(false);
});
