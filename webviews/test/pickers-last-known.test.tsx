// A picker opened again draws what it read last, with no loading line, and reads again behind it
// (lastKnown.ts): the Context screen's inventory, the diff base picker's refs and the cloud
// repository picker's list.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, createRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { LastKnown } from "../src/lastKnown";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (cb: (t: number) => void) => setTimeout(() => cb(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver:
      w.ResizeObserver ??
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function mount(node: React.ReactNode): HTMLElement {
  const host = document.getElementById("root")!;
  root = createRoot(host);
  act(() => root!.render(node));
  return host;
}

async function unmount() {
  if (root) await act(async () => root!.unmount());
  root = undefined;
}

const tick = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

test("the bounded map drops the least recently used key", () => {
  const map = new LastKnown<number>(2);
  map.set("a", 1);
  map.set("b", 2);
  expect(map.get("a")).toBe(1);
  map.set("c", 3);
  expect(map.get("b")).toBeUndefined();
  expect(map.get("a")).toBe(1);
  expect(map.size).toBe(2);
});

const inventory = (label: string) => ({
  parts: [{ id: "p", source: "cmux", label, tokens: 10, included: true, editable: false, measurement: "measured" }],
  totalTokens: 10,
  cmuxTokens: 10,
});

test("the Context screen opened again draws the last inventory, then the new one", async () => {
  const { ContextScreen } = await import("../src/agent-session/acpmux/context/ContextScreen");
  let answer = deferred<unknown>();
  const load = () => answer.promise;
  let host = mount(<ContextScreen load={load} onClose={() => {}} />);
  expect(host.querySelector('[data-context-state="loading"]')).not.toBeNull();
  await act(async () => answer.resolve(inventory("First read")));
  expect(host.textContent).toContain("First read");
  await unmount();

  answer = deferred<unknown>();
  host = mount(<ContextScreen load={load} onClose={() => {}} />);
  // The warm open: the last inventory, no loading line, while the read is still out.
  expect(host.querySelector('[data-context-state="loading"]')).toBeNull();
  expect(host.textContent).toContain("First read");
  await act(async () => answer.resolve(inventory("Second read")));
  expect(host.textContent).toContain("Second read");
  await unmount();

  // A failed read behind a last-known inventory keeps it on screen.
  const offline = Promise.reject(new Error("offline"));
  offline.catch(() => {});
  answer = { promise: offline, resolve: () => {} };
  host = mount(<ContextScreen load={load} onClose={() => {}} />);
  await tick();
  expect(host.querySelector('[data-context-state="failed"]')).toBeNull();
  expect(host.textContent).toContain("Second read");
});

const groups = (refs: string[], current?: string) => [
  { id: "branches", label: "Branches", rows: refs.map((ref) => ({ ref, label: ref, current: ref === current })) },
];

test("the base picker opened after a base change lists the last refs at once and lists again behind them", async () => {
  const { BranchBasePicker, resetLastKnownRefsForTests } = await import("../src/BranchBasePicker");
  resetLastKnownRefsForTests();
  const answers: ReturnType<typeof deferred<unknown>>[] = [];
  const transport = {
    request: () => {
      const answer = deferred<unknown>();
      answers.push(answer);
      return answer.promise;
    },
  };
  const picker = (currentRef: string) => ({
    repoRoot: "/repo",
    // A base change opens a new session with its own token: the refs are still the repository's.
    capabilityToken: `token-${currentRef}`,
    currentRef,
    refsURL: "",
    regenerateURLTemplate: "",
  });
  const render = (currentRef: string) => (
    <BranchBasePicker
      key={currentRef}
      label={(key) => key}
      onNavigate={() => {}}
      onSelectBranchBase={() => {}}
      picker={picker(currentRef) as never}
      transport={transport as never}
    />
  );
  let host = mount(render("main"));
  const open = () => act(() => host.querySelector<HTMLButtonElement>("button")!.click());
  await open();
  expect(document.body.textContent).toContain("branchPickerLoading");
  await act(async () => answers[0]!.resolve({ type: "branches", value: { groups: groups(["main", "dev"], "main") } }));
  expect(document.body.textContent).toContain("dev");
  await unmount();

  // The base moved to dev: the picker mounts again (its key names the base).
  host = mount(render("dev"));
  await open();
  expect(document.body.textContent).not.toContain("branchPickerLoading");
  expect(document.body.textContent).toContain("main");
  expect(answers.length).toBe(2);
  await act(async () =>
    answers[1]!.resolve({ type: "branches", value: { groups: groups(["main", "dev", "feat"], "dev") } }),
  );
  expect(document.body.textContent).toContain("feat");
});

