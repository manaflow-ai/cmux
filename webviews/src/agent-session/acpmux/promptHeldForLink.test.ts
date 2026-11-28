// A send never blocks on the link (acpmux prompt-link-wait-v1): a prompt for a chat on a machine that
// is down asks acpmux to hold it (`_meta.acpmux.waitForLink`), but only of an acpmux that lists the
// capability (an older host's pane policy refuses an unknown key). Held (`_acpmux/prompt_held`), its
// row says "sending when ready" past every failure deadline and is delivered once acpmux takes it.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

const policyPath = path.resolve(import.meta.dir, "../../../../cmux-tui/crates/cmux-agent-pane-policy/policy.json");
const allowedPromptMeta: string[] = JSON.parse(readFileSync(policyPath, "utf8")).known_params["session/prompt"].acpmux;

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
type Globals = { cmuxAcpmuxMockCapabilities?: string[] };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterEach(() => {
  delete (globalThis as Globals).cmuxAcpmuxMockCapabilities;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const settle = async (done: () => boolean) => {
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Row = {
  kind: string;
  text?: string;
  failed?: boolean;
  delivery?: { state: string; promptId: string; waitingForHost?: boolean };
};
type Hooks = { answer: (method: string, params: any) => Promise<unknown>; deliver: (message: unknown) => void };

/// A host whose `session/prompt` never answers; `held` says it holds each one for the link.
async function connect(held: boolean) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const prompts: any[] = [];
  let hooks: Hooks | undefined;
  class FarHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        prompts.push(params);
        if (held)
          hooks!.deliver({
            jsonrpc: "2.0",
            method: "_acpmux/prompt_held",
            params: { sessionId: params.sessionId, promptId: params._meta?.acpmux?.promptId, peer: "far" },
          });
        return new Promise(() => undefined);
      };
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new FarHost() as unknown as WebSocket,
  );
  return { client, prompts, hooks: () => hooks!, rows: () => rows };
}

test("a held prompt waits past every failure deadline and is delivered once acpmux takes it", async () => {
  const { deliveryTiming } = await import("./direct");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20, failMs: 60, localFailMs: 60 }); // motion-allow: delivery timeouts, not motion
  (globalThis as Globals).cmuxAcpmuxMockCapabilities = ["prompt-link-wait-v1"];
  const { client, prompts, hooks, rows } = await connect(true);
  const mine = () => rows().find((row) => row.kind === "user" && row.text === "while it sleeps");
  try {
    void client.send("while it sleeps").catch(() => undefined);
    await settle(() => mine()?.delivery?.waitingForHost === true);
    expect(prompts[0]._meta.acpmux.waitForLink).toBe(true);
    expect(Object.keys(prompts[0]._meta.acpmux).filter((key) => !allowedPromptMeta.includes(key))).toEqual([]);
    // fixed-wait: proving the row does not fail means outwaiting the failure deadline a few times.
    await new Promise((resolve) => setTimeout(resolve, deliveryTiming.localFailMs * 4));
    expect(mine()?.failed).toBeFalsy();
    expect(mine()?.delivery?.state).toBe("sending");
    expect(prompts.length).toBe(1);
    hooks().deliver({
      jsonrpc: "2.0",
      method: "_acpmux/prompt_accepted",
      params: { sessionId: prompts[0].sessionId, promptId: mine()!.delivery!.promptId, turnId: "t", queued: false },
    });
    await settle(() => mine()?.delivery?.state === "delivered");
    expect(mine()?.failed).toBeFalsy();
  } finally {
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
});

test("an acpmux that does not list the capability is never asked to wait", async () => {
  const { client, prompts } = await connect(false);
  try {
    void client.send("older daemon").catch(() => undefined);
    await settle(() => prompts.length === 1);
    expect("waitForLink" in prompts[0]._meta.acpmux).toBe(false);
  } finally {
    client.close?.();
  }
});
