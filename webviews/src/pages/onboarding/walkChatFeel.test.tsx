// The intro walk's chat feel row (cmux#56827, Leo: "immensely easy ways to undo and redo and whatever turn
// shit on and off"): on screen 2 a "Sending a Prompt" row picks Instant (as cmux ships) or Pop In over
// agentPane.display.sendPop; one walk write per click, the opening value back when it means the same;
// the walk switched off (today's one screen) and the other walk screens show no row.
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
const { chatFeel, chatFeelWrites } = await import("./walk");
const strings = createStrings(table, ["en"]);
const SEND_POP = "agentPane.display.sendPop";
const SEND_TOP = "agentPane.display.sendScrollsToTop";

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

const radio = (root: HTMLElement, value: string) =>
  root.querySelector<HTMLInputElement>(`input[name="chatFeel"][value="${value}"]`);

describe("intro walk: chat feel row", () => {
  test("switch off: no row", async () => {
    const { root, done } = await mount(undefined, false);
    expect(radio(root, "instant")).toBeNull();
    await done();
  });

  for (const screen of ["look", "trust", "tune"] as const) {
    test(`${screen}: no row`, async () => {
      const { root, done } = await mount(screen);
      expect(radio(root, "instant")).toBeNull();
      await done();
    });
  }

  test("work: Instant preselected; Pop In is one walk write", async () => {
    const { calls, root, done } = await mount("work");
    expect(root.textContent).toContain(strings.t("onboarding.makeItYours.chatFeel.label"));
    expect(radio(root, "instant")!.checked).toBe(true);
    await act(async () => radio(root, "pop")!.click());
    expect(calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: SEND_POP, value: true }] } }]);
    await done();
  });

  test("work: Pinned writes the sent-prompt-to-top setting and leaves the pop as opened", async () => {
    const { calls, root, done } = await mount("work");
    expect(root.textContent).toContain(strings.t("onboarding.makeItYours.chatFeel.top"));
    await act(async () => radio(root, "top")!.click());
    expect(calls).toEqual([{ op: OPS.walk, params: { writes: [{ path: SEND_TOP, value: true }] } }]);
    await done();
  });
});

describe("chatFeel", () => {
  test("unset reads as Instant, as cmux ships", () => {
    expect(chatFeel({})).toBe("instant");
    expect(chatFeel({ [SEND_POP]: true })).toBe("pop");
    expect(chatFeel({ [SEND_TOP]: true })).toBe("top");
    expect(chatFeel({ [SEND_POP]: true, [SEND_TOP]: true })).toBe("top");
  });

  test("Pinned and back: the opening values return, and the pop is kept as it opened", () => {
    const opened = { [SEND_POP]: true, [SEND_TOP]: null };
    expect(chatFeelWrites("top", opened, opened)).toEqual([{ path: SEND_TOP, value: true }]);
    expect(chatFeelWrites("pop", opened, { [SEND_POP]: true, [SEND_TOP]: true })).toEqual([
      { path: SEND_TOP, value: null },
    ]);
    expect(chatFeelWrites("instant", opened, { [SEND_POP]: true, [SEND_TOP]: true })).toEqual([
      { path: SEND_POP, value: false },
      { path: SEND_TOP, value: null },
    ]);
  });

  test("back to Instant puts the opening value back; a no-op writes nothing", () => {
    const opened = { [SEND_POP]: null };
    expect(chatFeelWrites("instant", opened, { [SEND_POP]: true })).toEqual([{ path: SEND_POP, value: null }]);
    expect(chatFeelWrites("instant", opened, opened)).toEqual([]);
    expect(chatFeelWrites("pop", { [SEND_POP]: true }, { [SEND_POP]: false })).toEqual([
      { path: SEND_POP, value: true },
    ]);
  });
});
