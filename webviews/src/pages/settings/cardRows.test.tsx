// Settings cards whose lists are small (capped by the host, or a few per person) are not windowed,
// but a row draws again only when its own part changes (visible-only rule 2): Updates > Channels'
// builds, Machines' and Spaces' rows, Devices, Accounts and a harness's accounts. Each test changes
// one row, or something no row shows, and counts the rows drawn again (test/support/rowPropsRenders.ts).
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { ProviderAccount } from "./ops";
import type { Rendered } from "./testing";
import { rowPropsRenders } from "../../../test/support/rowPropsRenders";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage, run, settle } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const all = (selector: string) => () => page!.container.querySelectorAll(selector);

/** A write to a setting none of these cards shows. */
const elsewhere = () =>
  run(() => page!.store.set("sessions.keepAwake", !page!.store.getSnapshot().rows.get("sessions.keepAwake")?.value));

test("Channels: a switch's stage draws its own build row, and a write elsewhere draws none", async () => {
  page = await renderPage({ path: "/settings/updates" });
  await settle();
  await run(() => page!.store.set("updates.channel", "nightly"));
  await settle();
  const builds = all('[data-card="channels"] [data-channel-build]');
  expect(builds().length).toBeGreaterThan(4);
  const renders = rowPropsRenders(builds);

  await run(() => page!.provider.setSwitchProgress({ build: "3422", label: "Downloading… 42%", fraction: 0.42 }));
  renders.mark();
  await run(() => page!.provider.setSwitchProgress({ build: "3422", label: "Downloading… 43%", fraction: 0.43 }));
  // The running row; Dev lists the same build, but only the followed track's row runs.
  expect(renders.since()).toBe(1);

  await run(() => page!.provider.setSwitchProgress(null));
  renders.mark();
  await elsewhere();
  expect(renders.since()).toBe(0);
});

test("Machines: one machine's change or color draws its row alone, and a write elsewhere draws none", async () => {
  page = await renderPage({ path: "/settings/machines" });
  await settle();
  const host = page.provider.host;
  const second = { ...host.machines[0]!, id: "m-second", title: "second-mac", color_key: "second-mac" };
  await act(async () => page!.provider.setHost({ ...host, machines: [...host.machines, second] }));
  await settle();
  const rows = all('[data-card="machines"] [data-host-row]');
  expect(rows().length).toBe(2);
  const renders = rowPropsRenders(rows);

  renders.mark();
  await act(async () =>
    page!.provider.setHost({
      ...page!.provider.host,
      machines: page!.provider.host.machines.map((row) =>
        row.id === "m-second" ? { ...row, subtitle: "Online" } : row,
      ),
    }),
  );
  await settle();
  expect(renders.since()).toBe(1);

  renders.mark();
  await run(() => page!.store.set("appearance.machineColors", { "second-mac": "#112233" }));
  await settle();
  expect(renders.since()).toBe(1);

  renders.mark();
  await elsewhere();
  expect(renders.since()).toBe(0);
});

test("Devices: Remove asking again draws its own row alone", async () => {
  page = await renderPage({ path: "/settings/machines" });
  await settle();
  const rows = all('[data-card="devices"] [data-device-row]');
  expect(rows().length).toBe(3);
  const renders = rowPropsRenders(rows);
  renders.mark();
  await click(page.container.querySelector('[data-remove-device="peer:mini-7"]')!);
  expect(renders.since()).toBe(1);
  renders.mark();
  await elsewhere();
  expect(renders.since()).toBe(0);
});

test("Accounts: a push that changes no provider, or a write elsewhere, draws no row", async () => {
  page = await renderPage({ path: "/settings/accounts" });
  await settle();
  const rows = all('[data-card="accounts"] [data-accounts-group] .accounts-row');
  expect(rows().length).toBeGreaterThan(1);
  const renders = rowPropsRenders(rows);
  renders.mark();
  await run(() => page!.store.runAccounts({ action: "focus" }));
  await settle();
  expect(renders.since()).toBe(0);
  renders.mark();
  await elsewhere();
  expect(renders.since()).toBe(0);
});

test("a harness's accounts: turning one account's routing off draws that account's row alone", async () => {
  page = await renderPage({ path: "/settings/agents" });
  await settle();
  // Three Codex accounts (as providerAccounts.test.tsx's).
  const accounts: ProviderAccount[] = [
    {
      id: "codex-login",
      family: "codex",
      name: "ChatGPT",
      home: null,
      defaultHome: "~/.codex",
      shadowOf: null,
      signedIn: true,
      plan: "pro",
      email: "codex-login@example.com",
      enabled: true,
      builtin: true,
    },
    {
      id: "codex-2",
      family: "codex",
      name: "ChatGPT 2",
      home: "~/.cmux/accounts/codex-2",
      defaultHome: "~/.codex",
      shadowOf: "codex-login",
      signedIn: true,
      plan: "pro",
      email: "codex-2@example.com",
      enabled: true,
      builtin: false,
    },
    {
      id: "codex-3",
      family: "codex",
      name: "ChatGPT 3",
      home: "~/.cmux/accounts/codex-3",
      defaultHome: "~/.codex",
      shadowOf: null,
      signedIn: true,
      plan: "pro",
      email: "codex-3@example.com",
      enabled: true,
      builtin: false,
    },
  ];
  await act(async () => page!.provider.setHarnesses({ ...page!.provider.harnesses, accounts }));
  await settle();
  const rows = all('[data-card="harnesses"] [data-harness="codex"] [data-account]');
  expect(rows().length).toBeGreaterThan(1);
  const renders = rowPropsRenders(rows);
  renders.mark();
  await click(rows()[1]!.querySelector('[role="switch"]')!);
  await settle();
  expect(renders.since()).toBe(1);
});
