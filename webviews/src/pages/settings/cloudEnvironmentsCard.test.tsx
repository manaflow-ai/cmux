// Settings > Cloud > Cloud Environments (#47676): the page lists the account's Cloud environments through
// `cmux.settings.cloud_environment` (the composer's editor requests, served by the platform), the Default
// first, and opens each in the shared editor; a save sends only what changed and the list follows. Add
// Environment creates one by name and opens it. With Cloud off or signed out the card explains instead.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { MockSettingsProvider } from "./mockProvider";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, click } = await import("./testing");
const { mockDefaultEnvironment, mockTeamEnvironment } = await import("./mockCloudEnvironments");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="cloudEnvironments"]')!;
const methods = (provider: MockSettingsProvider) => provider.cloudEnvironments.calls.map((call) => call.method);
// The sheet's footer: Cancel and the primary Save (each also draws its key hint, so match by role, not text).
const sheetSave = () => document.querySelector<HTMLButtonElement>(".env-actions .env-primary")!;
const sheetCancel = () => document.querySelector<HTMLButtonElement>(".env-actions .env-button:not(.env-primary)")!;

async function open(setup?: (provider: MockSettingsProvider) => void) {
  const page = await renderPage({ path: "/settings/cloud", setup });
  await settle();
  return page;
}

test("the card lists the Default first, marked, then the team's environments", async () => {
  const page = await open();
  expect(methods(page.provider)).toEqual(["cloud.environment.list"]);
  const rows = Array.from(card(page.container).querySelectorAll<HTMLElement>("[data-environment]"));
  expect(rows.map((row) => row.dataset.environment)).toEqual([mockDefaultEnvironment.id, mockTeamEnvironment.id]);
  expect(rows[0]!.querySelector('[data-environment-badge="default"]')!.textContent).toContain("Default");
  expect(rows[0]!.querySelector("[data-environment-details]")!.textContent).toBe(
    "Personal · Setup worked out per repository",
  );
  expect(rows[1]!.querySelector('[data-environment-badge="default"]')).toBeNull();
  expect(rows[1]!.querySelector("[data-environment-details]")!.textContent).toBe("Team · Custom setup script");
  page.unmount();
});

test("Edit on the Default opens the editor, and Save sends only the changed setup script", async () => {
  const page = await open();
  await click(
    card(page.container).querySelector<HTMLButtonElement>(
      `[data-environment="${mockDefaultEnvironment.id}"] [data-environment-action="edit"]`,
    )!,
  );
  await settle();
  expect(page.provider.cloudEnvironments.calls.at(-1)).toEqual({
    method: "cloud.environment.get",
    params: { id: mockDefaultEnvironment.id },
  });
  // The Default keeps its name.
  expect(document.querySelector<HTMLInputElement>(".env-field input")!.readOnly).toBe(true);
  await click(document.querySelectorAll<HTMLButtonElement>(".env-drill")[2]!);
  await changeValue(document.querySelector<HTMLTextAreaElement>(".env-code textarea")!, "pnpm install\n");
  await click(sheetSave());
  await settle();
  expect(page.provider.cloudEnvironments.calls).toContainEqual({
    method: "cloud.environment.update",
    params: { id: mockDefaultEnvironment.id, patch: { setup_script: "pnpm install\n" } },
  });
  // Saved: the editor closed and the list was read again, now with the Default's own script.
  expect(document.querySelector(".env-code textarea")).toBeNull();
  expect(methods(page.provider).at(-1)).toBe("cloud.environment.list");
  expect(
    card(page.container).querySelector(`[data-environment="${mockDefaultEnvironment.id}"] [data-environment-details]`)!
      .textContent,
  ).toBe("Personal · Custom setup script");
  page.unmount();
});

test("Add Environment creates one by name, opens it, and lists it when the editor closes", async () => {
  const page = await open();
  await click(card(page.container).querySelector<HTMLButtonElement>('[data-environments="add"]')!);
  const form = () => card(page.container).querySelector<HTMLElement>('[data-environments-form="new"]');
  expect(form()!.querySelector<HTMLButtonElement>('[data-environments="create"]')!.disabled).toBe(true);
  await changeValue(form()!.querySelector<HTMLInputElement>('[data-environment-field="name"]')!, "  docs ");
  await click(form()!.querySelector<HTMLButtonElement>('[data-environments="create"]')!);
  await settle();
  expect(page.provider.cloudEnvironments.calls).toContainEqual({
    method: "cloud.environment.create",
    params: { environment: { name: "docs", setup_script: null } },
  });
  expect(form()).toBeNull();
  // The editor is open on the new environment, its name editable.
  expect(document.querySelector<HTMLInputElement>(".env-field input")!.value).toBe("docs");
  await click(sheetCancel());
  await settle();
  const names = Array.from(card(page.container).querySelectorAll("[data-environment] .row-title")).map(
    (title) => title.firstChild?.textContent,
  );
  expect(names).toContain("docs");
  page.unmount();
});

test("with Cloud off or signed out the card explains instead of listing", async () => {
  const page = await open((provider) => {
    provider.cloudEnvironments.disabled = true;
  });
  expect(card(page.container).querySelector("[data-environments-unavailable]")).not.toBeNull();
  expect(card(page.container).querySelector('[data-environments="add"]')).toBeNull();
  // Signed in again: Refresh lists without leaving the page.
  page.provider.cloudEnvironments.disabled = false;
  await click(card(page.container).querySelector<HTMLButtonElement>('[data-environments="refresh"]')!);
  await settle();
  expect(card(page.container).querySelectorAll("[data-environment]")).toHaveLength(2);
  page.unmount();
});

test("a failed read says so, and Refresh reads again", async () => {
  const page = await open((provider) => {
    provider.cloudEnvironments.environments = [];
  });
  expect(card(page.container).querySelector("[data-environments-empty]")).not.toBeNull();
  page.provider.cloudEnvironments.run = () => {
    throw Object.assign(new Error("down"), { code: "cloud_environment.unavailable" });
  };
  await act(async () => {
    card(page.container).querySelector<HTMLButtonElement>('[data-environments="refresh"]')!.click();
  });
  await settle();
  expect(card(page.container).querySelector("[data-environments-error]")!.textContent).toBe(
    "Couldn't read your Cloud environments. Try Refresh.",
  );
  page.unmount();
});

test("an older list reply that lands after a newer one does not overwrite it", async () => {
  const page = await open();
  await click(
    card(page.container).querySelector<HTMLButtonElement>(
      `[data-environment="${mockDefaultEnvironment.id}"] [data-environment-action="edit"]`,
    )!,
  );
  await settle();
  // The read the editor's close starts stalls and answers a stale, empty list; Refresh's answers at once.
  let answerStale: (rows: unknown) => void = () => {};
  let reads = 0;
  const fresh = page.provider.cloudEnvironments.run.bind(page.provider.cloudEnvironments);
  page.provider.cloudEnvironments.run = (call) => {
    if (call.method === "cloud.environment.list" && reads++ === 0)
      return new Promise((resolve) => {
        answerStale = resolve;
      });
    return fresh(call);
  };
  await click(sheetCancel());
  await settle();
  await click(card(page.container).querySelector<HTMLButtonElement>('[data-environments="refresh"]')!);
  await settle();
  expect(reads).toBe(2);
  expect(card(page.container).querySelectorAll("[data-environment]")).toHaveLength(2);
  await act(async () => {
    answerStale([]);
  });
  await settle();
  expect(card(page.container).querySelector("[data-environments-empty]")).toBeNull();
  expect(card(page.container).querySelectorAll("[data-environment]")).toHaveLength(2);
  page.unmount();
});
