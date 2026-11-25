import { generateKeyPairSync, createHash, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import {
  LINUX_RELEASE_FILES_PREFIX,
  LINUX_RELEASE_KEYS,
  LINUX_RELEASE_MAX_FILE_BYTES,
  linuxReleaseKey,
  linuxReleaseTrustedKeys,
  verifyLinuxRelease,
  type LinuxReleaseKey,
} from "../services/vms/drivers/linuxRelease";
import {
  CMUX_TUI_RELEASE_TARGET,
  cmuxTuiInstallCommand,
  cmuxTuiPinnedCommit,
  cmuxTuiSourceOfCommit,
  resetCmuxTuiSourceCache,
  resolveCmuxTuiSource,
} from "../services/vms/drivers/cmuxTuiDaemon";
import { pinCmuxTuiManifest } from "../scripts/devbox-rebake";

const COMMIT = "bfc014745f74c8822b49837a82cd90b7f23b3c47";
const TREE = "df65220e9948cbe76924483c2a7ae1a98d52efbc";
const TARGET = CMUX_TUI_RELEASE_TARGET;
const FIXTURE = join(import.meta.dirname, "fixtures", "linux-release-bfc014745f74.json");
const WEB_UPDATE_KEYS = join(
  import.meta.dirname,
  "../../Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json",
);

type Signer = { readonly key: LinuxReleaseKey; readonly privateKey: KeyObject };

function signer(): Signer {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
  const id = createHash("sha256").update(raw).digest("hex").slice(0, 16);
  return { key: linuxReleaseKey(id, raw), privateKey };
}

function envelope(by: Signer, payload: unknown): string {
  const bytes = Buffer.from(JSON.stringify(payload));
  return JSON.stringify({
    schema: 1,
    payload: bytes.toString("base64"),
    signatures: [{ key_id: by.key.id, sig: sign(null, bytes, by.privateKey).toString("base64") }],
  });
}

function file(prefix: string, name: string, size: number, digit: string) {
  return { url: `${prefix}${name}-${TARGET}`, sha256: digit.repeat(64), size };
}

/** The phase 1 per-commit payload as CI publishes it, cut to one target. */
function payload(prefix = `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/`, extra: Record<string, unknown> = {}) {
  return {
    channel: "feat-cmux-next",
    commit: COMMIT,
    committed_at: 1_795_341_681,
    expires_at: 1_797_936_518,
    published_at: 1_795_344_518,
    purpose: "cmux-linux-release",
    schema: 1,
    targets: {
      [TARGET]: {
        "cmux-tui": file(prefix, "cmux-tui", 142_076_464, "a"),
        "cmux-tui-hook": file(prefix, "cmux-tui-hook", 4_877_392, "b"),
      },
    },
    version: "1.0.0+20261122100121.bfc014745f74",
    ...extra,
  };
}

describe("linux release file", () => {
  test("the keys compiled in equal web-update-keys.json", () => {
    const web = JSON.parse(readFileSync(WEB_UPDATE_KEYS, "utf8")) as { keys: { id: string; ed25519: string }[] };
    expect([...LINUX_RELEASE_KEYS].map(([id, key]) => [id, key]).sort()).toEqual(web.keys.map((k) => [k.id, k.ed25519]).sort());
    // Each id is the first 16 hex of the key's sha256, as the envelope's readers compute it.
    for (const [id, key] of LINUX_RELEASE_KEYS) {
      expect(createHash("sha256").update(Buffer.from(key, "base64")).digest("hex").slice(0, 16)).toBe(id);
    }
  });

  test("CI's published release file verifies with the compiled-in keys", () => {
    const release = verifyLinuxRelease(readFileSync(FIXTURE, "utf8"), { commit: COMMIT });
    expect(release.commit).toBe(COMMIT);
    expect(release.file(TARGET, "cmux-tui")).toEqual({
      url: `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/cmux-tui-${TARGET}`,
      sha256: "0393bf56d8ce61b1f7d70d0d8bdce1642fd49fe35134895cdcff112efa014933",
      size: 142_076_464,
    });
    expect(release.file(TARGET, "cmux-tui-acpmux")).toBeNull();
    expect(() => verifyLinuxRelease(readFileSync(FIXTURE, "utf8"), { commit: "1".repeat(40) })).toThrow(/is for commit/);
  });

  test("a file no trusted key signed, or changed after signing, is refused", () => {
    const [ours, theirs] = [signer(), signer()];
    const body = envelope(theirs, payload());
    expect(() => verifyLinuxRelease(body, { commit: COMMIT }, [ours.key])).toThrow(/no valid signature/);
    const tampered = JSON.parse(envelope(ours, payload())) as { payload: string };
    const changed = payload();
    changed.targets[TARGET]["cmux-tui"].sha256 = "c".repeat(64);
    tampered.payload = Buffer.from(JSON.stringify(changed)).toString("base64");
    expect(() => verifyLinuxRelease(JSON.stringify(tampered), { commit: COMMIT }, [ours.key])).toThrow(/no valid signature/);
    expect(() => verifyLinuxRelease("not json", { commit: COMMIT }, [ours.key])).toThrow(/not an envelope/);
    // The production keys do not take a test key's signature.
    expect(() => verifyLinuxRelease(envelope(ours, payload()), { commit: COMMIT }, linuxReleaseTrustedKeys())).toThrow();
  });

  test("another kind of file, another commit's or tree's file, or an expired channel is refused", () => {
    const s = signer();
    const keys = [s.key];
    expect(() => verifyLinuxRelease(envelope(s, payload(undefined, { purpose: "cmux-cloud-machine-update" })), { commit: COMMIT }, keys)).toThrow(/not a Linux release/);
    const { purpose: _purpose, ...web } = payload();
    expect(() => verifyLinuxRelease(envelope(s, web), { commit: COMMIT }, keys)).toThrow(/not a Linux release/);
    expect(() => verifyLinuxRelease(envelope(s, payload()), { tree: TREE }, keys)).toThrow(/tree/);
    const channel = { channel: "feat-cmux-next", now: new Date(1_795_400_000_000) };
    expect(verifyLinuxRelease(envelope(s, payload()), channel, keys).commit).toBe(COMMIT);
    expect(() => verifyLinuxRelease(envelope(s, payload()), { ...channel, channel: "stable" }, keys)).toThrow(/channel/);
    expect(() => verifyLinuxRelease(envelope(s, payload()), { ...channel, now: new Date(1_797_936_518_000) }, keys)).toThrow(/expired/);
  });

  test("a binary off the file's own prefix, or with a bad sha256 or size, is refused", () => {
    const s = signer();
    const keys = [s.key];
    for (const url of [
      `https://evil.example/cmux-tui/${COMMIT}/cmux-tui-${TARGET}`,
      `${LINUX_RELEASE_FILES_PREFIX}${"2".repeat(40)}/cmux-tui-${TARGET}`,
      `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/cmux-tui-hook-${TARGET}`,
      `${LINUX_RELEASE_FILES_PREFIX}tree/${TREE}/cmux-tui-${TARGET}`,
    ]) {
      const p = payload();
      p.targets[TARGET]["cmux-tui"].url = url;
      expect(() => verifyLinuxRelease(envelope(s, p), { commit: COMMIT }, keys).file(TARGET, "cmux-tui")).toThrow(/url/);
    }
    for (const [field, value] of [["sha256", "ABC"], ["size", 0], ["size", LINUX_RELEASE_MAX_FILE_BYTES + 1], ["size", "1"]] as const) {
      const p = payload() as unknown as { targets: Record<string, Record<string, Record<string, unknown>>> };
      p.targets[TARGET]["cmux-tui"][field] = value;
      expect(() => verifyLinuxRelease(envelope(s, p), { commit: COMMIT }, keys).file(TARGET, "cmux-tui")).toThrow(field);
    }
  });

  test("a tree alias and a tree's own file point under the tree", () => {
    const s = signer();
    const keys = [s.key];
    const alias = payload(`${LINUX_RELEASE_FILES_PREFIX}tree/${TREE}/`, { tree_key: TREE });
    expect(verifyLinuxRelease(envelope(s, alias), { commit: COMMIT }, keys).file(TARGET, "cmux-tui")?.url).toBe(
      `${LINUX_RELEASE_FILES_PREFIX}tree/${TREE}/cmux-tui-${TARGET}`,
    );
    expect(verifyLinuxRelease(envelope(s, alias), { tree: TREE }, keys).treeKey).toBe(TREE);
    const mixed = payload(undefined, { tree_key: TREE });
    expect(() => verifyLinuxRelease(envelope(s, mixed), { commit: COMMIT }, keys).file(TARGET, "cmux-tui")).toThrow(/url/);
  });
});

/** A files.cmux.com double: url -> body, a 404 for anything else. */
function files(published: Record<string, string>) {
  const asked: string[] = [];
  return { asked, fetchText: async (url: string) => (asked.push(url), published[url] ?? null) };
}

function withEnv<T>(name: string, value: string | undefined, run: () => T): T {
  const previous = process.env[name];
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
  try {
    return run();
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  }
}

describe("the Cloud bake's cmux-tui source", () => {
  afterEach(() => resetCmuxTuiSourceCache());
  const release = `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/release.json`;
  const manifest = `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/manifest.json`;
  const channel = `${LINUX_RELEASE_FILES_PREFIX}channels/linux-feat-cmux-next.json`;

  test("takes the daemon and hook, sha256 and size, from the commit's signed release file", async () => {
    const s = signer();
    const { fetchText, asked } = files({ [release]: envelope(s, payload()) });
    const source = await cmuxTuiSourceOfCommit(COMMIT, { fetchText, keys: [s.key] });
    expect(source).toMatchObject({
      commit: COMMIT,
      url: `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/cmux-tui-${TARGET}`,
      sha256: "a".repeat(64),
      size: 142_076_464,
      hookSha256: "b".repeat(64),
      hookSize: 4_877_392,
      acpmuxUrl: null,
    });
    expect(asked).toEqual([release, manifest]);
    // The install checks size and sha256, and curl stops past the signed size.
    const command = cmuxTuiInstallCommand(source!);
    expect(command).toContain(`--max-filesize 142076464 `);
    expect(command).toContain(`[ "$(wc -c < "$CMUX_TUI_TMP")" -eq 142076464 ] && printf`);
    expect(command).toContain(`-eq 4877392 ]`);
  });

  test("acpmux comes from the release file when it lists it, else (phase 1) the same commit's manifest", async () => {
    const s = signer();
    const prefix = `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/`;
    const withAcpmux = payload();
    (withAcpmux.targets[TARGET] as Record<string, unknown>)["cmux-tui-acpmux"] = file(prefix, "cmux-tui-acpmux", 20_000_000, "d");
    const signed = await cmuxTuiSourceOfCommit(COMMIT, { ...files({ [release]: envelope(s, withAcpmux) }), keys: [s.key] });
    expect(signed).toMatchObject({ acpmuxSha256: "d".repeat(64), acpmuxSize: 20_000_000 });
    const binaries = {
      [`cmux-tui-${TARGET}`]: "e".repeat(64),
      [`cmux-tui-hook-${TARGET}`]: "f".repeat(64),
      [`cmux-tui-acpmux-${TARGET}`]: "1".repeat(64),
    };
    const legacy = await cmuxTuiSourceOfCommit(COMMIT, {
      ...files({ [release]: envelope(s, payload()), [manifest]: JSON.stringify({ commit: COMMIT, binaries }) }),
      keys: [s.key],
    });
    // The manifest's daemon and hook sums are ignored; only acpmux is taken from it.
    expect(legacy).toMatchObject({ sha256: "a".repeat(64), hookSha256: "b".repeat(64), acpmuxSha256: "1".repeat(64), acpmuxSize: null });
  });

  test("a commit without a release file gives nothing; a forged one is refused", async () => {
    const s = signer();
    expect(await cmuxTuiSourceOfCommit(COMMIT, { ...files({}), keys: [s.key] })).toBeNull();
    await expect(cmuxTuiSourceOfCommit(COMMIT, { ...files({ [release]: envelope(signer(), payload()) }), keys: [s.key] })).rejects.toThrow(/refused/);
  });

  test("an unpinned bake follows the signed channel, a pinned one its commit", async () => {
    const s = signer();
    const channelPayload = payload(undefined, { expires_at: Math.floor(Date.now() / 1000) + 3600 });
    const { fetchText, asked } = files({ [channel]: envelope(s, channelPayload), [release]: envelope(s, payload()) });
    await withEnv("CMUX_VM_CMUX_TUI_MANIFEST_URL", undefined, async () => {
      expect((await resolveCmuxTuiSource("freestyle", { fetchText, keys: [s.key] })).commit).toBe(COMMIT);
    });
    expect(asked.slice(0, 2)).toEqual([channel, release]);
    resetCmuxTuiSourceCache();
    const other = "3".repeat(40);
    await withEnv("CMUX_VM_CMUX_TUI_MANIFEST_URL", `${LINUX_RELEASE_FILES_PREFIX}${other}/manifest.json`, async () => {
      await expect(resolveCmuxTuiSource("freestyle", { fetchText, keys: [s.key] })).rejects.toThrow(/no signed release file/);
    });
  });

  test("the pin names a files.cmux.com commit or latest; anything else is refused", () => {
    expect(withEnv("CMUX_VM_CMUX_TUI_MANIFEST_URL", undefined, () => cmuxTuiPinnedCommit())).toBeNull();
    expect(withEnv("CMUX_VM_CMUX_TUI_MANIFEST_URL", `${LINUX_RELEASE_FILES_PREFIX}latest/manifest.json`, () => cmuxTuiPinnedCommit())).toBeNull();
    expect(withEnv("CMUX_VM_CMUX_TUI_MANIFEST_URL", `${LINUX_RELEASE_FILES_PREFIX}${COMMIT}/manifest.json`, () => cmuxTuiPinnedCommit())).toBe(COMMIT);
    for (const url of [`https://mirror.example/cmux-tui/${COMMIT}/manifest.json`, `${LINUX_RELEASE_FILES_PREFIX}abc/manifest.json`]) {
      expect(() => withEnv("CMUX_VM_CMUX_TUI_MANIFEST_URL", url, () => cmuxTuiPinnedCommit())).toThrow(/release\.json/);
    }
  });

  test("the rebake pins the newest commit whose release file verifies and has acpmux", async () => {
    const s = signer();
    const [unsigned, noAcpmux, good, older] = ["1", "2", "3", "4"].map((c) => c.repeat(40));
    const at = (commit: string, acpmux: boolean) => {
      const prefix = `${LINUX_RELEASE_FILES_PREFIX}${commit}/`;
      const p = payload(prefix, { commit });
      if (acpmux) (p.targets[TARGET] as Record<string, unknown>)["cmux-tui-acpmux"] = file(prefix, "cmux-tui-acpmux", 1000, "d");
      return envelope(s, p);
    };
    const { fetchText } = files({
      [`${LINUX_RELEASE_FILES_PREFIX}${unsigned}/manifest.json`]: JSON.stringify({ commit: unsigned, binaries: {} }),
      [`${LINUX_RELEASE_FILES_PREFIX}${noAcpmux}/release.json`]: at(noAcpmux, false),
      [`${LINUX_RELEASE_FILES_PREFIX}${good}/release.json`]: at(good, true),
      [`${LINUX_RELEASE_FILES_PREFIX}${older}/release.json`]: at(older, true),
    });
    expect(await pinCmuxTuiManifest([unsigned, noAcpmux, good, older], fetchText, [s.key])).toBe(
      `https://files.cmux.com/cmux-tui/${good}/manifest.json`,
    );
    expect(await pinCmuxTuiManifest(["5".repeat(40)], fetchText, [s.key])).toBeNull();
  });
});
