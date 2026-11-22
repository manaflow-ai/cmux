import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { emulateMedia } from "../src/gallery/frame/media";

const stylesheet = readFileSync(new URL("../src/pages/shared/desktop.css", import.meta.url), "utf8");

test("gallery contrast control applies stronger shared theme tokens", () => {
  for (const more of [false, true]) {
    const window = new Window();
    const scope = globalThis as Record<string, unknown>;
    const globals = {
      window,
      document: window.document,
      CSSMediaRule: window.CSSMediaRule,
      // happy-dom has no CSSImportRule; this sheet contains no @imports.
      CSSImportRule: class {},
      MutationObserver: window.MutationObserver,
    };
    const saved = Object.keys(globals).map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
    try {
      for (const [key, value] of Object.entries(globals))
        Object.defineProperty(scope, key, { configurable: true, writable: true, value });
      const root = window.document.documentElement;
      root.style.cssText =
        "--cmux-text: #ffffff; --cmux-text-secondary: #999999; --cmux-separator: #222222; --agent-text: #ffffff; --agent-border: #222222; --agent-muted: #999999; --cmux-diff-fg: #ffffff; --cmux-diff-border: #222222";
      const style = window.document.createElement("style");
      style.textContent = stylesheet;
      window.document.head.append(style);
      emulateMedia({
        "prefers-color-scheme": "dark",
        "prefers-reduced-motion": "no-preference",
        "prefers-contrast": more ? "more" : "no-preference",
      });
      const computed = window.getComputedStyle(root);
      for (const token of ["--cmux-separator", "--agent-border", "--cmux-diff-border"])
        expect(computed.getPropertyValue(token).trim()).toBe(more ? "#ffffff" : "#222222");
      for (const token of ["--cmux-text-secondary", "--agent-muted"])
        expect(computed.getPropertyValue(token).trim()).toBe(more ? "#ffffff" : "#999999");
      if (more) expect(computed.getPropertyValue("--cmux-focus-ring-width").trim()).toBe("2px");
    } finally {
      for (const [key, descriptor] of saved)
        if (descriptor) Object.defineProperty(scope, key, descriptor);
        else Reflect.deleteProperty(scope, key);
      void window.happyDOM.close();
    }
  }
});
