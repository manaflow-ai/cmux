import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { UiProvider } from "../../../ui/UiProvider";
import { OptionsMenu } from "./OptionsMenu";
import { act } from "react";
import { installDom, press, render, settle, unmount, restoreDom } from "../../../../test/viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

const rows = [
  { label: "Refresh changes", run: () => {} },
  { label: "Word wrap", run: () => {} },
  null,
  { label: "Copy git apply command", run: () => {} },
] as const;

function view() {
  return (
    <UiProvider container={document.body}>
      <OptionsMenu rows={[...rows]} />
    </UiProvider>
  );
}

describe("changes options menu keyboard contract", () => {
  test("opens on the trigger, moves with arrows and supports typeahead", async () => {
    const root = await render(view());
    const trigger = root.querySelector<HTMLButtonElement>("button.acpmux-diff-tool")!;
    await act(async () => trigger.click());
    await settle();
    const items = [...document.querySelectorAll<HTMLElement>("[role=menuitem]")];
    expect(items).toHaveLength(3);
    expect(document.activeElement).toBe(items[0]);
    await press(items[0], "ArrowDown");
    expect(document.activeElement).toBe(items[1]);
    await press(items[1], "r");
    expect(document.activeElement).toBe(items[0]);
  });

  test("Escape closes and restores focus to the trigger", async () => {
    const root = await render(view());
    const trigger = root.querySelector<HTMLButtonElement>("button.acpmux-diff-tool")!;
    await act(async () => trigger.click());
    await settle();
    const first = document.querySelector<HTMLElement>("[role=menuitem]")!;
    await press(first, "Escape");
    expect(document.querySelector("[role=menu]")).toBeNull();
    expect(document.activeElement).toBe(trigger);
  });

  test("restores trigger focus after an asynchronous copy action", async () => {
    let finish!: () => void;
    const root = await render(
      <UiProvider container={document.body}>
        <OptionsMenu
          rows={[{ label: "Copy git apply command", run: () => new Promise<void>((resolve) => (finish = resolve)) }]}
        />
      </UiProvider>,
    );
    const trigger = root.querySelector<HTMLButtonElement>("button.acpmux-diff-tool")!;
    await act(async () => trigger.click());
    await settle();
    await act(async () => document.querySelector<HTMLElement>("[role=menuitem]")!.click());
    const field = document.createElement("input");
    root.append(field);
    await act(async () => field.focus());
    await act(async () => finish());
    await settle();
    expect(document.activeElement).toBe(trigger);
  });
});
