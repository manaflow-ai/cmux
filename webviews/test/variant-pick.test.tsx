import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { installDom, press, render, restoreDom, unmount } from "./viewer-empty-dom";
import { VariantPick } from "../src/ui/variant-pick/VariantPick";
import { moveVariant } from "../src/ui/variant-pick/model";
import { UiProvider } from "../src/ui/UiProvider";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);
const ids = ["a", "b", "c", "d"];
const options = ids.map((id) => ({ id, label: id.toUpperCase() }));

test("pure navigation wraps, handles missing options, home/end and RTL", () => {
  expect(moveVariant(ids, "a", "ArrowLeft")).toBe("d");
  expect(moveVariant(ids, "d", "ArrowRight")).toBe("a");
  expect(moveVariant(ids, "b", "ArrowRight", "rtl")).toBe("a");
  expect(moveVariant(ids, "b", "ArrowDown", "rtl")).toBe("c");
  expect(moveVariant(ids, "b", "Home")).toBe("a");
  expect(moveVariant(ids, "b", "End")).toBe("d");
  expect(moveVariant(ids, "removed", "ArrowRight")).toBe("a");
  expect(moveVariant([], "a", "ArrowRight")).toBeNull();
  expect(moveVariant(ids, "b", "Escape")).toBe("b");
});

test("arrows move focus without picking; Return picks once; click uses the same callback", async () => {
  const picked: string[] = [];
  const root = await render(
    <VariantPick
      options={options}
      recommendedId="b"
      currentPick="c"
      onPick={(id) => {
        picked.push(id);
      }}
    />,
  );
  const buttons = [...root.querySelectorAll("button")];
  expect(buttons.map((button) => button.tabIndex)).toEqual([-1, -1, 0, -1]);
  act(() => buttons[2]!.focus());
  await press(buttons[2]!, "ArrowRight");
  expect(document.activeElement === buttons[3]).toBe(true);
  expect(picked).toEqual([]);
  await press(buttons[3]!, "Enter");
  expect(picked).toEqual(["d"]);
  await act(async () => buttons[0]!.click());
  expect(picked).toEqual(["d", "a"]);
  expect(buttons[1]!.getAttribute("aria-label")).toContain("Recommended");
  expect(buttons[2]!.getAttribute("aria-pressed")).toBe("true");
});

test("RTL keys follow direction; shortcuts and preview keys are untouched", async () => {
  const picked: string[] = [];
  const root = await render(
    <UiProvider container={null} dir="rtl">
      <VariantPick
        options={options.map((option) => ({ ...option, preview: <input aria-label={option.label} /> }))}
        recommendedId="b"
        currentPick={null}
        onPick={(id) => {
          picked.push(id);
        }}
      />
    </UiProvider>,
  );
  const buttons = [...root.querySelectorAll("button")];
  act(() => buttons[0]!.focus());
  await press(buttons[0]!, "ArrowRight");
  expect(document.activeElement === buttons[3]).toBe(true);
  await press(buttons[3]!, "Enter", { metaKey: true });
  const input = root.querySelector("input")!;
  act(() => input.focus());
  await press(input, "ArrowDown");
  await press(input, "Enter");
  expect(document.activeElement === input).toBe(true);
  expect(picked).toEqual([]);
});

test("pending work blocks duplicate picks; failures leave the saved choice intact", async () => {
  let reject!: (error: Error) => void;
  let count = 0;
  const root = await render(
    <VariantPick
      options={options}
      currentPick="a"
      onPick={() => {
        count++;
        return new Promise<void>((_resolve, fail) => {
          reject = fail;
        });
      }}
    />,
  );
  const buttons = [...root.querySelectorAll("button")];
  await act(async () => {
    buttons[1]!.click();
    buttons[2]!.click();
  });
  await press(buttons[1]!, "Enter");
  expect(count).toBe(1);
  expect(root.querySelector('[aria-busy="true"]') !== null).toBe(true);
  await act(async () => reject(new Error("network")));
  expect(root.querySelector("output")!.textContent).toContain("Check the tracker");
  expect(buttons[0]!.getAttribute("aria-pressed")).toBe("true");
});
