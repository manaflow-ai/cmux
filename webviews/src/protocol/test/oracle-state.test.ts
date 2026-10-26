// The page side of the oracle's `webviews` facet (p15-oracle-215): the gate, the summary, and that
// a draft crosses only as its hash.

import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  ORACLE_STATE_OP,
  OracleState,
  OracleStateError,
  installOracleState,
  oracleRoute,
  oracleStateEnabled,
  provideOracleState,
  webCryptoDigest,
  type OracleStateHost,
  type OracleStateSummary,
} from "../oracle-state";

const sha = (text: string) => createHash("sha256").update(text).digest("hex");

class FakeHost implements OracleStateHost {
  readonly handlers = new Map<string, (params: unknown) => unknown>();
  handle(op: string, handler: (params: unknown) => unknown): () => void {
    this.handlers.set(op, handler);
    return () => this.handlers.delete(op);
  }
}

const page = (oracle: string | undefined, hash = "#/agent") => ({
  document: { documentElement: { dataset: oracle === undefined ? {} : { oracle } } },
  location: { hash },
});

describe("oracle state", () => {
  test("the route is the fragment's path without its query", () => {
    expect(oracleRoute("#/settings/general?focus=terminal.font")).toBe("/settings/general");
    expect(oracleRoute("#/agent")).toBe("/agent");
    expect(oracleRoute("")).toBe("/");
    expect(oracleRoute("#")).toBe("/");
  });

  test("the gate is open only for data-oracle=on", () => {
    expect(oracleStateEnabled({ dataset: { oracle: "on" } })).toBe(true);
    expect(oracleStateEnabled({ dataset: { oracle: "off" } })).toBe(false);
    expect(oracleStateEnabled({ dataset: {} })).toBe(false);
    expect(oracleStateEnabled(null)).toBe(false);
  });

  test("a page with no store reports its route only", async () => {
    const state = new OracleState(() => "#/history?q=private");
    expect(await state.summary()).toEqual({ route: "/history", selection: null, panels: [], draftSha256: null });
  });

  test("stores combine in name order, whatever the mount order", async () => {
    const forward = new OracleState(() => "#/agent");
    forward.provide("a", { selection: () => "msg_1", panels: () => ["files"], draft: () => "hello" });
    forward.provide("b", { selection: () => "msg_2", panels: () => ["diff", "files"], draft: () => "world" });
    const backward = new OracleState(() => "#/agent");
    backward.provide("b", { selection: () => "msg_2", panels: () => ["diff", "files"], draft: () => "world" });
    backward.provide("a", { selection: () => "msg_1", panels: () => ["files"], draft: () => "hello" });
    const summary = await forward.summary();
    expect(summary).toEqual(await backward.summary());
    expect(summary.selection).toBe("msg_1");
    expect(summary.panels).toEqual(["diff", "files"]);
    expect(summary.draftSha256).toBe(
      `sha256:${sha(
        JSON.stringify([
          ["a", "hello"],
          ["b", "world"],
        ]),
      )}`,
    );
  });

  test("the draft never crosses as text", async () => {
    const state = new OracleState(() => "#/agent");
    state.provide("composer", { draft: () => "my secret prompt" });
    const summary = await state.summary();
    expect(JSON.stringify(summary)).not.toContain("secret");
    expect(summary.draftSha256).toMatch(/^sha256:[0-9a-f]{64}$/);
  });

  test("an empty draft is no draft", async () => {
    const state = new OracleState(() => "#/agent");
    state.provide("composer", { draft: () => "" });
    expect((await state.summary()).draftSha256).toBeNull();
  });

  test("without a digest the page refuses instead of sending the text", async () => {
    const state = new OracleState(
      () => "#/agent",
      async () => null,
    );
    state.provide("composer", { draft: () => "text" });
    await expect(state.summary()).rejects.toBeInstanceOf(OracleStateError);
  });

  test("a removed store no longer reports, and a stale removal keeps its replacement", async () => {
    const state = new OracleState(() => "#/");
    const remove = state.provide("list", { selection: () => "row_1" });
    remove();
    expect((await state.summary()).selection).toBeNull();
    const removeOld = state.provide("list", { selection: () => "row_1" });
    state.provide("list", { selection: () => "row_2" });
    removeOld();
    expect((await state.summary()).selection).toBe("row_2");
  });

  test("WebCrypto's digest is SHA-256 hex", async () => {
    expect(await webCryptoDigest("abc")).toBe(sha("abc"));
  });

  test("a closed gate serves nothing", () => {
    const host = new FakeHost();
    expect(installOracleState(host, page(undefined))).toBeNull();
    expect(installOracleState(host, page("off"))).toBeNull();
    expect(host.handlers.size).toBe(0);
    // A store of a Release page is dropped, not held.
    provideOracleState("closed", { selection: () => "row_9" }, page(undefined));
  });

  test("an open gate serves the op, with stores that reported before the client", async () => {
    provideOracleState("early", { selection: () => "row_3" }, page("on"));
    const host = new FakeHost();
    const state = installOracleState(host, page("on", "#/files?path=x"));
    expect(state).not.toBeNull();
    const handler = host.handlers.get(ORACLE_STATE_OP);
    if (!handler) throw new Error("the op is not served");
    const read = async () => (await handler({})) as OracleStateSummary;
    expect(await read()).toEqual({ route: "/files", selection: "row_3", panels: [], draftSha256: null });
    const remove = provideOracleState("late", { panels: () => ["preview"] });
    expect((await read()).panels).toEqual(["preview"]);
    remove();
    expect((await read()).panels).toEqual([]);
  });
});
