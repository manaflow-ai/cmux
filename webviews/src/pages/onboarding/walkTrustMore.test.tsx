// The intro walk's Trust screen also sets Computer Use and the finish chime (cmux#56827, Leo: "immensely
// easy ways to undo and redo and whatever turn shit on and off"): the Computer Use row opens on the current
// mode (Full Access on a new Mac) and the chime switch on its current value (off); neither flips a default
// by itself; the walk switched off shows neither.
import { afterAll, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installDom } from "../settings/testDom";
import table from "./generated/strings.json";

const restore = installDom();
afterAll(restore);
const { createStrings } = await import("../shared/i18n");
const { makeItYoursState } = await import("./fixtures");
const { OnboardingPage } = await import("./Onboarding");
const { OPS } = await import("./ops");
const { OnboardingStore } = await import("./store");
const { computerUse, computerUseWrites, finishSoundOn, finishSoundWrites } = await import("./walk");
const strings = createStrings(table, ["en"]);

describe("walk helpers: Computer Use and the chime", () => {
  test("a new Mac reads Full Access and no chime", () => {
    expect(computerUse({})).toBe("fullAccess");
    expect(finishSoundOn({})).toBe(false);
  });

  test("a pick writes the mode; going back to the opening value puts the unset back", () => {
    const opened = {};
    expect(computerUseWrites("lookOnly", opened, {})).toEqual([{ path: "computerUse.mode", value: "lookOnly" }]);
    expect(computerUseWrites("fullAccess", opened, { "computerUse.mode": "lookOnly" })).toEqual([
      { path: "computerUse.mode", value: null },
    ]);
    expect(computerUseWrites("fullAccess", opened, {})).toEqual([]);
  });

  test("the chime on writes true; off puts the opening value back", () => {
    expect(finishSoundWrites(true, {}, {})).toEqual([{ path: "agentPane.display.finishSound", value: true }]);
    expect(finishSoundWrites(false, {}, { "agentPane.display.finishSound": true })).toEqual([
      { path: "agentPane.display.finishSound", value: null },
    ]);
  });
});

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
  const store = new OnboardingStore(client, makeItYoursState("fresh", { introWalk }));
  const root = document.createElement("div");
  document.body.append(root);
  const page = createRoot(root);
  await act(async () => page.render(<OnboardingPage store={store} strings={strings} makeItYoursScreen="trust" />));
  calls.length = 0;
  const done = async () => {
    await act(async () => page.unmount());
    root.remove();
  };
  return { calls, root, done };
}

describe("intro walk: Trust screen rows", () => {
  test("switch off: no Computer Use row, no chime", async () => {
    const { root, done } = await mount(false);
    expect(root.querySelector('[data-row="computerUse"]')).toBeNull();
    expect(root.querySelector('[data-row="finishSound"]')).toBeNull();
    await done();
  });

  test("Computer Use opens on Full Access; a pick sends one walk write", async () => {
    const { calls, root, done } = await mount();
    const radios = root.querySelectorAll<HTMLInputElement>('input[name="computerUse"]');
    expect(radios.length).toBe(5);
    expect(root.querySelector<HTMLInputElement>('input[name="computerUse"][value="fullAccess"]')!.checked).toBe(true);
    await act(async () => root.querySelector<HTMLInputElement>('input[name="computerUse"][value="lookOnly"]')!.click());
    expect(calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: "computerUse.mode", value: "lookOnly" }] } }]);
    await done();
  });

  test("the chime opens off; turning it on sends one walk write", async () => {
    const { calls, root, done } = await mount();
    const row = root.querySelector('[data-row="finishSound"]')!;
    const toggle = row.querySelector<HTMLElement>('[role="switch"], input[type="checkbox"]')!;
    expect(toggle).not.toBeNull();
    await act(async () => toggle.click());
    expect(calls).toEqual([
      { op: OPS.walk, params: { writes: [{ path: "agentPane.display.finishSound", value: true }] } },
    ]);
    await done();
  });
});
