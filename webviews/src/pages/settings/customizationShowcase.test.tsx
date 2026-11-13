import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage } = await import("./testing");

let page: Awaited<ReturnType<typeof renderPage>> | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

test("Customize > Examples copies a real template install command", async () => {
  page = await renderPage({ path: "/settings/customize" });
  const button = [...page.container.querySelectorAll<HTMLButtonElement>("button")].find(
    (candidate) => candidate.textContent === "Copy install command",
  );
  expect(button).toBeDefined();
  await click(button!);
  const copied = ops(page.provider, "cmux.app.clipboard.write")[0] as { text: string };
  expect(copied.text).toContain("raw.githubusercontent.com/manaflow-ai/cmux");
  expect(page.provider.clipboard).toContain("~/.config/cmux/customize/main.js");
});

test("Customize > Examples installs packaged apps through the non-Labs action", async () => {
  page = await renderPage({ path: "/settings/customize" });
  const button = [...page.container.querySelectorAll<HTMLButtonElement>("button")].find(
    (candidate) => candidate.textContent === "Install",
  );
  expect(button).toBeDefined();
  await click(button!);
  expect(ops(page.provider, "cmux.app.action.run")).toContainEqual({
    action: "app.install",
    args: { app: "manaflow-ai/quick-links" },
  });
});
