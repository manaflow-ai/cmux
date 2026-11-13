// The model button's menu as columns (QuickModelColumns.tsx): the rail, the models and the shown
// model's settings, with the account avatar in the search row's corner.
import { afterEach, expect, test } from "bun:test";
import React, { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { ChatAccounts, NewChatAccount } from "./chatAccounts";
import type { QuickFamily, QuickModel } from "./quickModelMenuModel";
import { authText, type SessionAuth } from "./sessionAuth";
import { translate } from "./i18n";
import { settleReact } from "../../../test/support/domTeardown";
import { modelMenuHeight, setModelMenuHeight } from "./modelMenuWidth";

let QuickModelColumns: typeof import("./QuickModelColumns").QuickModelColumns;

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
/// A test's own layout for the next installDom: jsdom lays nothing out, so a test of the menu's measured
/// size fakes the boxes and the text widths it reads.
let fakeLayout: ((window: JSDOM["window"]) => void) | undefined;

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
  fakeLayout?.(dom.window);
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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  fakeLayout = undefined;
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
          // A trailing level word names the level a match lands with, as the real search's does ("sol high").
          find: (query) => {
            const words = query.split(" ");
            const named = ["low", "medium", "high"].includes(words.at(-1) ?? "") ? words.pop() : undefined;
            const text = words.join(" ");
            return list.flatMap((family) =>
              [...family.models, ...family.more]
                .filter((row) => row.name.toLowerCase().includes(text))
                .map((row) => (named ? { ...row, effort: named } : row)),
            );
          },
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

test("the running model shows its session levels, lowest first, with the current one checked", async () => {
  await openMenu();
  expect(row("Opus").hasAttribute("data-hl")).toBe(true);
  expect(levels()).toEqual([
    { name: "Low", checked: false },
    { name: "Medium", checked: true },
    { name: "High", checked: false },
  ]);
});

test("a model with no levels says None under Reasoning", async () => {
  await openMenu();
  await press("ArrowDown");
  expect(row("Haiku").hasAttribute("data-hl")).toBe(true);
  expect(popup().querySelector(".acpmux-cols-tune-head")?.textContent).toBe("Reasoning");
  expect(tune().querySelector(".acpmux-cols-note")?.textContent).toBe("None");
});

test("the models column is one plain list, Legacy models last, and Reasoning heads a column beside the search row", async () => {
  await openMenu();
  const list = popup().querySelector<HTMLElement>("[role=listbox]")!;
  // No caption names the tab ("Claude Code") or its Legacy models (standup 2026-11-12).
  expect(list.querySelector(".acpmux-cols-caption")).toBeNull();
  expect(rows().at(-1)?.querySelector(".acpmux-cols-name")?.textContent).toBe("Old");
  // The effort column runs up to the search row: both are the body's own, the models are not.
  const body = popup().querySelector<HTMLElement>(".acpmux-cols-body")!;
  expect(body.querySelector(":scope > .acpmux-cols-search")).not.toBeNull();
  expect(body.querySelector(":scope > .acpmux-cols-tune")).toBe(tune());
  expect(list.parentElement?.classList.contains("acpmux-cols-lists")).toBe(true);
  // Reasoning heads the column from the search row, so the line under that row runs on under it.
  const head = body.querySelector<HTMLElement>(":scope > .acpmux-cols-tune-head")!;
  expect(head.textContent).toBe("Reasoning");
  expect(head.nextElementSibling).toBe(tune());
  // The levels scroll on their own; Fast stays fixed under them, at the column's bottom.
  expect(tune().querySelector("[role=radio]")?.closest(".acpmux-cols-tune-scroll")).not.toBeNull();
  expect(fastSwitch().closest(".acpmux-cols-tune-foot")).not.toBeNull();
  expect(fastSwitch().closest(".acpmux-cols-tune-scroll")).toBeNull();
});

test("a kept height sizes the menu, and a double-click on the edge away from the chip goes back", async () => {
  setModelMenuHeight(300);
  try {
    await openMenu();
    const frame = popup().querySelector<HTMLElement>(".acpmux-cols-frame")!;
    expect(frame.style.height).toContain("300px");
    // The height grip sits on the edge away from the chip: the top or the bottom one.
    const grip = popup().querySelector<HTMLElement>(".acpmux-cols-resize-y")!;
    expect(["top", "bottom"]).toContain(grip.dataset.edge!);
    await act(async () => {
      grip.dispatchEvent(new dom!.window.MouseEvent("dblclick", { bubbles: true }));
    });
    await settle();
    expect(modelMenuHeight()).toBeUndefined();
    expect(frame.style.height).toBe("");
  } finally {
    setModelMenuHeight(undefined);
  }
});

// The fake layout: each level row 28 px tall, the search row (and the Reasoning heading in it) 41 px,
// a provider caption 22 px, the Fast footer 37 px, the scrolling part 4 px padding above and below, a
// 1 px line on the column's top; each character 7 px wide. Nothing else is drawn outside the columns.
const ROW = 28;
const HEAD = 41;
const FOOT = 37;
const PAD = 4;
const LINE = 1;
const CHAR = 7;
function installFakeLayout(window: JSDOM["window"]) {
  const style = window.document.createElement("style");
  style.textContent = `
    .acpmux-cols-tune-scroll { padding: ${PAD}px; }
    .acpmux-cols-tune { border-top: ${LINE}px solid black; }
    .acpmux-cols-row { padding: 0 8px; }
    .acpmux-cols-tune-head { padding: 0 12px; }
    .acpmux-cols { font-size: 13px; }
    .acpmux-cols-lists { grid-template-columns: 48px 200px; }
    .acpmux-cols-body { grid-template-columns: 250px 120px; }
  `;
  window.document.head.append(style);
  const box = (height: number, width: number) => ({
    x: 0,
    y: 0,
    top: 0,
    left: 0,
    bottom: height,
    right: width,
    width,
    height,
    toJSON() {},
  });
  const proto = window.HTMLElement.prototype;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const has = (name: string) => this.classList.contains(name);
    if (has("acpmux-cols-tune-head")) return box(HEAD, 120) as DOMRect;
    if (has("acpmux-cols-tune-foot")) return box(FOOT, 120) as DOMRect;
    if (has("acpmux-cols-caption")) return box(22, 120) as DOMRect;
    if (has("acpmux-cols-row")) return box(ROW, 100) as DOMRect;
    if (has("acpmux-cols-check")) return box(14, 14) as DOMRect;
    if (has("acpmux-cols-switch")) return box(16, 28) as DOMRect;
    if (has("acpmux-cols-tune")) return box(300, 120) as DOMRect;
    if (has("acpmux-cols-list")) return box(300, 200) as DOMRect;
    if (has("acpmux-cols-frame") || has("acpmux-cols-body")) return box(400, 400) as DOMRect;
    return box(0, 0) as DOMRect;
  };
  Object.defineProperty(proto, "clientWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("acpmux-cols-row") ? 100 : 0;
    },
  });
  window.HTMLCanvasElement.prototype.getContext = (() => ({
    font: "",
    measureText: (text: string) => ({ width: text.length * CHAR }),
  })) as unknown as HTMLCanvasElement["getContext"];
}

