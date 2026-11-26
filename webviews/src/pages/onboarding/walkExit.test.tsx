// The intro walk's way out to a chat (cmux#56827, Leo: "immensely easy ways to undo and redo and whatever
// turn shit on and off"): Start Chatting on every screen before the last ends the step with the picks
// kept (the host's `next`, as Continue on the last screen); Skip still puts them back; the walk switched
// off shows no such button.
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
const strings = createStrings(table, ["en"]);

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

const exit = (root: HTMLElement) => root.querySelector<HTMLButtonElement>("button[data-walk-exit]");

describe("intro walk: Start Chatting", () => {
  test("switch off: no Start Chatting", async () => {
    const { root, done } = await mount(undefined, false);
    expect(exit(root)).toBeNull();
    await done();
  });

  for (const screen of ["look", "work", "trust"] as const) {
    test(`${screen}: Start Chatting ends the step with the picks kept`, async () => {
      const { calls, root, done } = await mount(screen);
      expect(exit(root)?.textContent).toBe(strings.t("onboarding.button.startChatting"));
      await act(async () => exit(root)!.click());
      expect(calls).toEqual([{ op: OPS.next, params: {} }]);
      await done();
    });
  }

  test("tune, the last screen: Continue already leaves, so no second button", async () => {
    const { root, done } = await mount("tune");
    expect(exit(root)).toBeNull();
    await done();
  });
});
