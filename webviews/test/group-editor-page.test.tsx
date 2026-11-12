// The workspace group editor page (src/pages/group-editor) against its wire contract with the
// native bubble: a new session id resets the field, focuses it and selects the name; a refresh keeps
// a name the person typed; every call carries the session; ready goes once per drawn revision with
// the card's height.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Event",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;
let view: Window & typeof globalThis;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Event: window.Event,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  view = window as unknown as Window & typeof globalThis;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const { mountGroupEditor } = await import("../src/pages/group-editor/mount");
const { GroupEditorOps, SET_ICON_ITEM } = await import("../src/pages/group-editor/host");
const { fixtureColors, fixtureSession } = await import("../src/pages/group-editor/fixtures");

type Call = { op: string; params: Record<string, unknown> };

/** Mounts the page on a recording client; frames run when the test says so. */
async function mount() {
  host = view.document.createElement("div");
  view.document.body.replaceChildren(host);
  const calls: Call[] = [];
  let emit!: (session: unknown) => void;
  const frames: Array<() => void> = [];
  const client = {
    call: (op: string, params: Record<string, unknown>) => {
      calls.push({ op, params });
      return Promise.resolve(undefined);
    },
    subscribe: async (_stream: string, onEvent: (data: unknown) => void) => {
      emit = onEvent;
      return () => {};
    },
    handle: () => () => {},
  };
  let editor!: ReturnType<typeof mountGroupEditor>;
  await act(async () => {
    editor = mountGroupEditor(host, client as never, {
      nextFrame: (run) => {
        frames.push(run);
        return () => {
          const at = frames.indexOf(run);
          if (at >= 0) frames.splice(at, 1);
        };
      },
    });
  });
  mounted.push(editor);
  const field = () => host.querySelector<HTMLInputElement>('[data-testid="cmux.sidebar.groupEditor.name"]')!;
  return {
    editor,
    calls,
    field,
    of: (op: string) => calls.filter((call) => call.op === op).map((call) => call.params),
    send: (session: unknown) => act(async () => emit(session)),
    flushFrames: () => act(async () => frames.splice(0).forEach((run) => run())),
    type: (text: string) =>
      act(async () => {
        const input = field();
        Object.getOwnPropertyDescriptor(view.HTMLInputElement.prototype, "value")!.set!.call(input, text);
        input.dispatchEvent(new view.Event("input", { bubbles: true }));
      }),
    /** A native press: mouse-down then mouse-up on the same control. */
    press: (testId: string) =>
      act(async () => {
        const target = host.querySelector(`[data-testid="${testId}"]`)!;
        target.dispatchEvent(new view.MouseEvent("mousedown", { bubbles: true, button: 0 }));
        target.dispatchEvent(new view.MouseEvent("mouseup", { bubbles: true, button: 0 }));
      }),
    key: (key: string) =>
      act(async () => {
        field().dispatchEvent(new view.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
      }),
  };
}

/** The editors a test mounted: each is unmounted after it, so its page listeners go with it. */
const mounted: Array<{ unmount(): void }> = [];
afterEach(async () => {
  await act(async () => mounted.splice(0).forEach((editor) => editor.unmount()));
  view.document.body.replaceChildren();
});

test("an empty session draws nothing and sends nothing", async () => {
  const page = await mount();
  await page.send({ ...fixtureSession(), id: "" });
  await page.flushFrames();
  expect(host.querySelector(".group-editor")).toBeNull();
  expect(page.calls).toEqual([]);
});

test("a new id resets the field to the name, focuses it and selects it all", async () => {
  const page = await mount();
  await page.send(fixtureSession({ id: "a", name: "Frontend" }));
  expect(page.field().value).toBe("Frontend");
  expect(view.document.activeElement).toBe(page.field());
  expect([page.field().selectionStart, page.field().selectionEnd]).toEqual([0, "Frontend".length]);

  await page.type("Typed in a");
  // Another open (a new id) starts over from the host's name, typed text and all.
  await page.send(fixtureSession({ id: "b", name: "Backend", revision: 2 }));
  expect(page.field().value).toBe("Backend");
  expect(view.document.activeElement).toBe(page.field());
  expect([page.field().selectionStart, page.field().selectionEnd]).toEqual([0, "Backend".length]);
});

test("a refresh updates an untouched field and keeps a typed one", async () => {
  const page = await mount();
  await page.send(fixtureSession({ id: "a", name: "Frontend", revision: 1 }));
  await page.send(fixtureSession({ id: "a", name: "Renamed elsewhere", revision: 2 }));
  expect(page.field().value).toBe("Renamed elsewhere");

  await page.type("My name");
  await page.send(fixtureSession({ id: "a", name: "Renamed again", revision: 3, chosen: "red" }));
  expect(page.field().value).toBe("My name");
  // The rest of the refresh still applies.
  const red = host.querySelector('[data-testid="cmux.sidebar.groupEditor.color.red"]')!;
  expect(red.getAttribute("aria-checked")).toBe("true");
});

/** Review of #37299 at d0f9d91 (F1): a page that reloads while the editor is open shows the name the host will commit. */
test("a reloaded page shows the typed draft the host keeps, and a refresh keeps it", async () => {
  const page = await mount();
  await page.send({ ...fixtureSession({ id: "a", name: "Frontend", revision: 4 }), draft: "Typed before the reload" });
  expect(page.field().value).toBe("Typed before the reload");
  await page.send({
    ...fixtureSession({ id: "a", name: "Renamed elsewhere", revision: 5 }),
    draft: "Typed before the reload",
  });
  expect(page.field().value).toBe("Typed before the reload");
});

test("draft, color, custom color, item and close carry the session", async () => {
  const page = await mount();
  await page.send(fixtureSession({ id: "s1", chosen: "blue" }));
  await page.type("Draft");
  await page.press("cmux.sidebar.groupEditor.color.green");
  await page.press("cmux.sidebar.groupEditor.customColor");
  await page.press("cmux.sidebar.groupEditor.icon");
  await page.press("cmux.sidebar.groupEditor.action.workspaceGroup.togglePin");
  await page.key("Enter");
  await page.key("Escape");
  expect(page.calls.filter((call) => call.op !== GroupEditorOps.ready)).toEqual([
    { op: GroupEditorOps.draft, params: { session: "s1", name: "Draft" } },
    { op: GroupEditorOps.color, params: { session: "s1", color: "green" } },
    { op: GroupEditorOps.customColor, params: { session: "s1" } },
    { op: GroupEditorOps.item, params: { session: "s1", item: SET_ICON_ITEM } },
    { op: GroupEditorOps.item, params: { session: "s1", item: "workspaceGroup.togglePin" } },
    { op: GroupEditorOps.close, params: { session: "s1" } },
    { op: GroupEditorOps.close, params: { session: "s1" } },
  ]);
});

test("a pressed dot is ringed at once, before the host refreshes", async () => {
  const page = await mount();
  await page.send(fixtureSession({ id: "s1", chosen: "blue" }));
  await page.press("cmux.sidebar.groupEditor.color.green");
  const checked = [...host.querySelectorAll('[role="radio"][aria-checked="true"]')].map((dot) =>
    dot.getAttribute("data-testid"),
  );
  expect(checked).toEqual(["cmux.sidebar.groupEditor.color.green"]);
  // The host's refresh is the truth from then on.
  await page.send({ ...fixtureSession({ id: "s1", revision: 2 }), colors: fixtureColors("yellow") });
  expect(host.querySelector('[aria-checked="true"]')?.getAttribute("data-testid")).toBe(
    "cmux.sidebar.groupEditor.color.yellow",
  );
});

test("a press released outside the control does nothing", async () => {
  const page = await mount();
  await page.send(fixtureSession({ id: "s1" }));
  await act(async () => {
    host
      .querySelector('[data-testid="cmux.sidebar.groupEditor.action.workspaceGroup.delete"]')!
      .dispatchEvent(new view.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    host
      .querySelector('[data-testid="cmux.sidebar.groupEditor.action.workspaceGroup.ungroup"]')!
      .dispatchEvent(new view.MouseEvent("mouseup", { bubbles: true, button: 0 }));
  });
  expect(page.of(GroupEditorOps.item)).toEqual([]);
});

test("ready goes once per drawn revision, a frame after the commit, with a height", async () => {
  const page = await mount();
  await page.send(fixtureSession({ id: "s1", revision: 1 }));
  // Not before the frame after the commit.
  expect(page.of(GroupEditorOps.ready)).toEqual([]);
  await page.flushFrames();
  await page.flushFrames();
  const first = page.of(GroupEditorOps.ready);
  expect(first).toHaveLength(1);
  expect(first[0]).toMatchObject({ session: "s1", revision: 1 });
  expect(typeof first[0]!.height).toBe("number");

  // A repeated or older revision draws nothing new and sends no ready.
  await page.send(fixtureSession({ id: "s1", revision: 1 }));
  await page.flushFrames();
  expect(page.of(GroupEditorOps.ready)).toHaveLength(1);

  // Two refreshes in one frame: the newer one's ready only.
  await page.send(fixtureSession({ id: "s1", revision: 2 }));
  await page.send(fixtureSession({ id: "s1", revision: 3 }));
  await page.flushFrames();
  expect(page.of(GroupEditorOps.ready).map((ready) => ready.revision)).toEqual([1, 3]);

  // A new open is ready on its own id.
  await page.send(fixtureSession({ id: "s2", revision: 4 }));
  await page.flushFrames();
  expect(page.of(GroupEditorOps.ready).at(-1)).toMatchObject({ session: "s2", revision: 4 });
});

test("the dots are radios in a radio group, the rows buttons, the field labelled", async () => {
  const page = await mount();
  await page.send(fixtureSession({ id: "s1", chosen: null }));
  const group = host.querySelector('[role="radiogroup"]')!;
  const radios = [...group.querySelectorAll('[role="radio"]')];
  expect(radios.map((radio) => radio.getAttribute("aria-label"))).toEqual([
    "No color",
    "Red",
    "Orange",
    "Yellow",
    "Green",
    "Cyan",
    "Blue",
    "Purple",
    "Pink",
    "Custom color",
  ]);
  // No color rings the grey dot.
  expect(radios[0]!.getAttribute("aria-checked")).toBe("true");
  expect(page.field().getAttribute("aria-label")).toBe("Group name");
  const rows = [...host.querySelectorAll(".group-editor-row")];
  expect(rows.every((row) => row.tagName === "BUTTON")).toBe(true);
  expect(rows.find((row) => row.textContent?.startsWith("Sort"))?.textContent).toBe("SortManual");
});