test("the cloud repository picker opened again lists the last repositories without Searching", async () => {
  const { CloudRepositoryPicker, resetLastKnownReposForTests } =
    await import("../src/agent-session/acpmux/session-info/CloudRepositoryPicker");
  resetLastKnownReposForTests();
  const answers: ReturnType<typeof deferred<unknown>>[] = [];
  const request = <T,>(method: string): Promise<T> => {
    if (method !== "cloud.repo.list") return Promise.resolve({} as T);
    const answer = deferred<unknown>();
    answers.push(answer);
    return answer.promise as Promise<T>;
  };
  const anchor = createRef<HTMLElement>();
  const render = () => (
    <CloudRepositoryPicker
      session="chat-1"
      anchor={anchor}
      open
      onOpenChange={() => {}}
      onAttached={() => {}}
      request={request}
    />
  );
  mount(render());
  await tick();
  expect(document.body.querySelector(".acpmux-cloud-repository-progress")).not.toBeNull();
  await act(async () => answers[0]!.resolve({ repos: [{ fullName: "you/first" }] }));
  expect(document.body.textContent).toContain("you/first");
  await unmount();

  mount(render());
  await tick();
  expect(document.body.querySelector(".acpmux-cloud-repository-progress")).toBeNull();
  expect(document.body.textContent).toContain("you/first");
  await act(async () => answers[1]!.resolve({ repos: [{ fullName: "you/first" }, { fullName: "you/second" }] }));
  expect(document.body.textContent).toContain("you/second");
});

const editable = (user: string) => ({
  ...inventory("Guidance"),
  canEditOverrides: true,
  overrides: { defaultText: "Default guidance", user },
});

function typeInto(field: HTMLTextAreaElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
  act(() => {
    setter.call(field, value);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

test("a refresh behind the last inventory keeps a draft typed before it answers", async () => {
  const { ContextScreen } = await import("../src/agent-session/acpmux/context/ContextScreen");
  let answer = deferred<unknown>();
  const load = () => answer.promise;
  const save = () => Promise.resolve(editable("Saved"));
  let host = mount(<ContextScreen load={load} save={save} onClose={() => {}} />);
  await act(async () => answer.resolve(editable("First")));
  const field = () => host.querySelector<HTMLTextAreaElement>('[data-context-editor="guidance"] textarea')!;
  expect(field().value).toBe("First");
  await unmount();

  // Untouched: the refresh's text replaces the last-known one.
  answer = deferred<unknown>();
  host = mount(<ContextScreen load={load} save={save} onClose={() => {}} />);
  expect(field().value).toBe("First");
  await act(async () => answer.resolve(editable("Changed elsewhere")));
  expect(field().value).toBe("Changed elsewhere");
  await unmount();

  // Typed before the refresh answers: the draft stays.
  answer = deferred<unknown>();
  host = mount(<ContextScreen load={load} save={save} onClose={() => {}} />);
  typeInto(field(), "My draft");
  await act(async () => answer.resolve(editable("Changed again")));
  expect(field().value).toBe("My draft");
});

test("the base picker's highlight stays on its ref when the refreshed rows move under it", async () => {
  const { BranchBasePicker, resetLastKnownRefsForTests } = await import("../src/BranchBasePicker");
  resetLastKnownRefsForTests();
  const answers: ReturnType<typeof deferred<unknown>>[] = [];
  const transport = {
    request: () => {
      const answer = deferred<unknown>();
      answers.push(answer);
      return answer.promise;
    },
  };
  const render = (currentRef: string) => (
    <BranchBasePicker
      key={currentRef}
      label={(key) => key}
      onNavigate={() => {}}
      onSelectBranchBase={() => {}}
      picker={
        { repoRoot: "/repo", capabilityToken: currentRef, currentRef, refsURL: "", regenerateURLTemplate: "" } as never
      }
      transport={transport as never}
    />
  );
  let host = mount(render("main"));
  const open = () => act(() => host.querySelector<HTMLButtonElement>("button")!.click());
  await open();
  await act(async () =>
    answers[0]!.resolve({ type: "branches", value: { groups: groups(["main", "dev", "feat"], "main") } }),
  );
  await unmount();

  host = mount(render("dev"));
  await open();
  const input = document.body.querySelector<HTMLInputElement>("input[aria-activedescendant]")!;
  const highlighted = () => document.getElementById(input.getAttribute("aria-activedescendant")!)?.textContent ?? "";
  for (let i = 0; i < 2; i += 1)
    void act(() => input.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })));
  expect(highlighted()).toContain("feat");
  // The refresh adds a Suggested group on top: every row moves down one.
  await act(async () =>
    answers[1]!.resolve({
      type: "branches",
      value: {
        groups: [
          { id: "suggested", label: "Suggested", rows: [{ ref: "dev", label: "dev", current: true }] },
          ...groups(["main", "dev", "feat"], "dev"),
        ],
      },
    }),
  );
  expect(highlighted()).toContain("feat");
});
