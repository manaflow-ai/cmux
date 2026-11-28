// The setups shelf (experiments.setupShelf, off by default; hq design dp-9eedbe44e5): the design's rule
// ("Try snapshots only the keys it writes, Revert restores that snapshot, Keep discards it"; rivals
// replace each other, other axes stack), the shelf drawn only with the switch on, each click one walk
// op, and every key the setup files write allowed by the host.
import { afterAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { makeItYoursState } from "./fixtures";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { OPS, type OnboardingState } from "./ops";
import { keepSetup, revertSetup, SHELF_SETUPS, type Shelf, type SetupId, trySetup } from "./setupShelf";
import { OnboardingStore } from "./store";
import type { WalkValues, WalkWrite } from "./walk";

const restore = installDom();
afterAll(restore);

const strings = createStrings(table, ["en"]);
const settingsOf = (id: SetupId) => SHELF_SETUPS.find((s) => s.id === id)!.settings;
const apply = (values: WalkValues, writes: WalkWrite[]): WalkValues => {
  const next = { ...values };
  for (const { path, value } of writes) {
    if (value === null) delete next[path];
    else next[path] = value;
  }
  return next;
};

describe("the rule", () => {
  test("Dense, Terminal-first and Calm stack; reverting each puts back only its own keys", () => {
    const before: WalkValues = { "appearance.density": "cozy", "layout.mainPane": "agent-chats" };
    let shelf: Shelf = {};
    let now = before;
    for (const id of ["dense", "terminalFirst", "calm"] as const) {
      const step = trySetup(shelf, id, now);
      shelf = step.shelf;
      now = apply(now, step.writes);
    }
    expect(Object.keys(shelf).sort()).toEqual(["calm", "dense", "terminalFirst"]);
    for (const id of ["dense", "terminalFirst", "calm"] as const) {
      for (const [path, value] of Object.entries(settingsOf(id))) expect(now[path]).toEqual(value);
    }
    const back = revertSetup(shelf, "dense", now);
    now = apply(now, back.writes);
    expect(back.writes.map((w) => w.path).sort()).toEqual(Object.keys(settingsOf("dense")).sort());
    expect(now["appearance.density"]).toBe("cozy");
    for (const id of ["terminalFirst", "calm"] as const) {
      for (const [path, value] of Object.entries(settingsOf(id))) expect(now[path]).toEqual(value);
    }
  });

  test("Chat-first over Terminal-first on trial replaces it, and Revert gives back the person's keys", () => {
    const before: WalkValues = { "layout.mainPane": "terminal", "layout.splitSizing": "golden" };
    const first = trySetup({}, "terminalFirst", before);
    const mid = apply(before, first.writes);
    const second = trySetup(first.shelf, "chatFirst", mid);
    expect(Object.keys(second.shelf)).toEqual(["chatFirst"]);
    const after = apply(mid, second.writes);
    // Terminal-first's other keys are back as the person had them.
    expect(after["layout.splitSizing"]).toBe("golden");
    expect(after["layout.newPanePlacement"]).toBeUndefined();
    expect(after["layout.focusFollowsMouse"]).toBeUndefined();
    for (const [path, value] of Object.entries(settingsOf("chatFirst"))) expect(after[path]).toEqual(value);
    // Revert puts the shared key back to the person's value, not Terminal-first's.
    const back = revertSetup(second.shelf, "chatFirst", after);
    expect(apply(after, back.writes)).toEqual(before);
  });

  test("Revert leaves a key the person changed after Try", () => {
    const tried = trySetup({}, "dense", { "sidebar.style": "full" });
    const now = { ...apply({ "sidebar.style": "full" }, tried.writes), "tabs.barPosition": "top" };
    const back = revertSetup(tried.shelf, "dense", now);
    expect(back.writes.some((w) => w.path === "tabs.barPosition")).toBe(false);
    expect(back.writes).toContainEqual({ path: "sidebar.style", value: "full" });
  });

  test("Keep drops the snapshot, so a later Revert writes nothing", () => {
    const tried = trySetup({}, "calm", {});
    const kept = keepSetup(tried.shelf, "calm");
    expect(kept.calm).toEqual({ status: "kept" });
    expect(revertSetup(kept, "calm", apply({}, tried.writes)).writes).toEqual([]);
  });

  test("Try writes only the keys that change", () => {
    const now = { ...settingsOf("terminalFirst") };
    expect(trySetup({}, "terminalFirst", now).writes).toEqual([]);
  });
});

describe("the page", () => {
  const render = (state: OnboardingState) =>
    renderToStaticMarkup(<OnboardingPage store={new OnboardingStore(null, state)} strings={strings} />);
  const withShelf = (on: boolean): OnboardingState => {
    const state = makeItYoursState("fresh");
    return { ...state, makeItYours: { ...state.makeItYours!, ...(on ? { setupShelf: true } : {}), walk: {} } };
  };

  test("no shelf with the switch off", () => {
    expect(render(withShelf(false))).not.toContain("onb-setups");
  });

  test("the four setups with the switch on", () => {
    const html = render(withShelf(true));
    expect(html).toContain("Start from a setup");
    for (const name of ["Calm", "Dense", "Chat-first", "Terminal-first"]) expect(html).toContain(`Try ${name}`);
  });

  test("Try, Revert and Keep: Try and Revert are each one walk op; Keep sends nothing", async () => {
    // A host that writes each walk op and sends the step back, as the stream does.
    const calls: { op: string; params: unknown }[] = [];
    let state = withShelf(true);
    let push: ((next: OnboardingState) => void) | undefined;
    const client = {
      call: async (op: string, params: unknown) => {
        if (op === OPS.state) return state as never;
        calls.push({ op, params });
        if (op === OPS.walk) {
          const choices = state.makeItYours!;
          const values = apply(
            { ...choices.walk, "appearance.density": choices.density },
            (params as { writes: WalkWrite[] }).writes,
          );
          const { "appearance.density": density, ...walk } = values;
          state = { ...state, makeItYours: { ...choices, density: String(density ?? "cozy"), walk } };
          push?.(state);
        }
        return {} as never;
      },
      subscribe: async (_op: string, listener: (next: OnboardingState) => void) => {
        push = listener;
        return () => {};
      },
      handle: () => () => {},
    };
    const store = new OnboardingStore(client as never, state);
    await store.start();
    const root = document.createElement("div");
    document.body.append(root);
    const page = createRoot(root);
    await act(async () => page.render(<OnboardingPage store={store} strings={strings} />));
    calls.length = 0;
    const button = (label: string) => root.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)!;
    await act(async () => button("Try Dense").click());
    expect(calls).toHaveLength(1);
    expect(calls[0].op).toBe(OPS.walk);
    const writes = (calls[0].params as { writes: WalkWrite[] }).writes;
    expect(writes.map((w) => w.path).sort()).toEqual(Object.keys(settingsOf("dense")).sort());
    await act(async () => button("Revert Dense").click());
    expect(calls).toHaveLength(2);
    expect(calls[1].op).toBe(OPS.walk);
    await act(async () => button("Try Calm").click());
    await act(async () => button("Keep Calm").click());
    expect(calls).toHaveLength(3);
    expect(root.querySelector('[data-setup="calm"]')?.getAttribute("data-status")).toBe("kept");
    await act(async () => page.unmount());
    store.stop();
    root.remove();
  });
});

test("every key a setup writes is one the host allows (FirstRunChoicesSettingsSource)", () => {
  const swift = readFileSync(
    join(
      import.meta.dir,
      "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextOnboarding/Model/FirstRunChoicesSettingsSource.swift",
    ),
    "utf8",
  );
  const block = (name: string) => {
    const match = swift.match(new RegExp(`static let ${name}: \\[\\[String\\]\\] = \\[([\\s\\S]*?)\\n\\s*\\]`));
    expect(match).not.toBeNull();
    return [...match![1].matchAll(/\[([^\[\]]+)\]/g)].map((m) =>
      [...m[1].matchAll(/"([^"]+)"/g)].map((s) => s[1]).join("."),
    );
  };
  // The picks' paths (`pickPaths`) are named by their settings' constants; a setup writes two of them:
  // the density and the new-tab template (terminal-first, #60084).
  const allowed = new Set([...block("walkPaths"), ...block("setupPaths"), "appearance.density", "tabs.newTabTemplate"]);
  for (const setup of SHELF_SETUPS) {
    for (const path of Object.keys(setup.settings)) expect([setup.id, allowed.has(path)]).toEqual([setup.id, true]);
  }
});
