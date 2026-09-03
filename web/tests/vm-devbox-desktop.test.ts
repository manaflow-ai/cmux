import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  DEVBOX_DESKTOP_FILES,
  DEVBOX_DESKTOP_INSTALLS,
  devboxDesktopDir,
  devboxDesktopPackages,
  devboxGhosttyDebUrl,
} from "../scripts/devbox-image-common";
import {
  DEVBOX_DESKTOP_DISPLAY,
  DEVBOX_DESKTOP_ENV_FILE,
  DEVBOX_DESKTOP_HOME,
  DEVBOX_DESKTOP_NOVNC_PORT,
  DEVBOX_DESKTOP_RFB_PORT,
  DEVBOX_DESKTOP_RUNTIME_DIR,
  DEVBOX_DESKTOP_START_SCRIPT,
  DEVBOX_DESKTOP_SUPERVISOR,
  DEVBOX_DESKTOP_UNIT,
  DEVBOX_DESKTOP_USER,
  devboxDesktopBaseUrl,
  devboxDesktopOpenUrl,
} from "../services/vms/images/desktop";

// Contract tests for the devbox desktop layer
// (services/vms/images/devbox/desktop): TigerVNC + openbox + the tint2 dock +
// noVNC, ported from the retired Blaxel cmux-devbox image, baked by the
// Dockerfile (started from cmux-devbox-boot) and by build-devbox-freestyle.ts
// (started from the cmux-desktop systemd unit). The Mac app opens the
// machine's screen on 6901 (CmuxTuiSnapshotParser.desktopPort), the CLI on
// cloudVMDesktopPort, and the Freestyle driver's openPort heals the unit, so
// the ports, user, display, file paths and the session env are pinned here.

