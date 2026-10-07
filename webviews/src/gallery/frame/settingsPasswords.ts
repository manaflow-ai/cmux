// The real pages, over their existing mock providers and the same cmuxPage bridge as the app.
import { HostError, installMockHost } from "../../../test/latency/mock-host";
import type { PageFixtureStep, PasswordsPageVariant, SettingsPageVariant } from "../format";
import type { SettingsClient } from "../../pages/settings/ops";
import { addPseudoLocales } from "../pseudo";
import type { StageContext } from "./context";

async function bridge(client: SettingsClient, ops: string[], streams: string[]) {
  const host = installMockHost(
    Object.fromEntries(ops.map((op) => [op, (params: unknown) => client.call(op, params)])),
    streams,
  );
  host.delayMs = 0;
  const stops = await Promise.all(
    streams.map((stream) => client.subscribe(stream, (event) => host.emit(stream, event))),
  );
  window.addEventListener("pagehide", () => stops.forEach((stop) => stop()), { once: true });
}

/** Wait on DOM changes, with a bounded failure instead of quietly capturing an unopened form. */
export function fixtureElement(selector: string): Promise<HTMLElement> {
  return new Promise((resolve, reject) => {
    const find = () => document.querySelector<HTMLElement>(selector);
    const found = find();
    if (found) return resolve(found);
    const observer = new MutationObserver(() => {
      const node = find();
      if (node) {
        observer.disconnect();
        clearTimeout(timer);
        resolve(node);
      }
    });
    const timer = setTimeout(() => {
      observer.disconnect();
      reject(new Error(`Gallery control missing: ${selector}`));
    }, 5000);
    observer.observe(document.body, { childList: true, subtree: true, attributes: true });
  });
}

export async function fixtureSteps(steps: PageFixtureStep[] = []): Promise<void> {
  for (const step of steps) {
    const node = await fixtureElement(step.selector);
    if (step.action === "click") node.click();
    else if (step.action === "focus") node.focus();
    else if (step.action === "select") {
      node.focus();
      (node as HTMLInputElement).select();
    } else if (step.action === "enter")
      node.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    else if (step.action === "input" || step.action === "change") {
      const proto = node instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(node, step.value ?? "");
      node.dispatchEvent(new Event(step.action, { bubbles: true }));
    }
    // React must commit one gesture before the next (input, then submit for example).
    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  }
}

