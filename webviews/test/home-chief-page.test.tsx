// New Chief and Edit Chief are a page, not a dialog (u2586): the editor on Home's right side and in
// Settings > Agents > Chiefs. Its Backend picker sends the record's harness, model and effort, and
// a new harness only after its real hello turn passed; Bring your own sends the key to the host
// once and keeps no copy; the lock and Undo / Restore send what the record needs; History shows
// when, who and what changed.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChiefPage } from "../src/pages/home-channels/ChiefPage";
import type { ChiefEditorService, ChiefSave } from "../src/pages/home-channels/chiefEditing";
import { RouteSheets } from "../src/pages/home-channels/RouteSheets";
import type { HomeSheets, SheetsSnapshot } from "../src/pages/home-channels/sheets";
import type {
  HomeChief,
  HomeChiefBackend,
  HomeChiefByoBackend,
  HomeChiefDoctor,
  HomeChiefRevision,
} from "../src/pages/home-channels/types";
import table from "../src/pages/home-channels/generated/strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "HTMLSelectElement",
  "Element",
  "Node",
  "Event",
  "MouseEvent",
  "KeyboardEvent",
  "Image",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  const w = dom.window;
  Object.assign(scope, {
    window: w,
    document: w.document,
    navigator: w.navigator,
    HTMLElement: w.HTMLElement,
    HTMLInputElement: w.HTMLInputElement,
    HTMLTextAreaElement: w.HTMLTextAreaElement,
    HTMLSelectElement: w.HTMLSelectElement,
    Element: w.Element,
    Node: w.Node,
    Event: w.Event,
    MouseEvent: w.MouseEvent,
    KeyboardEvent: w.KeyboardEvent,
    Image: w.Image,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return w.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const strings = createStrings(table, ["en"]);
const { t } = strings;

const CHIEF: HomeChief = {
  id: "agent_chief",
  name: "Chief",
  role: "Runs the team's agents",
  personality: "Brief.",
  instructions: "Ship small.",
  tools: ["chiefs", "spawn", "tell", "workspaces"],
  harnesses: [],
  selfEdit: ["avatar", "display_name"],
  isDefault: true,
  rev: 3,
  createdAt: "2026-10-10T09:00:00Z",
};

const BACKENDS: HomeChiefBackend[] = [
  {
    id: "claude",
    name: "Claude Code",
    models: [{ id: "claude-opus-5-5", name: "Opus 5.5", efforts: ["low", "high"] }],
  },
  {
    id: "codex",
    name: "Codex",
    models: [{ id: "gpt-6-astra", name: "GPT-6 Astra", efforts: ["low", "medium", "high"] }],
  },
  { id: "opencode", name: "OpenCode", models: [] },
];

const REVISIONS: HomeChiefRevision[] = [
  {
    rev: 3,
    at: "2026-10-12T10:00:00Z",
    actor: "agent_chief",
    operation: "chief.profile.update",
    record: CHIEF,
  },
  {
    rev: 2,
    at: "2026-10-11T10:00:00Z",
    actor: "",
    operation: "chief.profile.update",
    record: { ...CHIEF, rev: 2, instructions: "" },
  },
  {
    rev: 1,
    at: "2026-10-10T09:00:00Z",
    actor: "",
    operation: "chief.profile.create",
    record: { ...CHIEF, rev: 1, name: "Boss", instructions: "" },
  },
];

type Call = { op: string; args: unknown[] };

/** A controllable editor service: it records every call; each check waits until the test answers it. */
function fakeService(grants = true) {
  const calls: Call[] = [];
  const checks: { id: string; answer(result: HomeChiefDoctor): void }[] = [];
  const service: ChiefEditorService = {
    grants,
    create: async (save: ChiefSave) => {
      calls.push({ op: "create", args: [save] });
      return true;
    },
    update: async (before: HomeChief, save: ChiefSave) => {
      calls.push({ op: "update", args: [before.id, save] });
      return true;
    },
    close: () => calls.push({ op: "close", args: [] }),
    history: async (chief: string) => {
      calls.push({ op: "history", args: [chief] });
      return REVISIONS;
    },
    undo: async (chief: HomeChief, toRev?: number) => {
      calls.push({ op: "undo", args: [chief.id, toRev] });
      return { ...CHIEF, rev: chief.rev + 1, name: toRev === 1 ? "Boss" : chief.name, instructions: "" };
    },
    backends: async () => BACKENDS,
    addBackend: async (backend: HomeChiefByoBackend) => {
      calls.push({ op: "addBackend", args: [backend] });
      return "acme";
    },
    checkBackend: (id: string) =>
      new Promise<HomeChiefDoctor>((resolve) => {
        calls.push({ op: "checkBackend", args: [id] });
        checks.push({ id, answer: resolve });
      }),
  };
  return { service, calls, checks };
}

async function flush() {
  for (let i = 0; i < 4; i += 1) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

async function mount(container: HTMLElement, service: ChiefEditorService, chief?: HomeChief) {
  await act(async () => {
    root = createRoot(container);
    root.render(<ChiefPage service={service} strings={strings} chief={chief} />);
  });
  await flush();
}

const byLabel = <T extends HTMLElement>(container: HTMLElement, label: string, within = "") =>
  container.querySelector<T>(`${within} [aria-label="${label}"]`)!;

async function choose(select: HTMLSelectElement, value: string) {
  await act(async () => {
    select.value = value;
    select.dispatchEvent(new window.Event("change", { bubbles: true }));
  });
  await flush();
}

async function type(input: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const proto = input.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
  await act(async () => {
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(input, value);
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
}

async function click(element: HTMLElement) {
  await act(async () => {
    element.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  });
  await flush();
}

const button = (container: HTMLElement, text: string) =>
  [...container.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === text)!;

async function save(container: HTMLElement) {
  const form = container.querySelector<HTMLFormElement>(".chief-editor form")!;
  await act(async () => {
    form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  });
  await flush();
}

const lastSave = (calls: Call[]) =>
  calls
    .filter((call) => call.op === "update" || call.op === "create")
    .at(-1)
    ?.args.at(-1) as ChiefSave | undefined;

test("New Chief draws as a page on Home's right side, never a dialog", async () => {
  const container = installDom();
  const { service } = fakeService();
  await mount(container, service);
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  const page = container.querySelector<HTMLElement>("section.chief-editor");
  expect(page).not.toBeNull();
  const title = document.getElementById(page!.getAttribute("aria-labelledby")!);
  expect(title?.textContent).toBe(t("sheet.newChief.title"));

  // The route draws no sheet over the page: the Home page draws ChiefRoutePage in its right side.
  act(() => root!.unmount());
  root = undefined;
  const state: SheetsSnapshot = {
    route: { kind: "newChief" },
    ready: true,
    capabilities: { start: true, invite: true, chiefs: true },
    chiefGrants: true,
    chiefs: new Map([[CHIEF.id, CHIEF]]),
    pictures: new Map(),
  };
  for (const route of [{ kind: "newChief" } as const, { kind: "editChief", chief: CHIEF.id } as const]) {
    await act(async () => {
      root = createRoot(container);
      root.render(
        <RouteSheets
          sheets={{} as HomeSheets}
          state={{ ...state, route }}
          strings={strings}
          conversations={new Map()}
        />,
      );
    });
    expect(container.innerHTML).toBe("");
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    act(() => root!.unmount());
    root = undefined;
  }
});

test("the Backend picker sends harness, model and effort, after the harness's check passed", async () => {
  const container = installDom();
  const { service, calls, checks } = fakeService();
  await mount(container, service, CHIEF);
  const picker = byLabel<HTMLSelectElement>(container, t("chief.backend.title"));
  expect(picker.value).toBe("");
  expect([...picker.options].map((option) => option.textContent)).toEqual([
    t("chief.backend.default"),
    "Claude Code",
    "Codex",
    "OpenCode",
    t("chief.backend.byo"),
  ]);

  await choose(picker, "codex");
  // A real hello turn on the picked harness before the record takes it; Save waits for it.
  expect(calls.filter((call) => call.op === "checkBackend").map((call) => call.args[0])).toEqual(["codex"]);
  expect(container.textContent).toContain(t("chief.backend.checking"));
  expect(container.querySelector<HTMLButtonElement>(".lg-form-actions .primary")!.disabled).toBe(true);
  await act(async () => checks[0]!.answer({ ok: true, steps: [{ name: "prompt", ok: true }] }));
  await flush();
  expect(container.textContent).toContain(t("chief.backend.passed"));

  await choose(byLabel<HTMLSelectElement>(container, t("chief.backend.model")), "gpt-6-astra");
  const effort = byLabel<HTMLSelectElement>(container, t("chief.backend.effort"));
  // Effort options from the harness's capabilities (the picked model's efforts).
  expect([...effort.options].map((option) => option.value)).toEqual(["", "low", "medium", "high"]);
  await choose(effort, "high");
  await save(container);
  expect(lastSave(calls)?.engine).toEqual({ harness: "codex", model: "gpt-6-astra", effort: "high" });
});

test("Default (Chief's usual) clears the backend without a check", async () => {
  const container = installDom();
  const { service, calls } = fakeService();
  await mount(container, service, {
    ...CHIEF,
    engine: { harness: "claude", model: "claude-opus-5-5", effort: "high" },
  });
  const picker = byLabel<HTMLSelectElement>(container, t("chief.backend.title"));
  expect(picker.value).toBe("claude");
  await choose(picker, "");
  expect(calls.some((call) => call.op === "checkBackend")).toBe(false);
  await save(container);
  expect(lastSave(calls)?.engine).toEqual({ harness: "", model: "", effort: "" });
});

async function openBringYourOwn(container: HTMLElement) {
  const picker = byLabel<HTMLSelectElement>(container, t("chief.backend.title"));
  await choose(picker, picker.options[picker.options.length - 1]!.value);
  const form = container.querySelector<HTMLElement>("[data-chief-byo]");
  expect(form).not.toBeNull();
  const within = "[data-chief-byo]";
  await click(byLabel(container, t("chief.byo.kind.anthropic"), within));
  await type(byLabel(container, t("chief.byo.name"), within), "Acme");
  await type(byLabel(container, t("chief.byo.baseUrl"), within), "https://api.acme.dev");
  await type(byLabel(container, t("chief.byo.model"), within), "acme-1");
  await type(byLabel(container, t("chief.byo.apiKey"), within), "sk-secret-123");
  await click(button(container, t("chief.byo.add")));
}

const keyAnywhere = (container: HTMLElement) =>
  container.innerHTML.includes("sk-secret-123") ||
  [...container.querySelectorAll<HTMLInputElement>("input")].some((input) => input.value.includes("sk-secret-123"));

test("Bring your own sends the key to the host once, keeps no copy, and saves only after the check passed", async () => {
  const container = installDom();
  const { service, calls, checks } = fakeService();
  await mount(container, service, CHIEF);
  await openBringYourOwn(container);

  const added = calls.find((call) => call.op === "addBackend")!.args[0] as HomeChiefByoBackend;
  expect(added).toEqual({
    kind: "anthropic-endpoint",
    name: "Acme",
    baseUrl: "https://api.acme.dev",
    model: "acme-1",
    apiKey: "sk-secret-123",
  });
  // After submit the key is gone from the page: no field, no text.
  expect(keyAnywhere(container)).toBe(false);
  expect(byLabel<HTMLInputElement>(container, t("chief.byo.apiKey"), "[data-chief-byo]").value).toBe("");

  // The host's hello turn runs; until it passes the Chief's backend stays as it was.
  expect(calls.filter((call) => call.op === "checkBackend").map((call) => call.args[0])).toEqual(["acme"]);
  expect(container.textContent).toContain(t("chief.backend.checking"));
  expect(byLabel<HTMLSelectElement>(container, t("chief.backend.title")).value).toBe("");
  await act(async () => checks[0]!.answer({ ok: true, steps: [{ name: "prompt", ok: true }] }));
  await flush();
  expect(byLabel<HTMLSelectElement>(container, t("chief.backend.title")).value).toBe("acme");

  await save(container);
  const sent = lastSave(calls)!;
  expect(sent.engine).toEqual({ harness: "acme", model: "acme-1" });
  expect(JSON.stringify(calls.filter((call) => call.op !== "addBackend"))).not.toContain("sk-secret-123");
  expect(keyAnywhere(container)).toBe(false);
});

test("a failed check shows the failing step and its fix, and the backend is not saved", async () => {
  const container = installDom();
  const { service, calls, checks } = fakeService();
  await mount(container, service, CHIEF);
  await openBringYourOwn(container);
  await act(async () =>
    checks[0]!.answer({
      ok: false,
      steps: [
        { name: "launch", ok: true },
        { name: "prompt", ok: false, detail: "401 Unauthorized", fix: "Check the API key." },
      ],
    }),
  );
  await flush();
  expect(container.textContent).toContain(strings.format("chief.backend.failed", "prompt"));
  expect(container.textContent).toContain(strings.format("chief.backend.fix", "Check the API key."));
  expect(byLabel<HTMLSelectElement>(container, t("chief.backend.title")).value).toBe("");
  await save(container);
  expect(lastSave(calls)?.engine).toBeUndefined();
  expect(keyAnywhere(container)).toBe(false);
});

test("the lock switch sends locked, and only when it changed", async () => {
  const container = installDom();
  const { service, calls } = fakeService();
  await mount(container, service, CHIEF);
  const lock = container.querySelector<HTMLInputElement>("input[data-chief-lock]")!;
  expect(lock.getAttribute("aria-label")).toBe(t("chief.lock.title"));
  expect(lock.checked).toBe(false);
  await save(container);
  expect(lastSave(calls)?.locked).toBeUndefined();
  await click(lock);
  expect(lock.checked).toBe(true);
  await save(container);
  expect(lastSave(calls)?.locked).toBe(true);
});

test("History lists each revision with when, who and what changed", async () => {
  const container = installDom();
  const { service, calls } = fakeService();
  await mount(container, service, CHIEF);
  expect(calls.find((call) => call.op === "history")?.args).toEqual([CHIEF.id]);
  const rows = [...container.querySelectorAll<HTMLElement>("[data-chief-history] .ce-history-row")];
  expect(rows.map((row) => row.dataset.rev)).toEqual(["3", "2", "1"]);
  expect(rows[0]!.querySelector(".ce-history-what")!.textContent).toBe(t("chief.change.instructions"));
  expect(rows[0]!.querySelector(".ce-history-who")!.textContent).toBe("Chief");
  expect(rows[0]!.textContent).toContain(t("chief.history.current"));
  expect(rows[1]!.querySelector(".ce-history-what")!.textContent).toBe(t("chief.change.name"));
  expect(rows[1]!.querySelector(".ce-history-who")!.textContent).toBe(t("chief.history.you"));
  expect(rows[2]!.querySelector(".ce-history-what")!.textContent).toBe(t("chief.history.created"));
  expect(rows[2]!.querySelector("time")!.getAttribute("dateTime")).toBe("2026-10-10T09:00:00Z");
});

test("Undo Last Change and Restore This Version send chief.profile.undo, and the fields follow", async () => {
  const container = installDom();
  const { service, calls } = fakeService();
  await mount(container, service, CHIEF);
  await click(button(container, t("chief.history.undo")));
  expect(calls.filter((call) => call.op === "undo").map((call) => call.args)).toEqual([[CHIEF.id, undefined]]);
  expect(byLabel<HTMLTextAreaElement>(container, t("chief.field.instructions")).value).toBe("");

  const restore = container.querySelector<HTMLElement>('[data-chief-history] [data-rev="1"] button')!;
  expect(restore.textContent).toBe(t("chief.history.restore"));
  await click(restore);
  expect(calls.filter((call) => call.op === "undo").map((call) => call.args)).toEqual([
    [CHIEF.id, undefined],
    [CHIEF.id, 1],
  ]);
  expect(byLabel<HTMLInputElement>(container, t("chief.field.name")).value).toBe("Boss");
});

test("without the host's relay the gesture fields, the backend and the lock show read-only", async () => {
  const container = installDom();
  const { service } = fakeService(false);
  await mount(container, service, CHIEF);
  expect(byLabel<HTMLSelectElement>(container, t("chief.backend.title")).disabled).toBe(true);
  expect(container.querySelector<HTMLInputElement>("input[data-chief-lock]")!.disabled).toBe(true);
  expect(button(container, t("chief.history.undo")).disabled).toBe(true);
  expect(byLabel<HTMLInputElement>(container, t("chief.field.name")).disabled).toBe(false);
});
