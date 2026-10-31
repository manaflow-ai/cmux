import { afterAll, afterEach, expect, test } from "bun:test";
import { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { QuickModelMenu, type QuickMenu } from "../src/agent-session/acpmux/QuickModelMenu";
import { ModelPicker } from "../src/agent-session/acpmux/ModelPicker";
import type { ModelPickerProps } from "../src/agent-session/acpmux/modelPickerLayout";
import { UiProvider } from "../src/ui/UiProvider";
import type { PopupHost } from "../src/ui/popupHost";
import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "../src/ui/nativePopup";

let root: Root | undefined;
let dom: JSDOM | undefined;
const saved = new Map<string, unknown>();
const scope = globalThis as Record<string, unknown>;
function install() {
  dom = new JSDOM("<main id=root></main>", { pretendToBeVisual: true, url: "https://cmux.test" });
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  return dom.window.document.getElementById("root")!;
}
afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});
const emitted: NativePopupModel[] = [];
// The focused integration command compiles the generated Swift model plus the actual host
// validator and supplies this executable. Every descriptor emitted by the React consumers is
// decoded and validated, including asynchronous route and search updates.
afterAll(() => {
  const validator = process.env.NATIVE_POPUP_VALIDATOR;
  if (!validator) return;
  const result = Bun.spawnSync([validator], {
    stdin: Buffer.from(emitted.map((model) => JSON.stringify(model)).join("\n")),
  });
  expect(result.stderr.toString()).toBe("");
  expect(result.exitCode).toBe(0);
  expect(emitted.length).toBeGreaterThan(0);
});
function transport(shown = true) {
  const models: NativePopupModel[] = [];
  const listeners = new Set<(event: NativePopupEvent) => void>();
  const capture = (model: NativePopupModel) => {
    models.push(model);
    emitted.push(model);
  };
  const host: PopupHost = {
    show: async () => ({ shown: false }),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
    native: {
      show: async (model) => {
        capture(model);
        return { shown };
      },
      update: capture,
      hide() {},
      listen(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
  };
  const latest = () => models.at(-1)!;
  const emit = async (
    id: string,
    value?: string,
    type: NativePopupEvent["type"] = "pick",
    revision = latest().revision,
  ) => {
    const model = latest();
    await act(async () => {
      for (const listener of listeners) listener({ type, popupId: model.id, revision, id, value });
    });
  };
  return { host, latest, emit, rows: () => all(latest().rows), models };
}
const all = (rows: NativePopupRow[]): NativePopupRow[] => rows.flatMap((row) => [row, ...all(row.children ?? [])]);
async function mount(menu: QuickMenu, shown = true) {
  const container = install();
  const f = transport(shown);
  let update: (menu: QuickMenu) => void;
  let reopen: () => void;
  function Fixture() {
    const trigger = useRef<HTMLButtonElement>(null);
    const [open, setOpen] = useState(true);
    const [currentMenu, setMenu] = useState(menu);
    update = setMenu;
    reopen = () => setOpen(true);
    return (
      <UiProvider container={container} popupHost={f.host}>
        <QuickModelMenu
          open={open}
          onOpenChange={setOpen}
          trigger={trigger}
          chip={{ "data-menu": "Model", label: "Model", title: "Model" }}
          menu={currentMenu}
          onMore={() => {}}
        >
          Model
        </QuickModelMenu>
      </UiProvider>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Fixture />);
  });
  return {
    container,
    ...f,
    update: async (next: QuickMenu) => {
      await act(async () => update(next));
    },
    reopen: async () => {
      await act(async () => reopen());
    },
  };
}
const base = (): QuickMenu => ({
  models: [{ id: "a", name: "Alpha" }],
  current: "a",
  onModel() {},
});

test("native rows pick a model without mounting hidden menu rows", async () => {
  const picked: string[] = [];
  const f = await mount({
    ...base(),
    models: [{ id: "b", name: "Beta" }],
    onModel: (id) => picked.push(id),
  });
  expect(f.container.querySelector('[role^="menuitem"]')).toBeNull();
  const row = f.rows().find((row) => row.label === "Beta")!;
  expect(row.kind).toBe("action");
  await f.emit(row.id);
  expect(picked).toEqual(["b"]);
});

test("compatible Cmux routes remain provider choices, inherited default cannot unbind", async () => {
  const picked: [string, string | null][] = [];
  const f = await mount({
    ...base(),
    account: {
      sessionId: "session-a",
      accounts: {
        list: async () => ({
          active: "cmux",
          scope: "workspace",
          accounts: [
            { id: "cmux", name: "Cmux", kind: "cmux-router" },
            { id: "direct", name: "Direct", kind: "direct-api-key" },
          ],
        }),
        set: async (session, id) => {
          picked.push([session, id]);
        },
      },
    },
  });
  const provider = f.rows().find((row) => row.id === "providers")!;
  expect(provider.label).toBe("Account");
  expect(provider.children?.some((row) => row.label === "Cmux" && row.checked)).toBe(true);
  const fallback = provider.children![0]!;
  expect(fallback.disabled).toBe(true);
  await f.emit(fallback.id);
  expect(picked).toEqual([]);
  await f.emit(provider.children!.find((row) => row.label === "Direct")!.id);
  expect(picked).toEqual([["session-a", "direct"]]);
});

test("effort slider uses an index and maps changes to effort values", async () => {
  const picked: string[] = [];
  const f = await mount({
    ...base(),
    effort: {
      current: "high",
      levels: [
        { id: "low", name: "Low" },
        { id: "high", name: "High" },
      ],
      slider: true,
      onPick: (id) => picked.push(id),
    },
  });
  const slider = f.rows().find((row) => row.kind === "slider")!;
  expect(slider.value).toBe("1");
  await f.emit(slider.id, "0", "change");
  await f.emit(slider.id, "invalid", "change");
  expect(picked).toEqual(["low"]);
});

test.each(["submenu", "expanded", "row"] as const)(
  "provider presentation %s preserves distinct selectable offers",
  async (providers) => {
    const picked: string[] = [];
    const f = await mount({
      ...base(),
      providers,
      current: "other",
      models: [
        {
          id: "a",
          name: "Alpha",
          offers: [
            { id: "a", family: "", name: "Alpha", provider: "One" },
            { id: "other", family: "", name: "Alpha", provider: "Two" },
          ],
        },
      ],
      onModel: (id) => picked.push(id),
    });
    const rows = f.rows();
    expect(new Set(rows.map((row) => row.id)).size).toBe(rows.length);
    expect(rows.some((row) => row.kind === "choice" && !row.options?.length)).toBe(false);
    expect(rows.some((row) => row.kind === "section" && !!row.children?.length)).toBe(false);
    await f.emit(rows.find((row) => row.label === "One")!.id);
    expect(picked).toEqual(["a"]);
  },
);

test("search groups are flat headings and twins retain model identity", async () => {
  const families = [
    {
      id: "claude",
      name: "Claude",
      models: [{ id: "a", family: "claude", name: "Alpha" }],
      more: [],
    },
  ];
  const f = await mount({
    ...base(),
    families: { list: families, current: "claude", onPick() {} },
    search: {
      find: () => [
        { id: "one", name: "Same", family: "claude" },
        { id: "two", name: "Same", family: "claude" },
      ],
      pick() {},
    },
  });
  await f.emit("query", "same", "search");
  expect(f.latest().rows[0]).toMatchObject({ kind: "section", label: "Claude" });
  expect(f.latest().rows[0]!.children).toBeUndefined();
  expect(
    f
      .rows()
      .filter((row) => row.label === "Same")
      .map((row) => row.description),
  ).toEqual(["one", "two"]);
});

test("full native picker selects generated model IDs and retains native focus ownership", async () => {
  const container = install();
  const f = transport();
  const picked: string[] = [];
  const props: ModelPickerProps = {
    catalog: [
      {
        id: "claude",
        name: "Claude",
        models: [
          { id: "alpha", name: "Alpha" },
          { id: "beta", name: "Beta" },
        ],
      },
    ],
    harness: "claude",
    model: "alpha",
    label: "Alpha",
    efforts: [],
    recents: [],
    harnessFixed: true,
    onLand: (id) => picked.push(id),
    onEffort() {},
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={f.host}>
        <ModelPicker {...props} />
      </UiProvider>,
    );
  });
  await act(async () => {
    container.querySelector<HTMLButtonElement>("button")!.click();
  });
  expect(f.latest()).toBeDefined();
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  await act(async () => {
    window.dispatchEvent(new dom!.window.Event("blur"));
  });
  expect(container.querySelector("button")?.getAttribute("aria-expanded")).toBe("true");
  const row = f.rows().find((row) => row.label === "Beta")!;
  expect(row.kind).toBe("action");
  await f.emit(row.id);
  expect(picked).toEqual(["beta"]);
});