export async function mountSettingsPage(state: SettingsPageVariant, context: StageContext): Promise<void> {
  const { createMockClient } = await import("../../pages/settings/mockProvider");
  const { installCatalog } = await import("../../pages/settings/strings");
  const table = (await import("../../pages/settings/generated/strings.json")).default;
  addPseudoLocales(table);
  installCatalog(table);
  document.documentElement.lang = context.env.locale;
  const options = structuredClone(state.options ?? {});
  const themes = state.allThemes ? (await import("virtual:cmux-gallery/themes")).default : [];
  if (state.allThemes) {
    // The app publishes every bundled Ghostty theme and answers their colors.
    const { mockDomains } = await import("../../pages/settings/mockProvider");
    options.domains = { ...mockDomains, ...options.domains, themes: themes.map((theme) => theme.name) };
  }
  const mock = createMockClient(options);
  if (state.allThemes) mock.provider.themeColors = themes;
  mock.provider.host = { ...mock.provider.host, ...structuredClone(state.host ?? {}) };
  // The stage's own window theme stands in for the user's Ghostty config, as the app sends the
  // colors in effect while appearance.theme is unset.
  if (mock.provider.host.theme) {
    const config = { ...context.theme, name: "" };
    mock.provider.host = { ...mock.provider.host, theme: { ...mock.provider.host.theme, config } };
  }
  if (state.accounts) mock.provider.accounts = structuredClone(state.accounts);
  window.addEventListener("pagehide", mock.close, { once: true });
  const client: SettingsClient = {
    call: (op, params) =>
      state.loading && (op === "cmux.settings.list" || op === "cmux.settings.snapshot")
        ? new Promise(() => {})
        : mock.client.call(op, params),
    subscribe: (stream, listener) => mock.client.subscribe(stream, listener),
  };
  await bridge(
    client,
    [
      "cmux.settings.list",
      "cmux.settings.snapshot",
      "cmux.settings.set",
      "cmux.settings.reset",
      "cmux.settings.reset_all",
      "cmux.settings.preview",
      "cmux.settings.preview.end",
      "cmux.settings.sound.play",
      "cmux.settings.host.lists",
      "cmux.settings.accounts.state",
      "cmux.settings.accounts.run",
      "cmux.settings.theme.set",
      "cmux.settings.theme.colors",
      "cmux.settings.theme.accepts",
      "cmux.settings.file.reveal",
      "cmux.settings.folders.add",
      "cmux.settings.section.actions",
      "cmux.app.action.run",
    ],
    [
      "cmux.settings.changed",
      "cmux.page.connection",
      "cmux.page.command",
      "cmux.settings.host.changed",
      "cmux.settings.accounts.changed",
    ],
  );
  if (state.backdropImages) {
    const images = state.backdropImages;
    const replaceImages = () => {
      for (const img of document.querySelectorAll<HTMLImageElement>("img.backdrop-thumb")) {
        const id = decodeURIComponent(img.getAttribute("src")?.split("backdrop/")[1] ?? "");
        if (images[id]) img.src = images[id]!;
      }
    };
    const observer = new MutationObserver(replaceImages);
    observer.observe(document.body, { childList: true, subtree: true });
    window.addEventListener("pagehide", () => observer.disconnect(), { once: true });
  }
  const { sectionHref } = await import("../../pages/settings/router");
  history.replaceState(null, "", `${location.pathname}${location.search}#${sectionHref(state.section, state.focus)}`);
  document.documentElement.dataset.cmuxPage = "settings";
  if (state.look) document.documentElement.dataset.settingsLook = state.look;
  await import("../../pages/settings/main");
  if (!state.loading && !state.options?.failing && state.options?.connected !== false) {
    const { categoryOf, categoryRows } = await import("../../pages/settings/categories");
    await fixtureElement(
      categoryRows(categoryOf(state.section)).length
        ? "[data-row-key] input:not(:disabled), [data-row-key] button:not(:disabled), [data-row-key] select:not(:disabled), [data-theme-picker]:not(:disabled)"
        : "[data-card]",
    );
  }
  await fixtureSteps(state.steps);
}

export async function mountPasswordsPage(state: PasswordsPageVariant, context: StageContext): Promise<void> {
  const { MockPasswordsProvider } = await import("../../pages/passwords/mockProvider");
  const { PasswordOps } = await import("../../pages/passwords/types");
  const table = (await import("../../pages/passwords/generated/strings.json")).default;
  addPseudoLocales(table);
  document.documentElement.lang = context.env.locale;
  const provider = new MockPasswordsProvider(structuredClone(state.data));
  provider.authenticate = state.authenticate ?? true;
  provider.gesture = state.gesture ?? true;
  provider.confirm = state.confirm ?? true;
  const client: SettingsClient = {
    call: (op, params) => {
      if (state.loading && op === PasswordOps.state) return new Promise(() => {});
      if (state.failure?.op === op) throw new HostError(state.failure.code, state.failure.message);
      return provider.call(op, params);
    },
    subscribe: (stream, listener) => provider.subscribe(stream, listener),
  };
  await bridge(
    client,
    Object.values(PasswordOps).filter((op) => op !== PasswordOps.changed),
    [PasswordOps.changed, "cmux.page.connection", "cmux.page.command"],
  );
  document.documentElement.dataset.cmuxPage = "passwords";
  await import("../../pages/passwords/main");
  await fixtureSteps(state.steps);
}
