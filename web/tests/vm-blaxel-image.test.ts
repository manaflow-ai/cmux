import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

// Contract tests for the baked Blaxel machine image template
// (services/vms/images/blaxel). These pin the pieces other code depends on:
// the driver's VNC heal path, the CLI's desktop port, the provisioning
// short-circuit stamp, and the Blaxel template requirements. Deliberately not
// source-shape tests of app behavior: the template IS the artifact here, the
// same way freestyleBaseDockerfileContent is for Freestyle.

const templateDir = path.join(import.meta.dirname, "../services/vms/images/blaxel");
const read = (name: string) => readFileSync(path.join(templateDir, name), "utf8");

const dockerfile = read("Dockerfile");
const entrypoint = read("entrypoint.sh");
const startVnc = read("start-vnc.sh");
const bashrc = read("cmux-bashrc");
const toml = read("blaxel.toml");

describe("Blaxel baked image template", () => {
  test("template directory contains exactly the expected files", () => {
    expect(readdirSync(templateDir).sort()).toEqual([
      "Dockerfile",
      "WALLPAPER.md",
      "blaxel.toml",
      "chrome-managed-policy.json",
      "cmux-bashrc",
      "entrypoint.sh",
      "ghostty-cmux.desktop",
      "google-chrome-cmux.desktop",
      "seed-history",
      "start-vnc.sh",
      "thunar-cmux.desktop",
      "tint2rc",
      "wallpaper.jpg",
    ]);
  });

  test("every shell file parses (bash -n)", () => {
    for (const name of ["entrypoint.sh", "start-vnc.sh", "cmux-bashrc"]) {
      const result = spawnSync("bash", ["-n", path.join(templateDir, name)]);
      expect({ name, status: result.status }).toEqual({ name, status: 0 });
    }
  });

  test("embeds the Blaxel sandbox API and launches it from the entrypoint", () => {
    expect(dockerfile).toContain(
      "COPY --from=ghcr.io/blaxel-ai/sandbox:latest /sandbox-api /usr/local/bin/sandbox-api",
    );
    expect(dockerfile).toContain('ENTRYPOINT ["/entrypoint.sh"]');
    expect(entrypoint).toContain("/usr/local/bin/sandbox-api");
    // The control plane is supervised: a crashed API restarts instead of leaving a dead machine.
    expect(entrypoint).toContain("sandbox-api exited");
    expect(entrypoint.trimEnd().endsWith("wait")).toBe(true);
  });

  test("keeps the driver's desktop heal contract", () => {
    // web/services/vms/drivers/blaxel.ts DESKTOP_VNC_HEAL_COMMAND runs
    // start-vnc.sh as cua with DISPLAY=:1 and waits for a :5901 listener.
    expect(dockerfile).toContain("COPY start-vnc.sh /usr/local/bin/start-vnc.sh");
    expect(dockerfile).toContain("useradd -m -u 1000 -s /bin/bash cua");
    expect(startVnc).toContain("-rfbport 5901");
    expect(startVnc).toContain("-SecurityTypes None");
    expect(startVnc).toContain("-localhost");
    // The CLI's cloudVMDesktopPort: the noVNC web client must answer on 6901.
    expect(startVnc).toContain("websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:6901 127.0.0.1:5901");
    expect(dockerfile).toContain("ln -s vnc.html /usr/share/novnc/index.html");
  });

  test("bakes the provisioning short-circuit stamp last", () => {
    const stampRun = 'echo "cmux-devbox ${CMUX_IMAGE_EPOCH}" > /etc/cmux/image-stamp';
    expect(dockerfile).toContain(stampRun);
    const stampIndex = dockerfile.indexOf(stampRun);
    for (const layer of ["npm install -g", "ghostty", "blesh", "start-vnc.sh"]) {
      expect(dockerfile.indexOf(layer)).toBeGreaterThan(-1);
      expect(dockerfile.indexOf(layer)).toBeLessThan(stampIndex);
    }
  });

  test("pins every coding agent and Ghostty", () => {
    for (const arg of [
      "ARG CMUX_IMAGE_CLAUDE_CODE_VERSION=",
      "ARG CMUX_IMAGE_CODEX_VERSION=",
      "ARG CMUX_IMAGE_OPENCODE_VERSION=",
      "ARG CMUX_IMAGE_PI_VERSION=",
      "ARG CMUX_IMAGE_AGENT_BROWSER_VERSION=",
    ]) {
      expect(dockerfile).toContain(arg);
    }
    for (const pkg of [
      "@anthropic-ai/claude-code@${CMUX_IMAGE_CLAUDE_CODE_VERSION}",
      "@openai/codex@${CMUX_IMAGE_CODEX_VERSION}",
      "opencode-ai@${CMUX_IMAGE_OPENCODE_VERSION}",
      "@earendil-works/pi-coding-agent@${CMUX_IMAGE_PI_VERSION}",
      "agent-browser@${CMUX_IMAGE_AGENT_BROWSER_VERSION}",
    ]) {
      expect(dockerfile).toContain(pkg);
    }
    // Ghostty comes from a pinned release asset, never a moving tag.
    expect(dockerfile).toMatch(
      /ghostty-ubuntu\/releases\/download\/[0-9][^\s]*\/ghostty_[0-9][^\s]*_amd64_trixie\.deb/,
    );
  });

  test("shell setup survives the persistent /root volume shadowing the image", () => {
    // Nothing user-facing baked into /root except the one-line bashrc hook;
    // per-HOME state (seed history) materializes at shell start from /etc/cmux.
    expect(bashrc).toContain("/etc/cmux/seed-history");
    expect(bashrc).toContain('cp /etc/cmux/seed-history "$HOME/.bash_history"');
    expect(read("seed-history")).toBe("claude --dangerously-skip-permissions\ncodex --yolo\n");
    expect(bashrc).toContain("source /usr/local/share/blesh/ble.sh --noattach");
    expect(bashrc).toContain("ble-attach");
    // half-life prompt with the machine name kept (\h): machines are addressed by name.
    expect(bashrc).toContain("PS1='\\[\\e[38;5;135m\\]\\u@\\h");
    expect(dockerfile).toContain("echo 'set -g default-shell /bin/bash' >> /etc/tmux.conf");
    for (const target of ["/etc/bash.bashrc", "/etc/skel/.bashrc", "/root/.bashrc", "/home/cua/.bashrc"]) {
      expect(dockerfile).toContain(`'[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> ${target}`);
    }
  });

  test("declares the Blaxel template with the ports cmux opens", () => {
    expect(toml).toContain('name = "cmux-devbox"');
    expect(toml).toContain('type = "sandbox"');
    expect(toml).toContain("target = 7777");
    expect(toml).toContain("target = 6901");
  });

  test("desktop polish: pre-accepted Chrome, CC0 wallpaper, no clock, dock order", () => {
    // Chrome opens from the dock with first run pre-accepted: flagged .desktop
    // plus the "First Run" marker seeded into the recreated home at boot.
    expect(read("google-chrome-cmux.desktop")).toContain("--no-first-run");
    expect(dockerfile).toContain(
      "COPY google-chrome-cmux.desktop /etc/cmux/apps/google-chrome-cmux.desktop",
    );
    expect(entrypoint).toContain('touch "/home/cua/.config/google-chrome/First Run"');
    expect(entrypoint).not.toContain("chown -R");
    expect(entrypoint).toContain("chown cua:cua /home/cua");
    // Launcher icons are baked into /etc/cmux/icons because Blaxel's rootfs
    // slimming strips /usr/share/applications and the raster icon themes.
    for (const icon of ["google-chrome.png", "thunar.png", "ghostty.png"]) {
      expect(dockerfile).toContain(`/etc/cmux/icons/${icon}`);
    }
    for (const app of ["thunar-cmux.desktop", "ghostty-cmux.desktop"]) {
      expect(read(app)).toContain("Icon=/etc/cmux/icons/");
    }
    // Wallpaper is committed with provenance; the license must stay CC0.
    expect(read("WALLPAPER.md")).toContain("CC0 1.0 Universal");
    expect(dockerfile).toContain("COPY wallpaper.jpg /usr/share/backgrounds/cmux/wallpaper.jpg");
    expect(startVnc).toContain("feh --no-fehbg --bg-fill /usr/share/backgrounds/cmux/wallpaper.jpg");
    const tint2 = read("tint2rc");
    expect(tint2).toContain("panel_items = LT");
    expect(tint2).not.toContain("time1_format");
    const launchers = tint2
      .split("\n")
      .filter((line) => line.startsWith("launcher_item_app"))
      .join("\n");
    expect(launchers).toBe(
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
    // panel a garbage Background (out-of-bounds g_array_index): garbage borders
    // make the launcher's icon size negative, every scaled icon comes back NULL,
    // and the whole dock paints nothing — the 2026-08-27 invisible-toolbar
    // regression on real machines. Order is the contract, so pin it.
    const lines = read("tint2rc").split("\n");
    let backgrounds = 1;
    for (const [index, raw] of lines.entries()) {
      const line = raw.trim();
      if (line.startsWith("rounded")) backgrounds += 1;
      const ref = /^([a-z_]+_background_id)\s*=\s*(\d+)/.exec(line);
      if (!ref) continue;
      const id = Number(ref[2]);
      expect(
        id < backgrounds,
        `tint2rc line ${index + 1}: ${ref[1]} = ${id} references a background that is not defined yet (${backgrounds} known so far)`,
      ).toBe(true);
    }
    expect(backgrounds).toBeGreaterThan(1);
    // Every launcher entry is a template file whose icon is a baked PNG.
    for (const line of lines.filter((l) => l.startsWith("launcher_item_app"))) {
      const file = path.basename(line.split("=")[1].trim());
      expect(read(file)).toMatch(/^Icon=\/etc\/cmux\/icons\/[a-z-]+\.png$/m);
    }
  });

  test("never installs docker (unsupported in Blaxel microVMs)", () => {
    expect(dockerfile.toLowerCase()).not.toContain("docker.io");
    expect(dockerfile.toLowerCase()).not.toContain("docker-ce");
    expect(dockerfile.toLowerCase()).not.toContain("get.docker.com");
  });
});

describe("Blaxel driver provisioning short-circuit", () => {
  test("create-time provisioning exits early on baked images", () => {
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/blaxel.ts"),
      "utf8",
    );
    const provisionStart = driver.indexOf("CMUX_PROVISION_SCRIPT");
    const stampGuard = driver.indexOf("[ -f /etc/cmux/image-stamp ] && exit 0");
    expect(provisionStart).toBeGreaterThan(-1);
    expect(stampGuard).toBeGreaterThan(provisionStart);
    expect(stampGuard - provisionStart).toBeLessThan(1200);
  });
});
