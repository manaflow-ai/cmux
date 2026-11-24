// The intro walk (hq RFD 0057): Return walks the four screens before Continue, Back stays in the walk,
// Skip still skips; each look tile, trust row and Tidy is one walk op that changes only what differs
// and puts back the opening values for the rest; no row flips a default by itself.
import { afterAll, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { makeItYoursState } from "./fixtures";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { MockOnboardingProvider } from "./mockProvider";
import { OPS, type MakeItYoursState, type OnboardingState } from "./ops";
import { OnboardingStore } from "./store";
import {
  LOOK_BUNDLES,
  bundleWrites,
  noise,
  noiseWrites,
  permission,
  pickedBundle,
  tidyOn,
  tidyWrites,
  walkValues,
} from "./walk";

const restore = installDom();
afterAll(restore);
const strings = createStrings(table, ["en"]);

const choices = (walk: MakeItYoursState["walk"] = {}): MakeItYoursState => ({
  ...makeItYoursState("fresh", { introWalk: true }).makeItYours!,
  walk,
});
const bundle = (id: string) => LOOK_BUNDLES.find((b) => b.id === id)!;

async function mount(screen?: "look" | "work" | "trust" | "tune", introWalk = true) {
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
  await act(async () => page.render(<OnboardingPage store={store} strings={strings} makeItYoursScreen={screen} />));
  calls.length = 0;
  const done = async () => {
    await act(async () => page.unmount());
    root.remove();
  };
  return { calls, root, done };
}

const key = (k: string) => window.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));
const button = (root: HTMLElement, text: string) =>
  [...root.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.includes(text))!;

describe("intro walk: screens", () => {
  test("switch off (the default): today's one screen, and Return is Continue", async () => {
    const { calls, root, done } = await mount(undefined, false);
    expect(root.querySelector(".onb-title")?.textContent).toBe(strings.t("onboarding.makeItYours.title"));
    expect(root.querySelector(".onb-sentence")?.textContent).toBe(strings.t("onboarding.makeItYours.body"));
    expect(root.querySelectorAll('input[name="look"], input[name="permission"]').length).toBe(0);
    expect(root.querySelectorAll('input[name="workStyle"]').length).toBe(2);
    expect(root.querySelectorAll('input[name="density"]').length).toBe(5);
    await act(async () => key("Enter"));
    expect(calls).toEqual([{ op: OPS.next, params: {} }]);
    await done();
  });

  test("Return walks look, work, trust and tune, then Continue leaves the step", async () => {
    const { calls, root, done } = await mount();
    const title = () => root.querySelector(".onb-title")?.textContent;
    expect(title()).toBe(strings.t("onboarding.makeItYours.title"));
    expect(root.querySelectorAll('input[name="look"]').length).toBe(5);
    await act(async () => key("Enter"));
    expect(title()).toBe(strings.t("onboarding.makeItYours.work.label"));
    await act(async () => key("Enter"));
    expect(title()).toBe(strings.t("onboarding.makeItYours.trust.title"));
    await act(async () => key("Enter"));
    expect(title()).toBe(strings.t("onboarding.makeItYours.tune.title"));
    expect(calls).toEqual([]);
    await act(async () => key("Enter"));
    expect(calls).toEqual([{ op: OPS.next, params: {} }]);
    await done();
  });

  test("Back steps back inside the walk; Escape skips from any screen", async () => {
    const { calls, root, done } = await mount("trust");
    await act(async () => button(root, strings.t("onboarding.button.back")).click());
    expect(root.querySelector(".onb-title")?.textContent).toBe(strings.t("onboarding.makeItYours.work.label"));
    expect(calls).toEqual([]);
    await act(async () => key("Escape"));
    expect(calls).toEqual([{ op: OPS.skip, params: {} }]);
    await done();
  });

  test("a look tile is one walk op; trust and noise rows are theirs", async () => {
    const look = await mount("look");
    await act(async () =>
      look.root.querySelector<HTMLInputElement>('input[name="look"][value="twoToneStudio"]')!.click(),
    );
    expect(look.calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: "appearance.twoTone", value: "auto" }] } }]);
    await look.done();
    const trust = await mount("trust");
    await act(async () => trust.root.querySelector<HTMLInputElement>('input[name="permission"][value="ask"]')!.click());
    await act(async () => trust.root.querySelector<HTMLInputElement>('input[name="noise"][value="quiet"]')!.click());
    expect(trust.calls).toEqual([
      { op: OPS.walk, params: { writes: [{ path: "agents.defaultPermissionMode", value: "ask" }] } },
      {
        op: OPS.walk,
        params: {
          writes: [
            { path: "notifications.desktop", value: "never" },
            { path: "notifications.sound", value: "none" },
          ],
        },
      },
    ]);
    await trust.done();
  });
});

