import { describe, expect, it } from "bun:test";
import {
  DEFAULT_TURN_TTL_SECONDS,
  decodeTurnCredentialResponse,
  normalizeTurnTTLSeconds,
  turnCredentialsURL,
} from "../src/turnCredentials";

describe("Cloudflare TURN credential contract", () => {
  it("uses a bounded production default and clamps invalid values", () => {
    expect(normalizeTurnTTLSeconds(undefined)).toBe(DEFAULT_TURN_TTL_SECONDS);
    expect(normalizeTurnTTLSeconds("0")).toBe(DEFAULT_TURN_TTL_SECONDS);
    expect(normalizeTurnTTLSeconds("999999")).toBe(172800);
    expect(normalizeTurnTTLSeconds("1800")).toBe(1800);
  });

  it("builds the Cloudflare credential endpoint without exposing the key", () => {
    expect(turnCredentialsURL("key/with spaces")).toBe(
      "https://rtc.live.cloudflare.com/v1/turn/keys/key%2Fwith%20spaces/credentials/generate-ice-servers",
    );
  });

  it("normalizes Cloudflare's array response and drops malformed entries", () => {
    expect(decodeTurnCredentialResponse({
      iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        {
          urls: ["turn:turn.cloudflare.com:3478?transport=udp"],
          username: "u",
          credential: "c",
        },
        { urls: [] },
        { urls: ["turn:turn.cloudflare.com:443"], username: "u" },
      ],
    })).toEqual({
      iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        {
          urls: ["turn:turn.cloudflare.com:3478?transport=udp"],
          username: "u",
          credential: "c",
        },
      ],
    });
  });

  it("accepts Cloudflare's object response shape", () => {
    expect(decodeTurnCredentialResponse({
      iceServers: {
        urls: ["turn:turn.cloudflare.com:443"],
        username: "u",
        credential: "c",
      },
    })).toEqual({
      iceServers: [{
        urls: ["turn:turn.cloudflare.com:443"],
        username: "u",
        credential: "c",
      }],
    });
  });
});
