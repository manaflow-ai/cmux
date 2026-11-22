import { describe, expect, test } from "bun:test";
import { createMockPair } from "../adapters/mock";
import { decodeBinaryFrame, encodeBinaryFrame, utf8ByteLength } from "../envelope";
import { ProtocolError, ProtocolErrorCode } from "../errors";
import { Session, type SessionSchema } from "../session";
import type { ByteStream } from "../stream";

function pair(schema?: SessionSchema) {
  const [a, b] = createMockPair();
  const errors: Error[] = [];
  const client = new Session(a, { role: "client", schema, onProtocolError: (e) => errors.push(e) });
  const server = new Session(b, { role: "server", schema, onProtocolError: (e) => errors.push(e) });
  return { a, b, client, server, errors };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

/** A client Session facing a raw transport the test drives by hand. */
function clientOnly(schema?: SessionSchema) {
  const [a, b] = createMockPair();
  const client = new Session(a, { role: "client", schema });
  return { a, b, client };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function sentText(transport: { sent: (string | Uint8Array)[] }) {
  return transport.sent.filter((m): m is string => typeof m === "string").map((m) => JSON.parse(m));
}

describe("calls", () => {
  test("typed call round trip uses the spec envelope", async () => {
    const { a, client, server } = pair();
    server.register("cmux.test.echo", (params) => ({ echoed: params }));
    await expect(client.call("cmux.test.echo", { x: 1 })).resolves.toEqual({ echoed: { x: 1 } });
    expect(sentText(a)[0]).toEqual({ t: "call", id: 1, op: "cmux.test.echo", params: { x: 1 } });
  });

  test("results may arrive out of order", async () => {
    const { client, server } = pair();
    const gates = new Map<string, ReturnType<typeof deferred<string>>>();
    server.register("cmux.test.wait", (params) => {
      const gate = deferred<string>();
      gates.set((params as { name: string }).name, gate);
      return gate.promise;
    });
    const first = client.call("cmux.test.wait", { name: "first" });
    const second = client.call("cmux.test.wait", { name: "second" });
    await tick();
    const order: string[] = [];
    void first.then((v) => order.push(v as string));
    void second.then((v) => order.push(v as string));
    gates.get("second")!.resolve("second");
    await tick();
    gates.get("first")!.resolve("first");
    await Promise.all([first, second]);
    expect(order).toEqual(["second", "first"]);
  });

  test("errors carry code, retryable and details", async () => {
    const { client, server } = pair();
    server.register("cmux.git.status", () => {
      throw new ProtocolError("cmux.git.not_a_repo", "not a git repository", { details: { cwd: "/tmp" } });
    });
    const error = await client.call("cmux.git.status", { cwd: "/tmp" }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ProtocolError);
    expect(error).toMatchObject({ code: "cmux.git.not_a_repo", retryable: false, details: { cwd: "/tmp" } });
  });

  test("unknown op and thrown non-protocol errors map to protocol codes", async () => {
    const { client, server } = pair();
    server.register("cmux.test.boom", () => {
      throw new Error("kaboom");
    });
    await expect(client.call("cmux.test.nope", {})).rejects.toMatchObject({ code: ProtocolErrorCode.unknownOp });
    await expect(client.call("cmux.test.boom", {})).rejects.toMatchObject({
      code: ProtocolErrorCode.internal,
      message: "kaboom",
    });
  });

  test("cancel sends {t:cancel}, rejects locally, and aborts the handler", async () => {
    const { a, client, server, errors } = pair();
    const aborted = deferred<boolean>();
    server.register("cmux.test.slow", (_params, ctx) => {
      ctx.signal.addEventListener("abort", () => aborted.resolve(true));
      return new Promise(() => {});
    });
    const controller = new AbortController();
    const call = client.call("cmux.test.slow", {}, { signal: controller.signal });
    await tick();
    controller.abort();
    await expect(call).rejects.toMatchObject({ code: ProtocolErrorCode.cancelled });
    expect(await aborted.promise).toBe(true);
    await tick();
    expect(sentText(a).at(-1)).toEqual({ t: "cancel", id: 1 });
    // The late cancelled reply for id 1 is dropped silently.
    expect(errors).toEqual([]);
  });

  test("an already aborted signal never sends", async () => {
    const { a, client } = pair();
    await expect(client.call("x.y.z", {}, { signal: AbortSignal.abort() })).rejects.toMatchObject({
      code: ProtocolErrorCode.cancelled,
    });
    expect(a.sent).toEqual([]);
  });

  test("bidirectional: the provider calls a handler the page registered", async () => {
    const { client, server } = pair();
    client.register("cmux.page.confirm", (params) => ({ ok: (params as { q: string }).q === "proceed?" }));
    server.register("cmux.test.ask", async (_params, ctx) => ctx.session.call("cmux.page.confirm", { q: "proceed?" }));
    await expect(client.call("cmux.test.ask", {})).resolves.toEqual({ ok: true });
  });

  test("close rejects pending calls with a retryable closed error", async () => {
    const { a, client, server } = pair();
    server.register("cmux.test.hang", () => new Promise(() => {}));
    const call = client.call("cmux.test.hang", {});
    await tick();
    a.drop("network gone");
    await expect(call).rejects.toMatchObject({ code: ProtocolErrorCode.closed, retryable: true });
    await expect(client.call("cmux.test.hang", {})).rejects.toMatchObject({ code: ProtocolErrorCode.closed });
  });

  test("cap handle id is sent as cap", async () => {
    const { a, client, server } = pair();
    let seenCap: string | undefined;
    server.register("cmux.test.cap", (_p, ctx) => {
      seenCap = ctx.cap;
      return null;
    });
    await client.call("cmux.test.cap", {}, { cap: client.handle("h-1") });
    expect(seenCap).toBe("h-1");
    expect(sentText(a)[0].cap).toBe("h-1");
  });

  test("malformed messages are reported and dropped", async () => {
    const { b, errors } = pair();
    b.send("not json");
    b.send('{"t":"ok"}');
    b.send('{"t":"ok","id":999,"value":1}');
    b.send(new Uint8Array([1, 2]));
    await tick();
    expect(errors.map((e) => e.message)).toEqual([
      "message is not valid JSON",
      "ok.id must be an id in 0..2^53-1",
      "result for unknown call id 999",
      "binary frame shorter than its 8-byte header",
    ]);
  });
});

describe("subscriptions", () => {
  test("subscribe gets {sub}, events carry seq, unsub stops them", async () => {
    const { a, client, server } = pair();
    let emit: ((data: unknown) => void) | null = null;
    let stopped = false;
    server.provide("cmux.git.status.changed", (ctx) => {
      emit = ctx.emit;
      ctx.signal.addEventListener("abort", () => (stopped = true));
    });
    const events: Array<[unknown, number]> = [];
    const sub = await client.subscribe("cmux.git.status.changed", {
      filter: { cwd: "/r" },
      onEvent: (data, seq) => events.push([data, seq]),
    });
    expect(sentText(a)[0]).toEqual({ t: "sub", id: 1, stream: "cmux.git.status.changed", filter: { cwd: "/r" } });
    emit!({ n: 1 });
    emit!({ n: 2 });
    await tick();
    expect(events).toEqual([
      [{ n: 1 }, 1],
      [{ n: 2 }, 2],
    ]);
    expect(sub.lastSeq).toBe(2);
    sub.unsubscribe();
    await tick();
    expect(stopped).toBe(true);
    expect(sentText(a).at(-1)).toEqual({ t: "unsub", sub: sub.id });
  });

  test("seq gaps and provider-declared drops (gap:true) are reported", async () => {
    const { b, client } = clientOnly();
    const gaps: Array<{ expected: number; received: number; dropped: boolean }> = [];
    const seen: number[] = [];
    const pending = client.subscribe("x.y.ev", { onEvent: (_d, seq) => seen.push(seq), onGap: (g) => gaps.push(g) });
    b.send(JSON.stringify({ t: "ok", id: 1, value: { sub: 3 } }));
    const sub = await pending;
    b.send(JSON.stringify({ t: "ev", sub: sub.id, seq: 5, data: {} }));
    b.send(JSON.stringify({ t: "ev", sub: sub.id, seq: 6, data: {} }));
    b.send(JSON.stringify({ t: "ev", sub: sub.id, seq: 9, data: {} }));
    // Decision 15: seq stays contiguous; gap:true says events were dropped before this one.
    b.send(JSON.stringify({ t: "ev", sub: sub.id, seq: 10, data: {}, gap: true }));
    await tick();
    expect(gaps).toEqual([
      { expected: 7, received: 9, dropped: false },
      { expected: 10, received: 10, dropped: true },
    ]);
    expect(seen).toEqual([5, 6, 9, 10]);
  });

  test("a malformed request with a readable id gets err bad_message", async () => {
    const [a, b] = createMockPair();
    new Session(a, { role: "server" });
    const replies: string[] = [];
    b.onMessage((m) => replies.push(m as string));
    b.send('{"t":"call","id":4}'); // op missing
    b.send('{"t":"call","id":0,"op":"x.y.z"}'); // id 0 is unreadable as a request id: no reply
    await tick();
    await tick();
    expect(replies.map((r) => JSON.parse(r))).toEqual([
      { t: "err", id: 4, code: "cmux.protocol.bad_message", message: "call.op must be a string", retryable: false },
    ]);
  });

  test("using releases a subscription and a handle at scope exit", async () => {
    const { a, client, server } = pair();
    server.provide("x.y.ev", () => {});
    {
      using sub = await client.subscribe("x.y.ev", { onEvent: () => {} });
      using handle = client.handle("h-9");
      expect(sub.id).toBe(1);
      expect(handle.released).toBe(false);
    }
    await tick();
    const tail = sentText(a).slice(-2);
    expect(tail).toEqual([
      { t: "release", handle: "h-9" },
      { t: "unsub", sub: 1 },
    ]);
  });

  test("unknown stream errors; session close ends subscriptions", async () => {
    const { a, client, server } = pair();
    await expect(client.subscribe("x.y.none", { onEvent: () => {} })).rejects.toMatchObject({
      code: ProtocolErrorCode.unknownStream,
    });
    server.provide("x.y.ev", () => {});
    const ended = deferred<ProtocolError>();
    await client.subscribe("x.y.ev", { onEvent: () => {}, onEnd: (e) => ended.resolve(e) });
    a.drop();
    expect((await ended.promise).code).toBe(ProtocolErrorCode.closed);
  });
});

describe("handles", () => {
  test("release is sent once, and exported handles see the peer release", async () => {
    const { a, client, server } = pair();
    let released = 0;
    server.exportHandle("doc-1", () => (released += 1));
    const handle = client.handle("doc-1");
    expect(client.handle("doc-1")).toBe(handle);
    handle.release();
    handle.release();
    await tick();
    expect(released).toBe(1);
    expect(sentText(a).filter((m) => m.t === "release")).toEqual([{ t: "release", handle: "doc-1" }]);
    expect(client.handle("doc-1")).not.toBe(handle);
  });

  test("session close runs exported release callbacks", async () => {
    const { b, server } = pair();
    let released = false;
    server.exportHandle("doc-2", () => (released = true));
    b.drop();
    await tick();
    expect(released).toBe(true);
  });
});

describe("byte streams", () => {
  test("binary frame header is [u32 stream BE][u32 credit BE][payload]", () => {
    const frame = encodeBinaryFrame({ stream: 0x01020304, credit: 0x0a0b0c0d, payload: new Uint8Array([9]) });
    expect([...frame]).toEqual([1, 2, 3, 4, 10, 11, 12, 13, 9]);
    const decoded = decodeBinaryFrame(frame);
    expect(decoded.stream).toBe(0x01020304);
    expect(decoded.credit).toBe(0x0a0b0c0d);
    expect([...decoded.payload]).toEqual([9]);
  });

  test("writer sends only granted credit and resumes when credit arrives", async () => {
    const { a, b, client, server } = pair();
    let serverStream: ByteStream | null = null;
    const received: number[] = [];
    server.onStream("cmux.test.upload", (stream) => {
      serverStream = stream;
      stream.onData((chunk) => received.push(chunk.byteLength));
      stream.grant(4);
    });
    const stream = await client.openStream("cmux.test.upload", { name: "f" });
    expect(stream.id % 2).toBe(1);
    const write = stream.write(new Uint8Array(10));
    let done = false;
    void write.then(() => (done = true));
    await tick();
    expect(received).toEqual([4]);
    expect(done).toBe(false);
    serverStream!.grant(100);
    await write;
    await tick();
    expect(received).toEqual([4, 6]);
    const frames = a.sent.filter((m): m is Uint8Array => typeof m !== "string").map(decodeBinaryFrame);
    expect(frames.map((f) => [f.stream, f.payload.byteLength])).toEqual([
      [stream.id, 4],
      [stream.id, 6],
    ]);
    expect(sentText(b).filter((m) => m.t === "credit")).toEqual([
      { t: "credit", stream: stream.id, bytes: 4 },
      { t: "credit", stream: stream.id, bytes: 100 },
    ]);
  });

  test("window mode re-grants consumed bytes, frames split at maxFramePayload, end closes both ways", async () => {
    const [ta, tb] = createMockPair();
    const client = new Session(ta, { role: "client", maxFramePayload: 3 });
    const server = new Session(tb, { role: "server" });
    const chunks: string[] = [];
    const serverEnded = deferred<ProtocolError | null>();
    server.onStream("cmux.test.download", (stream) => {
      stream.onEnd((e) => serverEnded.resolve(e));
      void stream.write(new TextEncoder().encode("hello world")).then(() => stream.end());
    });
    const stream = await client.openStream("cmux.test.download", undefined, { window: 4 });
    const ended = deferred<ProtocolError | null>();
    stream.onData((chunk) => chunks.push(new TextDecoder().decode(chunk)));
    stream.onEnd((e) => ended.resolve(e));
    await tick();
    await tick();
    await stream.end();
    expect(await ended.promise).toBeNull();
    expect(await serverEnded.promise).toBeNull();
    expect(chunks.join("")).toBe("hello world");
    expect(Math.max(...chunks.map((c) => c.length))).toBeLessThanOrEqual(4);
  });

  test("a peer exceeding its credit aborts the stream", async () => {
    const { b, client, server } = pair();
    server.onStream("cmux.test.s", () => {});
    const stream = await client.openStream("cmux.test.s", undefined, {});
    const ended = deferred<ProtocolError | null>();
    stream.onEnd((e) => ended.resolve(e));
    b.send(encodeBinaryFrame({ stream: stream.id, credit: 0, payload: new Uint8Array(5) }));
    expect((await ended.promise)?.code).toBe(ProtocolErrorCode.creditExceeded);
  });

  test("calls are not starved behind a large stream", async () => {
    const [ta, tb] = createMockPair();
    const client = new Session(ta, { role: "client", maxFramePayload: 1024 });
    const server = new Session(tb, { role: "server" });
    server.register("cmux.test.ping", () => "pong");
    server.onStream("cmux.test.sink", (stream) => stream.grant(1024));
    const stream = await client.openStream("cmux.test.sink", undefined);
    void stream.write(new Uint8Array(1024 * 1024));
    // Only one 1 KiB frame went out; the rest waits for credit, so the call goes straight through.
    await expect(client.call("cmux.test.ping", {})).resolves.toBe("pong");
    expect(ta.sent.filter((m) => typeof m !== "string").length).toBe(1);
  });

  test("unknown stream op is refused with the normal err envelope", async () => {
    const { client } = pair();
    await expect(client.openStream("cmux.test.none", undefined)).rejects.toMatchObject({
      code: ProtocolErrorCode.unknownOp,
    });
  });
});

describe("schema enforcement", () => {
  const schema: SessionSchema = {
    validateParams: (op, v) =>
      op === "cmux.test.add"
        ? typeof (v as { n?: unknown })?.n === "number"
          ? []
          : [{ path: "/n", message: "expected number" }]
        : null,
    validateResult: (op, v) =>
      op === "cmux.test.add" ? (typeof v === "number" ? [] : [{ path: "", message: "nan" }]) : null,
    validateEvent: (ev, v) =>
      ev === "cmux.test.tick" ? (typeof v === "number" ? [] : [{ path: "", message: "nan" }]) : null,
  };

  test("invalid incoming params are refused before the handler runs", async () => {
    const { client, server } = pair(schema);
    let ran = false;
    server.register("cmux.test.add", () => {
      ran = true;
      return 1;
    });
    await expect(client.call("cmux.test.add", { n: "1" })).rejects.toMatchObject({
      code: ProtocolErrorCode.invalidParams,
    });
    expect(ran).toBe(false);
  });

  test("invalid results and unknown ops are refused by the receiver", async () => {
    const { b, client } = clientOnly(schema);
    const bad = client.call("cmux.test.add", { n: 1 });
    const unknown = client.call("cmux.test.other", {});
    await tick();
    b.send(JSON.stringify({ t: "ok", id: 1, value: "three" }));
    b.send(JSON.stringify({ t: "ok", id: 2, value: 1 }));
    const [badResult, unknownResult] = await Promise.allSettled([bad, unknown]);
    expect(badResult).toMatchObject({ status: "rejected", reason: { code: ProtocolErrorCode.invalidResult } });
    expect(unknownResult).toMatchObject({ status: "rejected", reason: { code: ProtocolErrorCode.invalidResult } });
  });

  test("invalid events are dropped and reported", async () => {
    const { b, client } = clientOnly(schema);
    const sub = client.subscribe("cmux.test.tick", { onEvent: (d) => good.push(d as number), onInvalid: () => bad++ });
    const good: number[] = [];
    let bad = 0;
    await tick();
    b.send(JSON.stringify({ t: "ok", id: 1, value: { sub: 7 } }));
    await sub;
    b.send(JSON.stringify({ t: "ev", sub: 7, seq: 1, data: 1 }));
    b.send(JSON.stringify({ t: "ev", sub: 7, seq: 2, data: "x" }));
    await tick();
    expect(good).toEqual([1]);
    expect(bad).toBe(1);
  });
});

describe("per-tick write batching", () => {
  test("messages queued in one tick go out as one sendBatch, in order", async () => {
    const [a, b] = createMockPair({ batch: true });
    const client = new Session(a, { role: "client" });
    const server = new Session(b, { role: "server" });
    server.register("cmux.test.echo", (p) => p);
    const calls = [1, 2, 3].map((n) => client.call("cmux.test.echo", { n }));
    expect(a.sent).toEqual([]); // nothing leaves until the tick ends
    await expect(Promise.all(calls)).resolves.toEqual([{ n: 1 }, { n: 2 }, { n: 3 }]);
    expect(a.writes).toEqual([3]);
    expect(sentText(a).map((m) => m.id)).toEqual([1, 2, 3]);
    // The server answered in one tick too.
    expect(b.writes).toEqual([3]);
  });

  test("without sendBatch, one send per message keeps order across text and binary", async () => {
    const [a, b] = createMockPair();
    const client = new Session(a, { role: "client" });
    const server = new Session(b, { role: "server" });
    server.onStream("cmux.test.sink", (stream) => stream.grant(10));
    const stream = await client.openStream("cmux.test.sink", undefined);
    await tick();
    const before = a.sent.length;
    void stream.write(new Uint8Array([1, 2]));
    void stream.end();
    void client.call("cmux.test.none", {}).catch(() => {});
    await tick();
    const kinds = a.sent.slice(before).map((m) => (typeof m === "string" ? JSON.parse(m).t : "binary"));
    expect(kinds).toEqual(["binary", "end", "call"]);
    expect(a.writes.slice(-3)).toEqual([1, 1, 1]);
  });

  test("close flushes queued messages before closing the transport", async () => {
    const { a, client } = clientOnly();
    client.handle("h-1").release();
    client.close();
    expect(sentText(a)).toEqual([{ t: "release", handle: "h-1" }]);
  });

  test("a transport send failure closes the session and rejects pending calls", async () => {
    const { a, client } = clientOnly();
    const original = a.send.bind(a);
    a.send = () => {
      throw new Error("socket broke");
    };
    const call = client.call("cmux.test.x", {});
    await expect(call).rejects.toMatchObject({ code: ProtocolErrorCode.closed, message: "send failed: socket broke" });
    expect(client.closed).toBe(true);
    a.send = original;
  });
});

describe("16 MiB limit in UTF-8 bytes", () => {
  test("a message under 16 Mi UTF-16 units but over 16 MiB of UTF-8 is refused", async () => {
    const { a, client } = clientOnly();
    // 6 Mi x "€" (3 UTF-8 bytes each) is 18 MiB on the wire but only 6 Mi string units.
    const big = "€".repeat(6 * 1024 * 1024);
    await expect(client.call("cmux.test.big", { big })).rejects.toThrow("exceeds 16 MiB");
    // 5 Mi x "€" is 15 MiB: allowed.
    const ok = "€".repeat(5 * 1024 * 1024);
    void client.call("cmux.test.big", { ok }).catch(() => {});
    await tick();
    expect(a.sent).toHaveLength(1);
  });

  test("utf8ByteLength matches TextEncoder, including surrogate pairs and lone surrogates", () => {
    for (const text of ["", "abc", "é", "€", "😀", "a😀b€é", "\ud800", "x\udc00y"]) {
      expect(utf8ByteLength(text)).toBe(new TextEncoder().encode(text).byteLength);
    }
  });

  test("incoming text over the limit is dropped and reported", async () => {
    const [a, b] = createMockPair();
    const errors: Error[] = [];
    new Session(a, { role: "client", onProtocolError: (e) => errors.push(e) });
    b.send(`{"t":"ok","id":1,"value":"${"€".repeat(6 * 1024 * 1024)}"}`);
    await tick();
    expect(errors.map((e) => e.message)).toEqual(["message exceeds 16 MiB"]);
  });
});
