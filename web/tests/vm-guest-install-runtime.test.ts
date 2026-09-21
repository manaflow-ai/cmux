import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { GUEST_BROWSER_FILES } from "../services/vms/guestBrowser";
import { freestyleGuestFixture, guestCreateOptions } from "./fixtures/freestyleGuest";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

/** Isolated guest filesystem; run the actual uploaded bytes and install command. */
function guest(options: { corruptUpload?: boolean; promptFails?: boolean; publishFails?: boolean } = {}) {
  const root = mkdtempSync(join(tmpdir(), "cmux-guest-install-"));
  roots.push(root);
  mkdirSync(join(root, "bin"));
  mkdirSync(join(root, "libexec"));
  mkdirSync(join(root, "fixture-bin"));
  const trigger = options.promptFails || options.publishFails;
  writeFileSync(join(root, "fixture-bin/getent"), trigger
    ? "#!/bin/sh\n[ \"$1\" = passwd ] || exit 1\ncase \"$2\" in root|cmux|ubuntu) printf '%s:x:0:0::%s:/bin/sh\\n' \"$2\" \"$CMUX_GUEST_FIXTURE_ROOT/home/$2\"; exit 0;; esac\nexit 1\n"
    : "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  writeFileSync(join(root, "fixture-bin/runuser"), trigger
    ? "#!/bin/sh\n[ \"$1\" = -u ] || exit 1\nuser=\"$2\"; shift 2; [ \"$1\" = -- ] || exit 1; shift\nHOME=\"$CMUX_GUEST_FIXTURE_ROOT/home/$user\"; export HOME\nexec \"$@\"\n"
    : "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  writeFileSync(join(root, "fixture-bin/xdg-mime"), trigger
    ? "#!/bin/sh\nif [ \"$CMUX_GUEST_FAILURE_STAGE\" = prompt ]; then rm -f \"$CMUX_GUEST_FIXTURE_ROOT/etc/prompt.bash\"; mkdir -p \"$CMUX_GUEST_FIXTURE_ROOT/etc/prompt.bash\"; fi\nif [ \"$CMUX_GUEST_FAILURE_STAGE\" = publish ]; then rm -f \"$CMUX_GUEST_FIXTURE_ROOT/bin/cmux\"; mkdir -p \"$CMUX_GUEST_FIXTURE_ROOT/bin/cmux\"; fi\nexit 0\n"
    : "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const prefixes: Record<string, string> = {
    "/usr/local/bin": join(root, "bin"), "/usr/local/libexec": join(root, "libexec"),
    "/usr/local/share": join(root, "share"),
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
        env: {
          ...process.env, HOME: root, PATH: `${join(root, "fixture-bin")}:${process.env.PATH}`,
          CMUX_GUEST_FIXTURE_ROOT: root,
          ...(options.promptFails ? { CMUX_GUEST_FAILURE_STAGE: "prompt" } : {}),
          ...(options.publishFails ? { CMUX_GUEST_FAILURE_STAGE: "publish" } : {}),
        },
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

  test("a fresh prompt install keeps its identity when an older revision attaches", async () => {
    const { fixture, root } = guest();
    await fixture.provider.create({
      ...guestCreateOptions,
      promptIdentity: { machineId: "synthetic", name: "fresh-machine", revision: 10 },
    });
    await fixture.provider.create({
      ...guestCreateOptions,
      promptIdentity: { machineId: "synthetic", name: "stale-machine", revision: 9 },
    });
    expect(readFileSync(join(root, "etc/vm-name"), "utf8")).toBe("fresh-machine\n");
    expect(JSON.parse(readFileSync(join(root, "etc/.prompt-identity"), "utf8"))).toEqual({
      machineId: "synthetic", name: "fresh-machine", revision: 10,
    });
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
    const { fixture, target, root } = guest({ promptFails: true });
    writeFileSync(target, "previous generation");
    const browserOpener = join(root, "bin/cmux-open-url");
    writeFileSync(browserOpener, "previous browser generation");
    mkdirSync(join(root, "etc"));
    writeFileSync(join(root, "etc/prompt.bash"), "previous prompt generation");
    writeFileSync(join(root, "etc/bashrc"), "previous bashrc generation");
    writeFileSync(join(root, "etc/.prompt-identity"), "previous identity");
    writeFileSync(join(root, "etc/vm-name"), "previous name\n");
    const failure = await fixture.provider.create({
      ...guestCreateOptions,
      promptIdentity: { machineId: "synthetic", name: "synthetic", revision: 1 },
    }).then(() => undefined, (error) => error);
    expect(failure?.cause?.stage).toBe("prompt");
    expect(readFileSync(target, "utf8")).toBe("previous generation");
    expect(readFileSync(browserOpener, "utf8")).toBe("previous browser generation");
    expect(readFileSync(join(root, "etc/prompt.bash"), "utf8")).toBe("previous prompt generation");
    expect(readFileSync(join(root, "etc/bashrc"), "utf8")).toBe("previous bashrc generation");
    expect(readFileSync(join(root, "etc/.prompt-identity"), "utf8")).toBe("previous identity");
    expect(readFileSync(join(root, "etc/vm-name"), "utf8")).toBe("previous name\n");
    const promptArtifacts = readdirSync(join(root, "etc"));
    expect(promptArtifacts.some((name) => name.startsWith(".cmux-install-") || (name.startsWith(".prompt-") && ![".prompt-lock", ".prompt-identity"].includes(name)))).toBe(false);
    expect(existsSync(join(root, "libexec", "cmux-coderouter"))).toBe(false);
    expect(existsSync(join(root, "bin", "coderouter"))).toBe(false);
    expect(readdirSync(join(root, "libexec")).filter((name) => name.startsWith("cmux-cloud-")).length).toBe(0);
    expect(fixture.liveVms.size).toBe(0);
  });

  test("publish failure restores browser, prompt, and shim generations without temp artifacts", async () => {
    const { fixture, target, root } = guest({ publishFails: true });
    writeFileSync(target, "previous generation");
    writeFileSync(join(root, "bin/cmux-open-url"), "previous browser generation");
    mkdirSync(join(root, "etc"));
    writeFileSync(join(root, "etc/prompt.bash"), "previous prompt generation");
    writeFileSync(join(root, "etc/bashrc"), "previous bashrc generation");
    writeFileSync(join(root, "etc/.prompt-identity"), "previous identity");
    writeFileSync(join(root, "etc/vm-name"), "previous name\n");
    const failure = await fixture.provider.create({
      ...guestCreateOptions,
      promptIdentity: { machineId: "synthetic", name: "synthetic", revision: 1 },
    }).then(() => undefined, (error) => error);
    expect(failure?.cause?.stage).toBe("publish");
    expect(readFileSync(target, "utf8")).toBe("previous generation");
    expect(readFileSync(join(root, "bin/cmux-open-url"), "utf8")).toBe("previous browser generation");
    expect(readFileSync(join(root, "etc/prompt.bash"), "utf8")).toBe("previous prompt generation");
    expect(readFileSync(join(root, "etc/bashrc"), "utf8")).toBe("previous bashrc generation");
    expect(readFileSync(join(root, "etc/.prompt-identity"), "utf8")).toBe("previous identity");
    expect(readFileSync(join(root, "etc/vm-name"), "utf8")).toBe("previous name\n");
    const publishArtifacts = readdirSync(join(root, "etc"));
    expect(publishArtifacts.some((name) => name.startsWith(".cmux-install-") || (name.startsWith(".prompt-") && ![".prompt-lock", ".prompt-identity"].includes(name)))).toBe(false);
    expect(existsSync(join(root, "libexec", "cmux-coderouter"))).toBe(false);
    expect(existsSync(join(root, "bin", "coderouter"))).toBe(false);
    expect(readdirSync(join(root, "libexec")).filter((name) => name.startsWith("cmux-cloud-")).length).toBe(0);
    expect(fixture.liveVms.size).toBe(0);
  });
});
