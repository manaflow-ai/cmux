import { describe, expect, it } from "vite-plus/test";
import { devServerTokenFrom } from "../dev-server/plugins";

// The app loads its pages from this server only when its answers carry web-dev.json's token
// (PageDevServer.token), so the server has to find the same token the app reads.
describe("dev server token", () => {
  const file = (body: string) => (name: string) => (name.endsWith("/cfg/web-dev.json") ? body : undefined);
  const env = { CMUX_NEXT_CONFIG_FILE: "/cfg/cmux-next.json" };

  it("reads the token from web-dev.json next to the config file", () => {
    expect(devServerTokenFrom(env, file(JSON.stringify({ server: "http://127.0.0.1:4200/", token: "abc" })))).toBe("abc");
  });

  it("prefers CMUX_WEB_DEV_TOKEN", () => {
    expect(devServerTokenFrom({ ...env, CMUX_WEB_DEV_TOKEN: "env" }, file(JSON.stringify({ token: "abc" })))).toBe("env");
  });

  it("sends nothing without a token or a readable file", () => {
    expect(devServerTokenFrom(env, file(JSON.stringify({ server: "http://127.0.0.1:4200/" })))).toBeUndefined();
    expect(devServerTokenFrom(env, file("{not json"))).toBeUndefined();
    expect(devServerTokenFrom(env, () => undefined)).toBeUndefined();
  });
});
