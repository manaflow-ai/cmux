import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import {
  callDiffComments,
  diffCommentsBridgeAvailable,
  installPageDiffComments,
  listComments,
} from "../src/comments/bridge";
import type { DiffEvent, DiffResult } from "../src/diff/generated/protocol";
import {
  DIFF_PAGE_EVENTS,
  diffPageOp,
  loadPageDiffConfig,
  pagePatchURL,
  startPageDiffLanguages,
} from "../src/diff/page";
import { bootPageDiff } from "../src/diff/pageBoot";
import { createDiffTransport, DiffTransportError, PageDiffTransport } from "../src/diff/transport";
import { BridgePageClient, pageError, type PageClient } from "../src/pages/shared/pageClient";
import { loadViewedFiles } from "../src/viewed-files";
import { loadViewerPrefs } from "../src/viewer-prefs";

const BASE = "cmux-page://cmux.diff/";

/** A fake page bridge: records calls and subscriptions, answers with `answer`. */
function fakePage(answer: (op: string, params: unknown) => unknown = () => null) {
  const calls: { op: string; params: unknown }[] = [];
  const streams = new Map<string, (data: unknown, seq: number) => void>();
  const stopped: string[] = [];
  let seq = 0;
  const page: PageClient = {
    async call<R>(op: string, params: unknown) {
      calls.push({ op, params });
      return (await answer(op, params)) as R;
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      if (stream === "unknown") throw pageError("cmux.protocol.unknown_op", stream);
      streams.set(stream, onEvent as (data: unknown, seq: number) => void);
      return () => void stopped.push(stream);
    },
    handle: () => () => undefined,
  };
  const push = (stream: string, data: unknown) => streams.get(stream)?.(data, ++seq);
  return { page, calls, streams, stopped, push };
}

const unknownOp = (op: string) => {
  throw pageError("cmux.protocol.unknown_op", op);
};

const opened = (patchID: string): DiffResult => ({
  type: "sessionOpened",
  value: {
    sessionId: "s1",
    patch: { id: patchID, mediaType: "text/x-diff", byteLength: null, revision: 1 },
    source: { kind: "unstaged", repoRoot: "/repo" },
    generatedPaths: [],
  },
});

const originalWindow = (globalThis as any).window;
const originalFetch = globalThis.fetch;
afterEach(() => {
  installPageDiffComments(null);
  globalThis.fetch = originalFetch;
  if (originalWindow === undefined) delete (globalThis as any).window;
  else (globalThis as any).window = originalWindow;
});

