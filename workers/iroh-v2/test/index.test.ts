import { describe, expect, test } from "bun:test";
import worker, { TeamControlPlane, type Env } from "../src/index";
import { challengeSigningInput, encodeBase64URL } from "../src/crypto";
import type { DurableObjectState } from "@cloudflare/workers-types";
import { descriptor } from "./fixtures";

const env = {
  STACK_API_URL: "https://stack.example/",
  STACK_PROJECT_ID: "project",
  STACK_PUBLISHABLE_KEY: "pk_test",
  API_TICKET_KEYS: "{}",
  ENVIRONMENT: "staging",
  TEAM_CONTROL_PLANE: {} as Env["TEAM_CONTROL_PLANE"],
} satisfies Env;

describe("v2 worker boundary", () => {
  test("health is unauthenticated and identifies the generation", async () => {
    const response = await worker.fetch(new Request("https://iroh.example/healthz"), env);
    expect(response.status).toBe(200);
    expect(await response.json() as unknown).toEqual({ ok: true, service: "cmux-iroh-v2", version: 2 });
  });

  test("legacy and unversioned routes do not reach a Durable Object", async () => {
    for (const path of ["/", "/v1/control/socket", "/api/iroh/ticket"]) {
      const response = await worker.fetch(new Request(`https://iroh.example${path}`), env);
      expect(response.status).toBe(404);
      expect(await response.json() as unknown).toEqual({ error: "unsupported_method" });
    }
  });

  test("socket setup requires an upgrade and a scoped identity", async () => {
    const response = await worker.fetch(new Request("https://iroh.example/v2/control/socket"), env);
    expect(response.status).toBe(415);
    expect((await response.json() as { code: string }).code).toBe("unsupported_media_type");
  });

  test("enrollment consumes one challenge and preserves its request identity", async () => {
    const values = new Map<string, unknown>();
    const ctx = {
      storage: {
        get: async <T>(key: string) => values.get(key) as T | undefined,
        put: async (key: string, value: unknown) => void values.set(key, value),
        delete: async (key: string) => values.delete(key),
      },
      blockConcurrencyWhile: async <T>(callback: () => Promise<T>) => callback(),
      acceptWebSocket: () => undefined,
    } as unknown as DurableObjectState;
    const team = new TeamControlPlane(ctx, env);
    const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
    if (!("publicKey" in keys)) throw new Error("Expected Ed25519 key pair");
    const raw = await crypto.subtle.exportKey("raw", keys.publicKey);
    if (!(raw instanceof ArrayBuffer)) throw new Error("Expected raw public key bytes");
    const enrolled = { ...descriptor, endpointId: Array.from(new Uint8Array(raw), (byte) => byte.toString(16).padStart(2, "0")).join("") };
    const challengeRequest = { schemaId: "challenge.request.v1", requestId: "challenge-request", device: enrolled };
    const headers = { "content-type": "application/json", "x-v2-verified-user": enrolled.identity.userId, "x-v2-identity": JSON.stringify(enrolled.identity) };
    const challengeResponse = await team.fetch(new Request("https://iroh.example/v2/challenges", { method: "POST", headers, body: JSON.stringify(challengeRequest) }));
    expect(challengeResponse.status).toBe(200);
    const challenge = (await challengeResponse.json() as { challenge: { challengeId: string; nonce: string } }).challenge;
    expect(challenge.challengeId).toBe((values.get(`challenge:${enrolled.identity.userId}:${enrolled.identity.deviceId}`) as { challengeId: string }).challengeId);

    const signature = encodeBase64URL(new Uint8Array(await crypto.subtle.sign("Ed25519", keys.privateKey, new TextEncoder().encode(challengeSigningInput(enrolled, challenge.challengeId, challenge.nonce)))));
    const register = { schemaId: "device.register.v1", requestId: "register-request", device: enrolled, challengeId: challenge.challengeId, nonce: challenge.nonce, signature };
    const response = await team.fetch(new Request("https://iroh.example/v2/register", { method: "POST", headers, body: JSON.stringify(register) }));
    expect(response.status).toBe(200);
    expect((await response.json() as { device: { descriptor: { endpointId: string } } }).device.descriptor.endpointId).toBe(enrolled.endpointId);
    expect(values.has(`challenge:${enrolled.identity.userId}:${enrolled.identity.deviceId}`)).toBe(false);
  });
});
