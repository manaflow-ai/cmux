import { describe, expect, test } from "bun:test";
import { fetchProviderRead } from "../services/coderouter/providerFetch";

describe("coderouter safe provider retries", () => {
  test("retries a transient read exactly once", async () => {
    let calls = 0;
    const response = await fetchProviderRead(async () => {
      calls++;
      return new Response(null, { status: calls === 1 ? 503 : 200 });
    });
    expect(response.status).toBe(200);
    expect(calls).toBe(2);
  });

  test("retries a network failure exactly once", async () => {
    let calls = 0;
    const response = await fetchProviderRead(async () => {
      calls++;
      if (calls === 1) throw new Error("network unavailable");
      return new Response(null, { status: 200 });
    });
    expect(response.status).toBe(200);
    expect(calls).toBe(2);
  });

  test("does not retry terminal responses or rate limits", async () => {
    for (const status of [400, 401, 403, 404, 429]) {
      let calls = 0;
      const response = await fetchProviderRead(async () => {
        calls++;
        return new Response(null, { status });
      });
      expect(response.status).toBe(status);
      expect(calls).toBe(1);
    }
  });
});
