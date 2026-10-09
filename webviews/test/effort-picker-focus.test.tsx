import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { EffortPicker } from "../src/agent-session/acpmux/EffortPicker";
import { click, installDom, render, restoreDom, settle, unmount } from "./viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

test("focuses the effort slider after its anchored menu becomes visible", async () => {
  const inputPrototype = window.HTMLInputElement.prototype;
  const originalFocus = inputPrototype.focus;
  const focusVisibility: string[] = [];
  inputPrototype.focus = function focus(options?: FocusOptions) {
    const menu = this.closest<HTMLElement>(".acpmux-effort-pop");
    const visibility = menu?.style.visibility ?? "missing";
    focusVisibility.push(visibility);
    if (visibility === "hidden") return;
    originalFocus.call(this, options);
  };
  try {
    const root = await render(
      <EffortPicker
        label="effort"
        efforts={[
          { id: "low", name: "Low" },
          { id: "medium", name: "Medium" },
          { id: "high", name: "High" },
        ]}
        current="medium"
        onPick={() => {}}
      />,
    );
    await click(root.querySelector<HTMLButtonElement>("button")!);
    await settle();
    const range = document.querySelector<HTMLInputElement>(".acpmux-effort-range")!;
    expect(focusVisibility).toContain("visible");
    expect(focusVisibility).not.toContain("hidden");
    expect(document.activeElement).toBe(range);
  } finally {
    inputPrototype.focus = originalFocus;
  }
});
