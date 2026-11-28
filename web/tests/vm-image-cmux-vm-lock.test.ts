import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  aptClosureProblems,
  basePackageProblems,
  bakedPrograms,
  chromeForTestingShape,
  cmuxCuaReleaseShape,
  DEFAULT_LOCK_PATH,
  diffCounts,
  diffFileManifests,
  dpkgChanges,
  fingerprintProblems,
  imageResourceName,
  isExactDebianVersion,
  isExactProgramVersion,
  KNOWN_PROGRAMS,
  LockError,
  npmGlobalProblems,
  parseDpkgList,
  parseFileManifest,
  parseInputsLock,
  percentile,
  profileLinks,
  programInstallCommand,
  readInputsLock,
  rolesManifest,
  sbomComponentCounts,
  validateInputsLock,
  withFingerprint,
} from "../scripts/cmux-vm-image/lock";
import { programChecksCommand } from "../scripts/cmux-vm-image/smoke";

const lockText = readFileSync(DEFAULT_LOCK_PATH, "utf8");
const fresh = () => JSON.parse(lockText) as Record<string, any>;

function problemsOf(raw: unknown): string[] {
  try {
    validateInputsLock(raw);
    return [];
  } catch (error) {
    if (error instanceof LockError) return [...error.problems];
    throw error;
  }
}

describe("images/cmux-vm/inputs.lock.json", () => {
  test("the checked-in lock is valid and lists every known program once", () => {
    const lock = readInputsLock();
    expect(lock.programs.map((p) => p.name).sort()).toEqual([...KNOWN_PROGRAMS, "cmux-cua", "chrome-for-testing", "cmux-browser-host"].sort());
    expect(lock.apt.ubuntu.uri).toContain(lock.apt.ubuntu.snapshot);
    expect(lock.apt.ubuntu.snapshot).toBe("20261001T000000Z");
    expect(profileLinks(lock).map((l) => l.command)).toContain("cr");
  });

  test("refuses a version range or tag on a program", () => {
    for (const version of ["^2.1.267", "~0.160.0", ">=1.0.0", "latest", "1.x", "*", "2.1"]) {
      const raw = fresh();
      raw.programs[3].version = version;
      expect(problemsOf(raw).some((p) => p.includes("programs[3].version"))).toBe(true);
    }
  });

  test("refuses a range on an apt package and accepts real Debian versions", () => {
    const raw = fresh();
    raw.apt.ubuntu.packages.ripgrep = ">= 14.1.0";
    raw.apt.pgdg.packages["postgresql-17"] = "17.*";
    const problems = problemsOf(raw);
    expect(problems.some((p) => p.includes("apt.ubuntu.packages.ripgrep"))).toBe(true);
    expect(problems.some((p) => p.includes("apt.pgdg.packages.postgresql-17"))).toBe(true);
    for (const ok of ["1:19.1.1-1ubuntu1~24.04.2", "17.11-1.pgdg24.04+2", "20260601~24.04.1", "293.pgdg24.04+1"]) expect(isExactDebianVersion(ok)).toBe(true);
    for (const bad of ["", "latest", "17.*", ">= 1", "1.0 | 2.0"]) expect(isExactDebianVersion(bad)).toBe(false);
  });

  test("refuses a missing or malformed sha256 and a missing size", () => {
    const raw = fresh();
    delete raw.programs[0].sha256;
    raw.programs[1].sha256 = raw.programs[1].sha256.toUpperCase();
    delete raw.programs[2].size;
    raw.tools.syft.sha256 = "abc";
    const problems = problemsOf(raw);
    expect(problems).toContain("programs[0].sha256: missing or not 64 lowercase hex");
    expect(problems).toContain("programs[1].sha256: missing or not 64 lowercase hex");
    expect(problems).toContain("programs[2].size: missing or not a positive integer");
    expect(problems).toContain("tools.syft.sha256: missing or not 64 lowercase hex");
  });

  test("refuses an unknown program, a duplicate and a missing one", () => {
    const raw = fresh();
    raw.programs.push({ ...raw.programs[0], name: "chief" });
    raw.programs.push({ ...raw.programs[1] });
    raw.programs = raw.programs.filter((p: { name: string }) => p.name !== "gh");
    const problems = problemsOf(raw);
    expect(problems.some((p) => p.includes('unknown program "chief"'))).toBe(true);
    expect(problems.some((p) => p.includes("duplicate cmux-tui-hook"))).toBe(true);
    expect(problems).toContain("programs: gh is missing");
  });

  test("refuses floating URLs, unsafe bin paths and a missing fingerprint", () => {
    const raw = fresh();
    raw.programs[0].url = "http://files.cmux.com/cmux-tui/x";
    raw.programs[1].url = "https://files.cmux.com/cmux-tui/latest/cmux-tui-hook";
    raw.programs[4].bin = { codex: "../../usr/bin/codex" };
    raw.programs[5].bin = { opencode: "/usr/bin/opencode" };
    delete raw.base.fingerprint.dpkgListSha256;
    raw.apt.ubuntu.uri = "https://archive.ubuntu.com/ubuntu/";
    const problems = problemsOf(raw);
    expect(problems).toContain("programs[0].url: must be an https:// URL");
    expect(problems.some((p) => p.startsWith("programs[1].url: a \"latest\" URL floats"))).toBe(true);
    expect(problems.some((p) => p.startsWith("programs[4].bin.codex"))).toBe(true);
    expect(problems.some((p) => p.startsWith("programs[5].bin.opencode"))).toBe(true);
    expect(problems).toContain("base.fingerprint.dpkgListSha256: missing or not 64 lowercase hex");
    expect(problems.some((p) => p.startsWith("apt.ubuntu.uri"))).toBe(true);
  });

  test("parse errors are LockErrors", () => {
    expect(() => parseInputsLock("{")).toThrow(LockError);
    expect(() => parseInputsLock("[]")).toThrow(LockError);
  });

  test("program versions: semver or a full commit", () => {
    expect(isExactProgramVersion("1.20260924.1")).toBe(true);
    expect(isExactProgramVersion("d7f8fd06326fb236daf8b4983065239b7b11e900")).toBe(true);
    expect(isExactProgramVersion("d7f8fd0")).toBe(false);
  });
});