test("late account replies cannot overwrite a different session, and refusal is shown on reopen", async () => {
  let resolveOld: ((value: { accounts: { id: string; name: string; kind: string }[] }) => void) | undefined;
  const accounts = {
    list: (session: string) =>
      session === "old"
        ? new Promise<{ accounts: { id: string; name: string; kind: string }[] }>((resolve) => {
            resolveOld = resolve;
          })
        : Promise.resolve({
            accounts: [{ id: "new-route", name: "New route", kind: "direct-api-key" }],
          }),
    set: async () => {
      throw new Error("refused");
    },
  };
  const f = await mount({ ...base(), account: { sessionId: "old", accounts } });
  await f.update({ ...base(), account: { sessionId: "new", accounts } });
  await act(async () => {
    resolveOld?.({ accounts: [{ id: "stale", name: "Stale route", kind: "direct-api-key" }] });
  });
  expect(f.rows().some((row) => row.label === "Stale route")).toBe(false);
  const row = f.rows().find((row) => row.label === "New route")!;
  await f.emit(row.id);
  await f.reopen();
  expect(f.rows().some((row) => row.id === "provider-refused")).toBe(true);
});

test("native fast mode stays open and auth refresh remains reachable", async () => {
  const picked: boolean[] = [];
  let refreshes = 0;
  const f = await mount({
    ...base(),
    fast: { checked: false, onChange: (value) => picked.push(value) },
    auth: {
      verdict: {
        state: "signedOut",
        source: "authCheck",
        evidenceAt: 1,
        login: { kind: "terminal", command: "login" },
      },
      onLogin() {},
      onRefresh: () => refreshes++,
    },
  });
  const fast = f.rows().find((row) => row.kind === "toggle")!;
  expect(fast.keepOpen).toBe(true);
  await f.emit(fast.id, "true", "change");
  expect(picked).toEqual([true]);
  expect(f.container.querySelector("button")?.getAttribute("aria-expanded")).toBe("true");
  await f.emit(f.rows().find((row) => row.label === "Check again")!.id);
  expect(refreshes).toBe(1);
});

