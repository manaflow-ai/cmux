import { afterAll, beforeAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { applySettingsTheme } from "./theme";

let restore: () => void;
beforeAll(() => {
  restore = installDom();
});
afterAll(() => restore());

test("applyTheme sets the AgentPaneTheme keys as CSS variables and ignores background keys", () => {
  const root = document.documentElement;
  applySettingsTheme({
    isDark: true,
    text: "rgba(1, 2, 3, 1)",
    border: "transparent",
    borders: "none",
    accentSoft: "rgba(4, 5, 6, 0.2)",
    inputBackground: "rgba(7, 8, 9, 0.1)",
    pageBackground: "rgba(9, 9, 9, 1)",
    motion: { hover: 0.12 },
  });
  expect(root.style.getPropertyValue("--text")).toBe("rgba(1, 2, 3, 1)");
  expect(root.style.getPropertyValue("--border")).toBe("transparent");
  expect(root.style.getPropertyValue("--accent-soft")).toBe("rgba(4, 5, 6, 0.2)");
  expect(root.style.getPropertyValue("--input-bg")).toBe("rgba(7, 8, 9, 0.1)");
  expect(root.style.getPropertyValue("--motion-hover")).toBe("120ms");
  expect(root.dataset.theme).toBe("dark");
  expect(root.dataset.borders).toBe("none");
  expect(root.getAttribute("style")).not.toContain("9, 9, 9");
  applySettingsTheme({ isDark: false });
  expect(root.style.getPropertyValue("--text")).toBe("");
  expect(root.dataset.borders).toBeUndefined();
});
