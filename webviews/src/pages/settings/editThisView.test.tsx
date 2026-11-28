// Edit this view (wow-20 idea 16, Labs: labs.editThisView): with the switch on, every section's
// title carries a button that opens the Customize chat on that section's source and the live page.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage, settle } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const button = (page: Rendered) => page.container.querySelector<HTMLElement>("[data-edit-this-view]");

test("Edit this view stays hidden while labs.editThisView is off, the default", async () => {
  page = await renderPage({ path: "/settings/updates" });
  await settle();
  expect(page.container.querySelector(".section-title")).not.toBeNull();
  expect(button(page)).toBeNull();
  expect(page.container.querySelector(".section-head")).toBeNull();
});

test("Edit this view opens the Customize chat naming the section, its source and cmux live start", async () => {
  page = await renderPage({ path: "/settings/updates", mock: { values: { "labs.editThisView": true } } });
  await settle();
  const edit = button(page)!;
  expect(edit).not.toBeNull();
  expect(edit.textContent).toBe("Edit this view");
  expect(page.container.querySelector('[data-section="updates"] .section-head .section-title')?.textContent).toBe("Updates");
  await click(edit);
  expect(page.provider.actionsRun).toEqual([
    {
      action: "customize.open",
      args: {
        draft: "/customize edit the Settings › Updates view (webviews/src/pages/settings, section updates; cmux live start, then Keep or Revert)",
      },
    },
  ]);
});