test("a digit typed into the empty search picks that numbered row", async () => {
  const picked: string[] = [];
  const f = await mount({
    ...base(),
    models: [
      { id: "a", name: "Alpha" },
      { id: "b", name: "Beta" },
    ],
    search: { find: () => [], pick() {} },
    onModel: (id) => picked.push(id),
  });
  expect(f.rows().find((row) => row.label === "Beta")?.shortcut).toBe("2");
  await f.emit("query", "2", "search");
  expect(picked).toEqual(["b"]);
});

test("the web menu draws an opening the native host could not show", async () => {
  const f = await mount({ ...base(), models: [{ id: "b", name: "Beta" }] }, false);
  await act(async () => {});
  expect(f.models.length).toBe(1);
  expect(document.querySelector('[role="menu"]')).not.toBeNull();
  expect([...document.querySelectorAll('[role^="menuitem"]')].some((row) => row.textContent?.includes("Beta"))).toBe(
    true,
  );
});

test("a model's effort is a side dropdown whose level lands with the model", async () => {
  const picked: { id: string; effort?: string }[] = [];
  const row = (id: string, name: string) => ({ id, name, family: "claude", efforts: ["low", "high"] });
  const f = await mount({
    ...base(),
    models: [],
    current: "a",
    inlineEffort: true,
    families: {
      list: [{ id: "claude", name: "Claude", models: [row("a", "Alpha"), row("b", "Beta")], more: [] }],
      current: "claude",
      onPick: (model) => picked.push({ id: model.id, ...(model.effort ? { effort: model.effort } : {}) }),
    },
  });
  const beta = f.latest().rows.find((candidate) => candidate.label === "Beta")!;
  expect(beta.kind).toBe("action");
  expect(beta.children?.map((level) => level.kind)).toEqual(["action", "action"]);
  const high = beta.children!.at(-1)!;
  await f.emit(high.id);
  expect(picked).toEqual([{ id: "b", effort: "high" }]);
  // The row itself still lands the model.
  await f.reopen();
  await f.emit(f.latest().rows.find((candidate) => candidate.label === "Beta")!.id);
  expect(picked.at(-1)).toEqual({ id: "b" });
});