describe("PageDiffTransport", () => {
  test("each request is the cmux.diff op of its method with the request's params", async () => {
    const { page, calls } = fakePage((op) =>
      op === "cmux.diff.protocolHandshake"
        ? { type: "handshake", value: { protocolVersion: 1, capabilities: ["branches"] } }
        : { type: "sessionClosed" },
    );
    const transport = new PageDiffTransport(page, 1, BASE);
    expect(await transport.request({ method: "protocolHandshake" })).toEqual({
      type: "handshake",
      value: { protocolVersion: 1, capabilities: ["branches"] },
    });
    await transport.request({ method: "sessionClose", params: { sessionId: "s1", capabilityToken: "t" } });
    expect(calls).toEqual([
      { op: "cmux.diff.protocolHandshake", params: {} },
      { op: "cmux.diff.sessionClose", params: { sessionId: "s1", capabilityToken: "t" } },
    ]);
    expect(diffPageOp("branchList")).toBe("cmux.diff.branchList");
  });

  test("an opened session's patch is the page host's own __patch URL", async () => {
    const { page } = fakePage(() => opened("__patch/tok/unstaged.patch"));
    const transport = new PageDiffTransport(page, 1, BASE);
    const result = await transport.request({
      method: "sessionOpen",
      params: { source: { kind: "unstaged", repoRoot: "/repo" }, capabilityToken: "t" },
    });
    expect(result.type === "sessionOpened" && result.value.patch.id).toBe(
      "cmux-page://cmux.diff/__patch/tok/unstaged.patch",
    );
  });

  test("a patch outside the page host is refused", async () => {
    for (const id of ["https://example.com/__patch/x", "cmux-page://cmux.history/__patch/x", "/elsewhere/x"]) {
      const { page } = fakePage(() => opened(id));
      const transport = new PageDiffTransport(page, 1, BASE);
      const error = await transport
        .request({ method: "sessionOpen", params: { source: { kind: "patch", path: "/p" }, capabilityToken: "t" } })
        .catch((caught: unknown) => caught);
      expect(error).toBeInstanceOf(DiffTransportError);
      expect((error as DiffTransportError).code).toBe("invalidResource");
    }
    expect(() => pagePatchURL("/__patch/a/b", BASE)).not.toThrow();
  });

  test("a host refusal keeps its code and message", async () => {
    const { page } = fakePage(() => {
      throw pageError("emptyDiff", "No changes");
    });
    const error = await new PageDiffTransport(page, 1, BASE)
      .request({ method: "protocolHandshake" })
      .catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(DiffTransportError);
    expect((error as DiffTransportError).code).toBe("emptyDiff");
    expect((error as DiffTransportError).message).toBe("No changes");
  });

  test("an answer without a result fails", async () => {
    const { page } = fakePage(() => null);
    const error = await new PageDiffTransport(page, 1, BASE)
      .request({ method: "protocolHandshake" })
      .catch((caught: unknown) => caught);
    expect((error as DiffTransportError).code).toBe("missingResult");
  });

  test("events come from cmux.diff.events, with patch refs resolved, until close", async () => {
    const { page, push, streams, stopped } = fakePage(() => ({ type: "sessionClosed" }));
    const transport = new PageDiffTransport(page, 1, BASE);
    const received: DiffEvent[] = [];
    transport.subscribe((event) => received.push(event));
    // A request waits for the subscription, so the stream is live before the host answers.
    await transport.request({ method: "protocolHandshake" });
    expect(streams.has(DIFF_PAGE_EVENTS)).toBe(true);
    push(DIFF_PAGE_EVENTS, { type: "sessionStatus", sessionId: "s1", status: "ready" });
    push(DIFF_PAGE_EVENTS, {
      type: "patchReady",
      sessionId: "s1",
      patch: { id: "/__patch/tok/2.patch", mediaType: "text/x-diff", byteLength: 3, revision: 2 },
    });
    push(DIFF_PAGE_EVENTS, {
      type: "patchReady",
      sessionId: "s1",
      patch: { id: "https://example.com/x", mediaType: "text/x-diff", byteLength: 3, revision: 3 },
    });
    push(DIFF_PAGE_EVENTS, { type: "sessionFailed", sessionId: "s1", error: { code: "gone", message: "gone" } });
    expect(received.map((event) => event.type)).toEqual(["sessionStatus", "patchReady", "sessionFailed"]);
    expect(received[1]?.type === "patchReady" && received[1].patch.id).toBe(
      "cmux-page://cmux.diff/__patch/tok/2.patch",
    );
    transport.close();
    expect(stopped).toEqual([DIFF_PAGE_EVENTS]);
    push(DIFF_PAGE_EVENTS, { type: "sessionStatus", sessionId: "s1", status: "closed" });
    expect(received).toHaveLength(3);
  });

  test("openResource fetches only the page host's patches", async () => {
    const fetched: string[] = [];
    globalThis.fetch = (async (input: string) => {
      fetched.push(String(input));
      return new Response("diff");
    }) as unknown as typeof fetch;
    const transport = new PageDiffTransport(fakePage().page, 1, BASE);
    const ref = { mediaType: "text/x-diff", byteLength: null, revision: 1 };
    await transport.openResource({ ...ref, id: "__patch/tok/a.patch" });
    const error = await transport.openResource({ ...ref, id: "https://example.com/a" }).catch((caught) => caught);
    expect(fetched).toEqual(["cmux-page://cmux.diff/__patch/tok/a.patch"]);
    expect((error as DiffTransportError).code).toBe("invalidResource");
  });

  test("createDiffTransport builds the page transport over the page client", () => {
    (globalThis as any).window = { location: { protocol: "cmux-page:" } };
    const { page } = fakePage();
    const config = { kind: "page" as const, endpoint: "", protocolVersion: 1 };
    expect(createDiffTransport(config, () => page)).toBeInstanceOf(PageDiffTransport);
    expect(createDiffTransport(config, () => null)).toBeNull();
  });

  test("it speaks the real cmuxPage envelope", async () => {
    const posted: any[] = [];
    const target: Record<string, unknown> = {};
    const client = new BridgePageClient(
      {
        async postMessage(envelope: any) {
          posted.push(envelope);
          if (envelope.t === "sub") return { t: "ok", id: envelope.id, value: { sub: 7 } };
          return { t: "ok", id: envelope.id, value: { type: "sessionClosed" } };
        },
      },
      target,
    );
    const transport = new PageDiffTransport(client, 1, BASE);
    const events: DiffEvent[] = [];
    transport.subscribe((event) => events.push(event));
    await transport.request({ method: "sessionClose", params: { sessionId: "s1", capabilityToken: "t" } });
    (target.__cmuxPageReceive as (message: unknown) => void)({
      t: "ev",
      sub: 7,
      seq: 1,
      data: { type: "sessionStatus", sessionId: "s1", status: "ready" },
    });
    expect(posted.map((envelope) => envelope.t)).toEqual(["sub", "call"]);
    expect(posted[0].stream).toBe("cmux.diff.events");
    expect(posted[1].op).toBe("cmux.diff.sessionClose");
    expect(events).toEqual([{ type: "sessionStatus", sessionId: "s1", status: "ready" }]);
  });
});

