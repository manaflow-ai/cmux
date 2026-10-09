import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { act, useState } from "react";
import { usePopoverTrigger } from "../src/ui/popoverTrigger";
import { Popover } from "../src/ui/Popover";
import { UiProvider } from "../src/ui/UiProvider";
import { installDom, render, settle, unmount, restoreDom } from "./viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

// A composer popover as the pickers build it: a button with the shared trigger and the shared
// Popover holding its rows. Press-drag-release is the macOS menu gesture: press the button, drag to
// a row, release to pick it.
function Picker({ onPick }: { onPick(value: string): void }) {
  const [open, setOpen] = useState(false);
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const press = usePopoverTrigger(open, setOpen);
  return (
    <UiProvider container={document.body}>
      <button ref={setButton} type="button" aria-expanded={open} {...press}>
        Folder
      </button>
      <Popover open={open} onOpenChange={setOpen} anchor={button} label="Folder">
        {["one", "two"].map((value) => (
          <button
            key={value}
            type="button"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="option"
            aria-selected={false}
            onClick={() => {
              onPick(value);
              setOpen(false);
            }}
          >
            {value}
          </button>
        ))}
      </Popover>
    </UiProvider>
  );
}

function pointer(type: string, pointerId = 1, x = 0, y = 0): Event {
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.assign(event, { pointerId, pointerType: "mouse", button: 0, clientX: x, clientY: y });
  return event;
}

function mouseClick(target: Element) {
  target.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 1 }));
}

/** Runs `run` with `elementFromPoint` answering `element` (jsdom has no layout). */
async function over(element: Element, run: () => Promise<void>) {
  const previous = document.elementFromPoint;
  document.elementFromPoint = () => element;
  try {
    await run();
  } finally {
    document.elementFromPoint = previous;
  }
}

const rows = () => [...document.querySelectorAll<HTMLElement>('[role="option"]')];

describe("composer popover press-drag-release", () => {
  test("a press opens the popover before the release", async () => {
    const root = await render(<Picker onPick={() => {}} />);
    const trigger = root.querySelector("button")!;
    await act(async () => trigger.dispatchEvent(pointer("pointerdown", 3)));
    await settle();
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    expect(rows()).toHaveLength(2);
  });

  test("pressing the button, dragging onto a row and releasing picks the row and closes", async () => {
    const picked: string[] = [];
    const root = await render(<Picker onPick={(value) => picked.push(value)} />);
    const trigger = root.querySelector("button")!;
    await act(async () => trigger.dispatchEvent(pointer("pointerdown", 4, 10, 10)));
    await settle();
    const two = rows()[1]!;
    await over(two, async () => {
      await act(async () => trigger.dispatchEvent(pointer("pointermove", 4, 10, 60)));
      await act(async () => trigger.dispatchEvent(pointer("pointerup", 4, 10, 60)));
    });
    await settle();
    expect(picked).toEqual(["two"]);
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
  });

  test("a plain click opens it and keeps it open; the next click on a row picks", async () => {
    const picked: string[] = [];
    const root = await render(<Picker onPick={(value) => picked.push(value)} />);
    const trigger = root.querySelector("button")!;
    await over(trigger, async () => {
      await act(async () => {
        trigger.dispatchEvent(pointer("pointerdown", 5, 10, 10));
        trigger.dispatchEvent(pointer("pointerup", 5, 10, 10));
        mouseClick(trigger);
      });
    });
    await settle();
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    await act(async () => rows()[0]!.click());
    await settle();
    expect(picked).toEqual(["one"]);
  });

  test("pressing the button of an open popover closes it, and that click does not reopen it", async () => {
    const root = await render(<Picker onPick={() => {}} />);
    const trigger = root.querySelector("button")!;
    await over(trigger, async () => {
      await act(async () => {
        trigger.dispatchEvent(pointer("pointerdown", 6, 10, 10));
        trigger.dispatchEvent(pointer("pointerup", 6, 10, 10));
        mouseClick(trigger);
      });
      await settle();
      await act(async () => {
        trigger.dispatchEvent(pointer("pointerdown", 7, 10, 10));
        trigger.dispatchEvent(pointer("pointerup", 7, 10, 10));
        mouseClick(trigger);
      });
    });
    await settle();
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
  });

  test("a keyboard click toggles the popover", async () => {
    const root = await render(<Picker onPick={() => {}} />);
    const trigger = root.querySelector("button")!;
    await act(async () => trigger.click());
    await settle();
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    await act(async () => trigger.click());
    await settle();
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
  });
});