test("the default height is one fixed height: six levels and Fast, whatever model or tab shows", async () => {
  // Lucas 2026-11-12: "a default fixed height", never one that follows the model. The chat runs Opus
  // (three levels); a seven-level model elsewhere and a model routed through eight providers change
  // nothing.
  const wide = model("codex", "Wide", { efforts: ["none", "minimal", "low", "medium", "high", "xhigh", "max"] });
  const routes = ["Anthropic", "Bedrock", "Vertex", "OpenRouter", "Azure", "Groq", "Together", "Fireworks"];
  const routed = model("claude", "Routed", {
    efforts: ["low", "high"],
    offers: routes.map((provider) => ({ ...model("claude", `Routed-${provider}`), provider })),
  });
  fakeLayout = installFakeLayout;
  await openMenu([
    { ...claude, models: [...claude.models, routed] },
    { ...codex, models: [...codex.models, wide] },
    gemini,
  ]);
  const frame = popup().querySelector<HTMLElement>(".acpmux-cols-frame")!;
  const fixed = HEAD + LINE + 2 * PAD + 6 * ROW + FOOT;
  expect(Number(frame.dataset.fitHeight)).toBe(fixed);
  await click(tab("Codex"));
  await click(row("Wide"));
  expect(Number(frame.dataset.fitHeight)).toBe(fixed);
});

test("the same default height in a chat on a model with no levels and no Fast", async () => {
  const bare = { ...claude, models: [model("claude", "Haiku", { efforts: [] })], more: [] };
  fakeLayout = installFakeLayout;
  await openMenu([bare, gemini]);
  const frame = popup().querySelector<HTMLElement>(".acpmux-cols-frame")!;
  expect(Number(frame.dataset.fitHeight)).toBe(HEAD + LINE + 2 * PAD + 6 * ROW + FOOT);
});

