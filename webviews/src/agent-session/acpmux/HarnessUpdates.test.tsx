// Harness updates available (Leo 2026-11-12, ask-3fdf0982ec): the model menus list every outdated
// agent CLI on this Mac, not only the chat's own. The chat's own keeps its offer (Skip This Version,
// Restart Chat after); any other updates in place through `harness.update {id}`; Update all starts
// every row; a sudo update, a skipped version or a current CLI is not listed.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HarnessUpdatesSection } from "./HarnessUpdates";
import { type HarnessHealth, SKIPPED, type UpdateOffer } from "./harnessHealthNoticeModel";
import { outdatedHarnesses, useHarnessUpdateList } from "./harnessUpdateList";
import { agentDisplayName } from "./agents";
import { settleReact } from "../../../test/support/domTeardown";

const outdated = (id: string, version: string, latest: string, elevated = false): HarnessHealth => ({
  id,
  version,
  latest,
  outdated: true,
  update: { command: `npm install -g ${id}@latest`, elevated },
});
const codex = outdated("codex", "0.164.0", "0.167.2");
const opencode = outdated("opencode", "1.19.0", "1.19.5");

test("lists every outdated agent CLI but the chat's own, a sudo update and a skipped version", () => {
  const rows: unknown[] = [
    codex,
    opencode,
    outdated("claude", "2.1.30", "2.1.34"),
    outdated("gemini", "0.9.0", "0.10.0", true),
    outdated("amp", "1.0.0", "1.1.0"),
    { id: "pi", version: "1.0.0", latest: "1.0.0", outdated: false, update: { command: "x", elevated: false } },
    { id: "goose", version: null, latest: "2.0.0", outdated: true, update: { command: "x", elevated: false } },
    null,
  ];
  expect(outdatedHarnesses(rows, { amp: "1.1.0" }, "claude").map((row) => row.id)).toEqual(["codex", "opencode"]);
  // A skipped version holds only for that version.
  expect(outdatedHarnesses(rows, { amp: "1.0.5" }, "claude").map((row) => row.id)).toContain("amp");
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
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
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
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
});

/// One `harness.update` call: `{id}` (one row's Update) or `{ids}` (Update all, one call for every row).
type Call = { id: unknown; ids?: unknown; resolve: (value: unknown) => void };

function List(props: {
  rows: unknown[];
  offer?: UpdateOffer;
  native(method: string, params: Record<string, unknown>): Promise<unknown>;
  onUpdated(): void;
  closed(): void;
}) {
  const updates = useHarnessUpdateList({
    rows: props.rows,
    offer: props.offer,
    own: props.offer?.harness,
    nameFor: agentDisplayName,
    native: props.native,
    onUpdated: props.onUpdated,
  });
  return updates ? <HarnessUpdatesSection updates={updates} onOwnUpdate={props.closed} /> : null;
}

async function mount(rows: unknown[], offer?: UpdateOffer) {
  const container = installDom();
  const calls: Call[] = [];
  const log = { updated: 0, closed: 0 };
  const native = (method: string, params: Record<string, unknown>) =>
    new Promise<unknown>((resolve) => {
      expect(method).toBe("harness.update");
      calls.push({ id: params.id, ids: params.ids, resolve });
    });
  const draw = async (next: unknown[]) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <List rows={next} offer={offer} native={native} onUpdated={() => log.updated++} closed={() => log.closed++} />,
      );
    });
  await draw(rows);
  const names = () =>
    [...container.querySelectorAll("[data-harness-update]")].map((row) => row.getAttribute("data-harness-update"));
  const rowOf = (id: string) => container.querySelector<HTMLElement>(`[data-harness-update="${id}"]`);
  const click = (element: Element | null) => act(async () => (element as HTMLElement).click());
  return { container, calls, log, draw, names, rowOf, click };
}

