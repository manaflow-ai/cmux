import { describe, expect, it } from "bun:test";
import { normalizePublicPath } from "../src/routeVersion";

describe("public API route versioning", () => {
  it("maps v2 control and session paths to the shared handlers", () => {
    expect(normalizePublicPath("/v2/iroh/session")).toBe("/v1/iroh/session");
    expect(normalizePublicPath("/v2/control/socket")).toBe("/v1/control/socket");
    expect(normalizePublicPath("/v2/presence/snapshot")).toBe("/v1/presence/snapshot");
    expect(normalizePublicPath("/v2/sync/paired-macs")).toBe("/v1/sync/paired-macs");
  });

  it("maps the legacy API-shaped Iroh paths without changing their API prefix", () => {
    expect(normalizePublicPath("/v2/api/devices/iroh/register")).toBe("/api/devices/iroh/register");
    expect(normalizePublicPath("/v2/api/relay/token")).toBe("/api/relay/token");
  });

  it("leaves health and legacy paths unchanged", () => {
    expect(normalizePublicPath("/healthz")).toBe("/healthz");
    expect(normalizePublicPath("/v1/presence/snapshot")).toBe("/v1/presence/snapshot");
    expect(normalizePublicPath("/api/devices/iroh")).toBe("/api/devices/iroh");
  });
});
