import { describe, expect, test } from "bun:test";
import {
  BridgePageClient,
  createPageClient,
  findReplyHandler,
  isPageError,
  RECEIVE_NAME,
  type ReplyHandler,
} from "./pageClient";

/** A fake host: answers each posted envelope with `reply(envelope)`. */
function host(reply: (message: any) => unknown) {
  const posted: any[] = [];
  const handler: ReplyHandler = {
    postMessage: async (body) => {
      posted.push(body);
      return reply(body);
    },
  };
  const target: Record<string, unknown> = {};
  const client = new BridgePageClient(handler, target);
  return { client, posted, target };
}

describe("BridgePageClient", () => {
  test("call posts a pane-protocol call envelope and returns the ok value", async () => {
    const { client, posted } = host((m) => ({ t: "ok", id: m.id, value: { n: 1 } }));
    expect(await client.call<{ n: number }>("cmux.history.entries.list", { limit: 1 })).toEqual({ n: 1 });
    expect(posted[0]).toEqual({ t: "call", id: 1, op: "cmux.history.entries.list", params: { limit: 1 } });
  });

  test("decision 31: a call carries its opid and events hand the echoed opid to the listener", async () => {
    const { client, posted, target } = host((m) =>
      m.t === "sub" ? { t: "ok", id: m.id, value: { sub: 7 } } : { t: "ok", id: m.id, value: null },
    );
    await client.call("cmux.markdown.save", { text: "x" }, { opid: "p-1" });
    expect(posted[0]).toEqual({ t: "call", id: 1, op: "cmux.markdown.save", params: { text: "x" }, opid: "p-1" });
    const events: unknown[] = [];
    await client.subscribe("cmux.markdown.changes", (data, seq, meta) => events.push([data, seq, meta]));
    (target[RECEIVE_NAME] as (m: unknown) => void)({ t: "ev", sub: 7, seq: 1, data: { a: 1 }, opid: "p-1" });
    (target[RECEIVE_NAME] as (m: unknown) => void)({ t: "ev", sub: 7, seq: 2, data: { a: 2 } });
    expect(events).toEqual([
      [{ a: 1 }, 1, { opid: "p-1" }],
      [{ a: 2 }, 2, {}],
    ]);
  });

  test("an event that arrives before the subscribe reply resolves reaches the listener", async () => {
    // The host may deliver a stream's first event (the icon picker's open session) before the
    // page has read the reply that names the subscription.
    let receive: (m: unknown) => void = () => undefined;
    const { client, target } = host((m) => {
      if (m.t === "sub") receive({ t: "ev", sub: 3, seq: 1, data: { session: "s1" } });
      return m.t === "sub" ? { t: "ok", id: m.id, value: { sub: 3 } } : { t: "ok", id: m.id, value: null };
    });
    receive = target[RECEIVE_NAME] as (m: unknown) => void;
    const events: unknown[] = [];
    await client.subscribe("cmux.iconPicker.session", (data, seq) => events.push([data, seq]));
    receive({ t: "ev", sub: 3, seq: 2, data: { session: "s2" } });
    expect(events).toEqual([
      [{ session: "s1" }, 1],
      [{ session: "s2" }, 2],
    ]);
  });

  test("err replies reject with the code and retryable flag", async () => {
    const { client } = host((m) => ({
      t: "err",
      id: m.id,
      code: "cmux.history.not_found",
      message: "gone",
      retryable: false,
    }));
    const error = await client.call("x", {}).catch((e) => e);
    expect(isPageError(error)).toBe(true);
    expect(error).toMatchObject({ code: "cmux.history.not_found", message: "gone", retryable: false });
  });

  test("err replies keep the host's details", async () => {
    const { client } = host((m) => ({
      t: "err",
      id: m.id,
      code: "operation.failed",
      message: "no",
      details: { origin: "session_host", details: { exit_code: 128 } },
    }));
    const error = await client.call("x", {}).catch((e) => e);
    expect((error as { details?: unknown }).details).toEqual({ origin: "session_host", details: { exit_code: 128 } });
    const plain = await host((m) => ({ t: "err", id: m.id, code: "c", message: "m" }))
      .client.call("x", {})
      .catch((e) => e);
    expect((plain as { details?: unknown }).details).toBeUndefined();
  });

  test("a failed post is a retryable transport error; a malformed reply is invalid_result", async () => {
    const lost: ReplyHandler = { postMessage: () => Promise.reject(new Error("closed")) };
    const error = await new BridgePageClient(lost, {}).call("x", {}).catch((e) => e);
    expect(error).toMatchObject({ code: "cmux.protocol.closed", retryable: true });
    const { client } = host(() => ({ t: "ok", id: 999 }));
    expect(await client.call("x", {}).catch((e) => e.code)).toBe("cmux.protocol.invalid_result");
  });

  // op.cancel (app-op-routing.md "Op cancel"): an aborted call rejects at once with
  // cmux.op.cancelled and tells the host to cancel the op ({t:"cancel", id}). A cancelled mutation
  // is indeterminate, so the error is retryable and names the opid a retry must reuse.
  test("an aborted call sends cancel for its id and rejects at once with cmux.op.cancelled", async () => {
    let release: (value: unknown) => void = () => undefined;
    const { client, posted } = host((m) => (m.t === "call" ? new Promise((resolve) => (release = resolve)) : null));
    const controller = new AbortController();
    const pending = client.call("cmux.cloud.files.push", { path: "/a" }, { opid: "op-1", signal: controller.signal });
    controller.abort();
    const error = await pending.then(
      () => null,
      (e: unknown) => e,
    );
    expect(isPageError(error) && error.code).toBe("cmux.op.cancelled");
    expect(isPageError(error) && error.retryable).toBe(true);
    expect(isPageError(error) && (error.details as { opid?: string } | undefined)?.opid).toBe("op-1");
    expect(posted).toEqual([
      { t: "call", id: 1, op: "cmux.cloud.files.push", params: { path: "/a" }, opid: "op-1" },
      { t: "cancel", id: 1 },
    ]);
    // The host's late answer for the cancelled id is ignored.
    release({ t: "ok", id: 1, value: { done: true } });
    await Promise.resolve();
    // A retry reuses the opid (the caller passes it again); it is a new call id.
    const retry = host((m) => ({ t: "ok", id: m.id, value: {} }));
    await retry.client.call("cmux.cloud.files.push", { path: "/a" }, { opid: "op-1" });
    expect(retry.posted[0].opid).toBe("op-1");
  });

  test("a signal aborted before the call posts nothing", async () => {
    const { client, posted } = host(() => ({ t: "ok", id: 1, value: {} }));
    const controller = new AbortController();
    controller.abort();
    const error = await client
      .call("cmux.cloud.files.push", {}, { signal: controller.signal })
      .catch((e: unknown) => e);
    expect(isPageError(error) && error.code).toBe("cmux.op.cancelled");
    expect(posted).toEqual([]);
  });

  test("events reach the subscriber in order; duplicates and old seqs are dropped", async () => {
    const { client, target, posted } = host((m) =>
      m.t === "sub" ? { t: "ok", id: m.id, value: { sub: 7 } } : { t: "ok", id: m.id },
    );
    const seen: number[] = [];
    const unsubscribe = await client.subscribe<{ revision: number }>("cmux.history.changed", (data, seq) =>
      seen.push(seq * 100 + data.revision),
    );
    const receive = target[RECEIVE_NAME] as (m: unknown) => void;
    receive({ t: "ev", sub: 7, seq: 1, data: { revision: 2 } });
    receive({ t: "ev", sub: 7, seq: 1, data: { revision: 2 } });
    receive({ t: "ev", sub: 7, seq: 2, data: { revision: 3 } });
    receive({ t: "ev", sub: 8, seq: 1, data: { revision: 9 } });
    expect(seen).toEqual([102, 203]);
    unsubscribe();
    receive({ t: "ev", sub: 7, seq: 3, data: { revision: 4 } });
    expect(seen).toEqual([102, 203]);
    expect(posted.at(-1)).toEqual({ t: "unsub", sub: 7 });
  });

  test("a subscription filter travels in the sub envelope", async () => {
    const { client, posted } = host((m) => ({ t: "ok", id: m.id, value: { sub: 3 } }));
    await client.subscribe("cmux.apps.logs", () => undefined, { app: "cmux.git", follow: true });
    expect(posted[0]).toEqual({ t: "sub", id: 1, stream: "cmux.apps.logs", filter: { app: "cmux.git", follow: true } });
  });

  test("host calls run the page handler and post the reply envelope", async () => {
    const { client, target, posted } = host(() => undefined);
    client.handle("cmux.page.command", (params: any) => ({ handled: params.command }));
    (target[RECEIVE_NAME] as (m: unknown) => void)({
      t: "call",
      id: 5,
      op: "cmux.page.command",
      params: { command: "find" },
    });
    (target[RECEIVE_NAME] as (m: unknown) => void)({ t: "call", id: 6, op: "nope" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect([...posted].sort((a, b) => a.id - b.id)).toEqual([
      { t: "ok", id: 5, value: { handled: "find" } },
      { t: "err", id: 6, code: "cmux.protocol.unknown_op", message: "nope" },
    ]);
  });
});

/** A parked pooled document (the host set `__cmuxPageParked` before page code ran). */
function parkedHost() {
  const posted: any[] = [];
  const replaced: string[] = [];
  const handler: ReplyHandler = {
    postMessage: async (body: any) => {
      posted.push(body);
      if (body.t === "sub") return { t: "ok", id: body.id, value: { sub: 9 } };
      if (body.t === "call") return { t: "ok", id: body.id, value: { op: body.op } };
      return undefined;
    },
  };
  const location = { hash: "", replace: (url: string) => replaced.push(url) };
  const target: Record<string, unknown> = { __cmuxPageParked: true, location };
  const client = new BridgePageClient(handler, target);
  const receive = (m: unknown) => (target[RECEIVE_NAME] as (m: unknown) => void)(m);
  const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
  return { client, posted, replaced, receive, tick };
}

describe("a parked pooled document", () => {
  test("holds its calls and subscriptions until the claim, then sends them in order and acknowledges", async () => {
    const { client, posted, replaced, receive, tick } = parkedHost();
    const read = client.call<{ op: string }>("cmux.settings.list", {});
    const sub = client.subscribe("cmux.settings.changed", () => undefined);
    await tick();
    expect(posted).toEqual([]);

    receive({ t: "call", id: 3, op: "cmux.page.claim", params: { route: "#/settings/general" } });
    expect(await read).toEqual({ op: "cmux.settings.list" });
    expect(typeof (await sub)).toBe("function");
    await tick();
    expect(replaced).toEqual(["#/settings/general"]);
    expect(posted.map((m) => m.t + ":" + (m.op ?? m.stream ?? m.id))).toEqual([
      "call:cmux.settings.list",
      "sub:cmux.settings.changed",
      "ok:3",
    ]);
    expect(posted[2]).toEqual({ t: "ok", id: 3, value: { claimed: true } });

    // Claimed: later calls go out at once.
    posted.length = 0;
    await client.call("cmux.settings.snapshot", {});
    expect(posted[0]).toMatchObject({ t: "call", op: "cmux.settings.snapshot" });
  });

  test("a held call that the caller aborts is dropped, never sent", async () => {
    const { client, posted, receive, tick } = parkedHost();
    const controller = new AbortController();
    const read = client.call("cmux.settings.list", {}, { signal: controller.signal });
    controller.abort();
    await expect(read).rejects.toMatchObject({ code: "cmux.op.cancelled" });
    receive({ t: "call", id: 4, op: "cmux.page.claim", params: {} });
    await tick();
    expect(posted).toEqual([{ t: "ok", id: 4, value: { claimed: true } }]);
  });

  test("a document that already ran answers a claim with not_parked, so the host reloads it", async () => {
    const { target, posted } = host(() => undefined);
    (target[RECEIVE_NAME] as (m: unknown) => void)({ t: "call", id: 2, op: "cmux.page.claim", params: {} });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(posted).toEqual([{ t: "err", id: 2, code: "cmux.page.not_parked", message: "the document already ran" }]);
  });
});

describe("createPageClient", () => {
  test("finds only a reply-capable cmuxPage handler", () => {
    expect(findReplyHandler("cmuxPage", {})).toBeNull();
    expect(findReplyHandler("cmuxPage", { webkit: { messageHandlers: { cmuxPage: {} } } })).toBeNull();
    const handler = { postMessage: async () => null };
    expect(findReplyHandler("cmuxPage", { webkit: { messageHandlers: { cmuxPage: handler } } })).toBe(handler);
  });

  test("without a bridge: the fallback, else null", () => {
    const fallback = {
      call: async () => null,
      subscribe: async () => () => undefined,
      handle: () => () => undefined,
    } as any;
    expect(createPageClient(() => fallback)).toBe(fallback);
    expect(createPageClient()).toBeNull();
  });
});
