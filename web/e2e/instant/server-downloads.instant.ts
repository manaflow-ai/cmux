import { expect, test } from "@playwright/test";

for (const method of ["GET", "HEAD"]) {
  for (const path of [
    "install.sh",
    "channel/stable/aarch64-darwin/latest.json.sig",
    "channel/beta/x86_64-linux/v/0.1.0.json",
  ]) {
    test(`${method} /server/${path} reaches the public artifact without locale or sign-in`, async ({ request }) => {
      const response = await request.fetch(`/server/${path}?probe=fixture`, {
        method,
        maxRedirects: 0,
        headers: { "accept-language": "ja", cookie: "fixture=value" },
      });
      expect(response.status()).toBe(307);
      expect(response.headers().location).toBe(`https://files.cmux.com/server/${path}`);
      expect(response.headers()["cache-control"]).toBe("no-store");
      expect(response.headers()["referrer-policy"]).toBe("strict-origin-when-cross-origin");
      expect(response.headers()["set-cookie"]).toBeUndefined();
      expect(await response.body()).toHaveLength(0);
    });
  }
}

test("unsupported server paths return machine errors from the real Next server", async ({ request }) => {
  for (const path of ["/server", "/server/private", "/server/channel/nightly/aarch64-darwin/latest.json"]) {
    const response = await request.get(path, {
      maxRedirects: 0,
      headers: { "accept-language": "ja" },
    });
    expect(response.status()).toBe(404);
    expect(response.headers().location).toBeUndefined();
    expect(response.headers()["set-cookie"]).toBeUndefined();
    expect(await response.json()).toEqual({ error: "server_download_not_found" });
    const head = await request.head(path, { maxRedirects: 0, headers: { "accept-language": "ja" } });
    expect(head.status()).toBe(404);
    expect(head.headers().location).toBeUndefined();
    expect(await head.body()).toHaveLength(0);
  }
});
