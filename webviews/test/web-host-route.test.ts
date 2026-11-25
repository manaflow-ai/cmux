// The web host's route reader (src/web-host/route.ts) reads every path vector of the shared file the
// Rust reader (cmux-tui/crates/cmux-web-route) runs too, so the two cannot drift
// (cmuxterm-hq docs/rfd/0083-cmux-web-client.md, Deeplinks).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseWebRoute, webRoutePath } from "../src/web-host/route";
import { webHostStart } from "../src/web-host/start";

type Vector = { name: string; address: string; route?: unknown; error?: string; path?: string };

const vectors: Vector[] = JSON.parse(
  readFileSync(join(import.meta.dir, "../../schemas/deeplinks/web-routes.json"), "utf8"),
).vectors;
const paths = vectors.filter((v) => v.address.startsWith("/"));

describe("web host routes", () => {
  test("the shared file has path vectors", () => {
    expect(paths.length).toBeGreaterThan(15);
  });

  for (const v of paths) {
    test(v.name, () => {
      const got = parseWebRoute(v.address);
      if (v.error) {
        expect(got).toEqual({ ok: false, error: v.error as never });
        return;
      }
      expect(got).toEqual({ ok: true, route: v.route as never });
      if (!got.ok) return;
      const path = webRoutePath(got.route);
      if (v.path) expect(path).toBe(v.path);
      if (path) expect(parseWebRoute(path)).toEqual(got);
    });
  }

  test("a route never carries anything but its address and message", () => {
    expect(parseWebRoute("/m/my-vm/agent/claude/s1?prompt=hi&run=1&approve=all")).toEqual({
      ok: true,
      route: { kind: "agent", machine: { name: "my-vm" }, harness: "claude", session: "s1" },
    });
    expect(parseWebRoute(`/m/my-vm/agent/claude/${"s".repeat(4096)}`)).toEqual({ ok: false, error: "not-a-route" });
    expect(parseWebRoute("cmux://agent/claude/s1")).toEqual({ ok: false, error: "not-a-route" });
  });

  test("the page opens its route's one chat, or nothing and why", () => {
    const hash = "#endpoint=ws://127.0.0.1:4321&token=t";
    expect(webHostStart("/m/my-vm/agent/claude/s1?message=m1", hash)).toEqual({
      open: "chat",
      route: { kind: "agent", machine: { name: "my-vm" }, harness: "claude", session: "s1", message: "m1" },
    });
    expect(webHostStart("/settings", hash).open).toBe("nothing");
    expect(webHostStart(`/m/my-vm/ws/ws_${"1".repeat(32)}`, hash).open).toBe("nothing");
    // No connection, or one off this machine's loopback: nothing opens.
    expect(webHostStart("/m/my-vm/agent/claude/s1", "").open).toBe("nothing");
    expect(webHostStart("/m/my-vm/agent/claude/s1", "#endpoint=ws://evil.com:1&token=t").open).toBe("nothing");
  });
});