describe("base fingerprint and closure checks", () => {
  const lock = readInputsLock();
  const fp = lock.base.fingerprint;

  test("fingerprint matches only the recorded kernel and dpkg digest", () => {
    expect(fingerprintProblems(lock, { kernelRelease: fp.kernelRelease, dpkgListSha256: fp.dpkgListSha256, dpkgPackageCount: fp.dpkgPackageCount })).toEqual([]);
    const drift = fingerprintProblems(lock, { kernelRelease: "6.1.200", dpkgListSha256: "0".repeat(64), dpkgPackageCount: 416 });
    expect(drift).toHaveLength(2);
    const updated = parseInputsLock(withFingerprint(lockText, { kernelRelease: "6.1.200", dpkgListSha256: "0".repeat(64), dpkgPackageCount: 416 }, "2026-10-03T00:00:00Z"));
    expect(updated.base.fingerprint.kernelRelease).toBe("6.1.200");
  });

  test("dpkg diff: extra, missing and wrong-version packages are refused", () => {
    const before = parseDpkgList("curl\t8.5.0-2ubuntu10.15\tamd64\ngit\t1:2.43.0-1ubuntu7.3\tamd64\n");
    const after = parseDpkgList("curl\t8.5.0-2ubuntu10.15\tamd64\ngit\t1:2.43.0-1ubuntu7.4\tamd64\nripgrep\t14.1.0-1\tamd64\nlibfoo:amd64\t1.0\tamd64\n");
    const added = dpkgChanges(before, after);
    expect([...added.keys()].sort()).toEqual(["git", "libfoo", "ripgrep"]);
    expect(aptClosureProblems({ ripgrep: "14.1.0-1", acl: "2.3.2-1build1.1" }, added).sort()).toEqual([
      "apt installed git=1:2.43.0-1ubuntu7.4, which is not in the lock",
      "apt installed libfoo=1.0, which is not in the lock",
      "lock package acl was not installed",
    ]);
    expect(aptClosureProblems({ ripgrep: "14.1.0-2" }, new Map([["ripgrep", "14.1.0-1"]]))).toEqual(["apt installed ripgrep=14.1.0-1, the lock says 14.1.0-2"]);
  });

  test("base packages and npm globals must be in the lock", () => {
    expect(basePackageProblems(lock, new Map(Object.entries(lock.base.basePackages)))).toEqual([]);
    expect(basePackageProblems(lock, new Map())).toHaveLength(Object.keys(lock.base.basePackages).length);
    const globals = new Map([["npm", "11.19.0"], ["openclaw", "2026.7.1-2"], ["left-pad", "1.3.0"], ["corepack", "0.37.0"]]);
    expect(npmGlobalProblems(lock, globals)).toEqual([
      "base npm global left-pad@1.3.0 is not in the lock (keep or strip it)",
      "base npm global corepack@0.37.0, lock keeps 0.36.0",
    ]);
  });
});

