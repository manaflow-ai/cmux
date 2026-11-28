// l10n-allow-file: test fixtures.
// model-picker-clicks-only: the picker's saved picks are the person's (spec); what the backend lists or a
// session reports is status, and status never writes spec. Random interleavings of Runs On switches,
// reported level changes, backend option-list refreshes and session starts (This Mac and Cloud), with the
// person's model and level clicks among them, against the real New Tab and chat chips in JSDOM: the saved
// picks of each side move only on a click on that side (Leo 2026-11-28, ask-ae2ecfa8ef: "Backend option
// lists must not overwrite them.").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";
import { until } from "./support/until";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await forgetPicks();
  (await import("../src/agent-session/acpmux/cloudModePick")).clearCloudModePick();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.document.body.querySelectorAll(".ui-popup").forEach((node) => node.remove());
  dom.window.localStorage.clear();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type Summary = NonNullable<Snapshot["summary"]>;
type Call = { method: string; params: Record<string, unknown> };

const FOLDER = "/home/dev/local-cloud-state";

async function catalog(): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  return BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
}

/// A New Tab page on `harness` before its first send; `startsOnCloud`: Cloud is picked in Runs On.
async function newTab(startsOnCloud: boolean, harness: string): Promise<Snapshot> {
  return {
    type: "snapshot",
    protocolVersion: 1,
    origin: "local",
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: await catalog(),
    summary: { sessionId: "", harness, turnCount: 0, cwd: FOLDER } as Summary,
    ...(startsOnCloud ? { startsOnCloud: true } : {}),
  } as Snapshot;
}

const calls: Call[] = [];
async function render(snapshot: Snapshot, chat = false) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabComposerChips, ChatComposerChips } = await import("../src/agent-session/acpmux/App");
  (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    {
      get:
        (_target, method) =>
        async (params: Record<string, unknown> = {}) =>
          void calls.push({ method: String(method), params }),
    },
  );
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        {chat ? <ChatComposerChips snapshot={snapshot} /> : <NewTabComposerChips snapshot={snapshot} cwd={FOLDER} />}
      </QueryClientProvider>,
    ),
  );
  await settle();
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const chip = () => host.querySelector<HTMLElement>('[data-menu="Model"]')!;
const cols = () => doc().querySelector<HTMLElement>(".acpmux-cols");
const nameOf = (row: Element) => row.querySelector(".acpmux-cols-name")?.textContent ?? "";
const click = async (target: HTMLElement) => {
  await act(async () => target.click());
  await settle();
};

/// Nothing held, shown or remembered. Run against a base without Cloud's own state (the before run in
/// the PR), the base's own clear stands in, so each test fails on its behaviour, not on a missing helper.
async function forgetPicks() {
  const picks = (await import("../src/agent-session/acpmux/cloudAgentPick")) as Record<string, unknown>;
  const forget = (picks.forgetCloudAgentPicksForTests ?? picks.clearCloudAgentPick) as () => void;
  forget();
  const chips = (await import("../src/agent-session/acpmux/chipMemory")) as Record<string, unknown>;
  (chips.forgetLevelPicksForTests as (() => void) | undefined)?.();
}