const read = (name: string) => readFileSync(path.join(devboxDesktopDir, name), "utf8");
const startVnc = read("start-vnc.sh");
const unit = read("cmux-desktop.service");
const boot = read("cmux-desktop-boot");
const desktopEnv = read("desktop-env.sh");
const dockerfile = readFileSync(path.join(devboxDesktopDir, "../Dockerfile"), "utf8");
const devboxBoot = readFileSync(path.join(devboxDesktopDir, "../cmux-devbox-boot"), "utf8");
const freestyleBake = readFileSync(path.join(import.meta.dirname, "../scripts/build-devbox-freestyle.ts"), "utf8");
const verify = readFileSync(path.join(import.meta.dirname, "../scripts/verify-devbox-image.ts"), "utf8");
const driver = readFileSync(path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"), "utf8");

describe("devbox desktop contract (services/vms/images/desktop.ts)", () => {
  test("the values shipped clients hardcode", () => {
    // CmuxTuiSnapshotParser.desktopPort / CLI cloudVMDesktopPort open 6901;
    // the verifier and the driver's heal read the same constants.
    expect(DEVBOX_DESKTOP_NOVNC_PORT).toBe(6901);
    expect(DEVBOX_DESKTOP_RFB_PORT).toBe(5901);
    expect(DEVBOX_DESKTOP_DISPLAY).toBe(":1");
    expect(DEVBOX_DESKTOP_USER).toBe("ubuntu");
    expect(DEVBOX_DESKTOP_HOME).toBe("/home/ubuntu");
    expect(DEVBOX_DESKTOP_UNIT).toBe("cmux-desktop");
    expect(DEVBOX_DESKTOP_RUNTIME_DIR).toBe("/run/cmux-desktop");
    expect(DEVBOX_DESKTOP_ENV_FILE).toBe("/run/cmux-desktop/env");
    expect(DEVBOX_DESKTOP_START_SCRIPT).toBe("/usr/local/bin/start-vnc.sh");
    expect(DEVBOX_DESKTOP_SUPERVISOR).toBe("/usr/local/bin/cmux-desktop-boot");
  });

  test("noVNC URLs: a query for clients to append display options to, IPv6 bracketed", () => {
    expect(devboxDesktopBaseUrl("10.0.0.5")).toBe("http://10.0.0.5:6901/");
    expect(devboxDesktopOpenUrl("10.0.0.5")).toBe("http://10.0.0.5:6901/vnc.html?path=websockify");
    expect(devboxDesktopOpenUrl("fd00:1::2")).toBe("http://[fd00:1::2]:6901/vnc.html?path=websockify");
    expect(devboxDesktopOpenUrl("[fd00:1::2]")).toBe("http://[fd00:1::2]:6901/vnc.html?path=websockify");
    // The app appends `&autoconnect=1&resize=remote&…` (CmuxTuiSnapshotParser.desktopURL).
    expect(new URL(`${devboxDesktopOpenUrl("10.0.0.5")}&autoconnect=1&resize=remote`).searchParams.get("resize")).toBe("remote");
  });
});

describe("devbox desktop layer", () => {
  test("directory contains exactly the expected files", () => {
    expect(readdirSync(devboxDesktopDir).sort()).toEqual([...DEVBOX_DESKTOP_FILES].sort());
  });

  test("every shell file parses", () => {
    expect(spawnSync("bash", ["-n", path.join(devboxDesktopDir, "start-vnc.sh")]).status).toBe(0);
    expect(spawnSync("sh", ["-n", path.join(devboxDesktopDir, "cmux-desktop-boot")]).status).toBe(0);
    expect(spawnSync("sh", ["-n", path.join(devboxDesktopDir, "desktop-env.sh")]).status).toBe(0);
  });

  test("one install map: every desktop file lands where the Dockerfile COPYs it, in both bakes and the verifier", () => {
    const shipped = DEVBOX_DESKTOP_FILES.filter((name) => name !== "WALLPAPER.md");
    expect(DEVBOX_DESKTOP_INSTALLS.map((install) => install.source).sort()).toEqual(shipped.map((name) => `desktop/${name}`).sort());
    for (const install of DEVBOX_DESKTOP_INSTALLS) {
      // The Dockerfile is the reference recipe: a COPY to the same path.
      expect({ source: install.source, copied: dockerfile.includes(`COPY ${install.source} ${install.target}\n`) })
        .toEqual({ source: install.source, copied: true });
      if (install.mode === 0o755) {
        expect(dockerfile).toMatch(new RegExp(`chmod 0755[^\\n]*${install.target.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}`));
      }
    }
    // The Freestyle bake writes the map and the verifier pins every entry
    // byte-identical; neither carries a path of its own.
    expect(freestyleBake).toContain("for (const install of DEVBOX_DESKTOP_INSTALLS)");
    expect(freestyleBake).toContain("await put(install.source, install.target, install.mode)");
    expect(freestyleBake).not.toContain('"desktop/start-vnc.sh", "/usr/local/bin/start-vnc.sh"');
    expect(verify).toContain("DEVBOX_DESKTOP_INSTALLS.map((install) =>");
    expect(verify).not.toContain('["start-vnc.sh", "/usr/local/bin/start-vnc.sh"]');
  });

  test("the desktop packages and the Ghostty .deb come from the Dockerfile, never a second copy", () => {
    const packages = devboxDesktopPackages(dockerfile);
    for (const required of [
      "tigervnc-standalone-server",
      "tigervnc-tools", // vncconfig, the clipboard helper
      "openbox",
      "tint2",
      "thunar",
      "feh",
      "novnc",
      "websockify",
      "at-spi2-core", // the accessibility bus computer-use reads window trees over
      "libglib2.0-bin", // gdbus: how cua-driver's doctor probes that bus
      "dbus-x11",
      "x11-xserver-utils",
    ]) {
      expect({ required, present: packages.includes(required) }).toEqual({ required, present: true });
    }
    expect(new Set(packages).size).toBe(packages.length);
    expect(dockerfile).toContain("apt-get install -y --no-install-recommends $CMUX_IMAGE_DESKTOP_PACKAGES");
    expect(freestyleBake).toContain("${devboxDesktopPackages().join(\" \")}");
    // Ghostty ships no upstream .deb; the pin is a release asset for Ubuntu 24.04, never a moving tag.
    expect(devboxGhosttyDebUrl(dockerfile)).toMatch(
      /ghostty-ubuntu\/releases\/download\/[0-9][^\s]*\/ghostty_[0-9][^\s]*_amd64_24\.04\.deb$/,
    );
    expect(dockerfile).toContain('curl -fsSL -o /tmp/ghostty.deb "$CMUX_IMAGE_GHOSTTY_DEB_URL"');
    expect(freestyleBake).toContain("${devboxGhosttyDebUrl()}");
    expect(freestyleBake).toContain("ghostty +version");
  });

  test("keeps the desktop port contract: RFB 5901 loopback-only, noVNC on 6901", () => {
    expect(startVnc).toContain(`-rfbport ${DEVBOX_DESKTOP_RFB_PORT}`);
    expect(startVnc).toContain("-SecurityTypes None");
    expect(startVnc).toContain("-localhost");
    // The app's desktop port: the noVNC web client must answer on 6901.
    expect(startVnc).toContain(`websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:${DEVBOX_DESKTOP_NOVNC_PORT} 127.0.0.1:${DEVBOX_DESKTOP_RFB_PORT}`);
    expect(dockerfile).toContain("ln -s vnc.html /usr/share/novnc/index.html");
    expect(freestyleBake).toContain("ln -s vnc.html /usr/share/novnc/index.html");
    // The verifier proves both ports from inside the VM (/proc/net/tcp, hex
    // ports from the contract) and that 5901 is loopback-only.
    expect(verify).toContain("hexPort(DEVBOX_DESKTOP_RFB_PORT)");
    expect(verify).toContain("hexPort(DEVBOX_DESKTOP_NOVNC_PORT)");
    expect(verify).toContain("vnc-5901-loopback-only");
    expect(DEVBOX_DESKTOP_RFB_PORT.toString(16).toUpperCase()).toBe("170D");
    expect(DEVBOX_DESKTOP_NOVNC_PORT.toString(16).toUpperCase()).toBe("1AF5");
  });

  test("runs as the ubuntu work user under systemd, supervised, with a runtime dir for the session env", () => {
    // One account for everything: SSH, the API's default exec user, terminal
    // panes, coding agents, and the desktop session all land in /home/ubuntu.
    expect(unit).toContain(`User=${DEVBOX_DESKTOP_USER}`);
    expect(unit).toContain(`Environment=HOME=${DEVBOX_DESKTOP_HOME}`);
    expect(unit).toContain(`Environment=DISPLAY=${DEVBOX_DESKTOP_DISPLAY}`);
    expect(unit).toContain(`Environment=CMUX_DESKTOP_RUNTIME_DIR=${DEVBOX_DESKTOP_RUNTIME_DIR}`);
    expect(unit).toContain("RuntimeDirectory=cmux-desktop");
    expect(unit).toContain("RuntimeDirectoryMode=0755");
    expect(unit).toContain(`ExecStart=${DEVBOX_DESKTOP_SUPERVISOR}`);
    expect(unit).toContain("Restart=always");
    expect(boot).toContain(`bash ${DEVBOX_DESKTOP_START_SCRIPT}`);
    expect(boot).toContain(`CMUX_DESKTOP_RUNTIME_DIR="${"${CMUX_DESKTOP_RUNTIME_DIR:-"}${DEVBOX_DESKTOP_RUNTIME_DIR}}"`);
    // Chrome's first run is pre-accepted for the desktop user on every boot.
    expect(boot).toContain('touch "$HOME/.config/google-chrome/First Run"');
    expect(freestyleBake).toContain("systemctl daemon-reload && systemctl enable --now ${DEVBOX_DESKTOP_UNIT}");
    expect(freestyleBake).toContain("grep -q '^User=${WORK_USER}$' /etc/systemd/system/${DEVBOX_DESKTOP_UNIT}.service");
    expect(freestyleBake).toContain("grep -q '^RuntimeDirectory=");
    expect(verify).toContain("pgrep -u ${DEVBOX_DESKTOP_USER} -x 'Xvnc|Xtigervnc'");
    expect(verify).toContain("/.config/google-chrome/First Run");
    expect(verify).toContain("systemctl is-active ${DEVBOX_DESKTOP_UNIT}");
  });

  test("a container without systemd gets the same desktop from cmux-devbox-boot, and only then", () => {
    // The boot supervisor starts cmux-desktop-boot as the uid-1000 account
    // (root without one) when there is no systemd to own it; under systemd
    // the cmux-desktop unit is the single supervisor, and the bake and the
    // verifier count exactly one.
    expect(devboxBoot).toContain(`DESKTOP_BOOT=${DEVBOX_DESKTOP_SUPERVISOR}`);
    expect(devboxBoot).toContain(`DESKTOP_RUNTIME_DIR=${DEVBOX_DESKTOP_RUNTIME_DIR}`);
    expect(devboxBoot).toContain(`DESKTOP_DISPLAY=${DEVBOX_DESKTOP_DISPLAY}`);
    expect(devboxBoot).toContain("[ -d /run/systemd/system ] && return 0");
    expect(devboxBoot).toContain("desktop_user=$(getent passwd 1000 | cut -d: -f1)");
    expect(devboxBoot).toContain('runuser -u "$desktop_user" -- env HOME="$desktop_home" USER="$desktop_user" DISPLAY="$DESKTOP_DISPLAY"');
    expect(devboxBoot).toContain("start_desktop\n  if [ -x \"$BIN\" ]");
    expect(freestyleBake).toContain('[ "$(pgrep -u ${WORK_USER} -f ${DEVBOX_DESKTOP_SUPERVISOR} | wc -l)" = 1 ]');
    expect(verify).toContain("single-desktop-supervisor");
    // The Dockerfile proves the container path at build time through the
    // real supervisor and ships no live desktop (no stale X lock).
    expect(dockerfile).toContain("cmux-devbox-boot >/tmp/cmux-devbox-boot.log 2>&1 &");
    expect(dockerfile).toContain("desktop-self-check-ok");
    expect(dockerfile).toContain("rm -rf /run/cmux-desktop /tmp/.X1-lock /tmp/.X11-unix/X1");
  });

  test("the session publishes DISPLAY and the accessibility bus, and every shell family picks them up", () => {
    // start-vnc.sh: one D-Bus session (reused across supervisor passes), the
    // accessibility bus launched immediately, the env published atomically.
    expect(startVnc).toContain('eval "$(dbus-launch --sh-syntax');
    expect(startVnc).toContain('kill -0 "$DBUS_SESSION_BUS_PID"');
    expect(startVnc).toContain("/usr/libexec/at-spi-bus-launcher");
    expect(startVnc).toContain('"$launcher" --launch-immediately');
    expect(startVnc).toContain("org.a11y.Bus.GetAddress");
    expect(startVnc).toContain(`RUNTIME_DIR="${"${CMUX_DESKTOP_RUNTIME_DIR:-"}${DEVBOX_DESKTOP_RUNTIME_DIR}}"`);
    expect(startVnc).toContain("echo \"export DISPLAY='$DISPLAY'\"");
    expect(startVnc).toContain("echo \"export AT_SPI_BUS_ADDRESS='$a11y_bus'\"");
    expect(startVnc).toContain("echo \"export AT_SPI_BUS='$a11y_bus'\"");
    expect(startVnc).toContain('mv -f "$RUNTIME_DIR/env.tmp" "$RUNTIME_DIR/env"');
    expect(startVnc).not.toContain("dbus-launch openbox");
    // desktop-env.sh: only a shell with no DISPLAY, only while the display is
    // up, and the session bus only for the session's own user.
    expect(desktopEnv).toContain(`[ -z "\${DISPLAY-}" ] && [ -r ${DEVBOX_DESKTOP_ENV_FILE} ] && [ -S /tmp/.X11-unix/X1 ]`);
    expect(desktopEnv).toContain('[ "${CMUX_DESKTOP_UID-}" = "$(id -u)" ]');
    // Chained into login shells and every rc file the devshell uses, in both recipes.
    const chain = "'[ -f /etc/cmux/desktop-env.sh ] && . /etc/cmux/desktop-env.sh'";
    expect(dockerfile).toContain(`echo ${chain} > /etc/profile.d/cmux-desktop.sh`);
    for (const target of ["/etc/bash.bashrc", "/etc/skel/.bashrc", "/root/.bashrc"]) {
      expect(dockerfile).toContain(`echo ${chain} >> ${target}`);
    }
    expect(freestyleBake).toContain("const desktopEnvLine = `'[ -f /etc/cmux/desktop-env.sh ] && . /etc/cmux/desktop-env.sh'`");
    expect(freestyleBake).toContain("...rcFiles.map((rc) => `echo ${desktopEnvLine} >> ${rc}`)");
    expect(freestyleBake).toContain("echo ${desktopEnvLine} > /etc/profile.d/cmux-desktop.sh");
    // Both bakes and the verifier prove it end to end: DISPLAY in a root login
    // shell and in the work user's, the buses only for the work user, the
    // accessibility bus reachable by cua-driver's doctor.
    for (const [name, source] of [["Dockerfile", dockerfile], ["build-devbox-freestyle.ts", freestyleBake], ["verify-devbox-image.ts", verify]] as const) {
      expect({ name, ok: source.includes("'echo \"$DISPLAY\"'") }).toEqual({ name, ok: true });
      expect({ name, ok: source.includes('test -n "$DBUS_SESSION_BUS_ADDRESS" && test -n "$AT_SPI_BUS_ADDRESS"') }).toEqual({ name, ok: true });
      expect({ name, ok: source.includes("_XROOTPMAP_ID") }).toEqual({ name, ok: true });
    }
    for (const source of [freestyleBake, verify]) {
      expect(source).toContain("cua-driver doctor");
      expect(source).toContain("X11 connection: connected");
      expect(source).toContain("AT-SPI: bus address present");
      expect(source).toContain("accessibility bus not reachable");
    }
    expect(verify).toContain("org.a11y.atspi.Registry");
  });

  test("the driver opens the desktop through the same heal contract", () => {
    // openPort(6901) waits for noVNC, (re)starting the unit once, and reads
    // "no desktop layer" from the start script's absence.
    expect(driver).toContain("freestyleDesktopHealCommand");
    expect(driver).toContain("systemctl start ${DEVBOX_DESKTOP_UNIT}");
    expect(driver).toContain("[ -x ${DEVBOX_DESKTOP_START_SCRIPT} ] || exit 3");
    expect(driver).toContain("devboxDesktopOpenUrl(address)");
  });

  test("desktop polish: pre-accepted Chrome, CC0 wallpaper, clipboard helper, no clock, dock order", () => {
    expect(read("google-chrome-cmux.desktop")).toContain("--no-first-run");
    for (const app of ["google-chrome-cmux.desktop", "thunar-cmux.desktop", "ghostty-cmux.desktop"]) {
      expect(read(app)).toMatch(/^Icon=\/etc\/cmux\/icons\/[a-z-]+\.png$/m);
    }
    for (const icon of ["google-chrome.png", "thunar.png", "ghostty.png"]) {
      expect(dockerfile).toContain(`/etc/cmux/icons/${icon}`);
      expect(freestyleBake).toContain(`/etc/cmux/icons/${icon}`);
    }
    expect(read("WALLPAPER.md")).toContain("CC0 1.0 Universal");
    expect(startVnc).toContain("feh --no-fehbg --bg-fill /usr/share/backgrounds/cmux/wallpaper.jpg");
    expect(startVnc).toContain("vncconfig -nowin");
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

  test("the bake stamps the layer and the verifier keys on the stamp", () => {
    expect(freestyleBake).toContain('withDesktop ? " desktop" : ""');
    expect(dockerfile).toContain('echo "cmux-devbox ${CMUX_IMAGE_EPOCH} desktop" > /etc/cmux/image-stamp');
    expect(verify).toContain("/\\bdesktop\\b/.test(stamp.output)");
  });
});
