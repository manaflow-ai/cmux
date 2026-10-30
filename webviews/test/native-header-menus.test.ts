import { expect, test } from "bun:test";
import {
  nativeChatMenu,
  nativeCustomizeMenu,
  nativeMenuText,
} from "../src/agent-session/acpmux/header/nativeMenuBindings";
import { dispatchNativeRowTool } from "../src/agent-session/acpmux/header/nativeRowTools";

test("native chat rows retain groups, children and disabled selection", () => {
  const invoked: string[] = [];
  const menu = nativeChatMenu([
    { key: "rename", label: "Rename", icon: "edit", onSelect: () => invoked.push("rename") },
    "separator",
    {
      key: "continue",
      label: "Continue In",
      icon: "next",
      children: [{ key: "claude", label: "Claude Code", onSelect: () => invoked.push("claude") }],
    },
    { key: "disabled", label: "Disabled", icon: "x", disabled: true, onSelect: () => invoked.push("disabled") },
  ])!;
  expect(menu.items[1].separatorBefore).toBe(true);
  expect(menu.items[1].children?.[0].label).toBe("Claude Code");
  menu.invoke("rename");
  menu.invoke("continue/claude");
  menu.invoke("disabled");
  menu.invoke("unknown");
  expect(invoked).toEqual(["rename", "claude"]);
});

test("native customization invokes the shared callback with checked and disabled states", () => {
  const invoked: string[] = [];
  const menu = nativeCustomizeMenu([
    {
      id: "open",
      label: "Click Opens Another",
      checked: true,
      separatorBefore: true,
      onSelect: () => invoked.push("open"),
    },
    { id: "hide", label: "Hide Terminal", disabled: true, onSelect: () => invoked.push("hide") },
  ]);
  const binding = {
    tool: {
      id: "terminal",
      symbol: "terminal",
      label: "Terminal",
      enabled: true,
      toggled: false,
      contextMenu: menu.items,
    },
    runMenu: menu.invoke,
    run: () => invoked.push("terminal"),
  };
  expect(menu.items[0]).toMatchObject({ checked: true, separatorBefore: true });
  dispatchNativeRowTool({ id: "terminal", menuItemId: "context:open" }, [binding]);
  dispatchNativeRowTool({ id: "terminal", menuItemId: "context:hide" }, [binding]);
  dispatchNativeRowTool({ id: "terminal", menuItemId: "unknown" }, [binding]);
  expect(invoked).toEqual(["open"]);
});

test("native menu text is bounded by both graphemes and encoded bytes", () => {
  expect(nativeMenuText("x".repeat(100))).toHaveLength(64);
  expect(nativeMenuText("a" + "\u0301".repeat(5000))).toBe("…");
  expect(new TextEncoder().encode(nativeMenuText("🐈".repeat(100))).length).toBeLessThanOrEqual(256);
});

test("menus exceeding native bounds retain the complete DOM fallback", () => {
  const row = (key: string) => ({ key, label: key, icon: "edit", onSelect() {} });
  expect(nativeChatMenu(Array.from({ length: 33 }, (_, index) => row(String(index))))).toBeUndefined();
  expect(nativeChatMenu([row("x".repeat(65))])).toBeUndefined();
  expect(
    nativeChatMenu(
      Array.from({ length: 9 }, (_, index) => ({
        ...row(String(index)),
        children: Array.from({ length: 32 }, (_, child) => row(String(child))),
      })),
    ),
  ).toBeUndefined();
});
