import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { importState } from "./fixtures";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";

const restore = installDom();
afterAll(restore);

async function mount() {
  const calls: string[] = [];
  const client = {
    call: async (op: string) => {
      calls.push(op);
      return {} as never;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const store = new OnboardingStore(client, importState("ready"));
  const root = document.createElement("div");
  document.body.append(root);
  await act(async () =>
    createRoot(root).render(<OnboardingPage store={store} strings={createStrings(table, ["en"])} />),
  );
  return { calls, root };
}

function enter(target: HTMLElement, repeat: boolean): KeyboardEvent {
  const event = new KeyboardEvent("keydown", { key: "Enter", repeat, bubbles: true, cancelable: true });
  target.dispatchEvent(event);
  return event;
}

// Tab to Import and hold Return: the repeats must not activate the focused button, which turns
// into Begin Importing and would ask for the password authorization with no second press.
test("a held Return's repeats do not activate the focused footer button", async () => {
  const { calls, root } = await mount();
  const button = root.querySelector<HTMLButtonElement>("button")!;
  button.focus();
  calls.length = 0;
  const repeat = enter(button, true);
  expect(repeat.defaultPrevented).toBe(true);
  expect(calls).toEqual([]);
});
