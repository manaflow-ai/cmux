import { describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import {
  NATIVE_RELAY_TICKET_TTL_SECONDS,
  deriveNativeRelayBootstrapToken,
  isNativeRelayProvisioned,
  markNativeRelayProvisioned,
  mintNativeRelayTicket,
  nativeRelayAttachGrants,
  nativeRelayBootstrapForVm,
  nativeRelayProviderEnvironment,
  nativeRelayShardsForVm,
  readNativeRelayConfig,
} from "../services/vms/nativeRelay";

const SECRET = Buffer.alloc(32, 7).toString("base64url");
const OTHER_SECRET = Buffer.alloc(32, 9).toString("base64url");
const ENV = {
  CMUX_NATIVE_RELAY_ENABLED: "1",
  CMUX_NATIVE_RELAY_BOOTSTRAP_SECRET_B64: SECRET,
  CMUX_NATIVE_RELAY_TICKET_ISSUER_URL: "https://cloud.cmux.cloud",
  CMUX_NATIVE_RELAY_SHARDS_JSON: JSON.stringify([
    { id: "westus2-a", route: "relay+wss://relay-a.cmux.cloud/v1/relay", issuer: "cmux-cloud-westus2-a", secretB64: SECRET },
    { id: "eastus2-a", route: "relay+https://relay-b.cmux.cloud/v1/relay", issuer: "cmux-cloud-eastus2-a", secretB64: OTHER_SECRET },
    { id: "centralus-a", route: "relay+wss://relay-c.cmux.cloud/v1/relay", issuer: "cmux-cloud-centralus-a", secretB64: SECRET },
  ]),
} as const;

describe("native relay configuration", () => {
  test("stays disabled until explicitly enabled", () => {
    expect(readNativeRelayConfig({})).toBeNull();
  });

  test("uses a non-secret marker to keep pre-rollout VMs on their old transport", () => {
    expect(isNativeRelayProvisioned(undefined)).toBe(false);
    expect(isNativeRelayProvisioned({ nativeRelay: false })).toBe(false);
    const metadata = markNativeRelayProvisioned({ image: "devbox", nativeRelay: false });
    expect(metadata).toEqual({ image: "devbox", nativeRelay: true });
    expect(isNativeRelayProvisioned(metadata)).toBe(true);
  });

  test("requires redundant TLS shards and normalizes their routes", () => {
    const config = readNativeRelayConfig(ENV);
    expect(config?.shards).toHaveLength(3);
    expect(config?.shards[0]?.route).toBe("relay+wss://relay-a.cmux.cloud/v1/relay");
    expect(config?.shards[1]?.route).toBe("relay+https://relay-b.cmux.cloud/v1/relay");
    expect(() => readNativeRelayConfig({
      ...ENV,
      CMUX_NATIVE_RELAY_SHARDS_JSON: JSON.stringify([
        { id: "one", route: "relay+ws://relay-a.cmux.cloud/v1/relay", issuer: "one", secretB64: SECRET },
        { id: "two", route: "relay+wss://relay-b.cmux.cloud/v1/relay", issuer: "two", secretB64: SECRET },
      ]),
    })).toThrow(/relay\+wss|relay\+https/);
  });

  test("rejects malformed or silently truncated base64 secrets", () => {
    const valid = Buffer.alloc(32, 7).toString("base64url");
    const base = {
      id: "relay-a",
      route: "relay+wss://relay-a.example/v1/relay",
      issuer: "issuer-a",
      secretB64: valid,
    };
    expect(() => readNativeRelayConfig({
      CMUX_NATIVE_RELAY_ENABLED: "1",
      CMUX_NATIVE_RELAY_SHARDS_JSON: JSON.stringify([
        base,
        { ...base, id: "relay-b", route: "relay+wss://relay-b.example/v1/relay", issuer: "issuer-b" },
      ]),
      CMUX_NATIVE_RELAY_BOOTSTRAP_SECRET_B64: `${valid}AA`,
      CMUX_NATIVE_RELAY_TICKET_ISSUER_URL: "https://cmux.example",
    })).toThrow(/base64/);
    expect(() => readNativeRelayConfig({
      CMUX_NATIVE_RELAY_ENABLED: "1",
      CMUX_NATIVE_RELAY_SHARDS_JSON: JSON.stringify([
        { ...base, secretB64: `${valid.slice(0, -1)}B` },
        { ...base, id: "relay-b", route: "relay+wss://relay-b.example/v1/relay", issuer: "issuer-b" },
      ]),
      CMUX_NATIVE_RELAY_BOOTSTRAP_SECRET_B64: valid,
      CMUX_NATIVE_RELAY_TICKET_ISSUER_URL: "https://cmux.example",
    })).toThrow(/base64/);
  });

  test("assigns exactly two stable shards and derives a VM-scoped bootstrap", () => {
    const config = readNativeRelayConfig(ENV)!;
    const vmId = "00000000-0000-4000-8000-000000000123";
    expect(nativeRelayShardsForVm(vmId, config).map((shard) => shard.id))
      .toEqual(nativeRelayShardsForVm(vmId, config).map((shard) => shard.id));
    const bootstrap = nativeRelayBootstrapForVm(vmId, config)!;
    expect(bootstrap.slot).toBe(`vm-${vmId}`);
    expect(bootstrap.routes).toHaveLength(2);
    expect(bootstrap.ticketUrl).toBe(`https://cloud.cmux.cloud/api/internal/vm/${vmId}/relay-ticket`);
    expect(bootstrap.bootstrapToken).toBe(deriveNativeRelayBootstrapToken(vmId, config.bootstrapSecret));
    expect(bootstrap.bootstrapToken).not.toContain(SECRET);
  });
});

describe("native relay tickets", () => {
  test("matches the Rust v2 ticket shape and rotates before expiry", () => {
    const config = readNativeRelayConfig(ENV)!;
    const shard = config.shards[0]!;
    const minted = mintNativeRelayTicket({
      shard,
      permission: "connect",
      slot: "vm-00000000-0000-4000-8000-000000000123",
      nowSeconds: 1_800_000_000,
    });
    expect(minted.expiresAtUnix - minted.issuedAtUnix).toBe(NATIVE_RELAY_TICKET_TTL_SECONDS);
    const [prefix, encoded, signature] = minted.ticket.split(".");
    expect(prefix).toBe("v2");
    expect(signature).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const claims = JSON.parse(Buffer.from(encoded!, "base64url").toString("utf8"));
    expect(claims).toMatchObject({
      version: 2,
      issuer: shard.issuer,
      permission: "connect",
      role: "client",
      slot: "vm-00000000-0000-4000-8000-000000000123",
      circuit: null,
      lane: null,
      generation: null,
      issued_at_unix: 1_800_000_000,
      expires_at_unix: 1_800_000_000 + NATIVE_RELAY_TICKET_TTL_SECONDS,
    });
    const signingPayload = [
      "cmux-relay-ticket-v2",
      claims.version,
      claims.issuer,
      claims.permission,
      claims.role,
      claims.slot,
      "",
      "",
      "",
      claims.issued_at_unix,
      claims.expires_at_unix,
    ].join("\n");
    expect(signature).toBe(createHmac("sha256", Buffer.from(SECRET, "base64url")).update(signingPayload).digest("base64url"));
  });

  test("returns one short-lived Connect grant per selected shard", () => {
    const config = readNativeRelayConfig(ENV)!;
    const grants = nativeRelayAttachGrants(
      "00000000-0000-4000-8000-000000000123",
      config,
      1_800_000_000,
    );
    expect(grants).toHaveLength(2);
    expect(new Set(grants.map((grant) => grant.shardId)).size).toBe(2);
    expect(grants.every((grant) => grant.expiresAtUnix > grant.refreshAfterUnix)).toBe(true);
    expect(grants.every((grant) => grant.ticket.startsWith("v2."))).toBe(true);
  });

  test("provider environment contains only the machine bootstrap, never a ticket", () => {
    const config = readNativeRelayConfig(ENV)!;
    const bootstrap = nativeRelayBootstrapForVm("00000000-0000-4000-8000-000000000123", config)!;
    const environment = nativeRelayProviderEnvironment(bootstrap);
    expect(environment.CMUX_NATIVE_RELAY_BOOTSTRAP_TOKEN).toBe(bootstrap.bootstrapToken);
    expect(environment.CMUX_NATIVE_RELAY_TICKET_URL).toContain("/relay-ticket");
    expect(Object.keys(environment).some((key) => key.includes("TICKET") && key.includes("VALUE"))).toBe(false);
    expect(JSON.stringify(environment)).not.toContain("v2.");
  });
});