describe("reproducibility diff and helpers", () => {
  test("SBOM multiset diff by type, name and version", () => {
    const a = sbomComponentCounts({ components: [{ type: "library", name: "x", version: "1" }, { type: "library", name: "x", version: "1" }, { type: "file", name: "y" }] });
    const b = sbomComponentCounts({ components: [{ type: "library", name: "x", version: "1" }, { type: "file", name: "y" }, { type: "library", name: "z", version: "2" }] });
    expect(diffCounts(a, a)).toEqual([]);
    expect(diffCounts(a, b)).toEqual(["library|x|1: 2 vs 1", "library|z|2: 0 vs 1"]);
  });

  test("file manifest diff honors the allow-list", () => {
    const a = parseFileManifest("/etc/cmux/image-stamp\tF\taaa\t10\t0o644\n/usr/local/bin/x\tF\tbbb\t5\t0o755\n/opt/cmux/current\tL\tprofiles/1\t10\n");
    const b = parseFileManifest("/etc/cmux/image-stamp\tF\tccc\t10\t0o644\n/usr/local/bin/x\tF\tddd\t5\t0o755\n/opt/cmux/current\tL\tprofiles/1\t10\n");
    const result = diffFileManifests(a, b);
    expect(result.allowed).toHaveLength(1);
    expect(result.diffs).toEqual(["/usr/local/bin/x: F bbb vs F ddd"]);
  });

  test("names: branch resources carry cmuxnp-dev-", () => {
    expect(imageResourceName({ promotion: false, tag: "ci-123", date: "20261003", sha: "abcdef1234567890" })).toBe("cmuxnp-dev-vmimg-ci-123");
    expect(imageResourceName({ promotion: true, tag: "x", date: "20261003", sha: "abcdef1234567890" })).toBe("cmux-vm-20261003-abcdef1234");
    expect(() => imageResourceName({ promotion: false, tag: "Bad Tag", date: "", sha: "" })).toThrow();
  });

  test("percentile", () => {
    expect(percentile([5, 1, 3, 2, 4], 50)).toBe(3);
    expect(percentile([5, 1, 3, 2, 4], 95)).toBe(5);
    expect(Number.isNaN(percentile([], 50))).toBe(true);
  });
});

