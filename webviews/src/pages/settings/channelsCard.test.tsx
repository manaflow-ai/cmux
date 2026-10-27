// Settings > Updates: its own category with the updates rows and the Channels card, which draws
// every channel's track from the host's `cmux.settings.channels.state` and no text of its own.
import { afterAll, expect, test } from "bun:test";
import { mockChannels, mockGoBack } from "./mockChannels";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, run, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="channels"]');

test("Updates is its own category: the update rows, then the Channels card; General has neither", async () => {
  const page = await renderPage({ path: "/settings/updates" });
  await settle();
  expect(page.container.querySelector('[data-row-key="updates.channel"]')).not.toBeNull();
  expect(card(page.container)).not.toBeNull();
  page.unmount();
  const general = await renderPage({ path: "/settings/general" });
  await settle();
  expect(general.container.querySelector('[data-row-key="updates.channel"]')).toBeNull();
  expect(card(general.container)).toBeNull();
  general.unmount();
});

test("one track per channel, the followed one marked, the installed build saying You Are Here", async () => {
  const page = await renderPage({ path: "/settings/updates" });
  await settle();
  const element = card(page.container)!;
  const tracks = [...element.querySelectorAll<HTMLElement>("[data-channel]")].map((node) => node.dataset.channel);
  expect(tracks).toEqual(["stable", "nightly", "canary", "dev"]);
  const nightly = element.querySelector<HTMLElement>('[data-channel="nightly"]')!;
  expect(nightly.querySelector("[data-channel-followed]")?.textContent).toBe("Following");
  expect(element.querySelectorAll("[data-channel-followed]").length).toBe(1);
  const here = [...nightly.querySelectorAll<HTMLElement>("[data-channel-build]")].filter((row) =>
    row.querySelector("[data-channel-here]"),
  );
  expect(here.map((row) => row.dataset.channelBuild)).toEqual(["3419"]);
  expect(element.querySelector('[data-channel="stable"]')?.textContent).toContain("No builds on this channel yet.");
  page.unmount();
});

test("choosing another channel in the row above moves Following to it at once", async () => {
  const page = await renderPage({ path: "/settings/updates" });
  await settle();
  await run(() => page.store.set("updates.channel", "canary"));
  const followed = [...card(page.container)!.querySelectorAll("[data-channel-followed]")];
  expect(followed.map((node) => node.closest<HTMLElement>("[data-channel]")?.dataset.channel)).toEqual(["canary"]);
  page.unmount();
});

test("each build shows its health and pull reason and links to its commit, PRs and the changes since yours", async () => {
  const page = await renderPage({ path: "/settings/updates" });
  await settle();
  const element = card(page.container)!;
  const pulled = element.querySelector<HTMLElement>('[data-channel-build="3421"]')!;
  expect(pulled.dataset.health).toBe("pulled");
  expect(pulled.textContent).toContain("Crashes on launch");
  expect(pulled.querySelector<HTMLAnchorElement>("[data-channel-compare]")?.href).toBe(
    "https://github.com/manaflow-ai/cmux/compare/3c1d9e0a...9f1e2d3c",
  );
  expect(pulled.querySelector<HTMLAnchorElement>("[data-channel-pr]")?.href).toBe(
    "https://github.com/manaflow-ai/cmux/pull/23947",
  );
  // The installed build compares with nothing.
  expect(element.querySelector('[data-channel-build="3419"] [data-channel-compare]')).toBeNull();
  expect(element.querySelector('[data-channel-build="3418"]')?.textContent).toContain("Kept on This Mac");
  page.unmount();
});

test("picking Nightly on a Dev build Nightly has not reached offers Go Back into the kept Nightly build", async () => {
  const page = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channelSwitch = mockGoBack;
    },
  });
  await settle();
  await run(() => page.store.set("updates.channel", "dev"));
  await settle();
  expect(card(page.container)?.querySelector("[data-channel-switch]")).toBeNull();
  await run(() => page.store.set("updates.channel", "nightly"));
  await settle();
  const way = card(page.container)!.querySelector<HTMLElement>('[data-channel-switch="nightly"]')!;
  expect(way.textContent).toContain("Restarts once into 1.0.0-nightly.3418, kept on this Mac.");
  const button = way.querySelector<HTMLButtonElement>("[data-channel-go-back]")!;
  expect(button.textContent).toBe("Go Back to Nightly");
  await run(() => button.click());
  await settle();
  expect(page.provider.wentBack).toBe("3418");
  // A reply that carries another channel's way back (a read for an earlier pick) offers no button.
  await run(() => page.store.set("updates.channel", "dev"));
  await settle();
  expect(card(page.container)!.querySelector("[data-channel-go-back]")).toBeNull();
  page.unmount();
});