describe("async page boot", () => {
  let warn: ReturnType<typeof spyOn>;
  let error: ReturnType<typeof spyOn>;
  beforeEach(() => {
    warn = spyOn(console, "warn");
    error = spyOn(console, "error");
  });
  afterEach(() => {
    warn.mockRestore();
    error.mockRestore();
  });

  test("renders with the config cmux.diff.config answers, on the page transport", async () => {
    const { page, calls } = fakePage((op) =>
      op === "cmux.diff.config" ? { payload: { title: "Diff", capabilityToken: "t" } } : unknownOp(op),
    );
    const rendered: { config: any; languages: unknown }[] = [];
    await bootPageDiff(
      page,
      (config, languages) => rendered.push({ config, languages }),
      () => undefined,
    );
    expect(calls[0]).toEqual({ op: "cmux.diff.config", params: {} });
    expect(rendered).toHaveLength(1);
    expect(rendered[0]?.config.payload.title).toBe("Diff");
    expect(rendered[0]?.config.payload.transport).toEqual({ kind: "page", endpoint: "", protocolVersion: 1 });
    expect(warn).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled();
  });

  test("a host transport in the config is kept", async () => {
    const transport = { kind: "page" as const, endpoint: "", protocolVersion: 2 };
    const { page } = fakePage(() => ({ payload: { transport } }));
    expect((await loadPageDiffConfig(page)).payload?.transport).toEqual(transport);
  });

  test("a config that is not an object fails the boot before rendering", async () => {
    const { page } = fakePage(() => "nope");
    let rendered = false;
    await expect(bootPageDiff(page, () => (rendered = true))).rejects.toThrow("not an object");
    expect(rendered).toBe(false);
  });

  test("without the cmux.diff.comments op, comments are hidden and viewed files and prefs stay local", async () => {
    (globalThis as any).window = { webkit: { messageHandlers: {} }, localStorage: undefined };
    const { page, calls } = fakePage((op) => (op === "cmux.diff.config" ? { payload: {}, ops: [] } : unknownOp(op)));
    await bootPageDiff(
      page,
      () => undefined,
      () => undefined,
    );
    expect(diffCommentsBridgeAvailable()).toBe(false);
    expect(await loadViewedFiles({ kind: "branch", repoRoot: "/repo" } as any)).toEqual([]);
    expect(await loadViewerPrefs()).toEqual({});
    expect(calls.map((call) => call.op)).toEqual(["cmux.diff.config", "cmux.diff.languages"]);
    expect(warn).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled();
  });

  test("with the cmux.diff.comments op, the comment messages go to it", async () => {
    (globalThis as any).window = { webkit: { messageHandlers: {} } };
    const comment = { id: "c1" };
    const { page, calls } = fakePage((op, params: any) => {
      if (op === "cmux.diff.config") return { payload: {}, ops: ["cmux.diff.comments"] };
      if (op === "cmux.diff.comments" && params.method === "comments.list") return { comments: [comment] };
      if (op === "cmux.diff.comments") throw pageError("comments.denied", "Denied");
      return unknownOp(op);
    });
    await bootPageDiff(
      page,
      () => undefined,
      () => undefined,
    );
    expect(diffCommentsBridgeAvailable()).toBe(true);
    expect(await listComments("/repo")).toEqual([comment] as any);
    expect(calls.at(-1)).toEqual({
      op: "cmux.diff.comments",
      params: { method: "comments.list", params: { repoRoot: "/repo" } },
    });
    const failure = await callDiffComments("comments.delete", {}).catch((caught: unknown) => caught);
    expect((failure as { code?: string }).code).toBe("comments.denied");
  });
});

describe("page languages", () => {
  test("the cmux.diff.languages answer is the initial pack; its stream applies changes after render", async () => {
    const initial = { files: [{ name: "overrides.json", text: "{}" }] };
    const { page, push, streams } = fakePage((op) =>
      op === "cmux.diff.config" ? { payload: {} } : op === "cmux.diff.languages" ? initial : unknownOp(op),
    );
    const applied: unknown[] = [];
    let reloads = 0;
    let renderedWith: unknown;
    let api: any;
    await bootPageDiff(
      page,
      (_config, languages) => {
        renderedWith = languages;
        api = {
          apply: (pack: any) => {
            applied.push(pack);
            return { languages: [], warnings: [], reloadRequired: pack.reload === true };
          },
          report: () => ({ languages: [], warnings: [] }),
        };
      },
      () => api,
      () => reloads++,
    );
    expect(renderedWith).toEqual(initial);
    expect(streams.has("cmux.diff.languages")).toBe(true);
    push("cmux.diff.languages", { files: [] });
    expect(applied).toEqual([{ files: [] }]);
    expect(reloads).toBe(0);
    push("cmux.diff.languages", { files: [], reload: true });
    expect(reloads).toBe(1);
  });

  test("a host without the languages op or stream boots without user languages or warnings", async () => {
    const warn = spyOn(console, "warn");
    const { page } = fakePage(unknownOp);
    const noStream: PageClient = { ...page, subscribe: (_stream, ...rest) => page.subscribe("unknown", ...rest) };
    expect(await startPageDiffLanguages(noStream, () => undefined)).toBeUndefined();
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
  });
});
