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

test("General lists the spaces and Browser the browser profiles, with no open-in-window link", async () => {
  // The old section route (`#/settings/rooms`, `app settings rooms`) opens General.
  const page = await renderPage({ path: "/settings/rooms" });
  expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("general");
  expect(page.container.textContent).toContain("Work");
  expect(page.container.querySelectorAll('[data-card="rooms"] [data-host-row]').length).toBe(2);
  page.unmount();
  const browser = await renderPage({ path: "/settings/browser" });
  const text = browser.container.textContent ?? "";
  expect(text).toContain("Browser Profiles");
  expect(text).toContain("Google Chrome · Work");
  expect(text).not.toContain("Open in Window");
  browser.unmount();
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
  const page = await renderPage({ path: "/settings/browser" });
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

test("a space and a browser profile with a stored image or SVG icon draw it from the host's icon resource", async () => {
  // cx-qno.2.3: an `svg:`/`image:` asset ref draws as the host's PNG of it (`icon/<ref>`), never
  // as the ref's text.
  const asset = `svg:sha256-${"b".repeat(64)}`;
  const src = `icon/${encodeURIComponent(asset)}`;
  const general = await renderPage({ path: "/settings/rooms" });
  await act(async () => {
    const rooms = general.provider.host.rooms!.map((room, index) => (index === 0 ? { ...room, icon: asset } : room));
    general.provider.setHost({ ...general.provider.host, rooms });
  });
  await settle();
  const room = general.container.querySelector('[data-card="rooms"] [data-host-row]')!;
  expect(room.querySelector("img")?.getAttribute("src")).toBe(src);
  expect(room.textContent).not.toContain("svg:");
  general.unmount();

  const browser = await renderPage({ path: "/settings/browser" });
  await act(async () => {
    const profiles = browser.provider.host.browser_profiles.map((profile) =>
      profile.id === "p-work" ? { ...profile, icon: asset } : profile,
    );
    browser.provider.setHost({ ...browser.provider.host, browser_profiles: profiles });
  });
  await settle();
  const avatar = browser.container.querySelector('[data-profile="p-work"] .host-avatar')!;
  expect(avatar.querySelector("img")?.getAttribute("src")).toBe(src);
  expect(avatar.textContent).toBe("");
  browser.unmount();
});

test("Development shows only when the host is a DEV build, however it is reached", async () => {
  const dev = await renderPage({ path: "/settings/development" });
  expect(dev.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("development");
  expect(dev.container.querySelector('[data-row-key="macScreen.debug.relayOnly"]')).not.toBeNull();
  expect(dev.container.querySelector('[data-section-link="development"]')).not.toBeNull();
  dev.unmount();
  // NIGHTLY and Release: the deep link (and the relay key's focus link) open the default page.
  for (const path of ["/settings/development", "/settings/development?focus=macScreen.debug.relayOnly"]) {
    const page = await renderPage({
      path,
      setup: (provider) => provider.setHost({ ...provider.host, dev_build: false }),
    });
    expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("general");
    expect(page.container.querySelector('[data-row-key="macScreen.debug.relayOnly"]')).toBeNull();
    expect(page.container.querySelector('[data-section-link="development"]')).toBeNull();
    page.unmount();
  }
});
