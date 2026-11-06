// The model button's menu as columns (QuickModelColumns.tsx): the rail, the models and the shown
// model's settings, with the account avatar in the search row's corner.
import { afterEach, expect, test } from "bun:test";
import React, { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { ChatAccounts, NewChatAccount } from "./chatAccounts";
import type { QuickFamily, QuickModel } from "./QuickModelMenu";
import { authText, type SessionAuth } from "./sessionAuth";
import { translate } from "./i18n";

let QuickModelColumns: typeof import("./QuickModelColumns").QuickModelColumns;

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

const model = (family: string, name: string, extra: Partial<QuickModel> = {}): QuickModel => ({
  id: `${family}-${name}`,
  name,
  family,
  ...extra,
});

const claude: QuickFamily = {
  id: "claude",
  name: "Claude",
  mark: "claude",
  accountFamily: "claude",
  models: [
    model("claude", "Opus", { efforts: ["low", "medium", "high"], canFast: true }),
    model("claude", "Haiku", { efforts: [] }),
  ],
  more: [model("claude", "Old")],
};
const codex: QuickFamily = {
  id: "codex",
  name: "Codex",
  mark: "codex",
  accountFamily: "codex",
  models: [
    model("codex", "Sol", { efforts: ["low", "high"], defaultEffort: "low", canFast: true }),
    model("codex", "Astra", { efforts: ["low", "medium", "high"], defaultEffort: "high" }),
  ],
  more: [],
};
const gemini: QuickFamily = {
  id: "gemini",
  name: "Gemini",
  accountFamily: "gemini",
  models: [model("gemini", "Pro", { disabled: true })],
  more: [],
  note: "Not installed",
  setUp() {},
};

type Calls = {
  picks: QuickModel[];
  efforts: string[];
  fast: boolean[];
  added: NewChatAccount[];
  open: boolean;
  logins: number;
  refreshes: number;
};

function Harness({
  calls,
  list,
  startEffort,
  auth,
}: {
  calls: Calls;
  list: QuickFamily[];
  startEffort: string;
  auth?: SessionAuth;
}) {
  const [open, setOpen] = useState(false);
  const [effort, setEffort] = useState(startEffort);
  const trigger = useRef<HTMLButtonElement | null>(null);
  calls.open = open;
  const accounts: ChatAccounts = {
    list: async () => ({
      accounts: [
        { id: "max", name: "Max", kind: "direct-subscription" },
        { id: "key", name: "Work key", kind: "direct-api-key" },
      ],
      active: "max",
      scope: "chat",
      family: "claude",
    }),
    add: async (account) => {
      calls.added.push(account);
    },
    set: async () => undefined,
  };
  return (
    <QuickModelColumns
      open={open}
      onOpenChange={setOpen}
      trigger={trigger}
      chip={{ "data-menu": "model", label: "Model", title: "Model" }}
      menu={{
        models: [],
        current: "claude-Opus",
        onModel() {},
        inlineEffort: true,
        ...(auth
          ? {
              auth: {
                verdict: auth,
                onLogin: () => {
                  calls.logins += 1;
                },
                onRefresh: () => {
                  calls.refreshes += 1;
                },
              },
            }
          : {}),
        effort: {
          levels: [
            { id: "low", name: "Low" },
            { id: "medium", name: "Medium", recommended: true },
            { id: "high", name: "High" },
            ...(startEffort === "ultracode" ? [{ id: "ultracode", name: "Ultracode" }] : []),
          ],
          current: effort,
          onPick(value) {
            calls.efforts.push(value);
            setEffort(value);
          },
        },
        // The session reports Fast later: the switch must show the pick before it does.
        fast: {
          checked: false,
          onChange(on) {
            calls.fast.push(on);
          },
        },
        account: { sessionId: "chat-1", accounts },
        search: {
          find: (query) =>
            list.flatMap((family) =>
              [...family.models, ...family.more].filter((row) => row.name.toLowerCase().includes(query)),
            ),
          pick(row) {
            calls.picks.push(row);
          },
        },
        families: {
          list,
          current: "claude",
          onPick(row) {
            calls.picks.push(row);
          },
          stars: { has: () => false, toggle() {} },
        },
      }}
      onMore={() => {}}
    >
      Model
    </QuickModelColumns>
  );
}

async function openMenu(list: QuickFamily[] = [claude, codex, gemini], startEffort = "medium", auth?: SessionAuth) {
  const container = installDom();
  QuickModelColumns ??= (await import("./QuickModelColumns")).QuickModelColumns;
  const calls: Calls = { picks: [], efforts: [], fast: [], added: [], open: false, logins: 0, refreshes: 0 };
  await act(async () => {
    root = createRoot(container);
    root.render(<Harness calls={calls} list={list} startEffort={startEffort} {...(auth ? { auth } : {})} />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  return calls;
}

const popup = () => document.querySelector<HTMLElement>(".acpmux-cols")!;
const tabs = () => [...popup().querySelectorAll<HTMLElement>(".acpmux-cols-tab[role=tab]")];
const tab = (name: string) => tabs().find((node) => node.getAttribute("aria-label") === name)!;
const rows = () => [...popup().querySelectorAll<HTMLElement>("[role=listbox] [role=option]")];
const row = (name: string) => rows().find((node) => node.querySelector(".acpmux-cols-name")?.textContent === name)!;
const tune = () => popup().querySelector<HTMLElement>(".acpmux-cols-tune")!;
const levels = () =>
  [...tune().querySelectorAll<HTMLElement>("[role=radio]")].map((node) => ({
    name: node.querySelector(".acpmux-cols-name")?.textContent,
    checked: node.getAttribute("aria-checked") === "true",
  }));
const fastSwitch = () => tune().querySelector<HTMLElement>("[role=switch]")!;
const press = async (key: string) => {
  await act(async () => {
    popup()
      .querySelector(".acpmux-cols-frame")!
      .dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true }));
  });
  await settle();
};
const click = async (node: HTMLElement) => {
  await act(async () => node.click());
  await settle();
};

test("the Starred tab is always first; an empty one shows a blank avatar with no badge", async () => {
  await openMenu();
  expect(tabs()[0]!.getAttribute("aria-label")).toBe("Starred");
  await click(tabs()[0]!);
  expect(popup().querySelector(".acpmux-cols-note")?.textContent).toBe("No starred models");
  const corner = popup().querySelector(".acpmux-cols-corner")!;
  expect(corner.querySelector("[data-blank]")).not.toBeNull();
  expect(corner.querySelector(".acpmux-cols-avatar-badge")).toBeNull();
  expect(corner.querySelector("button")).toBeNull();
});

test("the running model shows its session levels, highest first, with the current one checked", async () => {
  await openMenu();
  expect(row("Opus").hasAttribute("data-hl")).toBe(true);
  expect(levels()).toEqual([
    { name: "High", checked: false },
    { name: "Medium", checked: true },
    { name: "Low", checked: false },
  ]);
});

test("a model with no levels says None under Effort", async () => {
  await openMenu();
  await press("ArrowDown");
  expect(row("Haiku").hasAttribute("data-hl")).toBe(true);
  expect(tune().querySelector(".acpmux-cols-caption")?.textContent).toBe("Effort");
  expect(tune().querySelector(".acpmux-cols-note")?.textContent).toBe("None");
});

test("arrows move the highlight without landing; Return lands it and closes", async () => {
  const calls = await openMenu();
  await press("ArrowDown");
  expect(calls.picks).toHaveLength(0);
  await press("Enter");
  expect(calls.picks.map((pick) => pick.id)).toEqual(["claude-Haiku"]);
  expect(calls.open).toBe(false);
});

const chip = () => document.querySelector<HTMLButtonElement>("button[data-menu='model']")!;

test("a click on a model lands it at once and keeps the menu open", async () => {
  const calls = await openMenu();
  await click(tab("Codex"));
  await click(row("Sol"));
  expect(row("Sol").getAttribute("aria-selected")).toBe("true");
  expect(calls.open).toBe(true);
  expect(calls.picks.map((pick) => pick.id)).toEqual(["codex-Sol"]);
  // A close lands nothing more.
  await click(chip());
  expect(calls.open).toBe(false);
  expect(calls.picks).toHaveLength(1);
});

test("a picked model keeps the chat's level when it has it, else takes its recommended one", async () => {
  const calls = await openMenu();
  await click(tab("Codex"));
  // The chat is on Medium: Sol has no Medium, so it takes its recommended Low.
  await click(row("Sol"));
  expect(levels()).toEqual([
    { name: "High", checked: false },
    { name: "Low", checked: true },
  ]);
  expect(calls.picks[0]).toMatchObject({ id: "codex-Sol", effort: "low" });
  // Astra has Medium: it keeps it.
  await click(row("Astra"));
  expect(levels().find((level) => level.checked)?.name).toBe("Medium");
  expect(calls.picks).toHaveLength(2);
  expect(calls.picks[1]).toMatchObject({ id: "codex-Astra", effort: "medium" });
});

test("a level picked on one model carries to the next model clicked", async () => {
  const calls = await openMenu();
  await click(tab("Codex"));
  await click(row("Sol"));
  const high = [...tune().querySelectorAll<HTMLElement>("[role=radio]")].find((node) => node.textContent === "High")!;
  await click(high);
  // Astra has High: it takes the level just picked, not the chat's Medium or its own default.
  await click(row("Astra"));
  expect(levels().find((level) => level.checked)?.name).toBe("High");
  expect(calls.picks.at(-1)).toMatchObject({ id: "codex-Astra", effort: "high" });
});

test("a chat on Ultracode carries Extra High to a model that has it", async () => {
  const nova = model("codex", "Nova", { efforts: ["low", "high", "xhigh"], defaultEffort: "low" });
  const calls = await openMenu([claude, { ...codex, models: [...codex.models, nova] }, gemini], "ultracode");
  await click(tab("Codex"));
  await click(row("Nova"));
  expect(calls.picks[0]).toMatchObject({ id: "codex-Nova", effort: "xhigh" });
});

test("another model, then a level, then Fast each land at once, the level kept with Fast", async () => {
  const calls = await openMenu();
  await click(tab("Codex"));
  await click(row("Sol"));
  const high = [...tune().querySelectorAll<HTMLElement>("[role=radio]")].find((node) => node.textContent === "High")!;
  await click(high);
  await click(fastSwitch());
  expect(levels()).toEqual([
    { name: "High", checked: true },
    { name: "Low", checked: false },
  ]);
  expect(calls.picks.map((pick) => [pick.id, pick.effort, !!pick.fast])).toEqual([
    ["codex-Sol", "low", false],
    ["codex-Sol", "high", false],
    ["codex-Sol", "high", true],
  ]);
  // Return on the picked model only closes: it lands nothing again.
  await press("Enter");
  expect(calls.picks).toHaveLength(3);
});

test("a tab without the running model shows its first model's catalog levels", async () => {
  await openMenu();
  await click(tab("Codex"));
  expect(row("Sol").hasAttribute("data-hl")).toBe(true);
  expect(levels().map((level) => level.name)).toEqual(["High", "Low"]);
});

test("a level on the running model goes through the session's effort", async () => {
  const calls = await openMenu();
  await click(tune().querySelector<HTMLElement>("[role=radio]")!);
  expect(calls.efforts).toEqual(["high"]);
  expect(calls.picks).toHaveLength(0);
});

test("Fast flips at once on the running model, before the session reports it", async () => {
  const calls = await openMenu();
  expect(fastSwitch().getAttribute("aria-checked")).toBe("false");
  await click(fastSwitch());
  expect(calls.fast).toEqual([true]);
  expect(fastSwitch().getAttribute("aria-checked")).toBe("true");
  expect(fastSwitch().querySelector("[data-on]")).not.toBeNull();
});

test("Fast on another model holds it with Fast and no level the person did not pick", async () => {
  const calls = await openMenu();
  await click(tab("Codex"));
  await click(fastSwitch());
  expect(fastSwitch().getAttribute("aria-checked")).toBe("true");
  await click(chip());
  expect(calls.picks).toHaveLength(1);
  expect(calls.picks[0]).toMatchObject({ id: "codex-Sol", fast: true });
  expect(calls.picks[0]!.effort).toBeUndefined();
});

test("the chat's tab with no row for the running model still shows the session's levels", async () => {
  await openMenu([{ ...claude, models: [], more: [] }, codex]);
  expect(levels()).toEqual([
    { name: "High", checked: false },
    { name: "Medium", checked: true },
    { name: "Low", checked: false },
  ]);
  expect(fastSwitch()).not.toBeNull();
});

test("the account card lists only the other accounts, then Add account…", async () => {
  const calls = await openMenu();
  await click(popup().querySelector<HTMLElement>(".acpmux-cols-profile")!);
  const card = popup().querySelector<HTMLElement>(".acpmux-cols-card")!;
  expect(card.querySelector(".acpmux-cols-card-name")?.textContent).toBe("Max");
  const names = [...card.querySelectorAll(".acpmux-cols-card-list [role=button] .acpmux-cols-name")].map(
    (node) => node.textContent,
  );
  expect(names).toEqual(["CLI login", "Work key", "Add account…"]);
  const add = [...card.querySelectorAll<HTMLElement>("[role=button]")].find(
    (node) => node.textContent === "Add account…",
  )!;
  await click(add);
  expect(document.querySelector('[role="dialog"].acpmux-add-account')).not.toBeNull();
  expect(calls.added).toHaveLength(0);
});

test("a harness this Mac does not have shows a blank avatar", async () => {
  await openMenu();
  await click(tab("Gemini"));
  const corner = popup().querySelector(".acpmux-cols-corner")!;
  expect(corner.querySelector("[data-blank]")).not.toBeNull();
  expect(corner.querySelector(".acpmux-cols-avatar-badge")).toBeNull();
});

test("Escape clears a search before it closes the menu", async () => {
  const calls = await openMenu();
  const input = popup().querySelector<HTMLInputElement>(".acpmux-cols-search input")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "sol");
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await settle();
  expect(rows().map((node) => node.querySelector(".acpmux-cols-name")?.textContent)).toEqual(["Sol"]);
  await act(async () => {
    input.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await settle();
  expect(input.value).toBe("");
  expect(calls.open).toBe(true);
  await act(async () => {
    input.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await settle();
  expect(calls.open).toBe(false);
});

test("a re-render never takes the keyboard back from a control outside the menu", async () => {
  const calls = await openMenu();
  const input = popup().querySelector<HTMLInputElement>(".acpmux-cols-search input")!;
  expect(document.activeElement).toBe(input);
  // Another chip's menu took the keyboard while this one is still open.
  const other = document.createElement("button");
  document.body.append(other);
  other.focus();
  await act(async () => root!.render(<Harness calls={calls} list={[claude, codex, gemini]} startEffort="medium" />));
  await settle();
  expect(document.activeElement).toBe(other);
  other.remove();
});

// The chat's readiness (#31689's contract): one row under the search, whatever tab or search shows.
const authRow = () => popup().querySelector<HTMLElement>(".acpmux-cols-auth");
const authActions = () => [...(authRow()?.querySelectorAll("button") ?? [])].map((button) => button.textContent);
async function search(text: string) {
  const input = popup().querySelector<HTMLInputElement>(".acpmux-cols-search input")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, text);
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await settle();
}
const local = { host: null, login: { kind: "terminal" as const, command: "claude /login", host: null } };
const SIGN_IN_AGAIN = translate("turn.signInAgain");
const CHECK_AGAIN = translate("harnesses.checkAgain");
const cases: { name: string; auth: SessionAuth; words: string; actions: string[] }[] = [
  {
    name: "an expired local login",
    auth: { state: "expired", source: "authCheck", evidenceAt: 1, harness: "Claude Code", ...local },
    words: translate("turn.authExpired"),
    actions: [SIGN_IN_AGAIN, CHECK_AGAIN],
  },
  {
    name: "a turn that found it signed out",
    auth: { state: "signedOut", source: "turn", evidenceAt: 1, harness: "Claude Code", ...local },
    words: translate("harness.signedOut", { agent: "Claude Code" }),
    actions: [SIGN_IN_AGAIN, CHECK_AGAIN],
  },
  {
    // The strongest false-ready case: a route login is no local terminal login.
    name: "a route that needs sign-in",
    auth: {
      state: "routeAuthNeeded",
      source: "routeProbe",
      evidenceAt: 1,
      host: null,
      login: { kind: "route", routeId: "team-route" },
    },
    words: "team-route",
    actions: [CHECK_AGAIN],
  },
  {
    name: "a signed-out harness on another machine",
    auth: {
      state: "signedOut",
      source: "peerLink",
      evidenceAt: 1,
      harness: "Claude Code",
      host: "studio-mac",
      login: { kind: "terminal", command: "claude /login", host: "studio-mac" },
    },
    words: "studio-mac: claude /login",
    actions: [CHECK_AGAIN],
  },
  {
    name: "an unreachable machine",
    auth: { state: "peerUnreachable", source: "peerLink", evidenceAt: 1, harness: "Claude Code", host: "studio-mac" },
    words: "studio-mac",
    actions: [CHECK_AGAIN],
  },
];
for (const { name, auth, words, actions } of cases)
  test(`${name}: the readiness row says why and offers its actions, also during a search`, async () => {
    const calls = await openMenu(undefined, undefined, auth);
    for (const query of ["", "sol"]) {
      if (query) await search(query);
      expect(authRow()?.textContent, `${name} with "${query}"`).toContain(words);
      expect(authRow()?.querySelector("span")?.textContent).toBe(authText(auth));
      expect(authActions()).toEqual(actions);
    }
    // Another harness's tab shows the chat's readiness still: it is the chat's, not the tab's.
    await search("");
    await click(tab("Codex"));
    expect(authRow()?.textContent).toContain(words);
    const check = [...authRow()!.querySelectorAll("button")].find((button) => button.textContent === CHECK_AGAIN)!;
    await click(check);
    expect(calls.refreshes).toBe(1);
    expect(calls.open).toBe(true);
    const signIn = [...authRow()!.querySelectorAll("button")].find((button) => button.textContent === SIGN_IN_AGAIN);
    if (signIn) {
      await click(signIn);
      expect(calls.logins).toBe(1);
      expect(calls.open).toBe(false);
    }
  });

test("an unknown verdict draws no readiness row, before or during a search", async () => {
  await openMenu(undefined, undefined, { state: "unknown", source: "none", evidenceAt: null });
  expect(authRow()).toBeNull();
  await search("sol");
  expect(authRow()).toBeNull();
});

test("a harness this Mac does not have keeps its Install row beside the chat's readiness", async () => {
  await openMenu(undefined, undefined, cases[0]!.auth);
  await click(tab("Gemini"));
  expect(authRow()?.textContent).toContain(translate("turn.authExpired"));
  expect(
    [...popup().querySelectorAll("[role=listbox] [role=button]")].some(
      (row) => row.textContent === translate("harnesses.install"),
    ),
  ).toBe(true);
});
