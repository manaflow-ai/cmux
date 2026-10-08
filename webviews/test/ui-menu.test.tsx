import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { act } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup, Submenu } from "../src/ui/Menu";
import { Select } from "../src/ui/Select";
import { UiProvider } from "../src/ui/UiProvider";
import { installDom, render, settle, unmount, press, restoreDom } from "./viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

function pointer(type: string, pointerId = 1, x = 0, y = 0): Event {
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.assign(event, { pointerId, pointerType: "mouse", button: 0, clientX: x, clientY: y });
  return event;
}

function menu(onSelect: (value: string) => void) {
  return (
    <UiProvider container={document.body}>
      <Menu>
        <MenuButton label="Actions">Actions</MenuButton>
        <MenuPopup>
          <MenuItem onSelect={() => onSelect("one")}>One</MenuItem>
          <MenuItem onSelect={() => onSelect("two")}>Two</MenuItem>
        </MenuPopup>
      </Menu>
    </UiProvider>
  );
}

describe("shared menu pointer contract", () => {
  test("opens on press, highlights and selects on drag release", async () => {
    const chosen: string[] = [];
    const root = await render(menu((value) => chosen.push(value)));
    const trigger = root.querySelector<HTMLButtonElement>("button")!;
    await act(async () => trigger.dispatchEvent(pointer("pointerdown", 7, 10, 10)));
    await settle();
    const rows = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
    expect(rows).toHaveLength(2);
    const previous = document.elementFromPoint;
    document.elementFromPoint = () => rows[1]!;
    await act(async () => trigger.dispatchEvent(pointer("pointermove", 7, 30, 30)));
    await act(async () => trigger.dispatchEvent(pointer("pointerup", 7, 30, 30)));
    document.elementFromPoint = previous;
    await settle();
    expect(chosen).toEqual(["two"]);
    expect(document.querySelector('[role="menu"]')).toBeNull();
  });

  test("a trigger click leaves the menu open and the next click selects", async () => {
    const chosen: string[] = [];
    const root = await render(menu((value) => chosen.push(value)));
    const trigger = root.querySelector<HTMLButtonElement>("button")!;
    await act(async () => {
      trigger.dispatchEvent(pointer("pointerdown", 8));
      trigger.dispatchEvent(pointer("pointerup", 8));
    });
    await settle();
    const row = document.querySelector<HTMLElement>('[role="menuitem"]')!;
    await act(async () => row.click());
    await settle();
    expect(chosen).toEqual(["one"]);
  });

  test("Escape closes and returns focus to the trigger", async () => {
    const root = await render(menu(() => {}));
    const trigger = root.querySelector<HTMLButtonElement>("button")!;
    await act(async () => trigger.dispatchEvent(pointer("pointerdown", 9)));
    await settle();
    const row = document.querySelector<HTMLElement>('[role="menuitem"]')!;
    await act(async () => row.focus());
    await press(row, "Escape");
    expect(document.querySelector('[role="menu"]')).toBeNull();
    expect(document.activeElement).toBe(trigger);
  });
});

test("Select exposes one shared menu and reports the chosen value", async () => {
  const chosen: string[] = [];
  const root = await render(
    <UiProvider container={document.body}>
      <Select
        label="Theme"
        value="dark"
        options={[
          { value: "dark", label: "Dark" },
          { value: "light", label: "Light" },
        ]}
        onChange={(value) => chosen.push(value)}
      />
    </UiProvider>,
  );
  await act(async () => root.querySelector("button")!.click());
  await settle();
  const light = [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find((item) =>
    item.textContent?.includes("Light"),
  )!;
  await act(async () => light.click());
  expect(chosen).toEqual(["light"]);
});

test("submenu opens from the keyboard and closes back through Escape", async () => {
  const root = await render(
    <UiProvider container={document.body}>
      <Menu>
        <MenuButton label="Actions">Actions</MenuButton>
        <MenuPopup>
          <Submenu label="Share">
            <MenuItem onSelect={() => {}}>Copy link</MenuItem>
          </Submenu>
        </MenuPopup>
      </Menu>
    </UiProvider>,
  );
  await act(async () => root.querySelector("button")!.click());
  await settle();
  const share = document.querySelector<HTMLElement>('[role="menuitem"]')!;
  await press(share, "ArrowRight");
  await settle();
  expect([...document.querySelectorAll('[role="menu"]')].length).toBe(2);
  await press(document.querySelectorAll('[role="menu"]')[1]!, "Escape");
  expect([...document.querySelectorAll('[role="menu"]')].length).toBe(1);
});
