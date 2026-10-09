import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { useState } from "react";
import { EffortPicker } from "../src/agent-session/acpmux/EffortPicker";
import { openPicker } from "../src/agent-session/acpmux/pickerOpeners";
import { UiProvider } from "../src/ui/UiProvider";
import { click, installDom, press, render, restoreDom, settle, unmount } from "./viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

test("selects an effort row and returns to the trigger after Escape", async () => {
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
