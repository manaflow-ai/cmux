import { afterEach, describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { Window } from "happy-dom";
import type { SetupState } from "./setupModel";
import type { PageClient } from "../shared/pageClient";
import { SetupCardPage } from "./SetupCardPage";
import { SETUP_OPS } from "./ops";
import { SetupCardStore } from "./store";

const fresh: SetupState = {
  agents: [
    { id: "claude", name: "Claude Code", state: "missing" },
    { id: "codex", name: "Codex", state: "missing" },
  ],
  account: { signedIn: false },
  cli: "missing",
  classic: null,
};

/** A host that answers `state` and records every call. */
function host(state: SetupState) {
  const calls: [string, unknown][] = [];
  let push: ((next: SetupState) => void) | null = null;
  const client: PageClient = {
    async call<R>(op: string, params: unknown) {
      calls.push([op, params]);
      return (op === SETUP_OPS.state ? state : {}) as R;
    },
    async subscribe<E>(_stream: string, onEvent: (data: E, seq: number) => void) {
      push = (next) => onEvent(next as E, 0);
      return () => {};
    },
    handle: () => () => {},
  };
  return { client, calls, push: (next: SetupState) => push?.(next) };
}

/** The page mounted in a DOM with no ResizeObserver (as a hidden web view, which gets no callbacks). */
async function mounted(state: SetupState) {
  const window = new Window();
  Object.assign(globalThis, {
    document: window.document,
    window,
    ResizeObserver: undefined,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    navigator: window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const { client, calls } = host(state);
  const store = new SetupCardStore(client);
  const root = window.document.createElement("div");
  window.document.body.appendChild(root);
  await act(async () => {
    createRoot(root as unknown as HTMLElement).render(<SetupCardPage store={store} />);
    await store.start();
  });
  const button = (label: string) => {
    const found = [...root.querySelectorAll("button")].find((node) => node.textContent === label);
    if (!found) throw new Error(`no ${label} button`);
    return found as unknown as HTMLButtonElement;
  };
  return { root, calls, button };
}

const names = ["document", "window", "ResizeObserver", "HTMLElement", "Element", "Node", "navigator"] as const;
const saved = Object.fromEntries(names.map((name) => [name, (globalThis as Record<string, unknown>)[name]]));
afterEach(() => {
  Object.assign(globalThis, saved);
});

const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

describe("the Set Up cmux page", () => {
  test("shows every row in one card, with the words the first-run probe reads", async () => {
    const { client } = host(fresh);
    const store = new SetupCardStore(client);
    await store.start();
    const words = text(renderToStaticMarkup(<SetupCardPage store={store} />));
    for (const phrase of ["Set Up cmux", "Claude Code", "Codex", "cmux account", "Command line", "Install Claude Code"])
      expect(words).toContain(phrase);
    expect(renderToStaticMarkup(<SetupCardPage store={store} />)).toContain('data-look="rows"');
  });

  test("draws nothing before the host answers, then follows its stream", async () => {
    const { client, push } = host(fresh);
    const store = new SetupCardStore(client);
    expect(text(renderToStaticMarkup(<SetupCardPage store={store} />)).trim()).toBe("");
    await store.start();
    push({ ...fresh, account: { signedIn: true, email: "you@example.com" } });
    expect(store.getSnapshot()?.account.email).toBe("you@example.com");
  });

  test("a row's button and Hide are one host call each", async () => {
    const { client, calls } = host(fresh);
    const store = new SetupCardStore(client);
    store.send(SETUP_OPS.run, { action: { kind: "installCLI" } });
    store.send(SETUP_OPS.hide, {});
    await Promise.resolve();
    expect(calls).toEqual([
      [SETUP_OPS.run, { action: { kind: "installCLI" } }],
      [SETUP_OPS.hide, {}],
    ]);
  });

  test("reports its height once rendered, with no ResizeObserver callback (a hidden page gets none)", async () => {
    const { calls } = await mounted(fresh);
    expect(calls.some(([op]) => op === SETUP_OPS.size)).toBe(true);
  });

  test("Install Codex waits, greyed, while Claude Code installs, and runs once that ends", async () => {
    const claude = (state: "installing" | "failed") => ({
      ...fresh,
      agents: [{ ...fresh.agents[0]!, state }, fresh.agents[1]!],
    });
    const busy = await mounted(claude("installing"));
    expect(busy.root.textContent).toContain("Codex installs after Claude Code");
    await act(async () => busy.button("Install Codex").click());
    expect(busy.calls.filter(([op]) => op === SETUP_OPS.run)).toEqual([]);

    const failed = await mounted(claude("failed"));
    await act(async () => failed.button("Install Codex").click());
    expect(failed.calls.filter(([op]) => op === SETUP_OPS.run)).toEqual([
      [SETUP_OPS.run, { action: { kind: "installAgent", id: "codex" } }],
    ]);
  });
  test("Text Size and Density: the person's pick is one host call, sized over the density's own text", async () => {
    const look = { textSize: null, density: "cozy", body: 14 };
    const card = await mounted({ ...fresh, look });
    expect(card.root.textContent).toContain("Text size and density");
    const radio = (selector: string) => {
      const found = card.root.querySelector(selector);
      if (!found) throw new Error(`no ${selector}`);
      return found as unknown as HTMLInputElement;
    };
    expect(radio('input[data-text-size="default"]').checked).toBe(true);
    await act(async () => radio('input[data-text-size="larger"]').click());
    await act(async () => radio('input[data-density-choice="comfortable"]').click());
    expect(card.calls.filter(([op]) => op === SETUP_OPS.run)).toEqual([
      [SETUP_OPS.run, { action: { kind: "setTextSize", points: 16 } }],
      [SETUP_OPS.run, { action: { kind: "setDensity", id: "comfortable" } }],
    ]);
    // A size already set (16 pt): Default removes it.
    const larger = await mounted({ ...fresh, look: { ...look, textSize: 16 } });
    const checked = larger.root.querySelector('input[data-text-size="larger"]') as unknown as HTMLInputElement;
    expect(checked.checked).toBe(true);
    const reset = larger.root.querySelector('input[data-text-size="default"]') as unknown as HTMLInputElement;
    await act(async () => reset.click());
    expect(larger.calls.filter(([op]) => op === SETUP_OPS.run)).toEqual([
      [SETUP_OPS.run, { action: { kind: "setTextSize", points: null } }],
    ]);
  });

  test("no look from the host (an older app): no Text Size row", async () => {
    const card = await mounted(fresh);
    expect(card.root.querySelector('[data-step="look"]')).toBeNull();
  });
});
