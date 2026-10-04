import { describe, expect, test } from "bun:test";
import {
  CdpBindingTransport,
  CefQueryTransport,
  DEFAULT_RECEIVE_NAME,
  WebKitTransport,
  findWebKitHandler,
  type CefQueryRequest,
  type GlobalTarget,
} from "../adapters/engine";
import { MessagePortTransport, type MessagePortLike } from "../adapters/message-port";
import { AUTH_REFUSED_CLOSE_CODE, connectWebSocket, type WebSocketLike } from "../adapters/websocket";
import { ProtocolErrorCode } from "../errors";
import { Session } from "../session";
import type { TransportMessage } from "../transport";

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/** Fake WebSocket that a test drives like a listener would. */
class FakeSocket implements WebSocketLike {
  readyState = 0;
  binaryType = "blob";
  readonly sent: Array<string | ArrayBufferView> = [];
  closedWith: { code?: number; reason?: string } | null = null;
  private readonly listeners = new Map<string, Array<(event: never) => void>>();

  addEventListener(type: string, listener: (event: never) => void): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  send(data: string | ArrayBufferView): void {
    if (this.readyState !== 1) throw new Error("not open");
    this.sent.push(data);
  }
  close(code?: number, reason?: string): void {
    this.closedWith = { code, reason };
    this.readyState = 2;
    queueMicrotask(() => this.serverClose(code ?? 1000, reason ?? ""));
  }
  emit(type: string, event: unknown = {}): void {
    for (const listener of this.listeners.get(type) ?? []) listener(event as never);
  }
  serverOpen(): void {
    this.readyState = 1;
    this.emit("open");
  }
  serverSend(data: unknown): void {
    this.emit("message", { data });
  }
  serverClose(code: number, reason = ""): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit("close", { code, reason });
  }
}

describe("WebSocket adapter", () => {
  test("first frame is auth, the token stays out of the URL, binary arrives as Uint8Array", async () => {
    let socket!: FakeSocket;
    const pending = connectWebSocket({
      url: "ws://127.0.0.1:9/pane",
      token: "tok-1",
      createSocket: (url) => {
        expect(url).toBe("ws://127.0.0.1:9/pane");
        return (socket = new FakeSocket());
      },
    });
    socket.serverOpen();
    const transport = await pending;
    expect(socket.binaryType).toBe("arraybuffer");
    expect(socket.sent[0]).toBe('{"t":"auth","token":"tok-1"}');
    const received: TransportMessage[] = [];
    transport.onMessage((m) => received.push(m));
    socket.serverSend('{"t":"ok","id":1,"value":null}');
    socket.serverSend(new Uint8Array([0, 0, 0, 1, 0, 0, 0, 0, 7]).buffer);
    expect(received[0]).toBe('{"t":"ok","id":1,"value":null}');
    expect(received[1]).toBeInstanceOf(Uint8Array);
    expect([...(received[1] as Uint8Array)]).toEqual([0, 0, 0, 1, 0, 0, 0, 0, 7]);
    transport.send(new Uint8Array([1]));
    expect(socket.sent[1]).toBeInstanceOf(Uint8Array);
  });

  test("an err with id 0 before any other message is a refusal: the client closes", async () => {
    let socket!: FakeSocket;
    const pending = connectWebSocket({ url: "ws://x", token: "bad", createSocket: () => (socket = new FakeSocket()) });
    socket.serverOpen();
    const transport = await pending;
    const closed = new Promise((resolve) => transport.onClose(resolve));
    const session = new Session(transport, { role: "client" });
    const call = session.call("cmux.git.status", { cwd: "/" });
    socket.serverSend('{"t":"err","id":0,"code":"cmux.auth.invalid_token","message":"bad token","retryable":false}');
    expect(await closed).toMatchObject({ code: AUTH_REFUSED_CLOSE_CODE, reason: "bad token" });
    expect(socket.closedWith?.code).toBe(AUTH_REFUSED_CLOSE_CODE);
    await expect(call).rejects.toMatchObject({ code: ProtocolErrorCode.closed });
  });

  test("authAck ok waits for {t:ok,id:0}; a refusal rejects connect with auth_refused", async () => {
    let socket!: FakeSocket;
    const accepted = connectWebSocket({
      url: "ws://x",
      token: "t",
      authAck: "ok",
      createSocket: () => (socket = new FakeSocket()),
    });
    socket.serverOpen();
    let resolved = false;
    void accepted.then(() => (resolved = true));
    await tick();
    expect(resolved).toBe(false);
    socket.serverSend('{"t":"ok","id":0,"value":null}');
    await accepted;

    const refused = connectWebSocket({
      url: "ws://x",
      token: "t",
      authAck: "ok",
      createSocket: () => (socket = new FakeSocket()),
    });
    socket.serverOpen();
    socket.serverSend('{"t":"err","id":0,"code":"cmux.auth.expired","message":"expired","retryable":true}');
    await expect(refused).rejects.toMatchObject({ code: ProtocolErrorCode.authRefused, message: "expired" });
    expect(socket.closedWith?.code).toBe(AUTH_REFUSED_CLOSE_CODE);
  });

  test("listener closing during auth rejects; connect failure rejects retryable", async () => {
    let socket!: FakeSocket;
    const refused = connectWebSocket({
      url: "ws://x",
      token: "t",
      authAck: "ok",
      createSocket: () => (socket = new FakeSocket()),
    });
    socket.serverOpen();
    socket.serverClose(1008, "policy");
    await expect(refused).rejects.toMatchObject({ code: ProtocolErrorCode.authRefused });

    const failed = connectWebSocket({ url: "ws://x", token: "t", createSocket: () => (socket = new FakeSocket()) });
    socket.readyState = 3;
    socket.emit("error");
    await expect(failed).rejects.toMatchObject({ code: ProtocolErrorCode.closed, retryable: true });
  });
});

