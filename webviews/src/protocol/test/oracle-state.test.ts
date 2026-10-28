// The page half of the oracle's `webviews` facet (oracle-state.ts).
import { afterEach, describe, expect, test } from "bun:test";
import {
  contributeOracleState,
  mergeOracleReadings,
  noteOracleStateChanged,
  ORACLE_STATE_CHANGED_OP,
  ORACLE_STATE_ENABLED,
  ORACLE_STATE_OP,
  readOracleState,
  routeOfHash,
  serveOracleState,
  sha256Text,
  type OracleStateHost,
  type OracleStateTarget,
} from "../oracle-state";
import { BridgePageClient, type ReplyHandler } from "../../pages/shared/pageClient";
import { composerOracleReading } from "../../agent-session/acpmux/composerOracle";
import { settingsOracleReading } from "../../pages/settings/oracleState";

const enabled = (hash = ""): OracleStateTarget => ({ [ORACLE_STATE_ENABLED]: true, location: { hash } });

/** Records the ops a host serves. */
function recordingHost(): OracleStateHost & { ops: Map<string, (params: unknown) => unknown> } {
  const ops = new Map<string, (params: unknown) => unknown>();
  return {
    ops,
    handle(op, handler) {
      ops.set(op, handler);
      return () => ops.delete(op);
    },
  };
}

const removals: Array<() => void> = [];
afterEach(() => {
  for (const remove of removals.splice(0)) remove();
});

describe("oracle state gate", () => {
  test("a document the host did not enable serves nothing and keeps no reader", async () => {
    const host = recordingHost();
    const target: OracleStateTarget = { location: { hash: "#/x" } };
    expect(serveOracleState(host, target)).toBeNull();
    expect(host.ops.size).toBe(0);
    removals.push(contributeOracleState(() => ({ draft: "secret" }), target));
    // The reader was not kept: an enabled read sees no draft.
    expect((await readOracleState(enabled())).draftSha256).toBeNull();
  });

  test("an enabled document serves the op", () => {
    const host = recordingHost();
    const remove = serveOracleState(host, enabled());
    expect([...host.ops.keys()]).toEqual([ORACLE_STATE_OP]);
    remove?.();
    expect(host.ops.size).toBe(0);
  });
});

describe("oracle state reading", () => {
  test("defaults: the fragment as the route, nothing selected, no panels, no draft", async () => {
    expect(await readOracleState(enabled("#/settings/theme"))).toEqual({
      route: "/settings/theme",
      selection: null,
      panels: [],
      draftSha256: null,
    });
    expect(routeOfHash("")).toBe("/");
    expect(routeOfHash(undefined)).toBe("/");
  });

  test("a draft leaves the page only as its SHA-256", async () => {
    const target = enabled();
    removals.push(contributeOracleState(() => ({ draft: "hello" }), target));
    const state = await readOracleState(target);
    // sha256("hello")
    expect(state.draftSha256).toBe("sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    expect(JSON.stringify(state)).not.toContain("hello");
  });

  test("readings merge: last route and selection win, panels are a sorted union, blank drafts are none", () => {
    expect(
      mergeOracleReadings(
        [
          { route: "/a", selection: "one", panels: ["picker", "dialog"], draft: "  " },
          { selection: null, panels: ["dialog", "drawer"], draft: "x" },
          { route: "/b", draft: "y" },
        ],
        "/",
      ),
    ).toEqual({ route: "/b", selection: null, panels: ["dialog", "drawer", "picker"], draft: "x\u0000y" });
    expect(mergeOracleReadings([], "/z")).toEqual({ route: "/z", selection: null, panels: [], draft: null });
  });

  test("no WebCrypto is an error, never the raw text", async () => {
    await expect(sha256Text("secret", undefined)).rejects.toMatchObject({ code: "cmux.oracle.no_digest" });
  });
});

describe("oracle state over the page bridge", () => {
  test("the host's call gets the page's answer", async () => {
    let replied: (body: unknown) => void = () => undefined;
    const reply = new Promise<unknown>((resolve) => (replied = resolve));
    const handler: ReplyHandler = {
      // The page's own change note is a call; the host's answer is the reply.
      postMessage: (body) => {
        if ((body as { t?: string }).t !== "call") replied(body);
        return Promise.resolve({ t: "ok", value: {} });
      },
    };
    const target = enabled("#/chat");
    const client = new BridgePageClient(handler, target);
    const unserve = serveOracleState(client, target);
    expect(unserve).not.toBeNull();
    removals.push(() => unserve?.());
    removals.push(contributeOracleState(() => ({ selection: "row-1", panels: ["picker"] }), target));
    client.receive({ t: "call", id: 7, op: ORACLE_STATE_OP, params: {} });
    expect(await reply).toEqual({
      t: "ok",
      id: 7,
      value: { route: "/chat", selection: "row-1", panels: ["picker"], draftSha256: null },
    });
  });
});

describe("oracle state change notes", () => {
  /** A host that records the change calls the page makes. */
  function callingHost(): OracleStateHost & { calls: string[] } {
    const calls: string[] = [];
    return {
      calls,
      handle: () => () => undefined,
      call: (op) => {
        calls.push(op);
        return Promise.resolve({});
      },
    };
  }
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

  test("changes in one task send one note; adding and removing a part note too", async () => {
    const host = callingHost();
    const target = enabled();
    const unserve = serveOracleState(host, target);
    removals.push(() => unserve?.());
    noteOracleStateChanged();
    noteOracleStateChanged();
    await settle();
    expect(host.calls).toEqual([ORACLE_STATE_CHANGED_OP]);
    const remove = contributeOracleState(() => ({ selection: "a" }), target);
    await settle();
    remove();
    await settle();
    expect(host.calls).toEqual([ORACLE_STATE_CHANGED_OP, ORACLE_STATE_CHANGED_OP, ORACLE_STATE_CHANGED_OP]);
  });

  test("no note leaves a page whose host did not enable the oracle", async () => {
    const host = callingHost();
    expect(serveOracleState(host, { location: { hash: "" } })).toBeNull();
    noteOracleStateChanged();
    await settle();
    expect(host.calls).toEqual([]);
  });
});

describe("oracle state contributors", () => {
  test("the agent composer gives its chat as the selection and its prompt only as a hash", async () => {
    const target = enabled("#/chat");
    removals.push(contributeOracleState(() => composerOracleReading("session-1", "hello"), target));
    const state = await readOracleState(target);
    expect(state.selection).toBe("session-1");
    expect(state.draftSha256).toBe("sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    expect(JSON.stringify(state)).not.toContain("hello");
    expect(composerOracleReading(undefined, "").selection).toBeNull();
  });

  test("Settings gives its category as the route, the focused key, its search as panels and a hash", async () => {
    const target = enabled("#/settings/appearance?focus=ui.theme&q=secret%20words&changed=1");
    const location = {
      section: "appearance",
      focus: "ui.theme",
      workspace: null,
      query: "secret words",
      changedOnly: true,
    };
    removals.push(contributeOracleState(() => settingsOracleReading(location, "appearance"), target));
    const state = await readOracleState(target);
    expect(state.route).toBe("/settings/appearance");
    expect(state.selection).toBe("ui.theme");
    expect(state.panels).toEqual(["changed", "search"]);
    expect(state.draftSha256).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(JSON.stringify(state)).not.toContain("secret");
    const idle = settingsOracleReading({ ...location, focus: null, query: "", changedOnly: false }, "general");
    expect(idle).toEqual({ route: "/settings/general", selection: null, panels: [], draft: "" });
  });
});
