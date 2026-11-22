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
  offered?: (id: string) => boolean;
}) {
  const updates = useHarnessUpdateList({
    rows: props.rows,
    offer: props.offer,
    own: props.offer?.harness,
    nameFor: agentDisplayName,
    ...(props.offered ? { offered: props.offered } : {}),
    native: props.native,
    onUpdated: props.onUpdated,
  });
  return updates ? <HarnessUpdatesSection updates={updates} onOwnUpdate={props.closed} /> : null;
}

async function mount(rows: unknown[], offer?: UpdateOffer, offered?: (id: string) => boolean) {
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
        <List
          rows={next}
          offer={offer}
          native={native}
          onUpdated={() => log.updated++}
          closed={() => log.closed++}
          {...(offered ? { offered } : {})}
        />,
      );
    });
  await draw(rows);
  const names = () =>
    [...container.querySelectorAll("[data-harness-update]")].map((row) => row.getAttribute("data-harness-update"));
  const rowOf = (id: string) => container.querySelector<HTMLElement>(`[data-harness-update="${id}"]`);
  const click = (element: Element | null) => act(async () => (element as HTMLElement).click());
  return { container, calls, log, draw, names, rowOf, click };
}

/// Presses or releases Option, as WebKit reports it: a keydown or keyup of "Alt" with `altKey` set.
const holdOption = (down: boolean) =>
  act(async () => {
    window.dispatchEvent(new window.KeyboardEvent(down ? "keydown" : "keyup", { key: "Alt", altKey: down }));
  });

// David Beyer (Nov 20 call): the updates menu is messy. A row is the agent's mark, its name and
// Update; the versions and Skip This Version show only when the person asks, by holding Option (the
// Mac menus' way to show more), and go again when Option is let go.
test("versions and Skip This Version show only while Option is held", async () => {
  const offer: UpdateOffer = {
    harness: "claude",
    agent: "Claude Code",
    version: "2.1.30",
    latest: "2.1.34",
    update: () => undefined,
    updateWith: () => undefined,
    skip: () => undefined,
  };
  const view = await mount([codex, opencode], offer);
  const text = () => view.container.textContent ?? "";
  expect(text()).not.toContain("0.164.0");
  expect(text()).not.toContain("0.167.2");
  expect(text()).not.toContain("2.1.34");
  expect(text()).not.toContain("→");
  expect(text()).not.toContain("Skip This Version");
  expect(view.container.querySelector(".acpmux-harness-update-versions")).toBeNull();
  // Each row is its name and its Update, nothing else.
  expect(view.rowOf("codex")!.textContent).toBe("CodexUpdate");

  await holdOption(true);
  expect(view.rowOf("codex")!.textContent).toContain("0.164.0 → 0.167.2");
  expect(view.rowOf("claude")!.textContent).toContain("2.1.30 → 2.1.34");
  expect(view.rowOf("claude")!.querySelector(".acpmux-harness-update-skip")?.textContent).toBe("Skip This Version");

  await holdOption(false);
  expect(text()).not.toContain("0.164.0");
  expect(text()).not.toContain("Skip This Version");

  // Option held as the pointer moves in (Option-click to open the menu) shows them too.
  await act(async () => {
    window.dispatchEvent(new window.MouseEvent("pointermove", { altKey: true }));
  });
  expect(view.rowOf("codex")!.textContent).toContain("0.164.0 → 0.167.2");
  // Leaving the window lets go of it.
  await act(async () => {
    window.dispatchEvent(new window.Event("blur"));
  });
  expect(text()).not.toContain("0.164.0");
});

// Lawrence 2026-11-21: "maybe update all should be more prominent since that's the action most
// people will take". Update all is the footer's one default button, drawn in the accent; each row's
// Update is a quiet secondary. With one row, that row's Update is the default.
test("Update all is the one default button; with one row, its Update is", async () => {
  const view = await mount([codex, opencode]);
  const defaults = () => [...view.container.querySelectorAll("[data-default]")];
  expect(defaults()).toHaveLength(1);
  expect(defaults()[0]!.textContent).toBe("Update all");
  expect(defaults()[0]!.classList.contains("acpmux-harness-updates-all")).toBe(true);
  for (const id of ["codex", "opencode"])
    expect(view.rowOf(id)!.querySelector(".acpmux-harness-update-run")!.hasAttribute("data-default")).toBe(false);

  await view.draw([codex]);
  expect(defaults()).toHaveLength(1);
  expect(defaults()[0]!.closest("[data-harness-update]")?.getAttribute("data-harness-update")).toBe("codex");
  expect(defaults()[0]!.textContent).toBe("Update");
});

// a1315 (UI simplification lead, Lawrence: "drastically simplify all parts of the UI"): with one
// outdated agent there is no heading (its Update is the whole footer); a row's Update shows on hover
// or focus only, beside a filled Update all; a failed row is one red line, its mark's space empty.
test("one outdated agent is one row, no heading; row Updates wait for hover beside Update all", async () => {
  const view = await mount([codex]);
  expect(view.container.querySelector(".acpmux-harness-updates-head")).toBeNull();
  expect(view.container.textContent).toBe("CodexUpdate");
  // The section still says what it is to assistive tech; no tooltip covers the row on hover.
  const section = view.container.querySelector("section")!;
  expect(section.getAttribute("aria-label")).toBe("Harness updates available");
  expect(section.hasAttribute("title")).toBe(false);
  // The lone row's Update is always shown: it is the default.
  expect(view.rowOf("codex")!.querySelector(".acpmux-harness-update-run")!.hasAttribute("data-reveal")).toBe(false);

  await view.draw([codex, opencode]);
  expect(view.container.querySelector(".acpmux-harness-updates-head")?.textContent).toBe(
    "Harness updates availableUpdate all",
  );
  for (const id of ["codex", "opencode"])
    expect(view.rowOf(id)!.querySelector(".acpmux-harness-update-run")!.hasAttribute("data-reveal")).toBe(true);
});