test("by default the Reasoning column is as wide as its widest row, Extra High whole with its check", async () => {
  const opus = model("claude", "Opus", { efforts: ["low", "medium", "high", "xhigh", "max"], canFast: true });
  fakeLayout = installFakeLayout;
  await openMenu([{ ...claude, ultracode: true, models: [opus, ...claude.models.slice(1)] }, codex, gemini]);
  const body = popup().querySelector<HTMLElement>(".acpmux-cols-body")!;
  const fit = Number(body.dataset.tuneFit);
  // The room around a row's text: the column's 120 px less the row's 100 px content box, plus its padding.
  const row = popup().querySelector<HTMLElement>(".acpmux-cols-tune .acpmux-cols-row")!;
  const rowStyle = getComputedStyle(row);
  const padding = 120 - (100 - Number.parseFloat(rowStyle.paddingLeft) - Number.parseFloat(rowStyle.paddingRight));
  const gap = Number.parseFloat(rowStyle.columnGap) || 0;
  const extraHigh = "Extra High".length * CHAR + gap + 14 + padding;
  expect(fit).toBe(Math.ceil(extraHigh + 2));
  // Wider than the Reasoning heading, Ultracode and Fast with its switch.
  expect(fit).toBeGreaterThan("Reasoning".length * CHAR + 24);
  expect(fit).toBeGreaterThan("Ultracode".length * CHAR + gap + 14 + padding);
  expect(fit).toBeGreaterThan("Fast".length * CHAR + gap + 28 + padding);
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
    { name: "Low", checked: true },
    { name: "High", checked: false },
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

test("a Claude Code model shown but not picked lists Ultracode, and its pick lands it", async () => {
  // Lucas 2026-11-11: Ultracode showed only once the model was picked. Its harness offers it on every
  // model that runs Extra High (QuickFamily.ultracode), so a highlighted model lists it too.
  const sonnet = model("claude", "Sonnet", { efforts: ["low", "high", "xhigh"], defaultEffort: "high" });
  const nova = model("codex", "Nova", { efforts: ["low", "high", "xhigh"], defaultEffort: "low" });
  const calls = await openMenu(
    [
      { ...claude, ultracode: true, models: [...claude.models, sonnet] },
      { ...codex, models: [...codex.models, nova] },
      gemini,
    ],
    "medium",
  );
  await press("ArrowDown");
  await press("ArrowDown");
  expect(row("Sonnet").hasAttribute("data-hl")).toBe(true);
  expect(calls.picks).toEqual([]);
  expect(levels().map((level) => level.name)).toEqual(["Low", "High", "Extra High", "Ultracode"]);
  const ultracode = [...tune().querySelectorAll<HTMLElement>("[role=radio]")].find(
    (node) => node.textContent === "Ultracode",
  )!;
  await click(ultracode);
  expect(calls.picks.at(-1)).toMatchObject({ id: "claude-Sonnet", effort: "ultracode" });
  // A harness that does not offer it lists none, Extra High or not.
  await click(tab("Codex"));
  await press("ArrowDown");
  await press("ArrowDown");
  expect(row("Nova").hasAttribute("data-hl")).toBe(true);
  expect(levels().map((level) => level.name)).not.toContain("Ultracode");
});

test("another model, then a level, then Fast each land at once, the level kept with Fast", async () => {
  const calls = await openMenu();
  await click(tab("Codex"));
  await click(row("Sol"));
  const high = [...tune().querySelectorAll<HTMLElement>("[role=radio]")].find((node) => node.textContent === "High")!;
  await click(high);
  await click(fastSwitch());
  expect(levels()).toEqual([
    { name: "Low", checked: false },
    { name: "High", checked: true },
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
  expect(levels().map((level) => level.name)).toEqual(["Low", "High"]);
});

test("a level on the running model goes through the session's effort", async () => {
  const calls = await openMenu();
  await click([...tune().querySelectorAll<HTMLElement>("[role=radio]")].find((node) => node.textContent === "High")!);
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
    { name: "Low", checked: false },
    { name: "Medium", checked: true },
    { name: "High", checked: false },
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

test("a level picked by hand under a search does not outlast the menu: the same search reopened shows its own level", async () => {
  const calls = await openMenu();
  const search = async (text: string) => {
    const input = popup().querySelector<HTMLInputElement>(".acpmux-cols-search input")!;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
      setter.call(input, text);
      input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    await settle();
  };
  const checked = () => levels().find((level) => level.checked)?.name;
  await search("sol high");
  expect(checked()).toBe("High");
  const low = [...tune().querySelectorAll<HTMLElement>("[role=radio]")].find((node) => node.textContent === "Low")!;
  await click(low);
  expect(checked()).toBe("Low");
  // Escape clears the search, then closes the menu; the chip opens it again.
  await press("Escape");
  await press("Escape");
  expect(calls.open).toBe(false);
  await act(async () => document.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  await search("sol high");
  expect(checked()).toBe("High");
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