describe("intro walk: writes", () => {
  test("the gallery mock restores its opening choices after a walk bundle and Skip", async () => {
    const provider = new MockOnboardingProvider("makeItYours", makeItYoursState("picked", { introWalk: true }));
    const opened = await provider.call<OnboardingState>(OPS.state, {});
    await provider.call(OPS.walk, {
      writes: [
        { path: "tabs.newTabTemplate", value: "terminal" },
        { path: "appearance.density", value: "ultraCompact" },
        { path: "appearance.twoTone", value: "auto" },
      ],
    });
    const picked = await provider.call<OnboardingState>(OPS.state, {});
    expect(picked.makeItYours?.workStyle).toBe("terminal");
    expect(picked.makeItYours?.density).toBe("ultraCompact");
    expect(picked.makeItYours?.walk).toEqual({ "appearance.twoTone": "auto" });
    await provider.call(OPS.skip, {});
    const restored = await provider.call<OnboardingState>(OPS.state, {});
    expect(restored.makeItYours).toEqual(opened.makeItYours);
  });

  test("a new Mac opens on House, Full Access, Banners and Sound, Tidy off", () => {
    const now = walkValues(choices());
    expect(pickedBundle(now, now)).toBe("house");
    expect(permission(now)).toBe("fullAccess");
    expect(noise(now)).toBe("bannersSound");
    expect(tidyOn(now)).toBe(false);
  });

  test("moving between looks puts the last one's settings back to the opening values", () => {
    const opened = walkValues(choices());
    const dense = walkValues({
      ...choices({ "ui.animations.enabled": false, "notifications.sound": "none" }),
      workStyle: "terminal",
      density: "ultraCompact",
    });
    expect(pickedBundle(opened, dense)).toBe("denseOperator");
    expect(bundleWrites(bundle("house"), opened, dense)).toEqual([
      { path: "tabs.newTabTemplate", value: null },
      { path: "appearance.density", value: "cozy" },
      { path: "ui.animations.enabled", value: null },
      { path: "notifications.sound", value: null },
    ]);
    const quiet = bundleWrites(bundle("quietSolid"), opened, dense);
    expect(quiet).toContainEqual({ path: "ui.calm", value: "calm" });
    expect(quiet).toContainEqual({ path: "agents.defaultPermissionMode", value: "ask" });
    expect(quiet).toContainEqual({ path: "tabs.newTabTemplate", value: null });
  });

  test("Tidy turns on its three settings and off back to what was set", () => {
    const opened = walkValues(choices({ "agents.chats.archiveInactive": "30d" }));
    expect(tidyWrites(true, opened, opened)).toEqual([
      { path: "agents.chats.archiveInactive", value: "7d" },
      { path: "workspaces.autoArchive.style", value: "suggest" },
      { path: "sidebar.settleFinished", value: true },
    ]);
    const tidy = walkValues(
      choices({
        "agents.chats.archiveInactive": "7d",
        "workspaces.autoArchive.style": "suggest",
        "sidebar.settleFinished": true,
      }),
    );
    expect(tidyOn(tidy)).toBe(true);
    expect(tidyWrites(false, opened, tidy)).toEqual([
      { path: "agents.chats.archiveInactive", value: "30d" },
      { path: "workspaces.autoArchive.style", value: null },
      { path: "sidebar.settleFinished", value: null },
    ]);
  });

  test("Banners and Sound keeps a person's own sound", () => {
    const opened = walkValues(choices({ "notifications.sound": "Glass" }));
    expect(noise(opened)).toBe("bannersSound");
    const quiet = walkValues(choices({ "notifications.sound": "none", "notifications.desktop": "never" }));
    expect(noiseWrites("bannersSound", opened, quiet)).toEqual([
      { path: "notifications.desktop", value: null },
      { path: "notifications.sound", value: "Glass" },
    ]);
  });
});
