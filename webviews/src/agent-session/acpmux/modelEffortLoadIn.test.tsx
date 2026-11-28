// New Tab must keep the same model and both effort labels while its session attaches.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import { ComposerPickers } from "./ComposerPickers";
import { resetStartModesForTests } from "./startMode";
import { rememberLastChips } from "./chipMemory";
import { harnessProfiles } from "./harnessProfiles";
import { seedLastPicks } from "./lastPick";
import { newTabStart } from "./newtab/chipDefaults";
import { emptySnapshot } from "./snapshotCache";
import { settleReact } from "../../../test/support/domTeardown";

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
  "Element",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
  "MutationObserver",
  "ResizeObserver",
] as const;

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  resetStartModesForTests();
  return dom.window.document.getElementById("root")!;
}

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
  resetStartModesForTests();
});

const FOLDER = "/Users/test/project";
const MODEL = "claude-opus-5-5";
const options = (value: string) => [
  {
    id: "effort",
    name: "Effort",
    category: "thought_level",
    currentValue: value,
    options: ["low", "medium", "high", "xhigh", "max"].map((value) => ({ value })),
  },
];
function snapshot(sessionId: string, effort?: string, harness = "claude"): AcpmuxSnapshot {
  return {
    ...emptySnapshot(),
    origin: "local",
    ...(sessionId ? { sessionId } : {}),
    catalog: [
      {
        id: harness,
        name: "Claude Code",
        family: "claude",
        models: [{ id: MODEL, name: "Opus 5.5" }],
        start: { model: MODEL, modelSource: "saved", effort: "medium", effortSource: "saved" },
      },
    ],
    summary: {
      sessionId,
      harness,
      family: "claude",
      model: MODEL,
      cwd: FOLDER,
      turnCount: 0,
      ...(effort ? { configOptions: options(effort) } : sessionId ? { pendingEffort: "medium" } : {}),
    },
  } as AcpmuxSnapshot;
}
type Face = { model: string; effort: string; compact: string };
async function frames(makeSnapshots: () => AcpmuxSnapshot[], rememberedEffort = "medium"): Promise<Face[]> {
  const container = installDom();
  seedLastPicks({ global: { harness: "claude", model: MODEL }, folders: [] });
  rememberLastChips("claude", { effort: rememberedEffort === "high" ? "High" : "Medium" });
  harnessProfiles.observe(snapshot("previous", rememberedEffort).summary);
  root = createRoot(container);
  const result: Face[] = [];
  for (const snapshot of makeSnapshots()) {
    await act(async () =>
      root!.render(
        <ComposerPickers
          snapshot={snapshot}
          harnessesListed={snapshot.catalog.length > 0}
          onModel={() => undefined}
          onMode={() => undefined}
          onEffort={() => undefined}
          showPlan
        />,
      ),
    );
    result.push({
      model: container.querySelector(".acpmux-model-name")?.textContent?.trim() ?? "",
      effort: container.querySelector('.acpmux-model-detail[data-fit-forms^="full"]')?.textContent?.trim() ?? "",
      compact:
        container.querySelector('.acpmux-model-detail[data-fit-forms="short"]')?.getAttribute("data-label") ?? "",
    });
  }
  return result;
}
const MEDIUM: Face = { model: "Opus 5.5", effort: "Medium", compact: "Med" };
test("cached last-used model and effort survive cold catalog, attach and reported options", async () => {
  expect(
    await frames(() => [
      newTabStart(emptySnapshot(), [], "claude", FOLDER).snapshot,
      snapshot(""),
      snapshot("attached"),
      snapshot("attached", "medium"),
    ]),
  ).toEqual([MEDIUM, MEDIUM, MEDIUM, MEDIUM]);
});
test("an older opened chat shows its listed effort instead of the previous chat cache", async () => {
  expect(
    await frames(() => [
      {
        ...emptySnapshot(),
        sessionId: "old",
        origin: "local",
        catalog: snapshot("").catalog,
        sessions: [{ sessionId: "old", harness: "claude", model: MODEL, effort: "high", unsent: false }],
      } as AcpmuxSnapshot,
    ]),
  ).toEqual([{ model: "Opus 5.5", effort: "High", compact: "" }]);
});
test("a session reporting options without effort stops showing the cached effort", async () => {
  const result = await frames(() => {
    const settled = snapshot("attached");
    settled.summary = {
      ...settled.summary!,
      pendingEffort: undefined,
      configOptions: [
        {
          id: "model",
          name: "Model",
          category: "model",
          currentValue: MODEL,
          options: [{ value: MODEL, name: "Opus 5.5" }],
        },
      ],
    };
    return [snapshot(""), settled];
  });
  expect(result[0]).toEqual(MEDIUM);
  expect(result[1]).toEqual({ model: "Opus 5.5", effort: "", compact: "" });
});
test("a peer session never borrows this Mac's remembered effort", async () => {
  const result = await frames(() => [
    {
      ...snapshot("peer-attached"),
      origin: "peer",
      summary: { ...snapshot("peer-attached").summary!, pendingEffort: undefined },
    },
  ]);
  expect(result[0]?.effort).toBe("");
});

test("a nondefault last-used effort is present before the catalog replies", async () => {
  const result = await frames(() => {
    const confirmed = snapshot("attached", "high");
    confirmed.catalog[0]!.start!.effort = "high";
    const attached = {
      ...confirmed,
      summary: { ...confirmed.summary!, configOptions: undefined, pendingEffort: "high" },
    };
    return [newTabStart(emptySnapshot(), [], "claude", FOLDER).snapshot, attached, confirmed];
  }, "high");
  expect(result).toEqual(Array(3).fill({ model: "Opus 5.5", effort: "High", compact: "" }));
});
test("an explicit harness switch uses the target start effort, not the previous harness cache", async () => {
  const result = await frames(() => {
    const target = snapshot("", undefined, "claude-target");
    target.catalog[0]!.start!.effort = "high";
    const settled = snapshot("target-session", "high", "claude-target");
    return [
      snapshot(""),
      { ...target, switching: { phase: "starting", harness: "claude-target", name: "Claude target" } },
      settled,
    ];
  });
  expect(result[0]).toEqual(MEDIUM);
  expect(result.slice(1).map((face) => face.effort)).toEqual(["High", "High"]);
});

test("a peer uses its owning daemon's pending effort instead of this viewer's cache", async () => {
  const result = await frames(() => [
    {
      ...snapshot("peer-attached"),
      origin: "peer",
      summary: { ...snapshot("peer-attached").summary!, pendingEffort: "high" },
    },
  ]);
  expect(result[0]).toEqual({ model: "Opus 5.5", effort: "High", compact: "" });
});
