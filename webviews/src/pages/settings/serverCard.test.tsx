// Settings > Server (plans/cmux-next/server-updates-DESIGN.md section 10): each server's status and
// version line, a Restart Recommended row with the host's own confirm behind its button, the local
// socket and the Tailscale address with Pair and Copy. The card follows the host lists live.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { ServerHostState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => [...container.querySelectorAll<HTMLElement>('[data-card="server"]')];
const old: ServerHostState = {
  title: "Server",
  empty: "No server has answered yet.",
  socket_title: "Local Socket",
  tailnet_title: "Tailscale Address",
  copy_title: "Copy",
  pair_title: "Pair",
  servers: [
    {
      id: "cmux-tui|local",
      kind: "cmux-tui",
      host: null,
      name: "cmux-tui",
      running: true,
      status: "Running",
      version_line: "Version 0.66.0 · Build old1234 · Protocol 12",
      restart: {
        title: "Restart Recommended",
        help: "A restart turns on: Tab groups and 2 more",
        button: "Restart cmux-tui…",
      },
      socket: "/tmp/cmux/main.sock",
      tailnet: "100.64.0.7:7777",
    },
  ],
};

test("the card shows status, version line, socket and tailnet address", async () => {
  const page = await renderPage({ path: "/settings/server" });
  await act(async () => page.provider.setHost({ ...page.provider.host, server: old }));
  await settle();
  const [section] = card(page.container);
  expect(section!.dataset.running).toBe("true");
  expect(section!.textContent).toContain("Running");
  expect(section!.textContent).toContain("Version 0.66.0 · Build old1234 · Protocol 12");
  expect(section!.textContent).toContain("/tmp/cmux/main.sock");
  expect(section!.textContent).toContain("100.64.0.7:7777");
  page.unmount();
});

test("Restart Recommended shows only when the host offers a restart, and its button asks the host to confirm", async () => {
  const page = await renderPage({ path: "/settings/server" });
  await act(async () => page.provider.setHost({ ...page.provider.host, server: old }));
  await settle();
  expect(card(page.container)[0]!.textContent).toContain("Restart Recommended");
  expect(card(page.container)[0]!.textContent).toContain("A restart turns on: Tab groups and 2 more");
  await act(async () => card(page.container)[0]!.querySelector<HTMLButtonElement>("[data-server-restart]")!.click());
  await settle();
  const sent = page.provider.log.filter((entry) => entry.op === "cmux.settings.server.restart");
  expect(sent.map((entry) => entry.params)).toEqual([{ kind: "cmux-tui", host: null }]);
  // The restarted server answers current: the row goes away without the page doing anything.
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      server: { ...old, servers: [{ ...old.servers[0]!, restart: null }] },
    }),
  );
  await settle();
  expect(card(page.container)[0]!.textContent).not.toContain("Restart Recommended");
  expect(card(page.container)[0]!.querySelector("[data-server-restart]")).toBeNull();
  page.unmount();
});

test("Pair asks the host and Copy writes the address to the pasteboard", async () => {
  const page = await renderPage({ path: "/settings/server" });
  await act(async () => page.provider.setHost({ ...page.provider.host, server: old }));
  await settle();
  await act(async () => card(page.container)[0]!.querySelector<HTMLButtonElement>("[data-server-pair]")!.click());
  await act(async () =>
    card(page.container)[0]!.querySelector<HTMLButtonElement>('[data-server-copy="tailnet"]')!.click(),
  );
  await settle();
  expect(page.provider.log.some((entry) => entry.op === "cmux.settings.server.pair")).toBe(true);
  expect(page.provider.clipboard).toBe("100.64.0.7:7777");
  page.unmount();
});

test("a server without a socket or address shows neither row, and no server shows the empty line", async () => {
  const page = await renderPage({ path: "/settings/server" });
  const bare = { ...old.servers[0]!, restart: null, socket: null, tailnet: null };
  await act(async () => page.provider.setHost({ ...page.provider.host, server: { ...old, servers: [bare] } }));
  await settle();
  expect(card(page.container)[0]!.textContent).not.toContain("Local Socket");
  expect(card(page.container)[0]!.textContent).not.toContain("Tailscale Address");
  await act(async () => page.provider.setHost({ ...page.provider.host, server: { ...old, servers: [] } }));
  await settle();
  expect(card(page.container)[0]!.textContent).toContain("No server has answered yet.");
  page.unmount();
});