test("a host with no updater shows no Channels card", async () => {
  const page = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = null;
    },
  });
  await settle();
  expect(card(page.container)).toBeNull();
  expect(mockChannels.tracks.length).toBe(4);
  page.unmount();
});

test("the card names the app's acpmux daemon's build and whether it is up to date, as the host says", async () => {
  const page = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = { ...mockChannels, daemon: { title: "acpmux daemon", value: "abc123 (restarting…)" } };
    },
  });
  await settle();
  const row = card(page.container)!.querySelector<HTMLElement>("[data-channel-daemon]")!;
  expect(row.textContent).toContain("acpmux daemon");
  expect(row.textContent).toContain("abc123 (restarting…)");
  page.unmount();
  // A host without a local daemon sends none, and the card has no such row.
  const none = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = { ...mockChannels, daemon: null };
    },
  });
  await settle();
  expect(card(none.container)!.querySelector("[data-channel-daemon]")).toBeNull();
  none.unmount();
});

test("the card lists the machines that cannot update in place or failed to, in one row, as the host says", async () => {
  const lines = [
    "lofty-lemon-stoat runs a cmux too old to update in place. Its chats and terminals keep working; features newer than its cmux stay off there.",
    "Couldn't update build-box: Bootstrap failed: 125",
  ];
  const page = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = { ...mockChannels, machines: { title: "Other machines", lines } };
    },
  });
  await settle();
  const rows = card(page.container)!.querySelectorAll<HTMLElement>("[data-channel-machines]");
  expect(rows.length).toBe(1);
  expect(rows[0]!.textContent).toContain("Other machines");
  expect([...rows[0]!.querySelectorAll("[data-channel-machine]")].map((line) => line.textContent)).toEqual(lines);
  page.unmount();
  // None to list: no row.
  const none = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = { ...mockChannels, machines: null };
    },
  });
  await settle();
  expect(card(none.container)!.querySelector("[data-channel-machines]")).toBeNull();
  none.unmount();
});

test("a machine failing while the card shows joins its row at once, without a re-read", async () => {
  const page = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = { ...mockChannels, machines: null };
    },
  });
  await settle();
  expect(card(page.container)!.querySelector("[data-channel-machines]")).toBeNull();
  const line = "Couldn't update build-box: Bootstrap failed: 125";
  await run(() => page.provider.setMachines({ title: "Other machines", lines: [line] }));
  const lines = [...card(page.container)!.querySelectorAll("[data-channel-machine]")].map((node) => node.textContent);
  expect(lines).toEqual([line]);
  await run(() => page.provider.setMachines(null));
  expect(card(page.container)!.querySelector("[data-channel-machines]")).toBeNull();
  page.unmount();
});

test("a machine too old to update in place has one Update button, which asks the host for that machine", async () => {
  const tooOld = "tidy-yellow-tern runs a cmux too old to update in place. Its chats and terminals keep working; features newer than its cmux stay off there.";
  const failed = "Couldn't update build-box: Bootstrap failed: 125";
  const page = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = {
        ...mockChannels,
        machines: { title: "Other machines", lines: [tooOld, failed], updates: ["cloud:vm-9c96", null], updateLabel: "Update" },
      };
    },
  });
  await settle();
  const buttons = [...card(page.container)!.querySelectorAll<HTMLButtonElement>("[data-channel-update-machine]")];
  expect(buttons.map((button) => [button.dataset.channelUpdateMachine, button.textContent])).toEqual([["cloud:vm-9c96", "Update"]]);
  await run(() => buttons[0]!.click());
  await settle();
  expect(page.provider.updatedMachines).toEqual(["cloud:vm-9c96"]);
  // The app's push: the machine is updating, so its line says so and has no button.
  const updating = "Updating tidy-yellow-tern to this Mac's build…";
  await run(() => page.provider.setMachines({ title: "Other machines", lines: [updating, failed], updates: [null, null], updateLabel: "Update" }));
  expect([...card(page.container)!.querySelectorAll("[data-channel-machine]")].map((node) => node.textContent)).toEqual([updating, failed]);
  expect(card(page.container)!.querySelector("[data-channel-update-machine]")).toBeNull();
  page.unmount();
});

test("an app that offers no Update button shows the lines only", async () => {
  const page = await renderPage({
    path: "/settings/updates",
    setup: (provider) => {
      provider.channels = { ...mockChannels, machines: { title: "Other machines", lines: ["Couldn't update build-box: disk full"] } };
    },
  });
  await settle();
  expect(card(page.container)!.querySelectorAll("[data-channel-machine]").length).toBe(1);
  expect(card(page.container)!.querySelector("[data-channel-update-machine]")).toBeNull();
  page.unmount();
});
