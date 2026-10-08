import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { act, useState } from "react";
import { FileMenu } from "../src/agent-session/acpmux/changes/FileMenu";
import { ScopeMenu } from "../src/agent-session/acpmux/changes/ScopeMenu";
import type { ChangeScope } from "../src/agent-session/acpmux/changes/model";
import { UiProvider } from "../src/ui/UiProvider";
import { click, installDom, press, render, restoreDom, settle, unmount } from "./viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

function FileFixture({ onOpen = () => {} }: { onOpen?: () => void }) {
  return (
    <UiProvider container={document.body}>
      <FileMenu path="src/app.ts" name="app.ts" collapsed={false} onToggleCollapsed={() => {}} onOpenInTab={onOpen} />
      <input aria-label="Next field" />
    </UiProvider>
  );
}
function ScopeFixture({ onScope = (_scope: ChangeScope) => {} }: { onScope?: (scope: ChangeScope) => void }) {
  const [scope, setScope] = useState<ChangeScope>("staged");
  return (
    <UiProvider container={document.body}>
      <ScopeMenu
        scope={scope}
        onScope={(next) => {
          setScope(next);
          onScope(next);
        }}
      />
    </UiProvider>
  );
}
const items = () => [...document.querySelectorAll<HTMLElement>('[role^="menuitem"]')];
const focused = () => document.activeElement?.textContent?.replace("✓", "").trim();

describe("Changes file menu", () => {
  test("ArrowDown opens the file actions and typeahead runs Open file in a tab", async () => {
    let opens = 0;
    const root = await render(
      <FileFixture
        onOpen={() => {
          opens += 1;
        }}
      />,
    );
    const trigger = root.querySelector<HTMLButtonElement>("button")!;
    await act(async () => trigger.focus());
    await press(trigger, "ArrowDown");
    expect(items()).toHaveLength(3);
    expect(focused()).toBe("Copy path");
    await press(document.activeElement!, "o");
    expect(focused()).toBe("Open file in a tab");
    await press(document.activeElement!, "Enter");
    expect(opens).toBe(1);
    expect(document.querySelector('[role="menu"]')).toBeNull();
    expect(document.activeElement === trigger).toBe(true);
  });
  test("a delayed clipboard completion does not take focus from the next field", async () => {
    let finish!: () => void;
    const copied: string[] = [];
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: (text: string) => {
          copied.push(text);
          return new Promise<void>((resolve) => {
            finish = resolve;
          });
        },
      },
    });
    try {
      const root = await render(<FileFixture />);
      await click(root.querySelector("button")!);
      await click(items()[0]!);
      const field = root.querySelector("input")!;
      await act(async () => field.focus());
      await act(async () => finish());
      await settle();
      expect(copied).toEqual(["src/app.ts"]);
      expect(document.activeElement === field).toBe(true);
    } finally {
      Reflect.deleteProperty(navigator, "clipboard");
    }
  });
  test("Escape closes only the menu and restores the file trigger", async () => {
    let escaped = 0;
    const root = await render(
      <div
        onKeyDown={(event) => {
          if (event.key === "Escape") escaped += 1;
        }}
      >
        <FileFixture />
      </div>,
    );
    const trigger = root.querySelector<HTMLButtonElement>("button")!;
    await click(trigger);
    await press(document.activeElement!, "Escape");
    expect(document.querySelector('[role="menu"]')).toBeNull();
    expect(document.activeElement === trigger).toBe(true);
    expect(escaped).toBe(0);
  });
});
describe("Changes scope menu", () => {
  test("opens on the selected scope, typeahead finds Branch, and selection closes", async () => {
    const selected: ChangeScope[] = [];
    const root = await render(<ScopeFixture onScope={(scope) => selected.push(scope)} />);
    const trigger = root.querySelector<HTMLButtonElement>("button")!;
    await act(async () => trigger.focus());
    await press(trigger, "ArrowDown");
    expect(document.activeElement?.getAttribute("aria-checked")).toBe("true");
    expect(focused()).toBe("Staged");
    await press(document.activeElement!, "b");
    expect(focused()).toBe("Branch");
    await press(document.activeElement!, "Enter");
    expect(selected).toEqual(["branch"]);
    expect(document.querySelector('[role="menu"]')).toBeNull();
    expect(document.activeElement === trigger).toBe(true);
  });
  test("choosing the current scope closes and keeps the current choice", async () => {
    const root = await render(<ScopeFixture />);
    const trigger = root.querySelector<HTMLButtonElement>("button")!;
    await click(trigger);
    expect(document.activeElement?.getAttribute("aria-checked")).toBe("true");
    await click(document.activeElement!);
    expect(document.querySelector('[role="menu"]')).toBeNull();
    expect(document.activeElement === trigger).toBe(true);
    expect(trigger.textContent).toContain("Staged");
  });
});
