// New Tab preserves the shared composer controls. The model always sits in the footer;
// Its appearance stays Claude regardless of the saved chat composer look.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";
import { suggestionsAnchor } from "../src/agent-session/acpmux/newtab/suggestionsAnchor";
import { resolveUiOverlayPosition, UI_ANCHOR_GAP } from "../src/ui/anchor";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
  "MutationObserver",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    ResizeObserver: window.ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads Element and Node (Node below).
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    // The field is the composer's Markdown field (ProseMirror).
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await act(async () => root?.unmount());
  await teardownDom(saved, { scope });
});

const noop = () => {};

function Chips() {
  return (
    <span className="acpmux-chips">
      <span className="acpmux-model-name">Claude Opus 5.5</span>
    </span>
  );
}

async function mount(
  options: {
    machineName?: string;
    snapshot?: AcpmuxSnapshot;
    onCommands?(harness: string, cwd?: string): void;
    template?: "cards";
    accessory?: React.ReactNode;
  } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={options.snapshot ?? noChat()}
        {...(options.template ? { template: options.template } : {})}
        {...(options.machineName ? { machineName: options.machineName } : {})}
        lastAgent="claude"
        cwd="/Users/you"
        startCwd="/Users/you/src/app"
        projects={[{ cwd: "/Users/you/src/app", label: "app" }]}
        chips={Chips}
        accessory={options.accessory}
        onCommands={options.onCommands}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
}

test("Codex slash commands are available before the first message and selecting one keeps its arguments", async () => {
  const snapshot = noChat();
  snapshot.summary = { sessionId: "", harness: "codex", model: "m" };
  snapshot.commands = [{ name: "goal", description: "Set a goal", hint: "<objective>" }];
  const requests: string[] = [];
  await mount({ snapshot, onCommands: (harness) => requests.push(harness) });
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type("/go");
  });
  const row = host.querySelector<HTMLElement>(".acpmux-slash-row")!;
  expect(row?.textContent).toContain("/goal");
  await act(async () => row.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
  expect(handle.plainText()).toBe("/goal ");
  expect(requests).toEqual(["codex"]);
});

test("the New Tab card keeps Send in the box and model in the footer", async () => {
  await mount();
  const composer = host.querySelector<HTMLElement>(".nt-composer")!;
  const card = composer.querySelector<HTMLElement>(".nt-box")!;
  const parts = [
    ...composer.querySelectorAll<HTMLElement>(".acpmux-composer-strip, .nt-field, .acpmux-chips, .nt-send"),
  ];
  // The field is the composer's Markdown field (`acpmux-md-field nt-field`): it is named by its New Tab class.
  const name = (part: HTMLElement) => (part.classList.contains("nt-field") ? "nt-field" : part.className.split(" ")[0]);
  expect(parts.map(name)).toEqual(["acpmux-composer-strip", "nt-field", "acpmux-send", "acpmux-chips"]);
  // The project is the location strip's (hq#1957 composer location strip), as in the agent
  // composer: never in the card or its bar.
  const row = composer.querySelector<HTMLElement>(".acpmux-composer-strip .acpmux-composer-context")!;
  expect(row.textContent).toContain("app");
  expect(card.querySelector(".acpmux-composer-context, .acpmux-location-button, .acpmux-chips")).toBeNull();
  expect(composer.querySelector(".acpmux-composer-foot .acpmux-chips")).not.toBeNull();
});

test("New Tab keeps Claude and its controls when the saved chat look is Codex", async () => {
  const { savedComposerLook, setComposerLook, useComposerLook } =
    await import("../src/agent-session/acpmux/composerLook");
  function ControlLook() {
    return <span data-control-look={useComposerLook()} />;
  }
  act(() => setComposerLook("codex"));
  for (const template of [undefined, "cards"] as const) {
    await mount({ template, accessory: <ControlLook /> });
    const composer = host.querySelector<HTMLElement>(".nt-composer")!;
    expect(composer.dataset.composerLook ?? "claude").toBe("claude");
    expect(composer.querySelector("[data-control-look=claude]")).not.toBeNull();
    expect(composer.querySelector(".nt-foot .acpmux-composer-foot .acpmux-chips")).not.toBeNull();
    expect(composer.querySelector(".nt-above .acpmux-composer-context")?.textContent).toContain("app");
    expect(composer.querySelectorAll(".acpmux-composer-context")).toHaveLength(1);
    expect(savedComposerLook()).toBe("codex");
  }
  act(() => setComposerLook("claude"));
});

