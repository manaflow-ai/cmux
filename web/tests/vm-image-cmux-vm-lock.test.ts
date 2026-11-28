import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  aptClosureProblems,
  basePackageProblems,
  bakedPrograms,
  chromeForTestingShape,
  cmuxCuaReleaseShape,
  cmuxRdReleaseShape,
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
import { acpmuxListCommand, acpmuxListProblems, programChecksCommand } from "../scripts/cmux-vm-image/smoke";
import { runChild } from "./helpers/run-child";

const lockText = readFileSync(DEFAULT_LOCK_PATH, "utf8");
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- tests mutate arbitrary nested lock fields
const fresh = () => JSON.parse(lockText) as Record<string, any>;

/** Whether `want` is the release right after `pin`: the next patch, minor (patch 0) or major (minor and patch 0). */
function nextRelease(pin: string, want: string): boolean {
  const [a, b] = [pin, want].map((v) => v.split(/[-+]/)[0]!.split(".").map(Number));
  if (b![0] === a![0]! + 1) return b![1] === 0 && b![2] === 0;
  if (b![0] !== a![0]) return false;
  if (b![1] === a![1]! + 1) return b![2] === 0;
  return b![1] === a![1] && b![2] === a![2]! + 1;
}

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
    expect(lock.programs.map((p) => p.name).sort()).toEqual([...KNOWN_PROGRAMS, "cmux-cua", "chrome-for-testing", "cmux-browser-host", "agent-desktop", "cmux-rd", "optchat-chief"].sort());
    expect(lock.apt.ubuntu.uri).toContain(lock.apt.ubuntu.snapshot);
    expect(lock.apt.ubuntu.snapshot).toBe("20261122T000000Z");
    expect(profileLinks(lock).map((l) => l.command)).toContain("cr");
  });

  test("Claude Code is the devbox Dockerfile's pin, so the native image never ships an older one", () => {
    // One source of truth: the native bake installs the lock's claude, the devbox image the Dockerfile's
    // CMUX_IMAGE_CLAUDE_CODE_VERSION. A lock left behind shipped 2.1.267, which the API refuses (2.1.280 or newer).
    const dockerfile = readFileSync(new URL("../services/vms/images/devbox/Dockerfile", import.meta.url), "utf8");
    const pin = /^ARG CMUX_IMAGE_CLAUDE_CODE_VERSION=(\S+)$/m.exec(dockerfile)?.[1];
    const claude = readInputsLock().programs.find((p) => p.name === "claude");
    expect(pin).toBeDefined();
    expect(claude?.version).toBe(pin);
    expect(claude?.expect).toBe(pin);
    expect(claude?.url).toBe(`https://downloads.claude.ai/claude-code-releases/${pin}/linux-x64/claude`);
  });

  test("codex ships with the code-mode host it spawns next to itself, and the install refuses an entry without it", () => {
    // Codex 0.160 runs every tool through codex-code-mode-host from its own folder. The plain musl
    // tarball has codex alone, so Cloud chats failed every tool call: failed to spawn code-mode host
    // /opt/cmux/store/<sha>/codex-code-mode-host. The codex-package tarball carries both.
    const codex = readInputsLock().programs.find((p) => p.name === "codex")!;
    expect(codex.url).toBe(`https://github.com/openai/codex/releases/download/rust-v${codex.version}/codex-package-x86_64-unknown-linux-musl.tar.gz`);
    expect(codex.bin.codex).toBe("bin/codex");
    const install = programInstallCommand(codex);
    expect(install).toContain(`test -x /opt/cmux/store/${codex.sha256}.partial/bin/codex-code-mode-host`);
    expect(install.indexOf("codex-code-mode-host")).toBeLessThan(install.indexOf("chmod -R a-w"));
  });

  test("acpmux is cmux-tui under its own name (argv0 dispatch), checked by version and by a session list", async () => {
    // Automation agent steps run `acpmux run`; cmux-tui runs acpmux when argv0 is `acpmux`.
    const lock = readInputsLock();
    const tui = lock.programs.find((p) => p.name === "cmux-tui")!;
    expect(tui.bin.acpmux).toBe(tui.fileName!);
    const link = profileLinks(lock).find((l) => l.command === "acpmux");
    expect(link?.target).toBe(profileLinks(lock).find((l) => l.command === "cmux-tui")!.target);
    expect(programChecksCommand(lock)).toContain("acpmux --version");
    const list = acpmuxListCommand();
    expect(list).toContain("acpmux ls --json");
    // acpmux ls no longer starts a daemon (#28046), so the smoke starts one before listing.
    expect(list.indexOf("acpmux daemon start")).toBeGreaterThan(-1);
    expect(list.indexOf("acpmux daemon start")).toBeLessThan(list.indexOf("acpmux ls --json"));
    const syntax = await runChild("bash", ["-n"], { input: list, timeout: 20_000 });
    expect(syntax.stderr).toBe("");
    expect(syntax.status).toBe(0);
    expect(acpmuxListProblems(0, '{"sessions": []}\n', "")).toEqual([]);
    expect(acpmuxListProblems(127, "", "bash: line 1: acpmux: command not found\n")).toEqual(["acpmux ls --json: exit 127: bash: line 1: acpmux: command not found"]);
    expect(acpmuxListProblems(0, "no sessions", "")[0]).toContain("not JSON");
    expect(acpmuxListProblems(0, "{}", "")[0]).toContain("no sessions list");
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

  test("a locked package the base already has at the locked version counts as installed", () => {
    // The 10-21 Freestyle base started shipping ripgrep 14.1.0-1, so apt had nothing to add for it.
    const base = parseDpkgList("ripgrep\t14.1.0-1\tamd64\nacl\t2.3.2-1build1\tamd64\n");
    expect(aptClosureProblems({ ripgrep: "14.1.0-1" }, new Map(), base)).toEqual([]);
    expect(aptClosureProblems({ acl: "2.3.2-1build1.1" }, new Map(), base)).toEqual(["lock package acl=2.3.2-1build1.1 was not installed (the base has 2.3.2-1build1)"]);
    expect(aptClosureProblems({ ripgrep: "14.1.0-1" }, new Map())).toEqual(["lock package ripgrep was not installed"]);
  });

  test("base packages and npm globals must be in the lock", () => {
    expect(basePackageProblems(lock, new Map(Object.entries(lock.base.basePackages)))).toEqual([]);
    expect(basePackageProblems(lock, new Map())).toHaveLength(Object.keys(lock.base.basePackages).length);
    const globals = new Map([["npm", lock.base.npmGlobals.keep.npm], ["openclaw", "2026.7.1-2"], ["left-pad", "1.3.0"], ["corepack", "0.37.0"]]);
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

  test("the repro diff allows the npm download cache by directory, and only under it", () => {
    const a = new Map([["/home/cmux/.npm/_cacache/index-v5/aa/bb", "F 1"], ["/home/cmux/.npm/_cacache/content-v2/sha512/x", "F 2"], ["/home/cmux/.npm/_logs/1.log", "F 3"], ["/home/cmux/.npmrc", "F 4"]]);
    const b = new Map([["/home/cmux/.npm/_cacache/index-v5/aa/bb", "F 9"], ["/home/cmux/.npm/_cacache/content-v2/sha512/y", "F 2"], ["/home/cmux/.npm/_logs/1.log", "F 8"], ["/home/cmux/.npmrc", "F 7"]]);
    const result = diffFileManifests(a, b);
    expect(result.allowed).toHaveLength(3);
    expect(result.diffs.map((l) => l.split(":")[0])).toEqual(["/home/cmux/.npm/_logs/1.log", "/home/cmux/.npmrc"]);
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

  test("cmux-cua 0.8.12 (the macOS app's release, scripts/build-cmux-cua.sh; LICENSE inside) is pinned by URL, sha256, size and checksums.txt, role cua", () => {
    const pinned = lock.programs.find((p) => p.name === "cmux-cua")!;
    expect(pinned).toMatchObject({ ...cmuxCuaReleaseShape("0.8.12", "x86_64"), expect: "cmux-cua 0.8.12", sha256: "3a81784562139f273e9489baefe2ce8b63cb59cf61290a10a18377ebaa15c521", size: 8741562 });
    expect(pinned.checksumsUrl).toBe("https://github.com/manaflow-ai/cmux-cua/releases/download/cmux-cua-v0.8.12/checksums.txt");
    expect(pinned.checksumsName).toBe("cmux-cua-0.8.12-linux-x86_64.tar.gz");
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

describe("agent-desktop (vercel-labs, Lawrence's ask 2026-10-30)", () => {
  test("1.0.2 x86_64 is baked by release URL, sha256, size and checksums.txt, with its clipboard helper beside the binary", () => {
    const lock = readInputsLock();
    const pinned = lock.programs.find((p) => p.name === "agent-desktop")!;
    expect(pinned).toMatchObject({
      version: "1.0.2",
      url: "https://github.com/vercel-labs/agent-desktop/releases/download/v1.0.2/agent-desktop-v1.0.2-x86_64-unknown-linux-gnu.tar.gz",
      sha256: "ad661b7a3fd8f990a769243f4889a240ca0e2c8dab3ef5bddd6019086c71e0b4",
      size: 3359127,
      format: "tar.gz",
      bin: { "agent-desktop": "agent-desktop" },
      versionArgs: ["--version"],
      expect: "agent-desktop 1.0.2",
      checksumsUrl: "https://github.com/vercel-labs/agent-desktop/releases/download/v1.0.2/checksums.txt",
      checksumsName: "agent-desktop-v1.0.2-x86_64-unknown-linux-gnu.tar.gz",
    });
    expect(pinned.firstUse).toBeUndefined();
    expect(bakedPrograms(lock).map((p) => p.name)).toContain("agent-desktop");
    expect(profileLinks(lock).map((l) => l.command)).toContain("agent-desktop");
    expect(programChecksCommand(lock)).toContain("agent-desktop --version");
    const install = programInstallCommand(pinned);
    expect(install).toContain("agent-desktop-v1.0.2-x86_64-unknown-linux-gnu.tar.gz' ");
    expect(install).toContain("ad661b7a3fd8f990a769243f4889a240ca0e2c8dab3ef5bddd6019086c71e0b4");
  });
});

describe("browser role: off by default, installed on first use, sandboxed, background tabs throttled (RT8, D-A1)", () => {
  const lock = readInputsLock();
  const CFT_SHA256 = "e6c94490f0b6b337225aeb2d2a5034858516b7017356980ba94f5176d8774a50";
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

  test("Chrome for Testing 156 (CfT Stable) x86_64 is pinned by Google's release URL, our sha256 and size; first use, role browser", () => {
    const cft = lock.programs.find((p) => p.name === "chrome-for-testing")!;
    expect(cft).toMatchObject({ ...chromeForTestingShape("156.0.8078.47"), sha256: CFT_SHA256, size: 200206486, firstUse: true });
    expect(cft.url).toBe("https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.47/linux64/chrome-linux64.zip");
    expect(cft.source).toContain("md5=cvpoYXzFXs9OK75pfi91hA==");
    expect(isExactProgramVersion("156.0.8078.47")).toBe(true);
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
      expect.objectContaining({ name: "chrome-for-testing", version: "156.0.8078.47", sha256: CFT_SHA256, size: 200206486, format: "zip", url: lock.programs.find((p) => p.name === "chrome-for-testing")!.url }),
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
    expect(problemsOf(raw)).toContain(`programs[${cftIndex()}].url: must be ${chromeForTestingShape("156.0.8078.47").url}`);
  });
});

describe("cmux-browser-host 1.0.0-r1 in the browser role (release cmux-browser-host-v1.0.0-r1, browser-host.md 6d; the host the daemon starts must accept --history-fd)", () => {
  const lock = readInputsLock();
  const X64 = "756021355332841537aad2ec102b1b9703950c9f90504c3b082b3b18e8af4fbb";
  const ARM64 = "2a74586ca8cb215180a56b4d0b89478b2479a02b0f4b01163ba46d0b0a3afecc";
  const base = "https://github.com/manaflow-ai/cmux/releases/download/cmux-browser-host-v1.0.0-r1";
  const hostIndex = () => fresh().programs.findIndex((p: { name: string }) => p.name === "cmux-browser-host");

  test("pinned for both arches by release URL, sha256, size and SHA256SUMS; first use, role browser; notices ship with the binary", () => {
    const host = lock.programs.find((p) => p.name === "cmux-browser-host")!;
    expect(host).toMatchObject({
      version: "1.0.0-r1",
      url: `${base}/cmux-browser-host-1.0.0-r1-x86_64-unknown-linux-gnu.tar.gz`,
      sha256: X64,
      size: 2474679,
      format: "tar.gz",
      bin: { "cmux-browser-host": "bin/cmux-browser-host" },
      versionArgs: ["version"],
      expect: "cmux-browser-host 1.0.0 (4cf5c4ccc7c5c93bf90ebdb910b31b90f075ac72)",
      checksumsUrl: `${base}/SHA256SUMS`,
      checksumsName: "./cmux-browser-host-1.0.0-r1-x86_64-unknown-linux-gnu.tar.gz",
      roles: ["browser"],
      firstUse: true,
      notices: ["LICENSE", "THIRD_PARTY_LICENSES.md"],
      otherArches: { aarch64: { url: `${base}/cmux-browser-host-1.0.0-r1-aarch64-unknown-linux-gnu.tar.gz`, sha256: ARM64, size: 2286591, checksumsName: "./cmux-browser-host-1.0.0-r1-aarch64-unknown-linux-gnu.tar.gz" } },
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
    expect(host).toMatchObject({ sha256: X64, notices: ["LICENSE", "THIRD_PARTY_LICENSES.md"], otherArches: { aarch64: { sha256: ARM64, size: 2286591 } } });
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

describe("codex ships codex-code-mode-host beside codex (2026-11-25: every Cloud Codex tool call failed to spawn the host)", () => {
  const lock = readInputsLock();
  const codexIndex = () => fresh().programs.findIndex((p: { name: string }) => p.name === "codex");
  const HOST = "bin/codex-code-mode-host";

  test("the lock lists the host beside the codex binary", () => {
    const codex = lock.programs.find((p) => p.name === "codex")!;
    expect(codex.companions).toEqual([HOST]);
    expect(Object.values(codex.bin)[0]).toBe("bin/codex");
  });

  test("the install refuses an archive without the host before it moves into the store", () => {
    const codex = lock.programs.find((p) => p.name === "codex")!;
    const cmd = programInstallCommand(codex);
    expect(cmd).toContain(`test -x /opt/cmux/store/${codex.sha256}.partial/${HOST}`);
    expect(cmd.indexOf(`/${HOST}`)).toBeLessThan(cmd.indexOf("chmod -R a-w"));
  });

  test("a codex entry without the host is refused with the reason", () => {
    const raw = fresh();
    delete raw.programs[codexIndex()].companions;
    expect(problemsOf(raw)).toContain(
      `programs[${codexIndex()}].companions: codex spawns codex-code-mode-host from beside bin/codex; list ${HOST} (an archive without it breaks every tool call)`,
    );
  });

  test("a companion must be a relative path inside the store entry", () => {
    const raw = fresh();
    raw.programs[codexIndex()].companions = ["../codex-code-mode-host"];
    expect(problemsOf(raw)).toContain(`programs[${codexIndex()}].companions: must be a non-empty array of relative paths inside the store entry`);
  });
});

describe("cmux-rd (the cmux.rd/1 Linux host, role desktop; release cmux-rd-v<V> on manaflow-ai/cmux)", () => {
  const entry = (version = "0.1.0") => ({ ...cmuxRdReleaseShape(version), sha256: "cd".repeat(32), size: 4096 });
  const withRd = (patch: Record<string, unknown> = {}) => {
    const raw = fresh();
    raw.programs = raw.programs.filter((p: { name: string }) => p.name !== "cmux-rd");
    raw.programs.push({ ...entry(), ...patch });
    return raw;
  };
  const rdIndex = (raw: ReturnType<typeof fresh>) => raw.programs.findIndex((p: { name: string }) => p.name === "cmux-rd");

  test("the shape is the release tarball, checked against the release checksums.txt, baked in role desktop", () => {
    expect(cmuxRdReleaseShape("0.1.0")).toEqual({
      name: "cmux-rd",
      version: "0.1.0",
      url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-rd-v0.1.0/cmux-rd-0.1.0-x86_64-unknown-linux-gnu.tar.gz",
      format: "tar.gz",
      bin: { "cmux-rd": "bin/cmux-rd" },
      versionArgs: [],
      checksumsUrl: "https://github.com/manaflow-ai/cmux/releases/download/cmux-rd-v0.1.0/checksums.txt",
      checksumsName: "cmux-rd-0.1.0-x86_64-unknown-linux-gnu.tar.gz",
      notices: ["LICENSE", "THIRD_PARTY_LICENSES.md"],
      roles: ["desktop"],
    });
    expect(problemsOf(withRd())).toEqual([]);
    const lock = validateInputsLock(withRd());
    expect(bakedPrograms(lock).map((p) => p.name)).toContain("cmux-rd");
    expect(profileLinks(lock).find((l) => l.command === "cmux-rd")?.target).toBe(`/opt/cmux/store/${"cd".repeat(32)}/bin/cmux-rd`);
    expect(programInstallCommand(lock.programs[rdIndex(withRd())])).toContain(`grep -qx '${"cd".repeat(32)}  cmux-rd-0.1.0-x86_64-unknown-linux-gnu.tar.gz'`);
  });

  test("the install unpacks an archive packed as scripts/release.py packs it (bin/cmux-rd, LICENSE, THIRD_PARTY_LICENSES.md at the root)", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-rd-archive-"));
    try {
      const archive = path.join(dir, "cmux-rd-0.1.0-x86_64-unknown-linux-gnu.tar.gz");
      // The members, modes and order of release.py package(); written here, not derived from the shape.
      const pack = [
        "import gzip, io, sys, tarfile",
        "raw = io.BytesIO()",
        "with tarfile.open(fileobj=raw, mode='w', format=tarfile.PAX_FORMAT) as tar:",
        "    for name, mode, payload in (('LICENSE', 0o644, b'GPL'), ('THIRD_PARTY_LICENSES.md', 0o644, b'# notices'), ('bin', 0o755, None), ('bin/cmux-rd', 0o755, b'#!/bin/sh\\necho rd\\n')):",
        "        info = tarfile.TarInfo(name); info.mode = mode",
        "        if payload is None: info.type = tarfile.DIRTYPE; tar.addfile(info)",
        "        else: info.size = len(payload); tar.addfile(info, io.BytesIO(payload))",
        "open(sys.argv[1], 'wb').write(gzip.compress(raw.getvalue(), mtime=0))",
      ].join("\n");
      expect((await runChild("python3", ["-I", "-c", pack, archive], { timeout: 20_000 })).status).toBe(0);
      const bytes = readFileSync(archive);
      const sha256 = createHash("sha256").update(bytes).digest("hex");
      const program = { ...cmuxRdReleaseShape("0.1.0"), sha256, size: bytes.length, url: `file://${archive}`, checksumsUrl: undefined, checksumsName: undefined };
      const store = path.join(dir, "store");
      const command = programInstallCommand(program).replaceAll("/opt/cmux/store", store).replaceAll("/tmp/cmux-dl", path.join(dir, "dl"));
      const r = await runChild("bash", ["-c", command], { timeout: 60_000, env: { ...process.env, CMUX_PINNED_MIRROR: "" } });
      expect(r.stderr).toBe("");
      expect(r.status).toBe(0);
      const entry = path.join(store, sha256);
      for (const target of [...Object.values(program.bin), ...program.notices]) expect(existsSync(path.join(entry, target))).toBe(true);
      expect((await runChild(path.join(entry, program.bin["cmux-rd"]), [], { timeout: 20_000 })).stdout.trim()).toBe("rd");
    } finally {
      await runChild("chmod", ["-R", "u+w", dir]);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("0.2.9 is pinned from release cmux-rd-v0.2.9 (#50463, run 45160613949) by URL, sha256, size and checksums.txt, baked in role desktop", () => {
    const pinned = readInputsLock().programs.find((p) => p.name === "cmux-rd")!;
    expect(pinned).toMatchObject({ ...cmuxRdReleaseShape("0.2.9"), sha256: "09e4120d8428b2e7ce626e14dbbbb74e29f0a36c2ce5b4080c958fca4496305e", size: 10234313 });
    expect(pinned.pendingRelease).toBeUndefined();
    expect(pinned.firstUse).toBeUndefined();
    expect(bakedPrograms(readInputsLock()).map((p) => p.name)).toContain("cmux-rd");
  });

  // A joined or Cloud Linux machine runs the cmux-rd these pins name, and the viewer speaks the
  // crate's version: a pin left behind the crate hands the machine a host many fixes old (0.2.3
  // against 0.2.7, screen share part 9). Every cmux-rd pin (this lock, and any acpmux source that
  // names a cmux-rd-v<V> release URL) must be at least cmux-rd-host's crate version.
  // One exception, for the window between a crate bump and its release (the release builds from
  // the bump's merge commit, so the bump cannot carry the pin): the lock's cmux-rd entry names
  // the crate version as pendingRelease, and every pin is the release just before it. The PR
  // that pins the published release clears the marker; a marker left behind fails too.
  test("no cmux-rd pin falls behind cmux-rd-host's crate version, but by one pending release the lock names", () => {
    const repo = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
    const cargo = readFileSync(path.join(repo, "cmux-tui/crates/cmux-rd-host/Cargo.toml"), "utf8");
    const packageTable = cargo.split(/^\[package\]\s*$/m)[1]?.split(/^\[/m)[0] ?? "";
    const crate = /^version\s*=\s*"(\d+\.\d+\.\d+[^"]*)"/m.exec(packageTable)?.[1];
    expect(crate).toBeDefined();
    const parts = (v: string) => v.split(/[-+]/)[0]!.split(".").map(Number);
    const behind = (pin: string, want: string) => {
      const [a, b] = [parts(pin), parts(want)];
      for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i]! < b[i]!;
      return false;
    };
    const rd = readInputsLock().programs.find((p) => p.name === "cmux-rd")!;
    const pending = rd.pendingRelease;
    const pins = [{ where: "images/cmux-vm/inputs.lock.json", version: rd.version }];
    const acpmux = path.join(repo, "cmux-tui/crates/acpmux/src");
    const sources = readdirSync(acpmux, { recursive: true, encoding: "utf8" }).filter((file) => file.endsWith(".rs"));
    for (const file of sources) {
      for (const m of readFileSync(path.join(acpmux, file), "utf8").matchAll(/releases\/download\/cmux-rd-v(\d+\.\d+\.\d+[^/"]*)\//g)) {
        pins.push({ where: `cmux-tui/crates/acpmux/src/${file}`, version: m[1]! });
      }
    }
    expect(pins.filter((p) => behind(p.version, crate!) && !(pending === crate && nextRelease(p.version, crate!))).map((p) => `${p.where}: cmux-rd ${p.version} is behind the crate's ${crate}${pending === undefined ? "" : ` (pendingRelease ${pending})`}`)).toEqual([]);
    const trailing = pins.some((p) => behind(p.version, crate!));
    if (pending !== undefined) expect(trailing ? [] : [`pendingRelease ${pending} is left in the lock with every pin at the crate's ${crate}: clear it`]).toEqual([]);
  });

  test("a crate one release ahead of the pin is the only gap pendingRelease covers", () => {
    expect(nextRelease("0.2.7", "0.2.8")).toBe(true);
    expect(nextRelease("0.2.7", "0.3.0")).toBe(true);
    expect(nextRelease("0.2.7", "1.0.0")).toBe(true);
    expect(nextRelease("0.2.6", "0.2.8")).toBe(false);
    expect(nextRelease("0.2.7", "0.3.1")).toBe(false);
    expect(nextRelease("0.2.7", "0.2.7")).toBe(false);
    expect(problemsOf(withRd({ pendingRelease: "next" }))).toContain(`programs[${rdIndex(withRd())}].pendingRelease: must be a version X.Y.Z`);
    const raw = fresh();
    const other = raw.programs.findIndex((p: { name: string }) => p.name !== "cmux-rd");
    raw.programs[other].pendingRelease = "1.0.0";
    expect(problemsOf(raw)).toContain(`programs[${other}].pendingRelease: only cmux-rd has a pending release`);
  });

  test("another URL, no checksums.txt, no desktop role or a first-use entry is refused", () => {
    const at = rdIndex(withRd());
    expect(problemsOf(withRd({ url: "https://example.com/cmux-rd.tar.gz" }))).toContain(`programs[${at}].url: must be ${cmuxRdReleaseShape("0.1.0").url}`);
    expect(problemsOf(withRd({ checksumsUrl: undefined, checksumsName: undefined })).some((p) => p.startsWith(`programs[${at}].checksumsUrl: must be`))).toBe(true);
    expect(problemsOf(withRd({ roles: ["cua"] }))).toContain(`programs[${at}].roles: cmux-rd is in the desktop role`);
    expect(problemsOf(withRd({ firstUse: true })).some((p) => p.includes("cmux-rd is baked"))).toBe(true);
  });
});

describe("the Antigravity CLI (agy) in the store", () => {
  // Leo 2026-11-25: "we'll want to set up antigravity/antigravity cli and opencode capable".
  test("is baked as `agy` (acpmux runs `agy acp`) for both architectures, version-checked", () => {
    const lock = parseInputsLock(lockText);
    const agy = bakedPrograms(lock).find((p) => p.name === "agy");
    expect(agy).toBeDefined();
    expect(agy!.format).toBe("tar.gz");
    expect(agy!.bin).toEqual({ agy: "antigravity" });
    expect(agy!.versionArgs).toEqual(["--version"]);
    expect(agy!.expect).toBe(agy!.version);
    expect(agy!.url).toContain(`/antigravity-cli/${agy!.version}-`);
    expect(agy!.otherArches?.aarch64?.url).toContain(`/antigravity-cli/${agy!.version}-`);
    expect(programChecksCommand(lock)).toContain("agy --version");
  });

  test("its own updater is off in login shells and the systemd user manager", async () => {
    const { agyProfileScript, agyUserEnvironment, AGY_PROFILE_PATH, AGY_USER_ENV_PATH } = await import("../scripts/cmux-vm-image/bake");
    expect(AGY_PROFILE_PATH).toStartWith("/etc/profile.d/");
    expect(AGY_USER_ENV_PATH).toStartWith("/etc/environment.d/");
    expect(agyProfileScript()).toContain("\nexport AGY_CLI_DISABLE_AUTO_UPDATE=1\n");
    expect(agyUserEnvironment()).toContain("\nAGY_CLI_DISABLE_AUTO_UPDATE=1\n");
  });

  test("acpmux.service finds the store CLIs without its login shell read (roll 45862819601)", async () => {
    const { acpmuxStorePathDropIn, ACPMUX_STORE_PATH_DROPIN } = await import("../scripts/cmux-vm-image/bake");
    const { ACPMUX_UNIT_PATH } = await import("../services/vms/drivers/cmuxTuiDaemon");
    expect(ACPMUX_STORE_PATH_DROPIN).toBe("/etc/systemd/user/acpmux.service.d/10-cmux-store-path.conf");
    const lines = acpmuxStorePathDropIn().split("\n");
    expect(lines).toContain("[Service]");
    const pathLine = lines.find((l) => l.startsWith("Environment=PATH="));
    // The store first, as a login shell orders it, then every entry of the unit's own PATH.
    expect(pathLine).toBe(`Environment=PATH=/opt/cmux/github/bin:/opt/cmux/current/bin:${ACPMUX_UNIT_PATH}`);
  });
});
