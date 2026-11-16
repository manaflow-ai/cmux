import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { DESKTOP_SESSION_UNIT } from "../scripts/cmux-vm-image/agent-tools";
import { rolesOffFontsOnCommand } from "../scripts/cmux-vm-image/smoke";
import { runChild } from "./helpers/run-child";

// The roles-off-fonts-on smoke check, run under sh against a stand-in guest: a PATH of stub programs only (so this
// host's own openbox, xterm, ffmpeg or a running Xvfb never decide it) and stand-in manifest, font and unit paths.
type Guest = { programs: string[]; desktopUnit: boolean; xvfbRunning?: boolean };

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

async function runCheck(guest: Guest): Promise<{ status: number | null; stdout: string }> {
  const root = mkdtempSync(path.join(os.tmpdir(), "roles-off-"));
  dirs.push(root);
  const bin = path.join(root, "bin");
  const fonts = path.join(root, "fonts");
  const units = path.join(root, "units");
  for (const dir of [bin, fonts, units]) mkdirSync(dir, { recursive: true });
  for (const tool of ["ls", "grep"]) symlinkSync(`/usr/bin/${tool}`, path.join(bin, tool));
  const stub = (name: string, body: string) => {
    writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`);
    chmodSync(path.join(bin, name), 0o755);
  };
  stub("pgrep", guest.xvfbRunning ? "exit 0" : "exit 1");
  for (const program of guest.programs) stub(program, "exit 0");
  writeFileSync(path.join(root, "roles.json"), "{}\n");
  writeFileSync(path.join(fonts, "NotoSansCJK-Regular.ttc"), "");
  if (guest.desktopUnit) writeFileSync(path.join(units, DESKTOP_SESSION_UNIT), "[Unit]\n");
  const command = rolesOffFontsOnCommand({ manifest: path.join(root, "roles.json"), fonts, units });
  const result = await runChild("/usr/bin/sh", ["-c", command], { env: { PATH: bin }, timeout: 20_000 });
  return { status: result.status, stdout: result.stdout.trim() };
}

describe("roles-off-fonts-on smoke check", () => {
  test("an image that bakes the desktop session passes with openbox and xterm installed", async () => {
    // The agent-tools image since #44696; the check before this refused it ("! command -v openbox").
    const result = await runCheck({ programs: ["Xvfb", "openbox", "xterm"], desktopUnit: true });
    expect(result).toEqual({ status: 0, stdout: "roles-off-fonts-on desktop=baked" });
  });

  test("an image without the desktop session still refuses openbox", async () => {
    const result = await runCheck({ programs: ["Xvfb", "openbox"], desktopUnit: false });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("roles-off-fonts-on desktop=off problems: openbox-without-desktop");
  });

  test("an image without the desktop session and without openbox passes", async () => {
    const result = await runCheck({ programs: ["Xvfb"], desktopUnit: false });
    expect(result).toEqual({ status: 0, stdout: "roles-off-fonts-on desktop=off" });
  });

  test("a desktop session without its programs fails, naming each", async () => {
    const result = await runCheck({ programs: ["Xvfb"], desktopUnit: true });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("roles-off-fonts-on desktop=baked problems: desktop-without-openbox desktop-without-xterm");
  });

  test("the other roles stay off on every image: ffmpeg or a running display fails", async () => {
    const result = await runCheck({ programs: ["Xvfb", "openbox", "xterm", "ffmpeg"], desktopUnit: true, xvfbRunning: true });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("roles-off-fonts-on desktop=baked problems: xvfb-running ffmpeg-installed");
  });
});
