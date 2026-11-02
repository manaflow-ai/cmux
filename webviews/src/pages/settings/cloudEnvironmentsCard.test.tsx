// Settings > Accounts > Cloud Environments: the page reads the host's environments when the card
// opens, draws each with its localized status (a failed build with its log), and sends Add, Build,
// Delete and Refresh as `cmux.settings.environments.run`. Off the cmux-next Cloud path the card
// explains instead of listing.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { MockSettingsProvider } from "./mockProvider";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, click } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="cloudEnvironments"]')!;

async function open(setup?: (provider: MockSettingsProvider) => void) {
  const page = await renderPage({ path: "/settings/accounts", setup });
  await settle();
  return page;
}

test("the card lists each environment with its status and reads again when it opens", async () => {
  const page = await open();
  const element = card(page.container);
  expect(page.provider.environmentRuns[0]).toEqual({ action: "refresh" });
  const web = element.querySelector<HTMLElement>('[data-environment="env_00000000000000000001"]')!;
  expect(web.querySelector("[data-environment-status]")!.textContent).toContain("Ready");
  expect(web.textContent).toContain("manaflow-ai/cmux@feat-cmux-next");
  // A ready environment has nothing to build.
  expect(web.querySelector<HTMLButtonElement>('[data-environment-action="build"]')!.disabled).toBe(true);
  const api = element.querySelector<HTMLElement>('[data-environment="env_00000000000000000002"]')!;
  expect(api.querySelector("[data-environment-status]")!.textContent).toContain("Build failed");
  expect(api.textContent).toContain("setup exited 3");
  expect(api.querySelector("[data-environment-log]")!.textContent).toContain("lockfile mismatch");
  page.unmount();
});

test("Build and Delete send one run each and the list follows the host", async () => {
  const page = await open();
  const element = card(page.container);
  await click(
    element.querySelector<HTMLButtonElement>(
      '[data-environment="env_00000000000000000002"] [data-environment-action="build"]',
    )!,
  );
  await settle();
  expect(page.provider.environmentRuns).toContainEqual({ action: "build", id: "env_00000000000000000002" });
  expect(
    card(page.container).querySelector('[data-environment="env_00000000000000000002"] [data-environment-status]')!
      .textContent,
  ).toContain("Building");
  await click(
    card(page.container).querySelector<HTMLButtonElement>(
      '[data-environment="env_00000000000000000001"] [data-environment-action="delete"]',
    )!,
  );
  await settle();
  expect(page.provider.environmentRuns).toContainEqual({ action: "delete", id: "env_00000000000000000001" });
  expect(card(page.container).querySelector('[data-environment="env_00000000000000000001"]')).toBeNull();
  page.unmount();
});

test("Add Environment saves the typed name, repository and setup command", async () => {
  const page = await open();
  await click(card(page.container).querySelector<HTMLButtonElement>('[data-environments="add"]')!);
  const form = () => card(page.container).querySelector<HTMLElement>("[data-environments-form]")!;
  await changeValue(form().querySelector<HTMLInputElement>('[data-environment-field="name"]')!, "docs");
  await changeValue(form().querySelector<HTMLInputElement>('[data-environment-field="repo"]')!, "octo/docs");
  await changeValue(form().querySelector<HTMLInputElement>('[data-environment-field="setup"]')!, "npm ci");
  await click(form().querySelector<HTMLButtonElement>('[data-environments="save"]')!);
  await settle();
  expect(page.provider.environmentRuns).toContainEqual({
    action: "save",
    name: "docs",
    repo: "octo/docs",
    setup_script: "npm ci",
  });
  expect(card(page.container).textContent).toContain("docs");
  expect(card(page.container).querySelector("[data-environments-form]")).toBeNull();
  page.unmount();
});

test("off the cmux-next Cloud path the card explains and lists nothing", async () => {
  const page = await open((provider) => {
    provider.environments = { available: false, loading: false, environments: [], error: null };
  });
  const element = card(page.container);
  expect(element.querySelector("[data-environments-unavailable]")).not.toBeNull();
  expect(element.querySelector("[data-environment]")).toBeNull();
  await act(async () => {});
  page.unmount();
});