describe("WebKit adapter", () => {
  test("postMessage reply is delivered as the response; host pushes use the receive function", async () => {
    const posted: unknown[] = [];
    const target: GlobalTarget = {
      webkit: {
        messageHandlers: {
          cmuxPane: {
            postMessage: (body: unknown) => {
              posted.push(body);
              const msg = JSON.parse(body as string) as { id: number };
              return Promise.resolve(JSON.stringify({ t: "ok", id: msg.id, value: { tab: 3 } }));
            },
          },
        },
      },
    };
    const handler = findWebKitHandler("cmuxPane", target);
    expect(handler).not.toBeNull();
    expect(findWebKitHandler("missing", target)).toBeNull();
    const transport = new WebKitTransport({ handler: handler!, receiveName: "__push", target });
    const session = new Session(transport, { role: "client" });
    await expect(session.call("cmux.ui.tab.open", { url: "x" })).resolves.toEqual({ tab: 3 });
    expect(JSON.parse(posted[0] as string)).toMatchObject({ t: "call", op: "cmux.ui.tab.open" });

    const pushed: TransportMessage[] = [];
    transport.onMessage((m) => pushed.push(m));
    (target.__push as (m: string) => void)('{"t":"ev","sub":1,"seq":1,"data":{}}');
    expect(pushed).toEqual(['{"t":"ev","sub":1,"seq":1,"data":{}}']);
    transport.close();
    expect(target.__push).toBeUndefined();
  });

  test("an empty reply delivers nothing, a rejected reply closes, binary is refused", async () => {
    let fail = false;
    const transport = new WebKitTransport({
      handler: { postMessage: () => (fail ? Promise.reject(new Error("no handler")) : Promise.resolve(null)) },
    });
    const got: TransportMessage[] = [];
    transport.onMessage((m) => got.push(m));
    transport.send('{"t":"release","handle":"h"}');
    await tick();
    expect(got).toEqual([]);
    expect(() => transport.send(new Uint8Array(1))).toThrow("text envelopes only");
    fail = true;
    const closed = new Promise((resolve) => transport.onClose(resolve));
    transport.send('{"t":"release","handle":"h"}');
    expect(await closed).toMatchObject({ reason: "webkit bridge error: no handler" });
  });
});