test("an edit made at an earlier revision of the open popup still lands", async () => {
  const f = await mount({ ...base(), search: { find: () => [], pick() {} } });
  const first = f.latest().revision;
  await f.update({ ...base(), models: [{ id: "a", name: "Alpha 2" }], search: { find: () => [], pick() {} } });
  expect(f.latest().revision).toBeGreaterThan(first);
  await f.emit("query", "alp", "search", first);
  expect(f.latest().search?.value).toBe("alp");
});

async function mountPicker(props: Partial<ModelPickerProps>) {
  const container = install();
  const f = transport();
  const picked: string[] = [];
  const full: ModelPickerProps = {
    catalog: [
      {
        id: "claude",
        name: "Claude",
        models: [
          { id: "alpha", name: "Alpha" },
          { id: "beta", name: "Beta" },
        ],
      },
      { id: "codex", name: "Codex", models: [{ id: "gamma", name: "Gamma" }] },
    ],
    harness: "claude",
    model: "alpha",
    label: "Alpha",
    efforts: [],
    recents: [],
    onLand: (id) => picked.push(id),
    onEffort() {},
    ...props,
  } as ModelPickerProps;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={f.host}>
        <ModelPicker {...full} />
      </UiProvider>,
    );
  });
  await act(async () => {
    container.querySelector<HTMLButtonElement>("button")!.click();
  });
  return { ...f, picked, container };
}

test("full native picker lists this folder's profiles and opens one", async () => {
  const f = await mountPicker({
    catalog: [
      { id: "claude", name: "Claude", models: [{ id: "alpha", name: "Alpha" }] },
      {
        id: "machine-profile",
        name: "Build machine",
        folder: { folder: "/Users/me/app", state: "enabled" },
        models: [{ id: "machine-model", name: "Machine model" }],
      },
    ] as ModelPickerProps["catalog"],
  });
  const profile = f.rows().find((row) => row.label === "Build machine")!;
  expect(profile.kind).toBe("action");
  await f.emit(profile.id);
  expect(f.rows().find((row) => row.label === "Build machine")?.checked).toBe(true);
  expect(f.rows().some((row) => row.label === "Machine model")).toBe(true);
});

test("a native rail click during a search leaves the search for that harness", async () => {
  const f = await mountPicker({});
  await f.emit("query", "a", "search");
  expect(f.latest().search?.value).toBe("a");
  const codex = f.latest().rail!.find((row) => row.label === "Codex")!;
  await f.emit(codex.id);
  expect(f.latest().search?.value).toBe("");
  expect(f.latest().rail!.find((row) => row.label === "Codex")?.checked).toBe(true);
});

test("a digit typed into the full picker's empty search picks that numbered row", async () => {
  const f = await mountPicker({});
  expect(f.rows().find((row) => row.label === "Beta")?.shortcut).toBe("2");
  await f.emit("query", "2", "search");
  expect(f.picked).toEqual(["beta"]);
});

test("a native menu whose web look hides the field until typing still offers its search", async () => {
  const f = await mount({ ...base(), searchField: "typed", search: { find: () => [], pick() {} } });
  expect(f.latest().search?.id).toBe("query");
  await f.emit("query", "al", "search");
  expect(f.latest().search?.value).toBe("al");
});

test("the full native picker offers the current signed-out harness its Log In", async () => {
  const logins: string[] = [];
  const f = await mountPicker({
    signedOut: { claude: "claude" },
    onLogIn: (id: string) => logins.push(id),
  } as Partial<ModelPickerProps>);
  const login = f.rows().find((row) => row.id === "login");
  expect(login?.kind).toBe("action");
  // A search lists matches, never the signed-out note.
  await f.emit("query", "gam", "search");
  expect(f.rows().some((row) => row.id === "signed-out")).toBe(false);
  await f.emit("query", "", "search");
  await f.emit("login");
  expect(logins).toEqual(["claude"]);
});

test("the full native picker's informational Default row cannot be picked", async () => {
  const f = await mountPicker({
    catalog: [
      {
        id: "prime",
        name: "Prime",
        family: "prime",
        models: [
          { id: "default", name: "Default" },
          { id: "p1", name: "Prime One" },
        ],
      },
    ] as ModelPickerProps["catalog"],
    harness: "prime",
    model: "p1",
    label: "Prime One",
  });
  const fallback = f.latest().rows.find((row) => row.kind === "action" && /default/i.test(row.label));
  expect(fallback?.disabled).toBe(true);
  expect(f.latest().rows.find((row) => row.label === "Prime One")?.disabled).toBeUndefined();
});
