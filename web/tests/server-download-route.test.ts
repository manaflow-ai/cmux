import { describe, expect, test } from "bun:test";
import { GET, HEAD } from "../app/server/[[...artifact]]/route";

const digest = "a".repeat(64);
const targets = ["x86_64-linux", "aarch64-linux", "aarch64-darwin", "x86_64-darwin", "x86_64-windows", "aarch64-windows"];
const paths = [
  "install.sh", "install.sh.sig", "install.ps1", "install.ps1.sig",
  "bootstrap.json", "bootstrap.json.sig", "SHA256SUMS", "SHA256SUMS.sig",
  `packages/${digest}.tar.gz`,
  ...targets.flatMap((target) => [
    `bootstrap/${digest}/${target}.${target.endsWith("windows") ? "zip" : "tar.gz"}`,
    ...["stable", "beta"].flatMap((channel) => [
      `channel/${channel}/${target}/latest.json`,
      `channel/${channel}/${target}/latest.json.sig`,
      `channel/${channel}/${target}/v/0.1.0.json`,
      `channel/${channel}/${target}/v/0.1.0.json.sig`,
    ]),
  ]),
];

function context(path: string) {
  return { params: Promise.resolve({ artifact: path.split("/") }) };
}

describe("public server downloads", () => {
  test.each(paths)("redirects %s to the fixed public artifact namespace", async (path) => {
    const response = await GET(new Request(`https://cmux.com/server/${path}`), context(path));
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://files.cmux.com/server/${path}`);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(await response.text()).toBe("");
  });

  test.each(["install.sh", "channel/stable/aarch64-darwin/latest.json.sig", `packages/${digest}.tar.gz`])(
    "HEAD %s has the same redirect and no body",
    async (path) => {
      const response = await HEAD(new Request(`https://cmux.com/server/${path}`, { method: "HEAD" }), context(path));
      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe(`https://files.cmux.com/server/${path}`);
      expect(await response.text()).toBe("");
    },
  );

  test.each([
    "", "private", "private/object", "install.sh/extra", "install.sh.sig/extra",
    "channel/nightly/aarch64-darwin/latest.json", "channel/stable/riscv-linux/latest.json",
    "channel/stable/aarch64-darwin/other.json", "channel/stable/aarch64-darwin/v/../latest.json",
    "channel/stable/aarch64-darwin/v/0.1.0.json/extra", "channel/stable/aarch64-darwin/v/token?secret.json",
    `packages/${digest.toUpperCase()}.tar.gz`, "packages/not-a-digest.tar.gz", `packages/${digest}.zip`,
    `bootstrap/${digest}/aarch64-darwin.zip`, `bootstrap/${digest}/aarch64-windows.tar.gz`,
    `bootstrap/${digest}/riscv-linux.tar.gz`, `bootstrap/${digest}/aarch64-linux.tar.gz/extra`,
    "https://attacker.invalid/install.sh", "..\\install.sh", "%2Finstall.sh",
  ])("refuses unsupported path %s", async (path) => {
    const request = new Request("https://cmux.com/server/invalid");
    const response = await GET(request, context(path));
    expect(response.status).toBe(404);
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "server_download_not_found" });
    const head = await HEAD(request, context(path));
    expect(head.status).toBe(404);
    expect(await head.text()).toBe("");
  });

  test("does not forward query parameters, cookies, credentials or caller origin", async () => {
    const request = new Request("https://caller.invalid/server/install.sh?url=https://attacker.invalid&token=fixture", {
      headers: { authorization: "Bearer fixture", cookie: "fixture=value", "x-forwarded-host": "attacker.invalid" },
    });
    const response = await GET(request, context("install.sh"));
    expect(response.headers.get("location")).toBe("https://files.cmux.com/server/install.sh");
    expect(response.headers.get("authorization")).toBeNull();
    expect(response.headers.get("set-cookie")).toBeNull();
  });

  test("preserves the CLI version alphabet as literal path data", async () => {
    const path = "channel/beta/aarch64-darwin/v/0.1.0-beta_1+build.2.json.sig";
    const response = await GET(new Request("https://cmux.com/server/pinned"), context(path));
    expect(response.headers.get("location")).toBe("https://files.cmux.com/server/channel/beta/aarch64-darwin/v/0.1.0-beta_1%2Bbuild.2.json.sig");
  });

  test("serves the namespace root as a machine 404", async () => {
    const response = await GET(new Request("https://cmux.com/server"), { params: Promise.resolve({}) });
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "server_download_not_found" });
  });

});
