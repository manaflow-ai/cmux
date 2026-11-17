import { beforeEach, describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { ICE_TTL_S, type TurnMinter, mintTurn, parsePlatformIce } from "../src/turn";
import { hubEnv, mockOutbound, outbound } from "./helpers";

// The cmux relay ICE: cmux-platform's TurnMinter over the TURN_MINTER service
// binding first, the hub's own mint (TURN_KEY_*) when the binding fails or
// answers no servers (src/turn.ts).

const LOCAL_ICE = [
  { urls: ["stun:stun.cloudflare.com:3478"] },
  { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username: "u1", credential: "c1" },
];
const PLATFORM_ICE = [{ urls: ["turn:platform.test:3478?transport=udp"], username: "pu", credential: "pc" }];

/** A TURN_MINTER binding that records what it was asked and answers `answer`. */
function minter(answer: () => unknown): { binding: TurnMinter; asked: unknown[] } {
  const asked: unknown[] = [];
  return {
    asked,
    binding: {
      ice: async (options) => {
        asked.push(options);
        return answer();
      },
    },
  };
}

function env(over: Partial<Env>): Env {
  return { ...hubEnv, ...over };
}

const localCalls = () => outbound.filter((u) => u.startsWith("https://rtc.live.cloudflare.com/")).length;

describe("mintTurn", () => {
  beforeEach(() => {
    mockOutbound();
    outbound.length = 0;
  });

  it("uses the platform's answer over the binding and asks for 1 h", async () => {
    const m = minter(() => PLATFORM_ICE);
    expect(await mintTurn(env({ TURN_MINTER: m.binding }))).toEqual(PLATFORM_ICE);
    expect(m.asked).toEqual([{ ttlS: ICE_TTL_S }]);
    expect(localCalls()).toBe(0);
  });

  for (const [name, answer] of [
    ["an empty list (the platform has no TURN key)", () => []],
    ["a bad answer", () => [{ urls: "turn:x" }]],
    ["a non-list answer", () => ({ ice: PLATFORM_ICE })],
    [
      "a thrown RPC error",
      () => {
        throw new Error("entrypoint not found");
      },
    ],
  ] as const) {
    it(`falls back to the local mint on ${name}`, async () => {
      const m = minter(answer);
      expect(await mintTurn(env({ TURN_MINTER: m.binding }))).toEqual(LOCAL_ICE);
      expect(m.asked.length).toBe(1);
      expect(localCalls()).toBe(1);
    });
  }

  it("mints locally without the binding", async () => {
    expect(await mintTurn(env({ TURN_MINTER: undefined }))).toEqual(LOCAL_ICE);
    expect(localCalls()).toBe(1);
  });

  it("answers [] when the platform answers nothing and TURN_KEY_* are unset", async () => {
    const m = minter(() => []);
    expect(await mintTurn(env({ TURN_MINTER: m.binding, TURN_KEY_ID: undefined, TURN_KEY_API_TOKEN: undefined }))).toEqual([]);
    expect(localCalls()).toBe(0);
  });

  it("reaches the configured binding (the test stand-in for a keyless cmux-platform-production) and falls back", async () => {
    expect(hubEnv.TURN_MINTER).toBeDefined();
    expect(await mintTurn(hubEnv)).toEqual(LOCAL_ICE);
    expect(localCalls()).toBe(1);
  });
});

describe("parsePlatformIce", () => {
  it("takes a well-formed list and refuses any bad entry", () => {
    expect(parsePlatformIce(PLATFORM_ICE)).toEqual(PLATFORM_ICE);
    expect(parsePlatformIce([])).toEqual([]);
    for (const bad of [null, {}, { ice: PLATFORM_ICE }, [null], [{ urls: [] }], [{ urls: [""] }], [{ urls: ["turn:x"], username: 1 }]]) {
      expect(parsePlatformIce(bad)).toBeNull();
    }
  });
});
