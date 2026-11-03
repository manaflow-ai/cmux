import { afterEach, expect, test } from "bun:test";
import { naturalHeight } from "../src/ui/popupHost";

const original = globalThis.getComputedStyle;
afterEach(() => {
  globalThis.getComputedStyle = original;
});

for (const viewport of [168, 288]) {
  test(`a wrapped ${viewport}px row viewport counts shell padding once against its designed cap`, () => {
    const shell = {
      offsetHeight: viewport + 8,
      clientHeight: viewport + 8,
      scrollHeight: viewport + 8,
      classList: { contains: (name: string) => name === "ui-popup-scroll-shell" },
      querySelectorAll: () => [rows],
    } as unknown as HTMLElement;
    const rows = {
      clientHeight: viewport,
      scrollHeight: 800,
      parentElement: shell,
      classList: { contains: (name: string) => name === "ui-popup-scroll" },
    } as unknown as HTMLElement;
    globalThis.getComputedStyle = ((node: Element) => ({
      overflowY: node === rows ? "auto" : "visible",
      paddingTop: "4px",
      paddingBottom: "4px",
      getPropertyValue: () => "296px",
    })) as typeof getComputedStyle;
    expect(naturalHeight(shell)).toBe(296);
  });
}
