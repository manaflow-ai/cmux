import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { useState } from "react";
import { click, installDom, press, render, restoreDom, settle, unmount } from "./viewer-empty-dom";

let EffortPicker: typeof import("../src/agent-session/acpmux/EffortPicker").EffortPicker;
let openPicker: typeof import("../src/agent-session/acpmux/pickerOpeners").openPicker;
let UiProvider: typeof import("../src/ui/UiProvider").UiProvider;

beforeAll(async () => {
  installDom();
  ({ EffortPicker } = await import("../src/agent-session/acpmux/EffortPicker"));
  ({ openPicker } = await import("../src/agent-session/acpmux/pickerOpeners"));
  ({ UiProvider } = await import("../src/ui/UiProvider"));
});
afterEach(unmount);
afterAll(restoreDom);

test("focuses the selected effort row and returns to the trigger after Escape", async () => {
  function Fixture() {
    const [current, setCurrent] = useState("medium");
    return (
      <UiProvider container={document.body}>
        <EffortPicker
          label="effort"
          efforts={[
            { id: "low", name: "Low" },
            { id: "medium", name: "Medium" },
            { id: "high", name: "High" },
          ]}
          current={current}
          onPick={setCurrent}
        />
      </UiProvider>
    );
  }
  const root = await render(<Fixture />);
  const trigger = root.querySelector<HTMLButtonElement>("button")!;
  await act(async () => expect(openPicker("effort")).toBe(true));
  await settle();
  const selected = document.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]')!;
  expect(selected.textContent).toContain("Medium");
  expect(document.activeElement).toBe(selected);
  const high = [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find((item) =>
    item.textContent?.includes("High"),
  )!;
  await click(high);
  await settle();
  expect(root.querySelector(".acpmux-picker-button > span")?.textContent).toBe("High");
  await act(async () => expect(openPicker("effort")).toBe(true));
  await settle();
  await press(document.activeElement!, "Escape");
  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(trigger);
});
