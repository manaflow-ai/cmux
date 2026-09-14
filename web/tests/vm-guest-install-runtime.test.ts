import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { freestyleGuestFixture, guestCreateOptions } from "./fixtures/freestyleGuest";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

/** Isolated guest filesystem; run the actual uploaded bytes and install command. */
function guest(options: { corruptUpload?: boolean } = {}) {
  const root = mkdtempSync(join(tmpdir(), "cmux-guest-install-"));
  roots.push(root);
  mkdirSync(join(root, "bin"));
  const rebase = (value: string) => value.replaceAll("/usr/local/bin", join(root, "bin"))
    .replaceAll("/etc/cmux", join(root, "etc"));
  const target = join(root, "bin/cmux");
  const fixture = freestyleGuestFixture({
    write: (path, bytes) => writeFileSync(rebase(path), options.corruptUpload ? "#!/bin/sh\nexit 0\n" : bytes),
    remove: (path) => rmSync(rebase(path), { force: true }),
    exec: async (request) => {
      const result = spawnSync("/bin/sh", ["-c", rebase(request.command)], { encoding: "utf8", timeout: 5_000 });
      return Response.json({ statusCode: result.status, stdout: result.stdout, stderr: result.stderr });
    },
  });
  return { root, target, fixture };
}

describe("guest CLI publication in an isolated filesystem", () => {
  test("successful create installs the complete executable CLI and answers help", async () => {
    const { fixture, target } = guest();
    const handle = await fixture.provider.create(guestCreateOptions);
    expect(handle.status).toBe("running");
    expect(readFileSync(target, "utf8")).toBe(GUEST_CMUX_SHIM);
    expect(statSync(target).mode & 0o777).toBe(0o755);
    const result = spawnSync(target, ["--help"], { encoding: "utf8", timeout: 5_000 });
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("cmux");
  });

  test("replaces a target symlink without modifying its referent", async () => {
    const { fixture, root, target } = guest();
    const unrelated = join(root, "unrelated");
    writeFileSync(unrelated, "preserve me");
    symlinkSync(unrelated, target);
    await fixture.provider.create(guestCreateOptions);
    expect(readFileSync(unrelated, "utf8")).toBe("preserve me");
    expect(readFileSync(target, "utf8")).toBe(GUEST_CMUX_SHIM);
  });

  test("a directory destination fails instead of moving the shim inside and reporting ready", async () => {
    const { fixture, target } = guest();
    mkdirSync(target);
    const result = await fixture.provider.create(guestCreateOptions).then(() => "ready", () => "failed");
    expect(result).toBe("failed");
    expect(fixture.liveVms.size).toBe(0);
  });

  test("rejects a corrupted upload before replacing the previous generation", async () => {
    const { fixture, target } = guest({ corruptUpload: true });
    writeFileSync(target, "previous generation");
    const result = await fixture.provider.create(guestCreateOptions).then(() => "ready", () => "failed");
    expect(result).toBe("failed");
    expect(readFileSync(target, "utf8")).toBe("previous generation");
    expect(fixture.liveVms.size).toBe(0);
  });

  test("prompt failure does not publish a new shim generation", async () => {
    const { fixture, target, root } = guest();
    writeFileSync(target, "previous generation");
    writeFileSync(join(root, "etc"), "not a directory");
    const result = await fixture.provider.create({
      ...guestCreateOptions,
      promptIdentity: { machineId: "synthetic", name: "synthetic", revision: 1 },
    }).then(() => "ready", () => "failed");
    expect(result).toBe("failed");
    expect(readFileSync(target, "utf8")).toBe("previous generation");
    expect(fixture.liveVms.size).toBe(0);
  });
});
