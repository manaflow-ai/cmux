// R82 commit 2: Spaces & Profiles and Machines are drawn by the page from the host lists
// (`cmux.settings.host.lists`, live through `cmux.settings.host.changed`), not an "open in
// window" link, and every browser profile edit runs its `browserProfile.*` action with the
// profile as the target.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

test("Spaces & Profiles lists the spaces and browser profiles, with no open-in-window link", async () => {
  const page = await renderPage({ path: "/settings/rooms" });
  const text = page.container.textContent ?? "";
  expect(text).toContain("Work");
  expect(text).toContain("Browser Profiles");
  expect(text).toContain("Google Chrome · Work");
  expect(text).not.toContain("Open in Window");
  expect(page.container.querySelectorAll("[data-host-row]").length).toBe(2);
  page.unmount();
});

test("Machines lists the saved machines; a host change updates the list without a reload", async () => {
  const page = await renderPage({ path: "/settings/machines" });
  expect(page.container.textContent).toContain("build-mac");
  await act(async () => {
    page.provider.setHost({ ...page.provider.host, machines: [] });
  });
  await settle();
  expect(page.container.textContent).toContain("No saved machines.");
  page.unmount();
});

test("browser profile edits run the profile's actions with its target", async () => {
  const page = await renderPage({ path: "/settings/rooms" });
  const row = page.container.querySelector<HTMLElement>('[data-profile="p-work"]')!;
  await act(async () => row.querySelector<HTMLButtonElement>(".host-toggle")!.click());
  await act(async () => row.querySelector<HTMLButtonElement>('[aria-label="grey"]')!.click());
  await settle();
  const run = page.provider.log.filter((entry) => entry.op === "cmux.app.action.run").at(-1)!;
  expect(run.params).toEqual({
    action: "browserProfile.setColor",
    args: { color: "grey" },
    target: "browser-profile:p-work",
  });
  expect(page.provider.host.browser_profiles.find((profile) => profile.id === "p-work")!.color).toBe("grey");

  await act(async () => page.container.querySelector<HTMLButtonElement>("[data-new-profile]")!.click());
  await settle();
  expect(page.container.querySelectorAll("[data-profile]").length).toBe(3);
  // The default profile offers no delete.
  const first = page.container.querySelector<HTMLElement>('[data-profile="p-default"]')!;
  await act(async () => first.querySelector<HTMLButtonElement>(".host-toggle")!.click());
  expect(first.querySelector("[data-delete-profile]")).toBeNull();
  page.unmount();
});
