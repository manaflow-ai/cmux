// l10n-allow-file: browser fixture labels, not shipped UI.
// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page, type WebSocketRoute } from "playwright";
import type { ViteDevServer } from "vite";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chief-web-contract-browser.test.ts", async () => {
  const identity = { chiefId: "chief_alex", mainConversationId: "conv_chief", handle: "alex" };
  const conversation = {
    id: identity.mainConversationId,
    participants: [
      { id: "user_alex", kind: "person", display_name: "Alex" },
      { id: "agent_chief", kind: "agent", agent_class: "mux", display_name: "Chief" },
    ],
  };
  type MessageBody = { text: string; clientMessageId: string };
  type Fixture = {
    meStatus?: number;
    ticketStatus?: number;
    messageResults?: { status: number; ok?: boolean }[];
  };
  setDefaultTimeout(240_000);
  let vite: ViteDevServer | undefined;
  let bundleServer: ReturnType<typeof Bun.serve> | undefined;
  let browser: Browser;
  let origin: string;
  beforeAll(async () => {
    const bundle = process.env.CMUX_CHIEF_WEB_BUNDLE;
    if (bundle) {
      const directory = path.resolve(bundle);
      bundleServer = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        async fetch(request) {
          let pathname: string;
          try {
            pathname = decodeURIComponent(new URL(request.url).pathname);
          } catch {
            return new Response("Not found", { status: 404 });
          }
          // Match the platform's asset-only route, including its file extension allowlist.
          const relative =
            pathname === "/c/alex"
              ? "index.html"
              : pathname.startsWith("/c/assets/") && /\.(?:js|css|svg|png|woff|woff2)$/.test(pathname)
                ? pathname.slice("/c/".length)
                : undefined;
          if (!relative) return new Response("Not found", { status: 404 });
          const resolved = path.resolve(directory, relative);
          if (
            resolved !== path.join(directory, "index.html") &&
            !resolved.startsWith(path.join(directory, "assets") + path.sep)
          )
            return new Response("Not found", { status: 404 });
          const file = Bun.file(resolved);
          return (await file.exists()) ? new Response(file) : new Response("Not found", { status: 404 });
        },
      });
      origin = `http://127.0.0.1:${bundleServer.port}`;
    } else {
      const { createServer } = await import("vite");
      vite = await createServer({
        configFile: path.resolve(import.meta.dir, "../vite.config.chief-web.mjs"),
        server: { port: 0, host: "127.0.0.1", strictPort: false },
        logLevel: "error",
      });
      await vite.listen();
      await warmViteServer(vite, "/c/alex");
      origin = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    }
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await bundleServer?.stop(true);
  });

  async function open(fixture: Fixture = {}, locale = "en-US") {
    const page = await browser.newPage({
      viewport: { width: 390, height: 844 },
      deviceScaleFactor: 2,
      locale,
    });
    const messages: { body: MessageBody; at: number }[] = [];
    const tickets: { method: string; body: string | null }[] = [];
    const errors: string[] = [];
    let socket: WebSocketRoute | undefined;
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("response", (response) => {
      const url = new URL(response.url());
      if (url.origin === origin && url.pathname.startsWith("/c/") && response.status() >= 400)
        errors.push(`${response.status()} ${url.pathname}`);
    });
    await page.routeWebSocket("**/v1/chief/wire", (wire) => {
      socket = wire;
      wire.onMessage((raw) => {
        const frame = JSON.parse(String(raw));
        if (frame.t === "subscribe")
          wire.send(
            JSON.stringify({
              t: "snapshot",
              stream: `conv:${conversation.id}`,
              seq: 0,
              state: conversation,
              rows: { table: "msg", rows: [] },
            }),
          );
        if (frame.t === "run.live.get")
          wire.send(JSON.stringify({ t: "run.live", conversation: conversation.id, runs: [] }));
      });
      wire.send(JSON.stringify({ t: "welcome", principal: { user: "user_alex" } }));
    });
    await page.route("**/v1/chief/*", async (route) => {
      const request = route.request();
      const endpoint = new URL(request.url()).pathname.split("/").at(-1);
      const status =
        endpoint === "me"
          ? (fixture.meStatus ?? 200)
          : endpoint === "ticket"
            ? (fixture.ticketStatus ?? 200)
            : (fixture.messageResults?.[messages.length]?.status ?? 200);
      let body: unknown = { code: "chief.unavailable", message: "Chief is unavailable" };
      if (endpoint === "me" && status === 200) body = identity;
      if (endpoint === "ticket") {
        tickets.push({ method: request.method(), body: request.postData() });
        if (status === 200)
          body = {
            ticket: "single-use-ticket",
            websocketUrl: origin.replace("http:", "ws:") + "/v1/chief/wire",
          };
      }
      if (endpoint === "messages") {
        const sent = request.postDataJSON() as MessageBody;
        const result = fixture.messageResults?.[messages.length];
        messages.push({ body: sent, at: Date.now() });
        if (status === 200)
          body = {
            ok: result?.ok ?? true,
            clientMessageId: sent.clientMessageId,
            receipt: { accepted: true },
          };
      }
      await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });
      if (endpoint === "messages" && status === 200 && (body as { ok: boolean }).ok) {
        const sent = messages.at(-1)!.body;
        const rows = [
          {
            id: "prompt",
            seq: 1,
            author: "user_alex",
            client_msg_id: sent.clientMessageId,
            text: sent.text,
          },
          {
            id: "reply",
            seq: 2,
            author: "agent_chief",
            client_msg_id: "chief-reply",
            text: "Your hello page is ready. [Open your page](https://hello.preview-development.cmux.dev).",
          },
        ].map(({ text, ...row }) => ({
          ...row,
          conversation: conversation.id,
          parts: [{ type: "text", text }],
        }));
        socket?.send(
          JSON.stringify({
            t: "event",
            stream: `conv:${conversation.id}`,
            seq: 1,
            effects: {
              state: conversation,
              writes: rows.map((row) => ({
                op: "upsert",
                table: "msg",
                key: row.id,
                n: row.seq,
                row,
              })),
            },
          }),
        );
      }
    });
    await page.goto(origin + "/c/alex");
    await page.getByTestId("chief-web").waitFor();
    return {
      page,
      messages,
      tickets,
      errors,
      frame: (value: unknown) => socket?.send(JSON.stringify(value)),
    };
  }

  async function send(page: Page) {
    await page.getByRole("textbox", { name: "Message your Chief" }).fill("Build me a hello page");
    await page.getByRole("button", { name: "Send", exact: true }).click();
  }

  test("live reply tokens update their mounted row and survive resync until the exact committed reply", async () => {
    const fixture = await open();
    try {
      await fixture.page.waitForFunction(() => document.querySelector(".chief-web__connection")?.textContent === "");
      const live = { conversation: conversation.id, author: "agent_chief", run: "run_1" };
      fixture.frame({
        t: "step.delta",
        ...live,
        step: "talk:0",
        kind: "talk",
        seq: 0,
        text: "Building",
      });
      await fixture.page.getByText("Building", { exact: true }).waitFor();
      fixture.frame({
        t: "step.delta",
        ...live,
        step: "talk:0",
        kind: "talk",
        seq: 1,
        text: " your page",
      });
      await fixture.page.getByText("Building your page", { exact: true }).waitFor();
      fixture.frame({
        t: "conversation-run-changed",
        conversation: conversation.id,
        run: { id: "run_1", author: "agent_chief", turn: "reply-nonce", status: "done" },
        steps: [
          {
            id: "talk:0",
            kind: "talk",
            text: "Your page is ready",
            status: "done",
            seq: 0,
            rev: 2,
          },
        ],
      });
      await fixture.page.getByText("Your page is ready", { exact: true }).waitFor();
      fixture.frame({ t: "run.live", conversation: conversation.id, runs: [] });
      fixture.frame({
        t: "event",
        stream: `conv:${conversation.id}`,
        seq: 1,
        effects: {
          state: conversation,
          writes: [
            {
              op: "upsert",
              table: "msg",
              key: "reply",
              n: 1,
              row: {
                id: "reply",
                conversation: conversation.id,
                seq: 1,
                author: "agent_chief",
                client_msg_id: "reply-nonce",
                parts: [{ type: "text", text: "Your page is ready" }],
              },
            },
          ],
        },
      });
      await fixture.page.locator('[data-row-id="reply"]').waitFor();
      expect(await fixture.page.getByText("Your page is ready", { exact: true }).count()).toBe(1);
      expect(fixture.errors).toEqual([]);
    } finally {
      await fixture.page.close();
    }
  });

  test("HTTP-200 rejection stays failed, retry keeps its id, and the wire renders the reply link", async () => {
    const fixture = await open({
      messageResults: [
        { status: 200, ok: false },
        { status: 200, ok: true },
      ],
    });
    try {
      await send(fixture.page);
      await fixture.page.getByText("Message not sent", { exact: true }).waitFor();
      expect(fixture.messages).toHaveLength(1);
      expect(fixture.messages[0]!.body).toEqual({
        text: "Build me a hello page",
        clientMessageId: expect.stringMatching(/^[A-Za-z0-9_-]{1,128}$/),
      });
      await fixture.page.getByRole("button", { name: "Retry", exact: true }).click();
      const reply = fixture.page.getByRole("link", { name: "Open your page" });
      await reply.waitFor();
      expect(await reply.getAttribute("href")).toBe("https://hello.preview-development.cmux.dev/");
      expect(fixture.messages.map(({ body }) => body)).toEqual([fixture.messages[0]!.body, fixture.messages[0]!.body]);
      expect(fixture.tickets).toEqual([{ method: "POST", body: null }]);
      expect(fixture.errors).toEqual([]);
    } finally {
      await fixture.page.close();
    }
  });

  for (const endpoint of ["me", "ticket", "messages"] as const) {
    test(`${endpoint} 401 shows Signed out and reloads this Chief page for server sign-in`, async () => {
      const fixture = await open({
        ...(endpoint === "me" ? { meStatus: 401 } : {}),
        ...(endpoint === "ticket" ? { ticketStatus: 401 } : {}),
        ...(endpoint === "messages" ? { messageResults: [{ status: 401 }] } : {}),
      });
      try {
        if (endpoint === "messages") await send(fixture.page);
        await fixture.page.getByText("Signed out", { exact: true }).waitFor();
        const reload = fixture.page.waitForRequest((request) => request.isNavigationRequest());
        await fixture.page.getByRole("button", { name: "Sign in again" }).click();
        expect(new URL((await reload).url()).pathname).toBe("/c/alex");
        expect(fixture.errors).toEqual([]);
      } finally {
        await fixture.page.close();
      }
    });
  }

  for (const status of [403, 404]) {
    test(`${status} does not misreport the account as signed out`, async () => {
      const fixture = await open({ meStatus: status });
      try {
        await fixture.page.getByRole("alert").getByText("This Chief is not available to this account").waitFor();
        expect(await fixture.page.getByRole("button", { name: "Sign in again" }).count()).toBe(0);
        expect(fixture.errors).toEqual([]);
      } finally {
        await fixture.page.close();
      }
    });
  }

  test("503 retries after backoff with the same id and displays the successful reply", async () => {
    const fixture = await open({ messageResults: [{ status: 503 }, { status: 200 }] });
    try {
      await send(fixture.page);
      await fixture.page.getByRole("link", { name: "Open your page" }).waitFor();
      expect(fixture.messages).toHaveLength(2);
      expect(fixture.messages[1]!.body).toEqual(fixture.messages[0]!.body);
      expect(fixture.messages[1]!.at - fixture.messages[0]!.at).toBeGreaterThanOrEqual(900);
      expect(fixture.errors).toEqual([]);
    } finally {
      await fixture.page.close();
    }
  });

  test("Japanese browser locale loads translated sign-in labels", async () => {
    const fixture = await open({ meStatus: 401 }, "ja-JP");
    try {
      await fixture.page.getByRole("button", { name: "もう一度サインイン" }).waitFor();
      await fixture.page.getByText("サインアウト中", { exact: true }).waitFor();
      expect(await fixture.page.locator("html").getAttribute("lang")).toBe("ja");
      expect(fixture.errors).toEqual([]);
    } finally {
      await fixture.page.close();
    }
  });
});
