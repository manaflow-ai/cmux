// Pins the relay object naming: the optional x-cmux-instance-tag connect
// header adds a per-build dimension to the object name, absent (old clients,
// production lanes) keeps the historical untagged name byte for byte, and an
// unusable tag is a client error. Typechecked by tsconfig.worker-test.json.

import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { INSTANCE_TAG_HEADER } from "../src/protocol";
import { clearStackVerdictCacheForTesting } from "../src/stackAuth";

mock.module("cloudflare:workers", () => ({
  DurableObject: class {
    protected ctx: unknown;
    protected env: unknown;
    constructor(ctx: unknown, env: unknown) {
      this.ctx = ctx;
      this.env = env;
    }
  },
}));

const { default: worker, relayObjectName } = await import("../src/index");

const realFetch = globalThis.fetch;
afterAll(() => {
  globalThis.fetch = realFetch;
});

function makeEnv(): { env: Record<string, unknown>; names: string[] } {
  const names: string[] = [];
  const env = {
    STACK_PROJECT_ID: "project-1",
    STACK_PUBLISHABLE_CLIENT_KEY: "pck_test",
    HOST_RELAY: {
      idFromName(name: string) {
        names.push(name);
        return { name };
      },
      get(_id: unknown) {
        return {
          fetch: async () => new Response(null, { status: 200 }),
        };
      },
    },
  };
  return { env, names };
}

function connectRequest(headers: Record<string, string>): Request {
  return new Request("https://relay.test/v1/connect", {
    headers: {
      upgrade: "websocket",
      "x-cmux-role": "host",
      "x-cmux-host-device": "device-1",
      "x-cmux-device": "device-1",
      "x-cmux-stack-access": "token-naming",
      ...headers,
    },
  });
}

describe("relayObjectName", () => {
  test("untagged name is the historical v2 name", () => {
    expect(relayObjectName("user-1", "device-1")).toBe("v2:user-1:device-1");
    expect(relayObjectName("user-1", "device-1", null)).toBe("v2:user-1:device-1");
  });

  test("tagged name carries the tag under a distinct prefix", () => {
    expect(relayObjectName("user-1", "device-1", "feat-x")).toBe(
      "v2t:user-1:device-1:feat-x",
    );
  });

  test("a colon-bearing device id cannot collide with a tagged name", () => {
    // Tags are validated colon-free, so the tagged encoding of (device-1,
    // feat-x) can never equal the untagged encoding of "device-1:feat-x".
    expect(relayObjectName("user-1", "device-1:feat-x")).not.toBe(
      relayObjectName("user-1", "device-1", "feat-x"),
    );
  });
});

describe("connect naming", () => {
  beforeEach(() => {
    clearStackVerdictCacheForTesting();
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ id: "user-1" }), { status: 200 })) as unknown as typeof fetch;
  });

  test("absent header lands on the untagged object", async () => {
    const { env, names } = makeEnv();
    const response = await worker.fetch(connectRequest({}), env as never);
    expect(response.status).toBe(200);
    expect(names).toEqual(["v2:user-1:device-1"]);
  });

  test("a dev tag lands on its own object, normalized like device ids", async () => {
    const { env, names } = makeEnv();
    const response = await worker.fetch(
      connectRequest({ [INSTANCE_TAG_HEADER]: "  Feat-X " }),
      env as never,
    );
    expect(response.status).toBe(200);
    expect(names).toEqual(["v2t:user-1:device-1:feat-x"]);
  });

  test("release lanes ride the untagged object", async () => {
    for (const lane of ["default", "nightly", "rc", "staging"]) {
      const { env, names } = makeEnv();
      const response = await worker.fetch(
        connectRequest({ [INSTANCE_TAG_HEADER]: lane }),
        env as never,
      );
      expect(response.status).toBe(200);
      expect(names).toEqual(["v2:user-1:device-1"]);
    }
  });

  test("an unusable tag is a client error before any verification", async () => {
    const { env, names } = makeEnv();
    const response = await worker.fetch(
      connectRequest({ [INSTANCE_TAG_HEADER]: "has:colon" }),
      env as never,
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_instance_tag" });
    expect(names).toEqual([]);
  });
});
