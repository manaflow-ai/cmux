// Offline browser proof: build-guest-page-web.sh --out DIR, then
// CMUX_SHARE_GUEST_BUNDLE=DIR bun test ./scripts/cmux-next/share-two-accounts-guest.test.ts
import { expect, spyOn, test } from "bun:test";
import { mkdtemp, readdir, rmdir, stat, unlink } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { APIResponse, WebSocketRoute } from "../gallery-matrix/node_modules/playwright";
import { measure, measurements } from "./share-two-accounts";
import { createGuest, stagingLink } from "./share-two-accounts-guest";

const origin = "https://share-staging.cmux.dev";
const id = "fixture-room-id";
const pagePath = `/g/${id}`;
const api = `/v1/chat-shares/${id}`;
const fragment = "fixture-room-fragment";
const link = `${origin}${pagePath}#${fragment}`;

test("the guest only signs in to a staging link and preserves its fragment", () => {
  expect(stagingLink(link).href).toBe(link);
  expect(stagingLink(link.replace("share-staging.cmux.dev", "cmux-platform-staging.debussy.workers.dev")).href).toBe(link);
  for (const invalid of [link.replace("-staging", ""), link.replace("https:", "http:"), link.replace("/g/", "/i/"),
    link.replace("share-staging", "user:password@share-staging"), link.split("#")[0], "invalid"]) {
    expect(() => stagingLink(invalid)).toThrow(/Owner (returned an invalid|did not return a staging)/);
  }
});

test("a rejected handoff reports only its HTTP status", async () => {
  const fetch = spyOn(globalThis, "fetch").mockResolvedValue(new Response("fake-private-value", { status: 401 }));
  try {
    await expect(createGuest("", "fixture-bearer", link)).rejects.toThrow("Guest account handoff returned HTTP 401");
  } finally { fetch.mockRestore(); }
});

