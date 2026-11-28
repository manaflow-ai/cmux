import { describe, expect, test } from "bun:test";
import { Api, expiresAtMs } from "./cloud-journey";

// Job 139905166641: the install token (600 s) was minted at 12:33:45 and connect_info read it at 12:45:12 -> HTTP 401.
describe("an install token the journey holds past its 600 s", () => {
  test("expires_at in seconds or ms; none means never", () => {
    expect(expiresAtMs(1_795_697_000)).toBe(1_795_697_000_000);
    expect(expiresAtMs(1_795_697_000_000)).toBe(1_795_697_000_000);
    expect(expiresAtMs(Number(undefined))).toBe(Infinity);
    expect(expiresAtMs(0)).toBe(Infinity);
  });

  test("a token with under a minute left is minted again before the call; a fresh one is not", async () => {
    const api = new Api("http://127.0.0.1:1");
    let mints = 0;
    api.bearer = "old";
    api.remint = async () => ({ token: `new-${++mints}`, expiresAt: Date.now() + 600_000 });
    api.expiresAt = Date.now() + 30_000;
    await api.fresh();
    expect(api.bearer).toBe("new-1");
    await api.fresh();
    expect(api.bearer).toBe("new-1");
    expect(mints).toBe(1);
  });

  test("an Api with no remint keeps its bearer", async () => {
    const api = new Api("http://127.0.0.1:1");
    api.bearer = "kept";
    api.expiresAt = 0;
    await api.fresh();
    expect(api.bearer).toBe("kept");
  });
});
