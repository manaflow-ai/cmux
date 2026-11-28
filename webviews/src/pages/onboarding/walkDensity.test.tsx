// The intro walk's Tune asks density as three levels, the outer two behind More (cmux#56827, hq RFD 0057
// S6); it opens on all five when the setting is already an outer one; the walk switched off keeps all five.
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
const strings = createStrings(table, ["en"]);

async function mount({ introWalk = true, density }: { introWalk?: boolean; density?: string } = {}) {
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
  const state: OnboardingState =
    density == null ? first : { ...first, makeItYours: { ...first.makeItYours!, density } };
  const store = new OnboardingStore(client, state);
  const root = document.createElement("div");
  document.body.append(root);
  const page = createRoot(root);
  await act(async () =>
    page.render(<OnboardingPage store={store} strings={strings} makeItYoursScreen={introWalk ? "tune" : undefined} />),
  );
  calls.length = 0;
  const done = async () => {
    await act(async () => page.unmount());
    root.remove();
  };
  return { calls, root, done };
}

const levels = (root: HTMLElement) =>
  [...root.querySelectorAll<HTMLInputElement>('input[name="density"]')].map((input) => input.value);
const more = (root: HTMLElement) => root.querySelector<HTMLButtonElement>("button[data-density-more]");

describe("intro walk: density 3 + More", () => {
  test("switch off: all five, no More", async () => {
    const { root, done } = await mount({ introWalk: false });
    expect(levels(root)).toEqual(["ultraCompact", "compact", "cozy", "comfortable", "spacious"]);
    expect(more(root)).toBeNull();
    await done();
  });

  test("Tune shows three; More shows the outer two, and picking one is the density op", async () => {
    const { calls, root, done } = await mount();
    expect(levels(root)).toEqual(["compact", "cozy", "comfortable"]);
    expect(more(root)?.textContent).toBe(strings.t("onboarding.makeItYours.density.more"));
    await act(async () => more(root)!.click());
    expect(levels(root)).toEqual(["ultraCompact", "compact", "cozy", "comfortable", "spacious"]);
    expect(more(root)).toBeNull();
    await act(async () => root.querySelector<HTMLInputElement>('input[name="density"][value="spacious"]')!.click());
    expect(calls).toEqual([{ op: OPS.density, params: { value: "spacious" } }]);
    await done();
  });

  test("an outer density already set opens on all five", async () => {
    const { root, done } = await mount({ density: "ultraCompact" });
    expect(levels(root)).toEqual(["ultraCompact", "compact", "cozy", "comfortable", "spacious"]);
    expect(more(root)).toBeNull();
    await done();
  });
});