test("the chat's own offer leads, then the others; each Update runs its own update", async () => {
  const ran: string[] = [];
  const offer: UpdateOffer = {
    harness: "claude",
    agent: "Claude Code",
    version: "2.1.30",
    latest: "2.1.34",
    update: () => ran.push("offer"),
    updateWith: () => ran.push("offer.with"),
    skip: () => ran.push("skip"),
  };
  // acpmux's rows include the chat's own; it is listed once, as the offer.
  const view = await mount([outdated("claude", "2.1.30", "2.1.34"), codex, opencode], offer);
  expect(view.names()).toEqual(["claude", "codex", "opencode"]);
  expect(view.container.textContent).toContain("Harness updates available");
  expect(view.rowOf("codex")!.textContent).toContain("Codex");
  expect(view.rowOf("codex")!.textContent).toContain("0.164.0 → 0.167.2");
  expect(view.container.textContent).toContain("New models often need the latest version.");
  // Skip This Version stays on the chat's own row only.
  expect(view.rowOf("claude")!.querySelector(".acpmux-harness-update-skip")).not.toBeNull();
  expect(view.rowOf("codex")!.querySelector(".acpmux-harness-update-skip")).toBeNull();

  await view.click(view.rowOf("claude")!.querySelector(".acpmux-harness-update-run"));
  expect(ran).toEqual(["offer"]);
  expect(view.log.closed).toBe(1);

  await view.click(view.rowOf("opencode")!.querySelector(".acpmux-harness-update-run"));
  expect(view.calls.map((call) => call.id)).toEqual(["opencode"]);
  expect(view.rowOf("opencode")!.getAttribute("data-phase")).toBe("updating");
  // Another agent's update keeps the menu open: its progress shows on its row.
  expect(view.log.closed).toBe(1);
  await act(async () => view.calls[0]!.resolve({ ok: true, version: "1.19.5" }));
  expect(view.log.updated).toBe(1);
  expect(view.names()).toEqual(["claude", "codex"]);
});

test("Update all is one host call for every row, the chat's own too; each row takes its own answer", async () => {
  // The host spends the person's click on its first `harness.update` (AgentPaneHarnessCard), so
  // one call per row would update only the first agent.
  const own: Promise<unknown>[] = [];
  const offer: UpdateOffer = {
    harness: "claude",
    agent: "Claude Code",
    version: "2.1.30",
    latest: "2.1.34",
    update: () => {
      throw new Error("Update all must not ask the host again for the chat's own agent");
    },
    updateWith: (reply) => own.push(reply),
    skip: () => undefined,
  };
  const view = await mount([codex, opencode], offer);
  await view.click(view.container.querySelector(".acpmux-harness-updates-all"));
  expect(view.calls.map((call) => call.ids)).toEqual([["claude", "codex", "opencode"]]);
  expect(view.log.closed).toBe(1);
  expect(own).toHaveLength(1);
  await act(async () =>
    view.calls[0]!.resolve({
      results: [
        { id: "claude", ok: true, version: "2.1.34" },
        { id: "codex", ok: false, error: "npm error code EACCES" },
        { id: "opencode", ok: true, version: "1.19.5" },
      ],
    }),
  );
  // The chat's own answer goes to its offer (the composer's notice then offers Restart Chat).
  expect(await own[0]).toEqual({ id: "claude", ok: true, version: "2.1.34" });
  expect(view.names()).toEqual(["claude", "codex"]);
  const failed = view.rowOf("codex")!;
  expect(failed.getAttribute("data-phase")).toBe("failed");
  expect(failed.textContent).toContain("Try Again");
  expect(failed.querySelector("[title]")?.getAttribute("title")).toBe("npm error code EACCES");
  expect(view.log.updated).toBe(1);
  await view.click(failed.querySelector(".acpmux-harness-update-run"));
  expect(view.calls.map((call) => call.id)).toEqual([undefined, "codex"]);
});

test("one outdated agent has no Update all; a version skipped in this profile is not listed", async () => {
  const view = await mount([codex]);
  expect(view.container.querySelector(".acpmux-harness-updates-all")).toBeNull();
  localStorage.setItem(SKIPPED, JSON.stringify({ codex: "0.167.2" }));
  await view.draw([codex, opencode]);
  expect(view.names()).toEqual(["opencode"]);
});
