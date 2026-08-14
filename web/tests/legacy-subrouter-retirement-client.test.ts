import { describe, expect, test } from "bun:test";

import {
  LegacySubrouterRetirementError,
  createLegacySubrouterRetirementClient,
  legacySubrouterRetirementConfig,
} from "../services/subrouter/legacyRetirementClient";

describe("legacy Subrouter retirement client", () => {
  test("requires the legacy admin credential before retirement", () => {
    expect(() => legacySubrouterRetirementConfig({
      VERCEL_ENV: "production",
      SUBROUTER_ADMIN_TOKEN: "",
    })).toThrow("legacy Subrouter retirement is not configured");
  });

  test("revokes the exact legacy tenant without exposing the credential in the URL", async () => {
    const calls: Parameters<typeof fetch>[] = [];
    const client = createLegacySubrouterRetirementClient({
      baseUrl: "https://subrouter.example/",
      adminToken: "legacy-admin-secret",
      fetch: (async (...args: Parameters<typeof fetch>) => {
        calls.push(args);
        return Response.json({ ok: true });
      }) as typeof fetch,
    });

    await expect(client.revokeTenant("tenant/a b")).resolves.toEqual({ revoked: true });

    expect(String(calls[0]?.[0])).toBe(
      "https://subrouter.example/admin/tenants/tenant%2Fa%20b/revoke",
    );
    expect(new Headers(calls[0]?.[1]?.headers).get("authorization")).toBe(
      "Bearer legacy-admin-secret",
    );
    expect(String(calls[0]?.[0])).not.toContain("legacy-admin-secret");
  });

  test("treats an already-absent legacy tenant as idempotently retired", async () => {
    const client = createLegacySubrouterRetirementClient({
      baseUrl: "https://subrouter.example",
      adminToken: "legacy-admin-secret",
      fetch: (async () => new Response("missing", { status: 404 })) as typeof fetch,
    });

    await expect(client.revokeTenant("tenant-1")).resolves.toEqual({ revoked: false });
  });

  test("uses the credential-safe migration endpoint and validates its response", async () => {
    const calls: Parameters<typeof fetch>[] = [];
    const client = createLegacySubrouterRetirementClient({
      baseUrl: "https://subrouter.example",
      adminToken: "legacy-admin-secret",
      fetch: (async (...args: Parameters<typeof fetch>) => {
        calls.push(args);
        return Response.json({ ok: true, migrated: 4, sourceFinalized: false });
      }) as typeof fetch,
    });

    await expect(client.migrateTenant("tenant-1", {
      destinationUrl: "https://sr.cmux.com",
      tenantKey: "srt_0123456789abcdef0123456789abcdef",
      finalizeSource: false,
    })).resolves.toEqual({ migrated: 4, sourceFinalized: false });

    expect(JSON.parse(String(calls[0]?.[1]?.body))).toEqual({
      destinationUrl: "https://sr.cmux.com",
      tenantKey: "srt_0123456789abcdef0123456789abcdef",
      finalizeSource: false,
    });
  });

  test("does not copy an upstream error body into the thrown error", async () => {
    const client = createLegacySubrouterRetirementClient({
      baseUrl: "https://subrouter.example",
      adminToken: "legacy-admin-secret",
      fetch: (async () => new Response("credential=secret", { status: 409 })) as typeof fetch,
    });

    const error = await client.revokeTenant("tenant-1").catch((value) => value);
    expect(error).toBeInstanceOf(LegacySubrouterRetirementError);
    expect(error).toMatchObject({ status: 409 });
    expect(String(error)).not.toContain("credential=secret");
  });
});
