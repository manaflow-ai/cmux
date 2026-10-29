// Experimental > Feature Flags (feature featureFlagsCard): the host lists'
// `features` (the socket's features.list plus the next launch's local choices). Each feature shows
// its state, the input that decided it and its channel default; DEV and NIGHTLY get a choice per
// feature that applies at the next launch, Release none. Off (null) draws no card.
import { afterAll, expect, test } from "bun:test";
import type { FeatureFlagsState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, ops } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="feature-flags"]');
const row = (container: HTMLElement, name: string) =>
  card(container)!.querySelector<HTMLElement>(`[data-feature="${name}"]`)!;

function report(local: boolean, nextLocal: Record<string, boolean> = {}): FeatureFlagsState {
  return {
    channel: local ? "nightly" : "release",
    local_overrides: local,
    safe_mode: null,
    unknown_names: ["noSuchThing"],
    features: [
      {
        name: "perfThing",
        state: "on",
        source: "remote",
        default: false,
        kind: "perfPath",
        description: "A perf path.",
      },
      { name: "killThing", state: "off", source: "policy", default: true, kind: "killSwitch", description: "A kill." },
      { name: "labsThing", state: "on", source: "local", default: false, kind: "labs", description: "A lab." },
    ],
    next_local: nextLocal,
  };
}

test("the card is not drawn while feature featureFlagsCard is off", async () => {
  const page = await renderPage({ path: "/settings/experimental" });
  await settle();
  expect(page.container.querySelector('[data-section="experimental"]')).not.toBeNull();
  expect(card(page.container)).toBeNull();
  page.unmount();
});

test("each feature shows its state, source and channel default", async () => {
  const page = await renderPage({
    path: "/settings/experimental",
    setup: (provider) => provider.setHost({ ...provider.host, features: report(false) }),
  });
  await settle();
  expect(card(page.container)?.querySelector(".group-title")?.textContent).toBe("Feature Flags");
  const status = (name: string) => row(page.container, name).querySelector("[data-feature-status]")?.textContent;
  expect(status("perfThing")).toBe("On · Source: Remote · Default: Off");
  expect(status("killThing")).toBe("Off · Source: Managed policy · Default: On");
  expect(status("labsThing")).toBe("On · Source: Your choice · Default: Off");
  expect(card(page.container)!.querySelector("[data-feature-unknown]")?.textContent).toBe(
    "Names no feature has: noSuchThing",
  );
  page.unmount();
});

test("Release takes no local choices: no control on any row", async () => {
  const page = await renderPage({
    path: "/settings/experimental",
    setup: (provider) => provider.setHost({ ...provider.host, features: report(false) }),
  });
  await settle();
  expect(card(page.container)!.querySelectorAll("select").length).toBe(0);
  expect(card(page.container)!.textContent).toContain("Only DEV and NIGHTLY builds take local choices.");
  page.unmount();
});

test("DEV and NIGHTLY set a feature for the next launch, and back to automatic", async () => {
  const page = await renderPage({
    path: "/settings/experimental",
    setup: (provider) => provider.setHost({ ...provider.host, features: report(true, { labsThing: true }) }),
  });
  await settle();
  const native = (name: string) =>
    row(page.container, name).querySelector<HTMLSelectElement>("select.ui-select-native")!;
  // This launch applied labsThing's local choice: no restart note while the next launch keeps it.
  expect(native("labsThing").value).toBe("on");
  expect(row(page.container, "labsThing").querySelector("[data-feature-restart]")).toBeNull();
  expect(native("perfThing").value).toBe("automatic");

  await changeValue(native("perfThing"), "off");
  expect(ops(page.provider, "cmux.settings.features.set")).toEqual([{ name: "perfThing", on: false }]);
  expect(native("perfThing").value).toBe("off");
  expect(row(page.container, "perfThing").querySelector("[data-feature-restart]")?.textContent).toBe(
    "Changes when cmux restarts",
  );

  await changeValue(native("labsThing"), "automatic");
  expect(ops(page.provider, "cmux.settings.features.set")).toEqual([
    { name: "perfThing", on: false },
    { name: "labsThing", on: null },
  ]);
  expect(row(page.container, "labsThing").querySelector("[data-feature-restart]")).not.toBeNull();
  page.unmount();
});

test("safe mode says which remote flags apply", async () => {
  const page = await renderPage({
    path: "/settings/experimental",
    setup: (provider) =>
      provider.setHost({ ...provider.host, features: { ...report(true), safe_mode: { level: "no-remote" } } }),
  });
  await settle();
  expect(card(page.container)!.querySelector("[data-feature-safe-mode]")?.textContent).toBe(
    "Safe mode: after repeated crashes, cmux ignores remote flags. Kill switches stay off.",
  );
  page.unmount();
});