describe("roles: baked packages that stay off, first-use packages, optional programs (cloud-automation.md 2, CLOUD-AUTOMATION)", () => {
  const lock = readInputsLock();

  test("the display role is baked and off; openbox and ffmpeg are first-use packages, never baked", () => {
    expect(lock.roles.display.default).toBe("off");
    for (const name of lock.roles.display.apt) expect(lock.apt.ubuntu.packages[name]).toBeDefined();
    expect(lock.roles.display.apt).toEqual(expect.arrayContaining(["xvfb", "xauth", "at-spi2-core"]));
    expect(lock.roles.display.apt).toContain("libxkbcommon0"); // cmux-cua links libxkbcommon
    // openbox pulls Ghostscript, CUPS and poppler (+64 packages, about 92 MB): installed when a display first starts.
    expect(lock.roles["display-wm"].firstUse).toBe(true);
    expect(lock.apt.ubuntu.firstUse["display-wm"].openbox).toBeDefined();
    expect(lock.apt.ubuntu.packages.openbox).toBeUndefined();
    expect(lock.roles["cua-video"].default).toBe("off");
    expect(lock.roles["cua-video"].firstUse).toBe(true);
    expect(lock.apt.ubuntu.firstUse["cua-video"].ffmpeg).toBeDefined();
    expect(lock.apt.ubuntu.packages.ffmpeg).toBeUndefined();
  });

  test("CJK fonts are baked (D-A2)", () => {
    expect(lock.roles.fonts.default).toBe("on");
    expect(lock.apt.ubuntu.packages["fonts-noto-cjk"]).toBeDefined();
  });

  test("a role naming a package that no closure carries is refused", () => {
    const raw = fresh();
    raw.roles.display.apt.push("xterm-not-locked");
    expect(problemsOf(raw)).toContain('roles.display.apt: "xterm-not-locked" is not in apt.ubuntu.packages');
  });

  test("a first-use package that is also baked is refused, and first-use needs exact versions", () => {
    const raw = fresh();
    raw.apt.ubuntu.firstUse["cua-video"].ripgrep = raw.apt.ubuntu.packages.ripgrep;
    raw.apt.ubuntu.firstUse["cua-video"].ffmpeg = "7.*";
    const problems = problemsOf(raw);
    expect(problems).toContain("apt.ubuntu.firstUse.cua-video: ripgrep is also baked in apt.ubuntu.packages");
    expect(problems.some((p) => p.startsWith("apt.ubuntu.firstUse.cua-video.ffmpeg"))).toBe(true);
  });

  test("a first-use role needs a first-use closure, and a role default is on or off", () => {
    const raw = fresh();
    delete raw.apt.ubuntu.firstUse["cua-video"];
    raw.roles.display.default = "maybe";
    const problems = problemsOf(raw);
    expect(problems).toContain("roles.cua-video: firstUse needs apt.ubuntu.firstUse.cua-video");
    expect(problems).toContain('roles.display.default: must be "on" or "off"');
  });

  test("roles manifest written to /etc/cmux/roles.json lists defaults and first-use closures", () => {
    const manifest = rolesManifest(lock);
    expect(manifest.schema).toBe(1);
    expect(manifest.roles.display).toEqual({ default: "off", firstUse: false, apt: lock.roles.display.apt, env: {}, programs: [] });
    expect(manifest.roles["cua-video"].firstUse).toBe(true);
    expect(manifest.firstUse["cua-video"]).toEqual(lock.apt.ubuntu.firstUse["cua-video"]);
    expect(manifest.aptSnapshot).toBe(lock.apt.ubuntu.uri);
    expect(manifest.aptSources).toContain(`URIs: ${lock.apt.ubuntu.uri}`);
    expect(manifest.aptSources).toContain(`Signed-By: ${lock.apt.ubuntu.signedBy}`);
  });

  test("cmux-cua 0.8.7 (full release, LICENSE inside) is pinned by URL, sha256, size and checksums.txt, role cua", () => {
    const pinned = lock.programs.find((p) => p.name === "cmux-cua")!;
    expect(pinned).toMatchObject({ ...cmuxCuaReleaseShape("0.8.7", "x86_64"), expect: "cmux-cua 0.8.7", sha256: "95d18427ac02ea9964a198ca844f8ad6feb2113d784c2199e171cf459686e11e", size: 8706672 });
    expect(pinned.checksumsUrl).toBe("https://github.com/manaflow-ai/cmux-cua/releases/download/cmux-cua-v0.8.7/checksums.txt");
    expect(pinned.checksumsName).toBe("cmux-cua-0.8.7-linux-x86_64.tar.gz");
    expect(cmuxCuaReleaseShape("0.8.0", "x86_64")).toEqual({
      name: "cmux-cua",
      version: "0.8.0",
      url: "https://github.com/manaflow-ai/cmux-cua/releases/download/cmux-cua-v0.8.0/cmux-cua-0.8.0-linux-x86_64.tar.gz",
      format: "tar.gz",
      bin: { "cmux-cua": "cmux-cua-0.8.0-linux-x86_64/cmux-cua" },
      versionArgs: ["--version"],
      expect: "0.8.0",
      roles: ["cua"],
    });
    expect(cmuxCuaReleaseShape("0.8.0", "arm64").url).toContain("cmux-cua-0.8.0-linux-arm64.tar.gz");
    const raw = fresh();
    expect(problemsOf(raw)).toEqual([]);
    raw.programs.find((p: { name: string }) => p.name === "cmux-cua").roles = ["cua", "nope"];
    expect(problemsOf(raw).some((p) => p.includes('roles: unknown role "nope"'))).toBe(true);
  });
});

