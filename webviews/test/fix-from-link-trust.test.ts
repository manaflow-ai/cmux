// l10n-allow-file: test fixture transport replies, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import { PERMISSION_GROUP_OPS } from "../src/agent-session/acpmux/permissions/protocol";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
  setNativeHost(async (method) => (method === "transport.gesture" ? { ticket: "fix-ticket" } : undefined));
});
afterAll(async () => {
  setNativeHost(undefined);
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

type Message = { id: number; method: string; params: Record<string, unknown> };
const sessionId = "non-object-frame";
const session = { sessionId, cwd: "/home/dev/project", harness: "codex", status: "idle", updatedAt: 1 };
const groups = {
  groups: [],
  chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
  coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
  batching: { windowMs: 100, maxItems: 32, maxPendingGroups: 64, maxReceipts: 64 },
};

/** An authenticated daemon that answers the handshake and leaves `probe` for the test to answer. */
class ProbeSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: Message[] = [];
  trusted = false;

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    this.sent.push(message);
    if (message.method === "chat.fix_from_link.prepare") {
      queueMicrotask(() =>
        this.onmessage?.({
          data: JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            ...(this.trusted
              ? { result: { cwd: "/repo" } }
              : {
                  error: { code: -32000, message: "Trust first", data: { reason: "trust.pending", cwd: "/repo" } },
                }),
          }),
        }),
      );
      return;
    }
    queueMicrotask(() => {
      const result =
        message.method === "chat.fix_from_link"
          ? { sessionId: "issue-chat" }
          : message.method === "initialize"
            ? {
                protocolVersion: 1,
                _meta: { acpmux: { origin: "local", operations: Object.values(PERMISSION_GROUP_OPS) } },
              }
            : message.method === "_acpmux/watch"
              ? { sessions: [session] }
              : message.method === "_acpmux/attach"
                ? { session, lastSeq: 0, events: [] }
                : message.method === PERMISSION_GROUP_OPS.groups
                  ? groups
                  : {};
      this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
    });
  }

  close(): void {
    this.readyState = 3;
  }
}

const host = {
  protocolVersion: 1 as const,
  transport: "acpmux-websocket" as const,
  endpoint: "ws://non-object.invalid/",
  token: "test",
  sessionId,
};

for (const cwd of [undefined, "/repo", "/repo/packages/app"])
  for (const answer of ["trust", "decline", "close"] as const) {
    test(`fix from link keeps its gesture through ${answer} from ${cwd ?? "discovery"}`, async () => {
      const socket = new ProbeSocket();
      const client = await AcpmuxDirectClient.connect(
        host,
        () => {},
        undefined,
        () => socket as unknown as WebSocket,
      );
      let retry: (() => void) | undefined;
      let decline: (() => void) | undefined;
      let refused!: () => void;
      const question = new Promise<void>((resolve) => {
        refused = resolve;
      });
      client.onTrustRefused = (refusal, again, declined) => {
        expect(refusal).toEqual({ reason: "trust.pending", cwd: "/repo" });
        retry = again;
        decline = declined;
        refused();
      };
      try {
        let settled = false;
        const started = client.fixFromLink("https://github.com/acme/widget/issues/12", cwd, "claude", "model");
        void started.then(
          () => {
            settled = true;
          },
          () => {
            settled = true;
          },
        );
        await question;
        expect(settled).toBe(false);
        if (answer === "trust") {
          socket.trusted = true;
          retry!();
          retry!(); // One answer cannot create two chats while its request is pending.
          expect(await started).toBe("issue-chat");
          const fixes = socket.sent.filter((message) => message.method === "chat.fix_from_link");
          expect(fixes).toHaveLength(1);
          expect(socket.sent.filter((message) => message.method === "chat.fix_from_link.prepare")).toHaveLength(2);
          expect(fixes[0]!.params).toEqual({
            url: "https://github.com/acme/widget/issues/12",
            ...(cwd ? { cwd } : {}),
            harness: "claude",
            model: "model",
            _meta: { cmuxGesture: "fix-ticket" },
          });
        } else {
          if (answer === "decline") decline!();
          else client.close();
          await expect(started).rejects.toMatchObject({ code: "start.cancelled" });
          retry!();
          expect(socket.sent.filter((message) => message.method === "chat.fix_from_link")).toHaveLength(0);
        }
      } finally {
        client.close();
      }
    });
  }
