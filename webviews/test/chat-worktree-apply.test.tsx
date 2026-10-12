// Apply from the worktree pill (cx-lyqio.4, Codex/Conductor style): a worktree chat's header pill
// opens what the worktree is, and Apply brings the chat's work to the main checkout as uncommitted
// changes (`git.worktree.apply`). It says how much landed, or inline why nothing did: the main
// checkout has its own changes there, or the work does not apply cleanly. A new chat has nothing
// to apply yet.
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
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The popover places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const WORKTREE = "/Users/me/.cmux/worktrees/app/fix-login";
const MAIN = "/Users/me/app";
const status = async () => ({
  root: WORKTREE,
  branch: "cmux/fix-login",
  base: "main",
  detached: false,
  worktree: { main_root: MAIN },
});
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const doc = () => dom.window.document;
const button = (name: string) =>
  [...doc().querySelectorAll<HTMLButtonElement>(".acpmux-worktree-status button")].find((item) =>
    item.textContent?.includes(name),
  );

async function render(onApplyWorktree?: () => Promise<unknown>) {
  const root = createRoot(doc().getElementById("root")!);
  await act(async () =>
    root.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={() => {}}
        summary={null}
        menu={() => []}
        folder={WORKTREE}
        readStatus={status}
        onApplyWorktree={onApplyWorktree}
      />,
    ),
  );
  await settle();
  await act(async () => doc().querySelector<HTMLButtonElement>("button.acpmux-header-worktree")!.click());
  await settle();
  return root;
}

test("Apply brings the chat's work to the main checkout and says how much landed", async () => {
  let applied = 0;
  const root = await render(async () => {
    applied += 1;
    return { value: { main_root: MAIN, files: ["a.txt", "src/new.rs"] }, replayed: false };
  });
  try {
    // The popover names the branch, the checkout it belongs to and its base.
    expect(doc().querySelector(".acpmux-worktree-status")?.textContent).toContain("cmux/fix-login");
    expect(doc().querySelector(".acpmux-worktree-status")?.textContent).toContain(
      "Worktree of /Users/me/app, branched from main",
    );
    await act(async () => button("Apply to main checkout")!.click());
    await settle();
    expect(applied).toBe(1);
    expect(doc().querySelector(".acpmux-worktree-status output")?.textContent).toBe("Applied 2 files to /Users/me/app");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a refusal says why inline and applies nothing", async () => {
  const root = await render(async () => {
    throw Object.assign(new Error("The commit or push did not go through."), {
      code: "operation.failed",
      details: {
        reason: "main_checkout_changed",
        extra: { message: "the main checkout has changes of its own", files: ["a.txt"] },
      },
    });
  });
  try {
    await act(async () => button("Apply to main checkout")!.click());
    await settle();
    expect(doc().querySelector(".acpmux-worktree-status [role=alert]")?.textContent).toBe(
      "/Users/me/app has its own changes to a.txt",
    );
    // It can be tried again once the user sorted their checkout out.
    expect(button("Apply to main checkout")).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a new chat's worktree has nothing to apply yet", async () => {
  const root = await render(undefined);
  try {
    expect(doc().querySelector(".acpmux-worktree-status")?.textContent).toContain("cmux/fix-login");
    expect(button("Apply to main checkout")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});
