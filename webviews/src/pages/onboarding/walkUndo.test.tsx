// The intro walk's Undo / Redo footer (cmux#56827, Leo: "immensely easy ways to undo and redo"): every
// pick on any screen is one step back; Redo steps forward until a new pick; Command-Z and
// Shift-Command-Z do the same; the walk switched off shows no pair.
import { afterAll, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installDom } from "../settings/testDom";
import table from "./generated/strings.json";
import type { OnboardingState } from "./ops";

const restore = installDom();
afterAll(restore);
const { createStrings } = await import("../shared/i18n");
const { makeItYoursState } = await import("./fixtures");
const { OnboardingPage } = await import("./Onboarding");
const { OPS } = await import("./ops");
const { OnboardingStore } = await import("./store");
const { restoreWrites } = await import("./walk");
const strings = createStrings(table, ["en"]);

async function mount(introWalk = true) {
  const calls: { op: string; params: unknown }[] = [];
  const client = {
    call: async (op: string, params: unknown) => {
      calls.push({ op, params });
      return {} as never;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const first = makeItYoursState("fresh", { introWalk });
  const store = new OnboardingStore(client, first);
  const root = document.createElement("div");
  document.body.append(root);
  const page = createRoot(root);
  await act(async () => page.render(<OnboardingPage store={store} strings={strings} />));
  calls.length = 0;
  /** The host's answer to a walk write: its values land in `walk`. */
  const land = async (walk: Record<string, string | number | boolean | null>) => {
    const now = store.getSnapshot()!;
    const next: OnboardingState = {
      ...now,
      makeItYours: { ...now.makeItYours!, walk: { ...now.makeItYours!.walk, ...walk } },
    };
    await act(async () => store.set(next));
  };
  const done = async () => {
    await act(async () => page.unmount());
    root.remove();
  };
  return { calls, root, land, done };
}

const button = (root: HTMLElement, text: string) =>
  [...root.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.includes(text));
const cmdZ = (shiftKey = false) =>
  window.dispatchEvent(
    new KeyboardEvent("keydown", { key: shiftKey ? "Z" : "z", metaKey: true, shiftKey, bubbles: true }),
  );

describe("intro walk: Undo / Redo", () => {
  test("switch off: no Undo or Redo", async () => {
    const { root, done } = await mount(false);
    expect(button(root, strings.t("onboarding.button.undo"))).toBeUndefined();
    await done();
  });

  test("a pick enables Undo; Undo writes the opening value back; Redo writes the pick again", async () => {
    const { calls, root, land, done } = await mount();
    const undo = () => button(root, strings.t("onboarding.button.undo"))!;
    const redo = () => button(root, strings.t("onboarding.button.redo"))!;
    expect(undo().disabled).toBe(true);
    expect(redo().disabled).toBe(true);
    await act(async () => root.querySelector<HTMLInputElement>('input[name="look"][value="twoToneStudio"]')!.click());
    expect(calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: "appearance.twoTone", value: "auto" }] } }]);
    await land({ "appearance.twoTone": "auto" });
    expect(undo().disabled).toBe(false);
    calls.length = 0;
    await act(async () => undo().click());
    expect(calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: "appearance.twoTone", value: null }] } }]);
    await land({ "appearance.twoTone": null });
    expect(undo().disabled).toBe(true);
    expect(redo().disabled).toBe(false);
    calls.length = 0;
    await act(async () => cmdZ(true));
    expect(calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: "appearance.twoTone", value: "auto" }] } }]);
    await land({ "appearance.twoTone": "auto" });
    calls.length = 0;
    await act(async () => cmdZ());
    expect(calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: "appearance.twoTone", value: null }] } }]);
    await done();
  });

  test("a new pick after Undo drops Redo", async () => {
    const { root, land, done } = await mount();
    const redo = () => button(root, strings.t("onboarding.button.redo"))!;
    await act(async () => root.querySelector<HTMLInputElement>('input[name="look"][value="twoToneStudio"]')!.click());
    await land({ "appearance.twoTone": "auto" });
    await act(async () => cmdZ());
    await land({ "appearance.twoTone": null });
    expect(redo().disabled).toBe(false);
    await act(async () => root.querySelector<HTMLInputElement>('input[name="look"][value="glasshouse"]')!.click());
    expect(redo().disabled).toBe(true);
    await done();
  });
});

describe("restoreWrites", () => {
  test("the work style goes back as its own op; the rest as one walk write", () => {
    const before = { "tabs.newTabTemplate": null, "appearance.density": "cozy", "appearance.twoTone": null };
    const after = {
      "tabs.newTabTemplate": "terminal",
      "appearance.density": "ultraCompact",
      "appearance.twoTone": null,
    };
    expect(restoreWrites(before, after)).toEqual({
      workStyle: "gui",
      writes: [{ path: "appearance.density", value: "cozy" }],
    });
    expect(restoreWrites(after, after)).toEqual({ workStyle: null, writes: [] });
  });
});
