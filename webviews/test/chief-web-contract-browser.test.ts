// l10n-allow-file: browser fixture labels, not shipped UI.
// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page, type WebSocketRoute } from "playwright";
import type { ViteDevServer } from "vite";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chief-web-contract-browser.test.ts", async () => {
  const identity = { chiefId: "agent_chief", mainConversationId: "conv_chief", handle: "alex" };
  const conversation = {
    id: identity.mainConversationId,
    participants: [
      { id: "user_alex", kind: "person", display_name: "Alex" },
      { id: "agent_chief", kind: "agent", agent_class: "mux", display_name: "Chief" },
    ],
  };
  type MessageBody = { text: string; clientMessageId: string };
  type Fixture = {
    login?: {
      harness?: "claude" | "codex";
      existing?: boolean;
      resumed?: boolean;
      status?: number;
      finishResults?: number[];
      finishWait?: Promise<void>;
    };
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
    // Exercise the normal browser fallback when asynchronous start cannot open a popup.
    await page.addInitScript(() => {
      window.open = () => null;
    });
    const messages: { body: MessageBody; at: number }[] = [];
    const tickets: { method: string; body: string | null }[] = [];
    const errors: string[] = [];
    const loginCalls: { method: string; body: Record<string, unknown> | null }[] = [];
    let resumed = fixture.login?.resumed ?? false;
    const login = {
      loginId: "login_test",
      url: "https://claude.com/cai/oauth/authorize",
      needsCode: fixture.login?.harness !== "codex",
      ...(fixture.login?.harness === "codex" ? { userCode: "ABCD-1234" } : {}),
    };
    let finishes = 0;
    let finishHandled!: () => void;
    const finishProcessed = new Promise<void>((resolve) => {
      finishHandled = resolve;
    });
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
              rows: {
                table: "msg",
                rows: fixture.login
                  ? [
                      {
                        key: "auth",
                        n: 1,
                        row: {
                          id: "auth",
                          seq: 1,
                          author: identity.chiefId,
                          conversation: conversation.id,
                          client_msg_id: `chief-machine-auth:${identity.chiefId}:run_42`,
                          parts: [{ type: "text", text: "Sign in to continue." }],
                        },
                      },
                    ]
                  : [],
              },
            }),
          );
        if (frame.t === "run.live.get")
          wire.send(JSON.stringify({ t: "run.live", conversation: conversation.id, runs: [] }));
      });
      wire.send(JSON.stringify({ t: "welcome", principal: { user: "user_alex" } }));
    });
    await page.route("**/v1/chief/machine-login/*", async (route) => {
      const request = route.request();
      const body = request.method() === "POST" ? (request.postDataJSON() as Record<string, unknown>) : null;
      loginCalls.push({ method: request.method(), body });
      let value: unknown = resumed
        ? { signedIn: true, resumed: true }
        : {
            waiting: true,
            harness: fixture.login?.harness ?? "claude",
            login: fixture.login?.existing ? login : null,
          };
      let status = fixture.login?.status ?? 200;
      if (body?.action === "start") value = login;
      if (body?.action === "cancel") value = { cancelled: true };
      if (body?.action === "finish") {
        await fixture.login?.finishWait;
        status = fixture.login?.finishResults?.[finishes++] ?? 200;
        if (status === 200) {
          resumed = true;
          value = { signedIn: true, resumed: true };
        }
      }
      try {
        await route.fulfill({
          status,
          contentType: "application/json",
          body: JSON.stringify(
            status === 200
              ? { ok: true, value }
              : {
                  ok: false,
                  error: { code: "chief.machine.login_unavailable", message: "synthetic-provider-secret" },
                },
          ),
        });
      } catch (error) {
        // A deliberately held finish can be aborted by the run replacement under test.
        if (!fixture.login?.finishWait) throw error;
      } finally {
        if (body?.action === "finish") finishHandled();
      }
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
      loginCalls,
      finishProcessed,
      errors,
      frame: (value: unknown) => socket?.send(JSON.stringify(value)),
    };
  }

  test("machine login reload recovery offers an explicit provider page and resumes the same run", async () => {
    const fixture = await open({ login: {} });
    try {
      const card = fixture.page.getByTestId("chief-machine-login");
      await card.getByRole("button", { name: "Sign in to Claude", exact: true }).click();
      const link = card.getByRole("link", { name: "Open sign-in page" });
      expect(await link.getAttribute("href")).toBe("https://claude.com/cai/oauth/authorize");
      expect(await link.getAttribute("rel")).toContain("noreferrer");
      await card.getByRole("textbox", { name: "Sign-in code" }).fill("synthetic-code");
      await card.getByRole("button", { name: "Continue", exact: true }).click();
      await card.waitFor({ state: "hidden" });
      expect(fixture.loginCalls.map((call) => call.body?.action ?? call.method)).toEqual(["GET", "start", "finish"]);
      expect(fixture.loginCalls.at(-1)?.body).toEqual({
        action: "finish",
        loginId: "login_test",
        code: "synthetic-code",
      });
      expect(fixture.messages).toEqual([]);
      await fixture.page.reload();
      await fixture.page.waitForFunction(() => document.querySelector(".chief-web__connection")?.textContent === "");
      await fixture.page.waitForFunction(() => !document.querySelector("[data-testid=chief-machine-login]"));
      expect(fixture.messages).toEqual([]);
      expect(fixture.errors).toEqual([]);
    } finally {
      await fixture.page.close();
    }
  });

  test("ambiguous finish clears the code and retries without replaying it", async () => {
    const fixture = await open({ login: { existing: true, finishResults: [503, 200] } });
    try {
      const card = fixture.page.getByTestId("chief-machine-login");
      await card.getByRole("textbox", { name: "Sign-in code" }).fill("synthetic-single-use-code");
      await card.getByRole("button", { name: "Continue", exact: true }).click();
      await card.getByRole("alert").waitFor();
      expect(await card.getByRole("textbox").count()).toBe(0);
      expect(await card.textContent()).not.toContain("synthetic-provider-secret");
      await card.getByRole("button", { name: "Continue", exact: true }).click();
      await card.waitFor({ state: "hidden" });
      const attempts = fixture.loginCalls.filter((call) => call.body?.action === "finish");
      expect(attempts.map((call) => call.body)).toEqual([
        { action: "finish", loginId: "login_test", code: "synthetic-single-use-code" },
        { action: "finish", loginId: "login_test" },
      ]);
      expect(fixture.messages).toEqual([]);
    } finally {
      await fixture.page.close();
    }
  });

  test("Codex device approval uses GET's harness and never requires a pasted code", async () => {
    const fixture = await open({ login: { harness: "codex", existing: true } });
    try {
      const card = fixture.page.getByTestId("chief-machine-login");
      await card.getByText("Sign in to Codex", { exact: true }).waitFor();
      await card.getByText("ABCD-1234", { exact: true }).waitFor();
      expect(await card.getByRole("textbox").count()).toBe(0);
      expect(fixture.loginCalls).toEqual([{ method: "GET", body: null }]);
      await card.getByRole("button", { name: "Continue", exact: true }).click();
      await card.waitFor({ state: "hidden" });
      expect(fixture.loginCalls.at(-1)?.body).toEqual({ action: "finish", loginId: "login_test" });
    } finally {
      await fixture.page.close();
    }
  });

  test("cancel leaves the run waiting and allows an explicit new sign-in", async () => {
    const fixture = await open({ login: { existing: true } });
    try {
      const card = fixture.page.getByTestId("chief-machine-login");
      await card.getByRole("textbox", { name: "Sign-in code" }).fill("discarded-code");
      await card.getByRole("button", { name: "Cancel", exact: true }).click();
      await card.getByRole("button", { name: "Sign in to Claude", exact: true }).waitFor();
      expect(fixture.loginCalls.at(-1)?.body).toEqual({ action: "cancel", loginId: "login_test" });
      expect(await card.getByRole("textbox").count()).toBe(0);
      expect(fixture.messages).toEqual([]);
    } finally {
      await fixture.page.close();
    }
  });

  test("replacing a run aborts finish and ignores its late reply", async () => {
    let release!: () => void;
    const wait = new Promise<void>((resolve) => {
      release = resolve;
    });
    const fixture = await open({ login: { existing: true, finishWait: wait } });
    try {
      const card = fixture.page.getByTestId("chief-machine-login");
      await card.getByRole("textbox", { name: "Sign-in code" }).fill("synthetic-code");
      const finish = fixture.page.waitForRequest(
        (request) => request.method() === "POST" && request.postDataJSON()?.action === "finish",
      );
      await card.getByRole("button", { name: "Continue", exact: true }).click();
      await finish;
      const replacement = fixture.page.waitForRequest(
        (request) => request.method() === "GET" && request.url().endsWith("/machine-login/run_43"),
      );
      fixture.frame({
        t: "conversation-run-changed",
        conversation: conversation.id,
        run: { id: "run_43", author: identity.chiefId, harness: "pi-durable", status: "running" },
        steps: [{ id: "machine:sign-in", kind: "note", text: "Waiting" }],
      });
      await replacement;
      await card.getByRole("textbox", { name: "Sign-in code" }).waitFor();
      release();
      await fixture.finishProcessed;
      expect(await card.getByRole("textbox", { name: "Sign-in code" }).inputValue()).toBe("");
      expect(await card.isVisible()).toBe(true);
      expect(fixture.messages).toEqual([]);
    } finally {
      release();
      await fixture.page.close();
    }
  });

  test("machine-login 401 signs out the page and 404 removes stale persisted notes", async () => {
    const expired = await open({ login: { status: 401 } });
    const stale = await open({ login: { status: 404 } });
    try {
      await expired.page.getByRole("button", { name: "Sign in again", exact: true }).waitFor();
      expect(await expired.page.getByRole("textbox", { name: "Message your Chief" }).isDisabled()).toBe(true);
      await stale.page.waitForFunction(() => document.querySelector(".chief-web__connection")?.textContent === "");
      await stale.page.waitForFunction(() => !document.querySelector("[data-testid=chief-machine-login]"));
      expect(stale.loginCalls).toEqual([{ method: "GET", body: null }]);
    } finally {
      await expired.page.close();
      await stale.page.close();
    }
  });

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
