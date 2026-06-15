import { describe, expect, test } from "bun:test";
import { controlStatus, normalizeEndpoint } from "../src/core";

describe("controlStatus", () => {
  test("names the deployed control plane without claiming managed routing", () => {
    const status = controlStatus(new Date("2026-06-15T00:00:00.000Z"));

    expect(status.service).toBe("cmux-subrouter");
    expect(status.durableObjectControlPlane).toBe(true);
    expect(status.dataPlaneManagedByCmux).toBe(false);
    expect(status.cloudVmRouterLifecycleManagedByCmux).toBe(false);
    expect(status.supportedAgentsToday).toEqual(["codex", "hermes"]);
    expect(status.updatedAt).toBe("2026-06-15T00:00:00.000Z");
  });
});

describe("normalizeEndpoint", () => {
  test("normalizes supported Subrouter URL forms", () => {
    for (const raw of [
      "http://subrouter-team.tail41290.ts.net:31415",
      "http://subrouter-team.tail41290.ts.net:31415/",
      "http://subrouter-team.tail41290.ts.net:31415/v1",
      "http://subrouter-team.tail41290.ts.net:31415/backend-api",
      "http://subrouter-team.tail41290.ts.net:31415/backend-api/codex",
    ]) {
      expect(normalizeEndpoint(raw)).toEqual({
        originUrl: "http://subrouter-team.tail41290.ts.net:31415",
        customBaseUrl: "http://subrouter-team.tail41290.ts.net:31415/v1",
        codexBackendUrl: "http://subrouter-team.tail41290.ts.net:31415/backend-api/codex",
        codexChatGPTBaseUrl: "http://subrouter-team.tail41290.ts.net:31415/backend-api",
      });
    }
  });

  test("rejects non-http and query-bearing URLs", () => {
    expect(normalizeEndpoint("ssh://host:31415")).toBeNull();
    expect(normalizeEndpoint("http://host:31415/v1?token=secret")).toBeNull();
    expect(normalizeEndpoint("not a url")).toBeNull();
  });
});
