import { beforeEach, describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { mintTurn, parsePlatformIce } from "../src/turn";
import { PLATFORM_TURN_ORIGIN, hubEnv, mockOutbound, outbound, platformTurn } from "./helpers";

const LOCAL_ICE = [
  { urls: ["stun:stun.cloudflare.com:3478"] },
  { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u1", credential: "c1" },
];
const PLATFORM_ICE = [{ urls: ["turn:platform.test:3478?transport=udp"], username: "pu", credential: "pc" }];

function env(over: Partial<Env>): Env {
  return { ...hubEnv, PLATFORM_TURN_ORIGIN, DEVICE_HUB_TURN_TOKEN: "hub-turn-token", ...over };
}

const localCalls = () => outbound.filter((u) => u.startsWith("https://rtc.live.cloudflare.com/")).length;

describe("mintTurn", () => {
  beforeEach(() => {
    mockOutbound();
    outbound.length = 0;
    platformTurn.calls.length = 0;
    platformTurn.answer = { body: { ice: PLATFORM_ICE } };
  });

  it("uses the platform's answer in platform-first and sends the token and ttl", async () => {
    expect(await mintTurn(env({ TURN_SOURCE: "platform-first" }))).toEqual(PLATFORM_ICE);
    expect(platformTurn.calls).toEqual([{ authorization: "Bearer hub-turn-token", body: { ttlSeconds: 3600 } }]);
    expect(localCalls()).toBe(0);
  });

  for (const [name, answer] of [
    ["a 502", { status: 502, body: { error: "turn_mint_failed" } }],
    ["a 503", { status: 503, body: { error: "turn_unconfigured" } }],
    ["a 401", { status: 401, body: { error: "unauthorized" } }],
    ["empty ice", { body: { ice: [] } }],
    ["a bad body", { body: { ice: [{ urls: "turn:x" }] } }],
    ["a network failure", "network"],
  ] as const) {
    it(`falls back to the local mint in platform-first on ${name}`, async () => {
      platformTurn.answer = answer as typeof platformTurn.answer;
      expect(await mintTurn(env({ TURN_SOURCE: "platform-first" }))).toEqual(LOCAL_ICE);
      expect(platformTurn.calls.length).toBe(1);
      expect(localCalls()).toBe(1);
    });
  }

  it("falls back to the local mint in platform-first when the platform times out", async () => {
    platformTurn.answer = "hang";
    expect(await mintTurn(env({ TURN_SOURCE: "platform-first" }), { timeoutMs: 100 })).toEqual(LOCAL_ICE);
    expect(localCalls()).toBe(1);
  });

  it("answers [] in platform-first when the platform fails and TURN_KEY_* are unset", async () => {
    platformTurn.answer = { status: 502, body: { error: "turn_mint_failed" } };
    expect(await mintTurn(env({ TURN_SOURCE: "platform-first", TURN_KEY_ID: undefined, TURN_KEY_API_TOKEN: undefined }))).toEqual([]);
    expect(localCalls()).toBe(0);
  });

  it("never calls the local mint in platform mode", async () => {
    expect(await mintTurn(env({ TURN_SOURCE: "platform" }))).toEqual(PLATFORM_ICE);
    platformTurn.answer = { status: 503, body: { error: "turn_unconfigured" } };
    expect(await mintTurn(env({ TURN_SOURCE: "platform" }))).toEqual([]);
    platformTurn.answer = "hang";
    expect(await mintTurn(env({ TURN_SOURCE: "platform" }), { timeoutMs: 100 })).toEqual([]);
    expect(platformTurn.calls.length).toBe(3);
    expect(localCalls()).toBe(0);
  });

  it("mints locally without DEVICE_HUB_TURN_TOKEN, in every mode", async () => {
    for (const TURN_SOURCE of ["platform-first", "platform"]) {
      expect(await mintTurn(env({ TURN_SOURCE, DEVICE_HUB_TURN_TOKEN: undefined }))).toEqual(LOCAL_ICE);
    }
    expect(platformTurn.calls.length).toBe(0);
    expect(localCalls()).toBe(2);
  });

  it("mints locally in local mode and for a missing or unknown TURN_SOURCE", async () => {
    for (const TURN_SOURCE of ["local", undefined, "bogus"]) {
      expect(await mintTurn(env({ TURN_SOURCE }))).toEqual(LOCAL_ICE);
    }
    expect(platformTurn.calls.length).toBe(0);
    expect(localCalls()).toBe(3);
  });

  it("local mode still answers [] without TURN_KEY_*", async () => {
    expect(await mintTurn(env({ TURN_SOURCE: "local", TURN_KEY_ID: undefined }))).toEqual([]);
    expect(outbound.length).toBe(0);
  });
});

describe("parsePlatformIce", () => {
  it("accepts the contract shape", () => {
    expect(parsePlatformIce({ ice: [{ urls: ["stun:a"] }, { urls: ["turn:b"], username: "u", credential: "c" }] })).toEqual([
      { urls: ["stun:a"] },
      { urls: ["turn:b"], username: "u", credential: "c" },
    ]);
  });

  it("rejects anything else", () => {
    for (const body of [
      null,
      [],
      { ice: "x" },
      { iceServers: [{ urls: ["stun:a"] }] },
      { ice: [null] },
      { ice: [{ urls: [] }] },
      { ice: [{ urls: ["stun:a", 3] }] },
      { ice: [{ urls: ["turn:b"], username: 1 }] },
      { ice: [{ urls: ["turn:b"], credential: {} }] },
    ]) {
      expect(parsePlatformIce(body), JSON.stringify(body)).toBeNull();
    }
  });
});
