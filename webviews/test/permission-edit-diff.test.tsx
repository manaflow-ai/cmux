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
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let root: Root | undefined;
let host: HTMLElement;
let dom: JSDOM;
const renderObservers = new Set<MutationObserver>();

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
    // jsdom has no layout observer; Pierre still needs its subscription API to render the hunks.
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // Pierre's registered elements (the diff card) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
  // Match the app's chunk preload. Pierre still paints asynchronously; waitForLines below observes
  // that paint, independently of whether an earlier test has warmed the syntax highlighter.
  const { loadEditDiffHunks } = await import("../src/agent-session/acpmux/conversation/EditDiff");
  await loadEditDiffHunks();
});

afterAll(() => {
  for (const observer of renderObservers) observer.disconnect();
  renderObservers.clear();
  act(() => root?.unmount());
  dom.window.close();
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

// Run the single-card preview first: its highlighter has no earlier render to warm it.
for (const grouped of [false, true]) {
  const surface = grouped ? "grouped approval" : "single approval";
  for (const v2 of [false, true]) {
    const envelope = v2 ? "ACP v2 subject" : "ACP tool call";
    test(`${surface} shows the explicit diff from an ${envelope}`, async () => {
      await renderAsk(
        {
          kind: "edit",
          title: "Edit upload.sh",
          content: [{ type: "diff", path, oldText: before, newText: after }],
          // The explicit diff is authoritative, even if input differs.
          rawInput: { file_path: path, old_string: "wrong\n", new_string: "also\nwrong\n" },
        },
        grouped,
        v2,
      );
      expect(shownChanges()).toEqual([{ name: "upload.sh", added: "+1", removed: "-0", cut: false }]);
      await waitForLines(1);
      expect(shownLines().flat()).toContain("# retried uploads");
      expect(shownLines().flat()).not.toContain("wrong");
    });

    test(`${surface} previews Claude Edit input from an ${envelope}`, async () => {
      await renderAsk(
        {
          kind: "edit",
          title: "Edit upload.sh",
          rawInput: { file_path: path, old_string: "exit 1\n", new_string: "echo done\nexit 0\n" },
        },
        grouped,
        v2,
      );
      expect(shownChanges()).toEqual([{ name: "upload.sh", added: "+2", removed: "-1", cut: false }]);
      await waitForLines(1);
      expect(shownLines()).toEqual([["exit 1", "echo done", "exit 0"]]);
    });
  }

  test(`${surface} previews every MultiEdit fragment`, async () => {
    await renderAsk(
      {
        kind: "edit",
        rawInput: {
          file_path: path,
          edits: [
            { old_string: "attempt=0\n", new_string: "attempt=1\n" },
            { old_string: "exit 1\n", new_string: "echo done\nexit 0\n" },
          ],
        },
      },
      grouped,
    );
    expect(shownChanges()).toEqual([{ name: "upload.sh", added: "+3", removed: "-2", cut: false }]);
    await waitForLines(2);
    expect(shownLines()).toEqual([
      ["attempt=0", "attempt=1"],
      ["exit 1", "echo done", "exit 0"],
    ]);
  });

  test(`${surface} does not invent a before image for Write or malformed input`, async () => {
    for (const rawInput of [
      { file_path: path, content: "replacement\n" },
      { file_path: path, old_string: null, new_string: "replacement\n" },
      { old_string: "before", new_string: "after" },
    ]) {
      await renderAsk({ kind: "edit", rawInput }, grouped);
      expect(shownChanges()).toEqual([]);
    }
  });

  test(`${surface} shows the text of acpmux's Write diff, which carries no old text`, async () => {
    // claude_stdio's `with_edit` puts a Write on the ask as a fragment diff with `oldText: null`.
    await renderAsk(
      {
        kind: "edit",
        rawInput: { file_path: path, content: "replacement\n" },
        content: [
          {
            type: "diff",
            path,
            oldText: null,
            newText: "replacement\n",
            _meta: { acpmux: { fragment: true } },
          },
        ],
      },
      grouped,
    );
    expect(shownChanges().map((change) => change.name)).toEqual(["upload.sh"]);
    await waitForLines(1);
    expect(shownLines()).toEqual([["replacement"]]);
  });

  test(`${surface} does not infer an edit from a different tool's input fields`, async () => {
    await renderAsk(
      {
        kind: "read",
        rawInput: { file_path: path, old_string: "before", new_string: "after" },
      },
      grouped,
    );
    expect(shownChanges()).toEqual([]);
  });
}

test("a pending edit's approval shows the file's change without Expand details", async () => {
  const { createRoot } = await import("react-dom/client");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  await act(async () => root?.unmount());
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

async function renderAsk(toolCall: Record<string, unknown>, grouped: boolean, v2 = false) {
  const { createRoot } = await import("react-dom/client");
  const { PermissionPanel } = await import("../src/agent-session/acpmux/permissions/Panel");
  const { PermissionCard } = await import("../src/agent-session/acpmux/PermissionCard");
  const { permissionFromMessage } = await import("../src/agent-session/acpmux/direct");
  const request = {
    ...(v2 ? { subject: { type: "tool_call", toolCall } } : { toolCall }),
    options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }],
  };
  await act(async () => root?.unmount());
  root = createRoot(host);
  await act(async () => {
    if (grouped) {
      root!.render(
        <PermissionPanel
          state={{ ...state, groups: [{ ...group, items: [{ ...group.items[0]!, request }] }] }}
          working
          onRespond={() => {}}
          onRetry={() => {}}
          onRevoke={() => {}}
          onRefresh={() => {}}
        />,
      );
    } else {
      const permission = permissionFromMessage(
        { sessionId: "session-1", permissionId: "permission-1", request },
        "session-1",
      );
      expect(permission).toBeDefined();
      root!.render(<PermissionCard permission={permission!} onAnswer={() => {}} />);
    }
  });
}

function shownChanges() {
  return [...host.querySelectorAll(".cv-edit-diff")].map((diff) => ({
    name: diff.querySelector(".cv-edit-diff__name")?.textContent,
    added: diff.querySelector(".cv-edit-diff__add")?.textContent,
    removed: diff.querySelector(".cv-edit-diff__del")?.textContent,
    cut: diff.querySelector(".cv-edit-diff__body")?.hasAttribute("data-preview"),
  }));
}

function shownLines() {
  return [...host.querySelectorAll(".cv-edit-diff__body diffs-container")].map((container) =>
    [...(container.shadowRoot?.querySelectorAll("[data-line]") ?? [])].map((line) => line.textContent?.trimEnd()),
  );
}

// Observe both React's mount and Pierre's shadow-root writes. The test's normal timeout still
// catches missing bodies; there is no sleep, retry, or longer deadline for rendering.
async function waitForLines(blocks: number) {
  await act(async () => {
    await new Promise<void>((resolve) => {
      const observer = new MutationObserver(check);
      renderObservers.add(observer);
      observer.observe(host, { childList: true, subtree: true });
      function check() {
        const containers = [...host.querySelectorAll(".cv-edit-diff__body diffs-container")];
        for (const container of containers)
          if (container.shadowRoot) observer.observe(container.shadowRoot, { childList: true, subtree: true });
        if (containers.length !== blocks || shownLines().some((lines) => lines.length === 0)) return;
        observer.disconnect();
        renderObservers.delete(observer);
        resolve();
      }
      check();
    });
  });
}