test("a failed row is one red line: no mark, its Try Again on hover", async () => {
  const view = await mount([codex, opencode]);
  await view.click(view.rowOf("codex")!.querySelector(".acpmux-harness-update-run"));
  await act(async () => view.calls[0]!.resolve({ ok: false, error: "npm error code EACCES" }));
  const failed = view.rowOf("codex")!;
  expect(failed.getAttribute("data-phase")).toBe("failed");
  expect(failed.querySelector("svg")).toBeNull();
  expect(failed.querySelector(".agent-mark-empty")).not.toBeNull();
  expect(failed.textContent).toBe("Couldn't update Codex.Try Again");
  expect(failed.querySelector(".acpmux-harness-update-run")!.hasAttribute("data-reveal")).toBe(true);
});

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
  // The reason is the heading's tooltip, not a line of its own (Lawrence 2026-11-21: simpler).
  expect(view.container.textContent).not.toContain("New models often need the latest version.");
  expect(view.container.querySelector(".acpmux-harness-updates-title")?.getAttribute("title")).toBe(
    "New models often need the latest version.",
  );
  // Skip This Version is the chat's own row's, and shows with the versions (Option held).
  await holdOption(true);
  expect(view.rowOf("claude")!.querySelector(".acpmux-harness-update-skip")).not.toBeNull();
  expect(view.rowOf("codex")!.querySelector(".acpmux-harness-update-skip")).toBeNull();
  await holdOption(false);

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
  // The failure takes the name's place, so the row never says "Codex" twice.
  expect(failed.textContent).toBe("Couldn't update Codex.Try Again");
  // The row says it plainly; the updater's words go to the log, not a hover title.
  expect(failed.outerHTML).not.toContain("EACCES");
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

// Lawrence 2026-11-19 (clip "CleanShot 2026-11-19 at 3.37.01 PM"): "OpenCode" twice. `opencode` and
// `opencode-v2` are two installs of one brand: the second is named as the rail names it, "OpenCode (v2)".
test("a harness the menus do not offer is not listed, and two rows never share a name", async () => {
  const view = await mount(
    [outdated("acme", "1.0.0", "1.1.0"), opencode, outdated("opencode-v2", "1.18.0", "1.19.6"), codex],
    undefined,
    (id) => id !== "acme",
  );
  expect(view.names()).toEqual(["opencode", "opencode-v2", "codex"]);
  const label = (id: string) => view.rowOf(id)!.querySelector(".acpmux-harness-update-name")?.textContent;
  expect(label("opencode")).toBe("OpenCode");
  expect(label("opencode-v2")).toBe("OpenCode (v2)");
  expect(label("codex")).toBe("Codex");
});

// Lawrence 2026-11-19 (msg 42278, "there are duplicates sometimes"): "Claude Code 2.1.325 → 2.1.329"
// and "Cmux 2.1.325 → 2.1.329" with Claude's mark. acpmux reports health per harness profile, and its
// `cmux` profile (the router fallback) runs the same ~/.local/bin/claude as `claude`. "Sometimes":
// the menus hid `cmux` only once the catalog said it is not pickable, so a menu opened before the
// catalog arrived (or a catalog without the row) listed it. The list is one row per installed
// binary, whatever the catalog says, named for the agent the binary is.
const claudeAt = (id: string, version = "2.1.325"): HarnessHealth => ({
  ...outdated(id, version, "2.1.329"),
  path: "/Users/me/.local/bin/claude",
  package: "@anthropic-ai/claude-code",
  update: { command: "/Users/me/.local/bin/claude update", elevated: false },
});

test("two profiles that run one binary are one row, named for that binary, before the catalog says either", async () => {
  const view = await mount([claudeAt("cmux"), claudeAt("claude"), codex]);
  expect(view.names()).toEqual(["claude", "codex"]);
  expect(view.rowOf("claude")!.querySelector(".acpmux-harness-update-name")?.textContent).toBe("Claude Code");
  await view.draw([claudeAt("claude"), claudeAt("cmux"), codex]);
  expect(view.names()).toEqual(["claude", "codex"]);
  // Update all updates that binary once.
  await view.click(view.container.querySelector(".acpmux-harness-updates-all"));
  expect(view.calls.map((call) => call.ids)).toEqual([["claude", "codex"]]);
});

test("a profile that wraps another agent's binary is never named by its profile id", async () => {
  const view = await mount([claudeAt("cmux"), codex]);
  expect(view.rowOf("cmux")!.querySelector(".acpmux-harness-update-name")?.textContent).toBe("Claude Code");
  expect(view.container.textContent).not.toContain("Cmux");
});

test("the chat's own offer covers every profile of its binary", async () => {
  const offer: UpdateOffer = {
    harness: "claude",
    agent: "Claude Code",
    version: "2.1.325",
    latest: "2.1.329",
    update: () => undefined,
    updateWith: () => undefined,
    skip: () => undefined,
  };
  const view = await mount([claudeAt("claude"), claudeAt("cmux"), codex], offer);
  expect(view.names()).toEqual(["claude", "codex"]);
});

test("a version skipped for one profile of a binary holds for all of them", async () => {
  const view = await mount([claudeAt("claude"), claudeAt("cmux"), codex]);
  localStorage.setItem(SKIPPED, JSON.stringify({ claude: "2.1.329" }));
  await view.draw([claudeAt("cmux"), claudeAt("claude"), codex]);
  expect(view.names()).toEqual(["codex"]);
});