const menuRows = () => [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-row[role="option"]')];
const levelRow = (name: string) =>
  [...(cols()?.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]') ?? [])].find(
    (row) => nameOf(row) === name,
  );

async function openMenu() {
  if (!cols()) await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
}

async function closeMenu() {
  if (!cols()) return;
  await act(async () => {
    cols()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await settle();
}

/// Picks `model` on the `tab` harness tab of the open menu.
async function pickModel(tab: string, model: string) {
  await openMenu();
  const rail = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')].find(
    (candidate) => candidate.getAttribute("aria-label") === tab,
  );
  expect(rail, `the ${tab} tab`).toBeDefined();
  await click(rail!);
  const row = menuRows().find((candidate) => nameOf(candidate) === model);
  expect(row, `the ${model} row`).toBeDefined();
  await click(row!);
}

async function pickLevel(level: string) {
  await openMenu();
  await until(
    () => levelRow(level) !== undefined,
    () => settle(),
  );
  await click(levelRow(level)!);
}

/// The chips gone and drawn again with `snapshot` (Runs On switched, the page shown again).
async function redraw(snapshot: Snapshot, chat = false) {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  doc()
    .body.querySelectorAll(".ui-popup")
    .forEach((node) => node.remove());
  await render(snapshot, chat);
}

type Side = "thisMac" | "cloud";
/// Run against a base without `levelPicked` (the before run in the PR), every kept level counts.
const chipMemory = (await import("../src/agent-session/acpmux/chipMemory")) as {
  levelPicked?: (harness: string, place: "local" | "cloud") => string | undefined;
};
/// A kept level's name ("Medium", "Extra High") as its option id ("medium", "xhigh").
const levelId = (name: string | undefined) => {
  const id = (name ?? "").toLowerCase().replace(/[^a-z]/g, "");
  return id === "extrahigh" ? "xhigh" : id;
};
/// One side's saved picks: its remembered pick, its kept levels, what it told the app to keep, and (This
/// Mac) what it sent acpmux.
function savedSide(side: Side): string {
  const levels = JSON.parse(dom.window.localStorage.getItem("cmux.acpmux.lastChips") ?? "{}") as Record<
    string,
    unknown
  >;
  // A kept level is written once the chat shows the level the person picked for it (ComposerPickers.tsx
  // keeps only `levelPicked`'s value), which can be a step after the click. A kept level that is the
  // person's own pick is theirs whenever it lands; any other is status writing spec.
  const ownLevels = Object.fromEntries(
    Object.entries(levels)
      .filter(([key]) => key.startsWith("cloud:") === (side === "cloud"))
      .filter(([key, chips]) => {
        const picked = chipMemory.levelPicked?.(key.replace(/^cloud:/, ""), side === "cloud" ? "cloud" : "local");
        return picked === undefined || levelId((chips as { effort?: string }).effort) !== picked;
      }),
  );
  const remembers = calls
    .filter((call) => call.method === "newTab.remember")
    .filter((call) => (call.params.place === "cloud") === (side === "cloud"))
    .map((call) => call.params);
  const pick = dom.window.localStorage.getItem(side === "cloud" ? "cmux.acpmux.cloudLastPick" : "cmux.acpmux.lastPick");
  // This Mac's saved defaults are acpmux's own: every chat.* call writes them (a pick in a local chat).
  const acpmux = side === "thisMac" ? calls.filter((call) => call.method.startsWith("chat.")) : [];
  return JSON.stringify({ pick, levels: ownLevels, remembers, acpmux });
}

/// A small seeded generator, so a failing sequence replays from its seed.
function generator(seed: number) {
  let state = seed >>> 0;
  return (n: number) => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (((t ^ (t >>> 14)) >>> 0) % n) | 0;
  };
}

const MODELS: [tab: string, row: string][] = [
  ["Claude Code", "Sonnet 5.5"],
  ["Claude Code", "Opus 5.5"],
  ["Codex", "GPT-6.1 Sol"],
];
const LEVELS = ["Low", "Medium", "High"];
const REPORTED: [harness: string, model: string][] = [
  ["claude", "claude-opus-5-5"],
  ["claude", "claude-sonnet-5-5"],
  ["codex", "gpt-6.1-sol"],
];
const VALUES = ["low", "medium", "high", "xhigh"];

type Step = { name: string; click?: Side; run: () => Promise<void> };

const totals = { clicks: 0, writes: 0 };
const SEEDS = Number(process.env.PICKER_PROPERTY_SEEDS ?? 12);
const LENGTH = 10;

for (let seed = 1; seed <= SEEDS; seed++) {
  test(`seed ${seed}: saved picks move only on the person's clicks, on the side clicked`, async () => {
    calls.length = 0;
    const roll = generator(seed);
    const local = await newTab(false, "claude");
    const localPage = {
      ...local,
      summary: { ...local.summary!, model: "claude-opus-5-5" } as Summary,
    };
    const cloudPage = { ...localPage, startsOnCloud: true } as Snapshot;
    let side: Side = roll(2) ? "cloud" : "thisMac";
    let onPage = true;
    const page = () => (side === "cloud" ? cloudPage : localPage);
    await render(page());
    /// The chat a session start opened on `side`, with what its backend reports.
    let chat: Summary | undefined;
    const drawChat = async (summary: Summary) => {
      chat = summary;
      onPage = false;
      await redraw(
        {
          ...page(),
          startsOnCloud: undefined,
          sessionId: summary.sessionId,
          summary,
        } as Snapshot,
        true,
      );
    };
    const toPage = async () => {
      if (onPage) return;
      onPage = true;
      chat = undefined;
      await redraw(page());
    };
    const options = (current: string, offered: string[]) => [
      {
        id: "reasoning_effort",
        name: "Effort",
        category: "thought_level",
        currentValue: current,
        options: offered.map((value) => ({ value })),
      },
    ];
    const steps: (() => Step)[] = [
      () => {
        const [tab, row] = MODELS[roll(MODELS.length)]!;
        return {
          name: `click ${row}`,
          click: side,
          run: async () => (await toPage(), await pickModel(tab, row), await closeMenu()),
        };
      },
      () => {
        const level = LEVELS[roll(LEVELS.length)]!;
        return {
          name: `click level ${level}`,
          click: side,
          run: async () => (await toPage(), await pickLevel(level), await closeMenu()),
        };
      },
      () => ({
        name: "switch Runs On",
        run: async () => {
          side = side === "cloud" ? "thisMac" : "cloud";
          onPage = true;
          chat = undefined;
          await redraw(page());
        },
      }),
      () => {
        const [harness, model] = REPORTED[roll(REPORTED.length)]!;
        return {
          name: `session starts on ${side} reporting ${model}`,
          run: async () => {
            if (side === "cloud") {
              const { cloudStartPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
              cloudStartPick({
                harness: "claude",
                model: "claude-opus-5-5",
                family: "claude",
              });
            }
            await drawChat({
              sessionId: `s-${seed}-${calls.length}`,
              harness,
              model,
              turnCount: 1,
              cwd: FOLDER,
              ...(side === "cloud" ? { hostKind: "cloud" } : {}),
            } as Summary);
          },
        };
      },
      () => {
        const offered = VALUES.filter(() => roll(2) === 1);
        const list = offered.length ? offered : ["medium"];
        const current = list[roll(list.length)]!;
        return {
          name: `option list refresh [${list.join(",")}] at ${current}`,
          run: async () => {
            if (!chat) return;
            await render(
              {
                ...page(),
                startsOnCloud: undefined,
                sessionId: chat.sessionId,
                summary: { ...chat, configOptions: options(current, list) },
              } as Snapshot,
              true,
            );
          },
        };
      },
      () => {
        const current = VALUES[roll(VALUES.length)]!;
        return {
          name: `reported level changes to ${current}`,
          run: async () => {
            if (!chat) return;
            chat = {
              ...chat,
              configOptions: options(current, VALUES),
            } as Summary;
            await render(
              {
                ...page(),
                startsOnCloud: undefined,
                sessionId: chat.sessionId,
                summary: chat,
              } as Snapshot,
              true,
            );
          },
        };
      },
    ];
    const trail: string[] = [];
    let clicks = 0;
    let clickWrites = 0;
    for (let index = 0; index < LENGTH; index++) {
      const step = steps[roll(steps.length)]!();
      trail.push(step.name);
      const before = {
        thisMac: savedSide("thisMac"),
        cloud: savedSide("cloud"),
      };
      await step.run();
      if (step.click) {
        clicks++;
        if (savedSide(step.click) !== before[step.click]) clickWrites++;
      }
      for (const kept of ["thisMac", "cloud"] as const) {
        if (step.click === kept) continue;
        expect(savedSide(kept), `seed ${seed}, ${kept} after: ${trail.join(" > ")}`).toBe(before[kept]);
      }
    }
    // The clicks are the writers: a run with clicks saved something (the check above is not vacuous).
    totals.clicks += clicks;
    totals.writes += clickWrites;
  });
}

// The clicks are the writers: across the runs, clicks saved picks, so the checks above are not vacuous.
test("the person's clicks do write saved picks", () => {
  expect(totals.clicks).toBeGreaterThan(0);
  expect(totals.writes).toBeGreaterThan(totals.clicks / 4);
});
