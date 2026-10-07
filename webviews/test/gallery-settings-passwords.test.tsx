// Gallery fixture gestures exercised against the real React pages in jsdom. No browser process.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import settings from "../src/pages/settings/settings.gallery";
import passwords from "../src/pages/passwords/passwords.gallery";
import { installDom } from "../src/pages/settings/testDom";
import { schema, rowsInSection, sections } from "../src/pages/settings/schema";
import { mockDomains } from "../src/pages/settings/mockProvider";
import { validate } from "../src/pages/settings/validate";
import { sectionHref } from "../src/pages/settings/router";
import { fixtureSteps } from "../src/gallery/frame/settingsPasswords";

const restore = installDom();
const savedSelect = globalThis.HTMLSelectElement;
globalThis.HTMLSelectElement = window.HTMLSelectElement;
const { renderPage, settle, run } = await import("../src/pages/settings/testing");
afterAll(() => {
  globalThis.HTMLSelectElement = savedSelect;
  restore();
});

test("customized fixtures provide valid values for every visible settings control", () => {
  const values = settings.variants["general-customized"]!.options!.values!;
  for (const row of schema.rows) expect(validate(row, values[row.key], mockDomains), row.key).toBeNull();
});

for (const [name, state] of Object.entries(settings.variants)) {
  // Pending transport is exercised by the page store's existing tests; don't resolve its fixture.
  if (state.loading) continue;
  test(`settings gallery: ${name}`, async () => {
    const page = await renderPage({
      mock: structuredClone(state.options ?? {}),
      path: sectionHref(state.section, state.focus),
    });
    try {
      await run(async () => {
        page.provider.setHost({ ...page.provider.host, ...structuredClone(state.host ?? {}) });
        if (state.accounts) page.provider.accounts = structuredClone(state.accounts);
        await page.store.refreshAccounts();
      });
      expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe(state.section);
      for (const row of rowsInSection(state.section))
        expect(page.container.querySelector(`[data-row-key="${row.key}"]`)).not.toBeNull();
      for (const step of state.steps ?? []) {
        // Flush each gesture's render before waiting for its resulting element.
        await act(async () => {
          await fixtureSteps([step]);
        });
        await settle();
      }
      if (name === "search-empty") expect(page.container.querySelectorAll("[data-row-key]").length).toBe(0);
      if (name === "search-results") expect(page.container.querySelectorAll("mark").length).toBeGreaterThan(0);
    } finally {
      page.unmount();
    }
  });
}

test("all settings sections are reachable through the real page", () => {
  expect(sections.every((section) => settings.variants[section.id])).toBe(true);
});

const { createRoot } = await import("react-dom/client");
const { PasswordsPage } = await import("../src/pages/passwords/PasswordsPage");
const { PasswordsStore } = await import("../src/pages/passwords/store");
const { MockPasswordsProvider } = await import("../src/pages/passwords/mockProvider");
const { pageError } = await import("../src/pages/shared/pageClient");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/passwords/generated/strings.json")).default;
for (const [name, state] of Object.entries(passwords.variants)) {
  test(`passwords gallery: ${name}`, async () => {
    const provider = new MockPasswordsProvider(structuredClone(state.data));
    provider.authenticate = state.authenticate ?? true;
    provider.gesture = state.gesture ?? true;
    provider.confirm = state.confirm ?? true;
    const store = new PasswordsStore({
      call: (op, params) => {
        if (state.loading) return new Promise(() => {});
        if (op === state.failure?.op) return Promise.reject(pageError(state.failure.code, state.failure.message));
        return provider.call(op, params);
      },
      subscribe: (stream, listener) => provider.subscribe(stream, listener),
      handle: () => () => {},
    });
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    try {
      await act(async () => {
        root.render(<PasswordsPage store={store} strings={createStrings(table, ["en"])} />);
      });
      await settle();
      expect(container.querySelector(".pw-page")).not.toBeNull();
      for (const step of state.steps ?? []) {
        await act(async () => {
          await fixtureSteps([step]);
        });
        await settle();
      }
      if (name === "locked") expect(store.getSnapshot().notice?.kind).toBe("failed");
      if (name === "entry-selected") {
        const input = container.querySelector<HTMLInputElement>(".pw-username-input")!;
        expect(input.selectionEnd! - input.selectionStart!).toBe(input.value.length);
      }
      if (name === "network-error") expect(store.getSnapshot().connection).toBe("disconnected");
      if (name === "loading") expect(store.getSnapshot().loading).toBe(true);
    } finally {
      act(() => root.unmount());
      store.stop();
      container.remove();
    }
  });
}