test("suggestions mirror the box-to-chip text gap at every density and zoom", async () => {
  await mount();
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  await act(async () => {
    field.acpmuxMarkdownField!.focus();
    field.acpmuxMarkdownField!.type("ff");
  });
  expect(document.querySelector(".nt-popover .nt-row")).not.toBeNull();
  const composer = host.querySelector<HTMLElement>(".nt-composer")!;
  const box = host.querySelector<HTMLElement>(".nt-box")!;
  const label = host.querySelector<HTMLElement>(".nt-foot .acpmux-model-name")!;
  const anchor = suggestionsAnchor(composer, box);
  // jsdom has no layout. Supply viewport rects with density, font and zoom varied independently.
  for (const density of [0.8, 0.86, 1, 1.2, 1.6]) {
    for (const zoom of [0.92, 1, 1.25]) {
      for (const lineHeight of [14, 18, 24]) {
        let growth = 0;
        const boxBottom = () => (160 + growth) * zoom;
        const textTop = () => boxBottom() + (6 * density - 2 + (28 * density - lineHeight) / 2) * zoom;
        const textBottom = () => textTop() + lineHeight * zoom;
        composer.getBoundingClientRect = () => new window.DOMRect(40, 80 * zoom, 600 * zoom, (140 + growth) * zoom);
        box.getBoundingClientRect = () => new window.DOMRect(40, 100 * zoom, 600 * zoom, (60 + growth) * zoom);
        label.getBoundingClientRect = () => new window.DOMRect(420, textTop(), 100, lineHeight * zoom);
        const rect = anchor.getBoundingClientRect();
        const popup = resolveUiOverlayPosition(rect, { width: 600, height: 100 }, { width: 1200, height: 1000 });
        expect(Math.abs(popup.top - textBottom() - (textTop() - boxBottom()))).toBeLessThanOrEqual(1);
        expect(rect.width).toBe(composer.getBoundingClientRect().width);
        const above = resolveUiOverlayPosition(
          rect,
          { width: 600, height: 40 },
          { width: 1200, height: 1000 },
          { side: "above" },
        );
        expect(above.top).toBe(composer.getBoundingClientRect().top - 6 - 40);
        for (const height of [lineHeight / 4, lineHeight / 2, lineHeight, lineHeight / 2, 0]) {
          growth = height;
          const moved = resolveUiOverlayPosition(
            anchor.getBoundingClientRect(),
            { width: 600, height: 100 },
            { width: 1200, height: 1000 },
          );
          expect(moved.top - popup.top).toBeCloseTo(growth * zoom);
        }
      }
    }
  }
  // A collapsed form keeps its box under visibility: hidden (at the chips' top); the label drawn sets the gap.
  const ghost = label.cloneNode(true) as HTMLElement;
  ghost.style.visibility = "hidden";
  ghost.getBoundingClientRect = () => new window.DOMRect(420, 0, 100, 14);
  label.before(ghost);
  composer.getBoundingClientRect = () => new window.DOMRect(40, 80, 600, 140);
  box.getBoundingClientRect = () => new window.DOMRect(40, 100, 600, 60);
  label.getBoundingClientRect = () => new window.DOMRect(420, 166, 100, 14);
  expect(anchor.getBoundingClientRect().bottom).toBe(180 + 166 - 160 - UI_ANCHOR_GAP);
  ghost.remove();
  label.getBoundingClientRect = () => new window.DOMRect();
  expect(anchor.getBoundingClientRect().toJSON()).toEqual(composer.getBoundingClientRect().toJSON());
});

// Review (#20148): the composer's Computer menu listed a remote chat's machine, so the row could
// name it while Return started the chat on this one. A New Tab chat starts where the page runs:
// the row names that machine as the host does, and offers no other.
test("the location row names the machine the chat starts on and offers no other", async () => {
  const [local] = manySessions(1);
  const remote = { ...local!, sessionId: "remote-1", peer: "devbox", cwd: "/home/you/api" };
  await mount({ machineName: "studio", snapshot: noChat([local!, remote]) });
  const row = host.querySelector<HTMLElement>(".acpmux-composer-context")!;
  expect(row.textContent).toContain("studio");
  expect(row.textContent).not.toContain("This Mac");
  const computer = row.querySelector<HTMLButtonElement>('button[aria-label="Computer: studio"]');
  expect(computer).not.toBeNull();
  await act(async () => computer!.click());
  const options = [...document.querySelectorAll(".acpmux-menu-label")].map((item) => item.textContent);
  expect(options).toContain("studio");
  expect(options).not.toContain("devbox");
});

test("a deferred chat's later command publication reaches New Tab and a superseded read stays behind", async () => {
  const { useSessionCommands } = await import("../src/agent-session/acpmux/newtab/useSessionCommands");
  const { createRoot } = await import("react-dom/client");
  const goal = [{ name: "goal", description: "Set a goal" }];
  let commands = [] as typeof goal;
  let late!: (value: typeof goal) => void;
  const read = (id: string) =>
    id === "old" ? new Promise<typeof goal>((resolve) => (late = resolve)) : Promise.resolve(commands);
  function Pending({ id, revision }: { id: string; revision: object }) {
    const loaded = useSessionCommands(id, revision, read);
    return <div>{loaded?.map((command) => command.name).join(",")}</div>;
  }
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<Pending id="old" revision={{}} />));
  await act(async () => root!.render(<Pending id="new" revision={{}} />));
  expect(host.textContent).toBe("");
  // Commands are published after session/new answered. Its metadata change triggers this read.
  commands = goal;
  await act(async () => root!.render(<Pending id="new" revision={{ commands: true }} />));
  expect(host.textContent).toBe("goal");
  await act(async () => late([{ name: "obsolete", description: "Old session" }]));
  expect(host.textContent).toBe("goal");
});

test("deferred command reads request the newest publication", async () => {
  const { directClientStub } = await import("./support/directClientStub");
  const calls: Record<string, unknown>[] = [];
  const client = directClientStub<{ sessionCommands(sessionId: string): Promise<unknown> }>({
    typed: async (_method: string, params: Record<string, unknown>) => {
      calls.push(params);
      return { events: [] };
    },
  });
  await client.sessionCommands("deferred-session");
  expect(calls[0]).toMatchObject({ sessionId: "deferred-session", beforeSeq: Number.MAX_SAFE_INTEGER, limit: 1 });
});