const bundle = process.env.CMUX_SHARE_GUEST_BUNDLE;
test.skipIf(!bundle)("the real guest joins, sees owner updates, sends a Talk prompt and sees revoke", async () => {
  const { chromium } = createRequire(new URL("../gallery-matrix/package.json", import.meta.url))("playwright") as
    typeof import("../gallery-matrix/node_modules/playwright");
  const out = await mkdtemp(join(tmpdir(), "cmux-test-share-guest-"));
  const handoff = "a".repeat(43);
  const fetch = spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ handoff, expires_at: Date.now() + 60_000 }));
  const launch = chromium.launch.bind(chromium);
  let socket!: WebSocketRoute;
  const received = Promise.withResolvers<{ text: string; at: number }>();
  const browser = await launch({
    executablePath: process.env.CMUX_SHARE_TEST_CHROME,
    // All HTTP and WS requests below are fulfilled in-process. Unhandled destinations cannot resolve.
    args: ["--host-resolver-rules=MAP * ~NOTFOUND"],
  });
  const launcher = spyOn(chromium, "launch").mockResolvedValue(browser);
  const context = browser.newContext.bind(browser);
  const contexts = spyOn(browser, "newContext").mockImplementation(async options => {
    const guest = await context(options);
    const cookie = "__Host-cmux-share";
    spyOn(guest.request, "get").mockImplementation(async (input, opts) => {
      expect(String(input)).toBe(`${origin}${pagePath}?cmux_handoff=${handoff}`);
      expect(opts?.maxRedirects).toBe(0);
      await guest.addCookies([{ name: cookie, value: "fixture-guest", url: origin, secure: true, httpOnly: true }]);
      return { status: () => 302 } as APIResponse;
    });
    await guest.route("**/*", async route => {
      const req = route.request();
      const url = new URL(req.url());
      if (url.origin !== origin) return route.abort();
      if (url.pathname === api + "/whoami" || url.pathname === api + "/redeem") {
        if (!(await req.headerValue("cookie"))?.includes(cookie + "=fixture-guest")) {
          return route.fulfill({ status: 401 });
        }
        if (url.pathname.endsWith("/whoami")) return route.fulfill({ json: { signed_in: true, name: "Fixture guest" } });
        const { secret, name, attempt_id } = req.postDataJSON();
        if (secret !== fragment || name !== "Fixture guest" || !attempt_id) return route.fulfill({ status: 403 });
        return route.fulfill({ json: { guest_id: "fixture-guest-id", role: "talk" } });
      }
      if (!url.pathname.startsWith("/g/")) return route.abort();
      const file = url.pathname === pagePath ? "index.html" : url.pathname.slice(3);
      return route.fulfill({ path: join(bundle!, file) });
    });
    await guest.routeWebSocket(`wss://share-staging.cmux.dev${api}/guest`, ws => {
      socket = ws;
      ws.onMessage(data => {
        const msg = JSON.parse(data.toString());
        if (msg.t === "prompt") received.resolve({ text: msg.text, at: performance.now() });
      });
      ws.send(JSON.stringify({ v: 1, t: "snapshot", chat: { title: "Staging proof" }, records: [], watermark: 0 }));
    });
    return guest;
  });
  let session: Awaited<ReturnType<typeof createGuest>> | undefined;
  try {
    session = await createGuest(out, "fixture-bearer", link);
    expect(fetch).toHaveBeenCalledTimes(1);
    const [url, init] = fetch.mock.calls[0];
    expect(String(url)).toBe(origin + api + "/handoff");
    expect(init?.method).toBe("POST");
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer fixture-bearer");
    expect(JSON.parse(String(init?.body))).toEqual({ page: "g" });
    let seq = 0;
    const m = measurements();
    await measure({
      async prompt(text) {
        const sent = performance.now();
        socket.send(JSON.stringify({ v: 1, t: "records", records: [
          { seq: ++seq, at: 1000 + seq, dir: "mux", kind: "user_message", msg: { text } },
        ] }));
        return sent;
      },
      async waitGuest(text) {
        const delivered = await Promise.race([received.promise, Bun.sleep(2_000)]);
        if (!delivered || delivered.text !== text) throw new Error("Fixture room did not receive the guest prompt");
        return delivered.at;
      },
      async revoke() {
        const requested = performance.now();
        socket.send(JSON.stringify({ v: 1, t: "end", reason: "revoked" }));
        return requested;
      },
    }, session, m, () => {});
    expect(m.updates).toHaveLength(20);
    expect(m.events.map(event => event.at_ms)).toEqual(m.events.map(event => event.at_ms).sort((a, b) => a - b));
    expect(m.events).toHaveLength(44);
    for (let i = 0; i < 20; i++) {
      const [sent, seen] = m.events.slice(i * 2, i * 2 + 2);
      expect([sent.side, seen.side, sent.sample, seen.sample]).toEqual(["owner", "guest", i + 1, i + 1]);
      expect(m.updates[i]).toBe(seen.at_ms - sent.at_ms);
    }
    const [typed, delivered, revoked, ended] = m.events.slice(-4);
    expect([typed.side, delivered.side, revoked.side, ended.side]).toEqual(["guest", "owner", "owner", "guest"]);
    expect(m.delivered).toBe(delivered.at_ms - typed.at_ms);
    expect(m.cutoff).toBe(ended.at_ms - revoked.at_ms);
    await expect(session.waitUpdate("missing owner update")).rejects.toThrow("Guest render owner update failed or timed out");
    await session.close();
    const updateImages = m.updates.map((_, i) => `guest-update-${String(i + 1).padStart(2, "0")}.png`);
    for (const file of ["flow.webm", "guest-join.png", "guest-joined.png", ...updateImages, "guest-typed.png", "guest-revoked.png"]) {
      expect((await stat(join(out, file))).size).toBeGreaterThan(0);
    }
  } finally {
    contexts.mockRestore();
    launcher.mockRestore();
    fetch.mockRestore();
    await session?.close();
    await browser.close();
    for (const file of await readdir(out)) await unlink(join(out, file));
    await rmdir(out);
  }
}, 60_000);
