import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { relay, serveRelay } from "../src/cmux-relay.ts";

test("the relay runs commands with the server's rights and returns their result; the socket is private", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mux-relay-"));
  const path = join(dir, "cmux.sock");
  const seen: string[][] = [];
  const server = serveRelay(path, async (argv) => {
    seen.push(argv);
    return { code: argv[0] === "fail" ? 1 : 0, stdout: `ran ${argv.join(" ")}\n`, stderr: "" };
  });
  try {
    expect(statSync(path).mode & 0o777).toBe(0o600);
    expect(await relay(path, ["list-workspaces", "--json"])).toEqual({
      code: 0,
      stdout: "ran list-workspaces --json\n",
      stderr: "",
    });
    expect((await relay(path, ["fail"])).code).toBe(1);
    expect(seen).toEqual([["list-workspaces", "--json"], ["fail"]]);
  } finally {
    server.stop(true);
    rmSync(dir, { recursive: true, force: true });
  }
});

test("without a relay the error says how to start one", async () => {
  expect(
    await relay("/tmp/definitely-missing-mux-relay.sock", ["identify"]).catch(
      (e: Error) => e.message,
    ),
  ).toContain("run `mux up`");
});
