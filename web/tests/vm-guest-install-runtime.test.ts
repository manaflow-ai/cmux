import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { GUEST_BROWSER_FILES } from "../services/vms/guestBrowser";
import { freestyleGuestFixture, guestCreateOptions } from "./fixtures/freestyleGuest";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

/** Isolated guest filesystem; run the actual uploaded bytes and install command. */
function guest(options: { corruptUpload?: boolean } = {}) {
  const root = mkdtempSync(join(tmpdir(), "cmux-guest-install-"));
  roots.push(root);
  mkdirSync(join(root, "bin"));
  mkdirSync(join(root, "fixture-bin"));
  writeFileSync(join(root, "fixture-bin/getent"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  writeFileSync(join(root, "fixture-bin/xdg-mime"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const prefixes: Record<string, string> = {
    "/usr/local/bin": join(root, "bin"), "/usr/local/share": join(root, "share"),
    "/etc/cmux": join(root, "etc"), "/etc": join(root, "system-etc"),
  };
  const rebase = (value: string) => value.replace(/\/usr\/local\/bin|\/usr\/local\/share|\/etc\/cmux|\/etc(?=\/)/g,
    (prefix) => prefixes[prefix]!);
  const target = join(root, "bin/cmux");
  const fixture = freestyleGuestFixture({
    write: (path, bytes) => writeFileSync(rebase(path), options.corruptUpload ? "#!/bin/sh\nexit 0\n" : bytes),
    remove: (path) => rmSync(rebase(path), { force: true }),
    exec: async (request) => {
      const result = spawnSync("/bin/sh", ["-c", rebase(request.command)], {
        encoding: "utf8", timeout: 5_000,
        env: { ...process.env, HOME: root, PATH: `${join(root, "fixture-bin")}:${process.env.PATH}` },
      });
      return Response.json({ statusCode: result.status, stdout: result.stdout, stderr: result.stderr });
    },
  });
  return { root, target, fixture };
}

describe("guest CLI publication in an isolated filesystem", () => {
  test("successful create installs the complete executable CLI and answers help", async () => {
    const { fixture, target, root } = guest();
    const handle = await fixture.provider.create(guestCreateOptions);
    expect(handle.status).toBe("running");
    expect(readFileSync(target, "utf8")).toBe(GUEST_CMUX_SHIM);
    for (const file of GUEST_BROWSER_FILES.filter((file) => file.path.startsWith("/usr/local/bin/"))) {
      expect(readFileSync(join(root, "bin", file.path.split("/").at(-1)!), "utf8")).toBe(file.content);
    }
    expect(statSync(target).mode & 0o777).toBe(0o755);
    const result = spawnSync(target, ["--help"], { encoding: "utf8", timeout: 5_000 });
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("cmux");
    const daemon = join(root, "cmux-tui");
    writeFileSync(daemon, '#!/bin/sh\nprintf \'%s\\n\' "$@" > "$HOME/daemon-args"\nprintf \'%s\\n\' \'{"session":"cloud","workspaces":[]}\'\n', { mode: 0o755 });
    const tree = spawnSync(target, ["tree", "--json"], {
      encoding: "utf8", timeout: 5_000,
      env: { ...process.env, HOME: root, CMUX_TUI_BIN: daemon },
    });
    expect(tree.status).toBe(0);
    expect(JSON.parse(tree.stdout)).toEqual({ session: "cloud", workspaces: [] });
    expect(readFileSync(join(root, "daemon-args"), "utf8").trim().split("\n"))
      .toEqual(["--session", "cloud", "--json", "session", "current", "snapshot"]);
    expect(readdirSync(join(root, "bin")).sort()).toEqual(["cmux", "cmux-open-url", "sensible-browser", "x-www-browser", "xdg-open"]);
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
    mkdirSync(join(root, "etc"));
    mkdirSync(join(root, "etc/.prompt-lock"));
    const failure = await fixture.provider.create({
      ...guestCreateOptions,
      promptIdentity: { machineId: "synthetic", name: "synthetic", revision: 1 },
    }).then(() => undefined, (error) => error);
    expect(failure?.cause?.stage).toBe("prompt");
    expect(readFileSync(target, "utf8")).toBe("previous generation");
    expect(fixture.liveVms.size).toBe(0);
  });
});