describe("browser role: off by default, installed on first use, sandboxed, background tabs throttled (RT8, D-A1)", () => {
  const lock = readInputsLock();
  const CFT_SHA256 = "ff43322f335e436b2f4dcdfeeec5db032299e335a7e8c1c618b326e100ce8732";
  const cftIndex = () => fresh().programs.findIndex((p: { name: string }) => p.name === "chrome-for-testing");

  test("the browser role is off and first-use; its closure is never baked; background tabs are not full rate", () => {
    expect(lock.roles.browser).toMatchObject({ default: "off", firstUse: true });
    expect(lock.roles.browser.env).toMatchObject({ CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE: "0" });
    for (const name of lock.roles.browser.apt) {
      expect(lock.apt.ubuntu.firstUse.browser[name]).toBeDefined();
      expect(lock.apt.ubuntu.packages[name]).toBeUndefined();
    }
    expect(lock.roles.browser.apt).toEqual(expect.arrayContaining(["libnss3", "libasound2t64", "libcups2t64", "fonts-liberation"]));
  });

  test("Chrome for Testing 154 (the CEF fork's major) x86_64 is pinned by Google's release URL, our sha256 and size; first use, role browser", () => {
    const cft = lock.programs.find((p) => p.name === "chrome-for-testing")!;
    expect(cft).toMatchObject({ ...chromeForTestingShape("154.0.8037.92"), sha256: CFT_SHA256, size: 196202491, firstUse: true });
    expect(cft.url).toBe("https://storage.googleapis.com/chrome-for-testing-public/154.0.8037.92/linux64/chrome-linux64.zip");
    expect(cft.source).toContain("md5=eb+FnbaHwkXCE8wFqB2DJw==");
    expect(isExactProgramVersion("154.0.8037.92")).toBe(true);
    expect(isExactProgramVersion("154.0.8037.*")).toBe(false);
  });

  test("first-use programs are not baked: no store install, no profile link, no programs-run check", () => {
    expect(bakedPrograms(lock).map((p) => p.name)).not.toContain("chrome-for-testing");
    expect(profileLinks(lock).map((l) => l.command)).not.toContain("chrome");
    expect(programChecksCommand(lock)).not.toContain("chrome --version");
  });

  test("roles.json carries the browser role's env, its first-use programs and the store path of chrome", () => {
    const browser = rolesManifest(lock).roles.browser;
    expect(browser.default).toBe("off");
    expect(browser.firstUse).toBe(true);
    expect(browser.env).toEqual({ CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE: "0", CMUX_BROWSER_HOST_CHROMIUM: `/opt/cmux/store/${CFT_SHA256}/chrome-linux64/chrome` });
    expect(browser.programs).toEqual([
      expect.objectContaining({ name: "chrome-for-testing", version: "154.0.8037.92", sha256: CFT_SHA256, size: 196202491, format: "zip", url: lock.programs.find((p) => p.name === "chrome-for-testing")!.url }),
      expect.objectContaining({ name: "cmux-browser-host" }),
    ]);
    expect(rolesManifest(lock).roles.display.programs).toEqual([]);
  });

  test("a zip program unpacks with unzip into its store entry, after the sha256 and size checks", () => {
    const cmd = programInstallCommand(lock.programs.find((p) => p.name === "chrome-for-testing")!);
    expect(cmd).toContain(`unzip -q /tmp/cmux-dl/${CFT_SHA256} -d /opt/cmux/store/${CFT_SHA256}.partial`);
    expect(cmd.indexOf("sha256sum -c")).toBeLessThan(cmd.indexOf("unzip"));
    expect(cmd).toContain(`test -x /opt/cmux/store/${CFT_SHA256}.partial/chrome-linux64/chrome`);
  });

  test("a first-use program needs roles that are all first-use roles", () => {
    const raw = fresh();
    raw.programs[cftIndex()].roles = ["cua"];
    expect(problemsOf(raw)).toContain(`programs[${cftIndex()}].firstUse: role cua is not a first-use role`);
    raw.programs[cftIndex()].roles = [];
    expect(problemsOf(raw)).toContain(`programs[${cftIndex()}].firstUse: needs at least one role`);
  });

  test("the browser role refuses full-rate background tabs and any sandbox-off switch", () => {
    const raw = fresh();
    raw.roles.browser.env.CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE = "1";
    raw.roles.browser.env.CMUX_BROWSER_HOST_CHROMIUM_ARGS = "--no-sandbox";
    raw.roles.browser.env.EXTRA = "--disable-setuid-sandbox";
    raw.roles.browser.env["bad key"] = "x";
    const problems = problemsOf(raw);
    expect(problems).toContain('roles.browser.env.CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE: must be "0" (background tabs are throttled, RT8 idle budget)');
    expect(problems).toContain("roles.browser.env.CMUX_BROWSER_HOST_CHROMIUM_ARGS: --no-sandbox is refused (the sandbox stays on)");
    expect(problems).toContain("roles.browser.env.EXTRA: --disable-setuid-sandbox is refused (the sandbox stays on)");
    expect(problems).toContain('roles.browser.env: bad variable name "bad key"');
    delete raw.roles.browser.env;
    expect(problemsOf(raw)).toContain('roles.browser.env.CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE: must be "0" (background tabs are throttled, RT8 idle budget)');
  });

  test("Chrome for Testing must come from Google's versioned release URL", () => {
    const raw = fresh();
    raw.programs[cftIndex()].url = "https://example.com/chrome-linux64.zip";
    expect(problemsOf(raw)).toContain(`programs[${cftIndex()}].url: must be ${chromeForTestingShape("154.0.8037.92").url}`);
  });
});

