import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  DEVBOX_DESKTOP_FILES,
  DEVBOX_GHOSTTY_DEB_URL,
  devboxDesktopDir,
} from "../scripts/devbox-image-common";

// Contract tests for the devbox desktop layer
// (services/vms/images/devbox/desktop), ported from the retired Blaxel
// cmux-devbox image and baked into the Freestyle snapshot by
// build-devbox-freestyle.ts. The Mac CLI opens the machine's screen on 6901
// (cloudVMDesktopPort) and a provider heal runs start-vnc.sh as `cua`, so the
// ports, user, and file paths are pinned here.

const read = (name: string) => readFileSync(path.join(devboxDesktopDir, name), "utf8");
const startVnc = read("start-vnc.sh");
const unit = read("cmux-desktop.service");
const boot = read("cmux-desktop-boot");
const freestyleBake = readFileSync(path.join(import.meta.dirname, "../scripts/build-devbox-freestyle.ts"), "utf8");
const verify = readFileSync(path.join(import.meta.dirname, "../scripts/verify-devbox-image.ts"), "utf8");

describe("devbox desktop layer", () => {
  test("directory contains exactly the expected files", () => {
    expect(readdirSync(devboxDesktopDir).sort()).toEqual([...DEVBOX_DESKTOP_FILES].sort());
  });

  test("every shell file parses", () => {
    expect(spawnSync("bash", ["-n", path.join(devboxDesktopDir, "start-vnc.sh")]).status).toBe(0);
    expect(spawnSync("sh", ["-n", path.join(devboxDesktopDir, "cmux-desktop-boot")]).status).toBe(0);
  });

  test("keeps the desktop port contract: RFB 5901 loopback-only, noVNC on 6901", () => {
    expect(startVnc).toContain("-rfbport 5901");
    expect(startVnc).toContain("-SecurityTypes None");
    expect(startVnc).toContain("-localhost");
    // The CLI's cloudVMDesktopPort: the noVNC web client must answer on 6901.
    expect(startVnc).toContain("websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:6901 127.0.0.1:5901");
    expect(freestyleBake).toContain("ln -s vnc.html /usr/share/novnc/index.html");
    // The verifier proves both ports from inside the VM (hex 170D / 1AF5).
    expect(verify).toContain("/:170D$/");
    expect(verify).toContain("/:1AF5$/");
  });

  test("runs as the ubuntu work user under systemd, supervised", () => {
    // One account for everything: SSH, the API's default exec user, terminal
    // panes, coding agents, and the desktop session all land in /home/ubuntu.
    expect(unit).toContain("User=ubuntu");
    expect(unit).toContain("Environment=HOME=/home/ubuntu");
    expect(unit).toContain("Environment=DISPLAY=:1");
    expect(unit).toContain("ExecStart=/usr/local/bin/cmux-desktop-boot");
    expect(unit).toContain("Restart=always");
    expect(boot).toContain("bash /usr/local/bin/start-vnc.sh");
    // Chrome's first run is pre-accepted for the desktop user on every boot.
    expect(boot).toContain('touch "$HOME/.config/google-chrome/First Run"');
    expect(freestyleBake).toContain("systemctl enable --now cmux-desktop");
    expect(freestyleBake).toContain('"desktop/cmux-desktop.service", "/etc/systemd/system/cmux-desktop.service"');
    expect(freestyleBake).toContain("grep -q '^User=${WORK_USER}$' /etc/systemd/system/cmux-desktop.service");
    expect(verify).toContain("pgrep -u ubuntu -x 'Xvnc|Xtigervnc'");
    expect(verify).toContain("/home/ubuntu/.config/google-chrome/First Run");
  });

  test("the work user is the base's ubuntu account, never a user the bake creates", () => {
    // Coding agents refuse a root shell (`claude --dangerously-skip-permissions`);
    // freestyle/ubuntu already ships `ubuntu` at uid 1000 with NOPASSWD sudo.
    expect(freestyleBake).toContain('const WORK_USER = "ubuntu"');
    expect(freestyleBake).not.toContain("useradd");
    expect(freestyleBake).toContain(`[ "$(id -u \${WORK_USER})" = 1000 ] && sudo -n -u \${WORK_USER} sudo -n true`);
    expect(verify).toContain("id -u ubuntu");
    expect(verify).toContain("= 1000 ] && sudo -n -u ubuntu sudo -n true");
  });

  test("Ghostty comes from a pinned Ubuntu 24.04 release asset, never a moving tag", () => {
    expect(DEVBOX_GHOSTTY_DEB_URL).toMatch(
      /ghostty-ubuntu\/releases\/download\/[0-9][^\s]*\/ghostty_[0-9][^\s]*_amd64_24\.04\.deb$/,
    );
    expect(freestyleBake).toContain("DEVBOX_GHOSTTY_DEB_URL");
    expect(freestyleBake).toContain("ghostty +version");
  });

  test("desktop polish: pre-accepted Chrome, CC0 wallpaper, no clock, dock order", () => {
    expect(read("google-chrome-cmux.desktop")).toContain("--no-first-run");
    for (const app of ["google-chrome-cmux.desktop", "thunar-cmux.desktop", "ghostty-cmux.desktop"]) {
      expect(read(app)).toMatch(/^Icon=\/etc\/cmux\/icons\/[a-z-]+\.png$/m);
      expect(freestyleBake).toContain(`"desktop/${app}", "/etc/cmux/apps/${app}"`);
    }
    for (const icon of ["google-chrome.png", "thunar.png", "ghostty.png"]) {
      expect(freestyleBake).toContain(`/etc/cmux/icons/${icon}`);
    }
    expect(read("WALLPAPER.md")).toContain("CC0 1.0 Universal");
    expect(freestyleBake).toContain('"desktop/wallpaper.jpg", "/usr/share/backgrounds/cmux/wallpaper.jpg"');
    expect(startVnc).toContain("feh --no-fehbg --bg-fill /usr/share/backgrounds/cmux/wallpaper.jpg");
    const tint2 = read("tint2rc");
    expect(tint2).toContain("panel_items = LT");
    expect(tint2).not.toContain("time1_format");
    expect(tint2.split("\n").filter((line) => line.startsWith("launcher_item_app")).join("\n")).toBe(
      [
        "launcher_item_app = /etc/cmux/apps/google-chrome-cmux.desktop",
        "launcher_item_app = /etc/cmux/apps/thunar-cmux.desktop",
        "launcher_item_app = /etc/cmux/apps/ghostty-cmux.desktop",
      ].join("\n"),
    );
  });

  test("tint2rc defines every background before the line that references it", () => {
    // tint2 resolves `*_background_id = N` while parsing, against the backgrounds
    // defined ABOVE that line (id 0 is the built-in transparent one; each
    // `rounded =` opens the next). A forward reference clamps to -1 and hands the
    // panel a garbage Background: the launcher's icon size goes negative and the
    // whole dock paints nothing (the 2026-08-27 invisible-toolbar regression).
    const lines = read("tint2rc").split("\n");
    let backgrounds = 1;
    for (const [index, raw] of lines.entries()) {
      const line = raw.trim();
      if (line.startsWith("rounded")) backgrounds += 1;
      const ref = /^([a-z_]+_background_id)\s*=\s*(\d+)/.exec(line);
      if (!ref) continue;
      if (Number(ref[2]) >= backgrounds) {
        throw new Error(
          `tint2rc line ${index + 1}: ${ref[1]} = ${ref[2]} references a background that is not defined yet (${backgrounds} known so far)`,
        );
      }
    }
    expect(backgrounds).toBeGreaterThan(1);
  });

  test("the verifier pins every desktop file byte-identical and the bake stamps the layer", () => {
    for (const name of DEVBOX_DESKTOP_FILES) {
      if (name === "WALLPAPER.md") continue;
      expect({ name, pinned: verify.includes(`["${name}", `) }).toEqual({ name, pinned: true });
    }
    expect(freestyleBake).toContain('withDesktop ? " desktop" : ""');
    expect(verify).toContain("/\\bdesktop\\b/.test(stamp.output)");
  });
});
