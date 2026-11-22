import { afterEach, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { readFileSync } from "node:fs";

const original = Object.getOwnPropertyDescriptor(globalThis, "document");
afterEach(() => {
  if (original) Object.defineProperty(globalThis, "document", original);
  else Reflect.deleteProperty(globalThis, "document");
});

// No-flicker audit: a screenshot is a data URL the page still decodes after the detail view
// paints. Its row keeps its height from the first frame, so the sections below never jump.
test("an app's screenshot reserves its row height before it decodes", () => {
  const window = new Window();
  Object.defineProperty(globalThis, "document", { configurable: true, value: window.document });
  const style = window.document.createElement("style");
  style.textContent = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
  window.document.head.append(style);
  window.document.body.innerHTML = '<div class="apps-screenshots"><img class="apps-screenshot" alt="" /></div>';
  const shot = window.getComputedStyle(window.document.querySelector(".apps-screenshot")!);
  expect(shot.height).toBe("220px");
  expect(shot.objectFit).toBe("contain");
});