describe("cmux-browser-host 0.1.0 in the browser role (release cmux-browser-host-v0.1.0, browser-host.md 6d)", () => {
  const lock = readInputsLock();
  const X64 = "79b0945cdbe6e585a781da2530b2a3aafaa10969bc6d63b7559ae6a96e57da18";
  const ARM64 = "cca1a3a51d89e15c1bcf2e2bb2bec0462470f59756bb471d0564dd510f4239f2";
  const base = "https://github.com/manaflow-ai/cmux/releases/download/cmux-browser-host-v0.1.0";
  const hostIndex = () => fresh().programs.findIndex((p: { name: string }) => p.name === "cmux-browser-host");

  test("pinned for both arches by release URL, sha256, size and SHA256SUMS; first use, role browser; notices ship with the binary", () => {
    const host = lock.programs.find((p) => p.name === "cmux-browser-host")!;
    expect(host).toMatchObject({
      version: "0.1.0",
      url: `${base}/cmux-browser-host-0.1.0-x86_64-unknown-linux-gnu.tar.gz`,
      sha256: X64,
      size: 2294597,
      format: "tar.gz",
      bin: { "cmux-browser-host": "bin/cmux-browser-host" },
      versionArgs: ["version"],
      expect: "cmux-browser-host 0.1.0 (db8565dfe127b2d182eb508754129c541cc7cecb)",
      checksumsUrl: `${base}/SHA256SUMS`,
      checksumsName: "./cmux-browser-host-0.1.0-x86_64-unknown-linux-gnu.tar.gz",
      roles: ["browser"],
      firstUse: true,
      notices: ["LICENSE", "THIRD_PARTY_LICENSES.md"],
      otherArches: { aarch64: { url: `${base}/cmux-browser-host-0.1.0-aarch64-unknown-linux-gnu.tar.gz`, sha256: ARM64, size: 2133182, checksumsName: "./cmux-browser-host-0.1.0-aarch64-unknown-linux-gnu.tar.gz" } },
    });
  });

  test("the install fails without the license and the third-party notices", () => {
    const cmd = programInstallCommand(lock.programs.find((p) => p.name === "cmux-browser-host")!);
    expect(cmd).toContain(`test -s /opt/cmux/store/${X64}.partial/LICENSE`);
    expect(cmd).toContain(`test -s /opt/cmux/store/${X64}.partial/THIRD_PARTY_LICENSES.md`);
    expect(cmd.indexOf("test -s")).toBeLessThan(cmd.indexOf("chmod -R a-w"));
  });

  test("roles.json lists the host with its other arch for aarch64 hosts", () => {
    const host = rolesManifest(lock).roles.browser.programs.find((p) => p.name === "cmux-browser-host")!;
    expect(host).toMatchObject({ sha256: X64, notices: ["LICENSE", "THIRD_PARTY_LICENSES.md"], otherArches: { aarch64: { sha256: ARM64, size: 2133182 } } });
    expect(rolesManifest(lock).roles.browser.programs.map((p) => p.name).sort()).toEqual(["chrome-for-testing", "cmux-browser-host"]);
  });

  test("another arch needs an https URL, a sha256 and a size; a notice is a relative path", () => {
    const raw = fresh();
    raw.programs[hostIndex()].otherArches.aarch64.sha256 = "nope";
    raw.programs[hostIndex()].otherArches.riscv = { url: "http://x", size: 0 };
    raw.programs[hostIndex()].notices = ["../LICENSE"];
    const problems = problemsOf(raw);
    expect(problems).toContain(`programs[${hostIndex()}].otherArches.aarch64.sha256: missing or not 64 lowercase hex`);
    expect(problems).toContain(`programs[${hostIndex()}].otherArches.riscv: unknown arch`);
    expect(problems).toContain(`programs[${hostIndex()}].notices: "../LICENSE" must be a relative path inside the store entry`);
  });
});