describe("CEF adapters", () => {
  test("cefQuery: one query per send, persistent listen query carries pushes, close cancels it", async () => {
    const queries: CefQueryRequest[] = [];
    const cancelled: number[] = [];
    const query = (request: CefQueryRequest) => {
      queries.push(request);
      if (!request.persistent) {
        const msg = JSON.parse(request.request) as { id: number };
        queueMicrotask(() => request.onSuccess(JSON.stringify({ t: "ok", id: msg.id, value: "pong" })));
      }
      return queries.length;
    };
    const transport = new CefQueryTransport({ query, cancel: (id) => cancelled.push(id), listenRequest: "listen" });
    expect(queries[0]).toMatchObject({ request: "listen", persistent: true });
    const session = new Session(transport, { role: "client" });
    await expect(session.call("cmux.test.ping", {})).resolves.toBe("pong");
    const got: TransportMessage[] = [];
    transport.onMessage((m) => got.push(m));
    queries[0].onSuccess("push-1");
    queries[0].onSuccess("push-2");
    expect(got).toEqual(["push-1", "push-2"]);
    transport.close();
    expect(cancelled).toEqual([1]);
  });

  test("cefQuery failure closes the transport and rejects pending calls", async () => {
    const transport = new CefQueryTransport({
      query: (request) => {
        queueMicrotask(() => request.onFailure(-1, "router gone"));
        return 1;
      },
    });
    const session = new Session(transport, { role: "client" });
    await expect(session.call("cmux.test.ping", {})).rejects.toMatchObject({ code: ProtocolErrorCode.closed });
  });

  test("CDP binding: one-way send, host delivers through the receive function", async () => {
    const target: GlobalTarget = {};
    const sent: string[] = [];
    const transport = new CdpBindingTransport({ binding: (payload) => sent.push(payload), target });
    const session = new Session(transport, { role: "client" });
    const call = session.call("cmux.test.ping", {});
    const msg = JSON.parse(sent[0]) as { id: number };
    (target[DEFAULT_RECEIVE_NAME] as (m: string) => void)(JSON.stringify({ t: "ok", id: msg.id, value: 1 }));
    await expect(call).resolves.toBe(1);
    expect(() => new CdpBindingTransport({ binding: () => {}, target })).toThrow("already installed");
    transport.close();
    expect(target[DEFAULT_RECEIVE_NAME]).toBeUndefined();
  });
});

describe("MessagePort adapter", () => {
  test("text and binary cross a real MessageChannel; close posts bye and closes the peer", async () => {
    const channel = new MessageChannel();
    const left = new MessagePortTransport(channel.port1 as unknown as MessagePortLike);
    const right = new MessagePortTransport(channel.port2 as unknown as MessagePortLike);
    const server = new Session(right, { role: "server" });
    server.register("cmux.test.echo", (p) => p);
    const client = new Session(left, { role: "client" });
    await expect(client.call("cmux.test.echo", { a: 1 })).resolves.toEqual({ a: 1 });

    const got = new Promise<TransportMessage>((resolve) => right.onMessage(resolve));
    left.send(new Uint8Array([0, 0, 0, 2, 0, 0, 0, 0, 5]));
    const frame = await got;
    expect(frame).toBeInstanceOf(Uint8Array);
    expect([...(frame as Uint8Array)]).toEqual([0, 0, 0, 2, 0, 0, 0, 0, 5]);

    const closed = new Promise((resolve) => right.onClose(resolve));
    left.close();
    expect(await closed).toMatchObject({ reason: "peer closed" });
  });
});
