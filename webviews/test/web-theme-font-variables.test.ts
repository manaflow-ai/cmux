// WebTheme.bootstrapScript registers each color variable as a `<color>` so theme changes transition.
// The font variables (`--cmux-font-ui`, `--cmux-font-code`, `--cmux-font-chat-size`) are `initial`
// when unset, and `CSS.supports('color', 'initial')` is true in WebKit and Chromium: registering
// them as `<color>` made `var(--cmux-font-*, <page default>)` resolve to `transparent` instead of
// the page's own face and size, and froze them against any later font setting until a reload.
import { expect, test } from "bun:test";
import vm from "node:vm";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";

const CSS_WIDE = new Set(["initial", "inherit", "unset", "revert", "revert-layer"]);

function page() {
  const registered: string[] = [];
  const set: Record<string, string> = {};
  const element = () => ({ id: "", textContent: "", appendChild() {} });
  const root = {
    style: { setProperty: (name: string, value: string) => void (set[name] = value), colorScheme: "" },
    setAttribute() {},
    getAnimations: () => [],
  };
  const context: Record<string, unknown> = {
    document: { documentElement: root, head: element(), createElement: element },
    // A browser's answer: CSS-wide keywords are valid for every property, colors for `color`.
    CSS: {
      supports: (property: string, value: string) =>
        property === "color" && (CSS_WIDE.has(value.trim()) || /^(#|rgba?\()/.test(value)),
      registerProperty: ({ name }: { name: string }) => void registered.push(name),
    },
    getComputedStyle: () => ({ getPropertyValue: () => "" }),
    CustomEvent: class {
      constructor(
        public type: string,
        public init: unknown,
      ) {}
    },
    dispatchEvent() {},
  };
  context.window = context;
  vm.runInNewContext(readWebThemeBootstrap(), context);
  const apply = (variables: Record<string, string>) =>
    (context.cmuxTheme as { apply(payload: unknown): void }).apply({ variables, colorScheme: "dark" });
  return { apply, registered, set };
}

test("unset font variables are never registered as colors, so pages keep their own face and size", () => {
  const { apply, registered, set } = page();
  apply({
    "--cmux-surface-background": "#101010",
    "--cmux-font-ui": "initial",
    "--cmux-font-code": "initial",
    "--cmux-font-chat-size": "initial",
  });
  expect(registered).toEqual(["--cmux-surface-background"]);
  expect(set["--cmux-font-chat-size"]).toBe("initial");

  // A font picked later still lands as the page's value.
  apply({ "--cmux-surface-background": "#101010", "--cmux-font-ui": "ui-serif", "--cmux-font-chat-size": "18px" });
  expect(registered).toEqual(["--cmux-surface-background"]);
  expect(set["--cmux-font-ui"]).toBe("ui-serif");
  expect(set["--cmux-font-chat-size"]).toBe("18px");
});
