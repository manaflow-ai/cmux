// New Tab preserves the shared composer controls. The model always sits in the footer;
// Claude may place location in that row while Codex keeps its tray above the box.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

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
    MutationObserver: window.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await act(async () => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

function Chips() {
  return <span className="acpmux-chips">Claude Opus 5.5</span>;
}

async function mount(
  options: {
    machineName?: string;
    snapshot?: AcpmuxSnapshot;
    onCommands?(harness: string, cwd?: string): void;
    template?: "cards";
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
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!.call(field, "/go");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const row = host.querySelector<HTMLElement>(".acpmux-slash-row")!;
  expect(row?.textContent).toContain("/goal");
  await act(async () => row.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })));
  expect(field.value).toBe("/goal ");
  expect(requests).toEqual(["codex"]);
});

test("the New Tab card keeps Send in the box and model in the footer", async () => {
  await mount();
  const composer = host.querySelector<HTMLElement>(".nt-composer")!;
  const card = composer.querySelector<HTMLElement>(".nt-box")!;
  const parts = [
    ...composer.querySelectorAll<HTMLElement>(".acpmux-composer-strip, .nt-field, .acpmux-chips, .nt-send"),
  ];
  expect(parts.map((part) => part.className.split(" ")[0])).toEqual([
    "acpmux-composer-strip",
    "nt-field",
    "acpmux-send",
    "acpmux-chips",
  ]);
  // The project is the location strip's (hq#1957 composer location strip), as in the agent
  // composer: never in the card or its bar.
  const row = composer.querySelector<HTMLElement>(".acpmux-composer-strip .acpmux-composer-context")!;
  expect(row.textContent).toContain("app");
  expect(card.querySelector(".acpmux-composer-context, .acpmux-location-button, .acpmux-chips")).toBeNull();
  expect(composer.querySelector(".acpmux-composer-foot .acpmux-chips")).not.toBeNull();
});

// Leo: "the claw thing should be one single row". The Claude split keeps the existing
// mode/model row and moves the folder/computer into it; Codex retains its top tray.
test("Claude New Tab location and model share the quiet row under the box", async () => {
  const { setComposerLook } = await import("../src/agent-session/acpmux/composerLook");
  act(() => setComposerLook("claude", { remember: false }));
  await mount({ template: "cards" });
  const composer = host.querySelector<HTMLElement>(".nt-composer")!;
  const row = composer.querySelector<HTMLElement>(".nt-foot .acpmux-composer-foot")!;
  expect(row.querySelector(".acpmux-composer-context")?.textContent).toContain("app");
  expect(row.querySelector(".acpmux-chips")).not.toBeNull();
  expect(composer.querySelector(".nt-above")).toBeNull();
  expect(composer.querySelectorAll(".acpmux-composer-context")).toHaveLength(1);

  act(() => setComposerLook("codex", { remember: false }));
  expect(composer.querySelector(".nt-above .acpmux-composer-context")).not.toBeNull();
  expect(composer.querySelector(".nt-foot .acpmux-chips")).not.toBeNull();
  expect(composer.querySelector(".nt-foot .acpmux-composer-context")).toBeNull();
  act(() => setComposerLook("claude", { remember: false }));
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
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const calls: Record<string, unknown>[] = [];
  const client = Object.create(AcpmuxDirectClient.prototype) as {
    sessionCommands(sessionId: string): Promise<unknown>;
    typed(method: string, params: Record<string, unknown>): Promise<unknown>;
  };
  client.typed = async (_method, params) => {
    calls.push(params);
    return { events: [] };
  };
  await client.sessionCommands("deferred-session");
  expect(calls[0]).toMatchObject({ sessionId: "deferred-session", beforeSeq: Number.MAX_SAFE_INTEGER, limit: 1 });
});
