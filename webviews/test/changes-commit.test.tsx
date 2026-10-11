// The Changes view's Commit (cx-tcwj, Codex desktop's commit box): the Staged scope ends in a commit
// bar. Draft asks the agent for a message, which lands in the field to edit; Commit commits what is
// staged with that message through the view's source, then the scope reloads. A refusal says why in
// the bar, without a dialog, and keeps the message.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The file menu places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { DiffPanel } = await import("../src/agent-session/acpmux/DiffPanel");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-one\n+two\n";
const changes = { root: "/repo", files: [{ path: "a.txt", status: "modified", additions: 1, deletions: 1, patch }] };
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const menuItem = (label: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"], [role="menuitemradio"]')].find(
    (item) => item.textContent === label,
  );
const button = (container: HTMLElement, label: string) =>
  [...container.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);

/// Types into a React-controlled field the way the browser does.
function type(field: HTMLTextAreaElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
  setter.call(field, value);
  field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
}

type Commit = { commit: (message: string) => Promise<unknown>; draftCommit: () => Promise<string> };

async function open(scopeLabel: string, git: Commit) {
  const reads: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const source = {
    diff: async (scope: string) => {
      reads.push(scope);
      return changes;
    },
    ...git,
  };
  await act(async () => root.render(<DiffPanel files={[]} onClose={() => {}} source={source} />));
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-diff-scope")!.click());
  await settle();
  await act(async () => menuItem(scopeLabel)!.click());
  await settle();
  const message = () => container.querySelector<HTMLTextAreaElement>('textarea[aria-label="Commit message"]');
  return { root, container, reads, message };
}

test("Staged drafts a message with the agent, takes an edit, commits it, then reloads", async () => {
  const committed: string[] = [];
  const view = await open("Staged", {
    draftCommit: async () => "Say two\n\nThe file said one.",
    commit: async (message) => void committed.push(message),
  });
  try {
    expect(button(view.container, "Commit")!.disabled).toBe(true);
    await act(async () => button(view.container, "Draft")!.click());
    await settle();
    expect(view.message()!.value).toBe("Say two\n\nThe file said one.");
    await act(async () => type(view.message()!, "Say two, not one"));
    await act(async () => button(view.container, "Commit")!.click());
    await settle();
    expect(committed).toEqual(["Say two, not one"]);
    expect(view.message()!.value).toBe("");
    expect(view.container.querySelector(".acpmux-commit-bar [role=status]")?.textContent).toBe("Committed");
    expect(view.reads).toEqual(["staged", "staged"]);
  } finally {
    await act(async () => view.root.unmount());
  }
});

test("A refused commit says why inline and keeps the message; other scopes have no commit bar", async () => {
  const view = await open("Staged", {
    draftCommit: async () => "",
    commit: async () => {
      throw new Error("nothing added to commit");
    },
  });
  try {
    await act(async () => type(view.message()!, "Say two"));
    await act(async () => button(view.container, "Commit")!.click());
    await settle();
    expect(view.container.querySelector(".acpmux-commit-bar [role=alert]")?.textContent).toBe(
      "nothing added to commit",
    );
    expect(view.message()!.value).toBe("Say two");
    expect(view.reads).toEqual(["staged"]);
  } finally {
    await act(async () => view.root.unmount());
  }
  const other = await open("Unstaged", { draftCommit: async () => "", commit: async () => undefined });
  try {
    expect(other.message()).toBeNull();
  } finally {
    await act(async () => other.root.unmount());
  }
});
