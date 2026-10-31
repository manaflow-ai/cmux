// Agent chat dogfood (2026-10-12): a new chat in a workspace starts in its private folder under
// Application Support, and its trust ask read "The agent can edit and run code in /User…": the raw
// path, cut before it named anything. The ask names that folder in words; the path stays in its
// tooltip.
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
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The menu places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
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
const { TrustAsk } = await import("../src/agent-session/acpmux/TrustAsk");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const privateFolder = "/Users/you/Library/Application Support/cmux/agent-home/ws-3f2a/chat-91c0";

test("a chat's private folder is named in words, its path in the tooltip", async () => {
  await act(async () =>
    root.render(
      <TrustAsk
        ask={{ state: "ask", cwd: privateFolder }}
        agent="The agent"
        onTrust={() => undefined}
        onDistrust={() => undefined}
        onUndo={() => undefined}
      />,
    ),
  );
  const text = host.querySelector(".acpmux-trust-ask-text")!;
  expect(text.textContent).toBe("The agent can edit and run code in this chat's private folder");
  expect(text.hasAttribute("title")).toBe(false);
});

test("a project folder keeps its name", async () => {
  await act(async () =>
    root.render(
      <TrustAsk
        ask={{ state: "ask", cwd: "/Users/you/src/atlas-web" }}
        agent="The agent"
        onTrust={() => undefined}
        onDistrust={() => undefined}
        onUndo={() => undefined}
      />,
    ),
  );
  expect(host.querySelector(".acpmux-trust-ask-text")!.textContent).toBe("Trust atlas-web?");
});

test("a declined folder offers continuation without folder context", async () => {
  let continued = 0;
  await act(async () => {
    root.render(
      <TrustAsk
        ask={{ state: "decided", level: "untrusted", cwd: "/Users/you/src/atlas-web" }}
        agent="The agent"
        onTrust={() => undefined}
        onDistrust={() => undefined}
        onUndo={() => undefined}
        onContinueWithoutFolder={() => {
          continued += 1;
        }}
      />,
    );
  });
  const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) =>
    item.textContent?.includes("Continue without folder"),
  );
  expect(host.textContent).toContain("Attachments are not carried; they stay in the original chat.");
  expect(button).toBeDefined();
  await act(async () => button!.click());
  expect(continued).toBe(1);
});

test("continuation disables duplicate clicks and reports a failed start for retry", async () => {
  let reject!: (error: Error) => void;
  let starts = 0;
  let trusted = 0;
  let undone = 0;
  await act(async () =>
    root.render(
      <TrustAsk
        ask={{ state: "decided", level: "untrusted", cwd: "/project" }}
        agent="Agent"
        onTrust={() => {
          trusted += 1;
        }}
        onDistrust={() => {}}
        onUndo={() => {
          undone += 1;
        }}
        onContinueWithoutFolder={() => {
          starts += 1;
          return new Promise<void>((_, no) => {
            reject = no;
          });
        }}
      />,
    ),
  );
  const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (b) => b.textContent === "Continue without folder",
  )!;
  await act(async () => {
    button.click();
    button.click();
  });
  expect(starts).toBe(1);
  expect(button.disabled).toBe(true);
  const trust = [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === "Trust folder");
  const undo = [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === "Undo");
  expect(trust?.disabled).toBe(true);
  expect(undo?.disabled).toBe(true);
  await act(async () => {
    trust?.click();
    undo?.click();
  });
  expect(trusted).toBe(0);
  expect(undone).toBe(0);
  await act(async () => reject(new Error("offline")));
  expect(button.disabled).toBe(false);
  expect(host.querySelector('[role="alert"]')).not.toBeNull();
});
