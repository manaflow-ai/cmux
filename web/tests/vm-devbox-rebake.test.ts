import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  REBAKE_INPUTS,
  REBAKE_INPUT_EXEMPT,
  REBAKE_SLUG_PREFIX,
  CMUX_TUI_FILES,
  pinCmuxTuiManifest,
  listAllSnapshots,
  pruneSelection,
  rebakeInputFiles,
  rebakeInputsKey,
  rebakeVersion,
  rebakeVersionOfSlug,
  settledAwaiting,
  type SnapshotRow,
} from "../scripts/devbox-rebake";
import { readDevboxAwaitingRebake, repoRoot, type DevboxAwaitingRebake } from "../scripts/devbox-image-common";

const here = path.dirname(fileURLToPath(import.meta.url));
// Bun's YAML parser; web/tests are typed by tests/bun-test.d.ts, which has no Bun global.
const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
const digest = "08eaadaaff2d2bae9b06f0ab85925fcbbfc8b35eea8da89088b58ea92842b0ee";

describe("rebakeVersion", () => {
  test("sorts by time and names the commit and the inputs", () => {
    const version = rebakeVersion(new Date("2026-10-27T22:05:09Z"), "4c2a4dc7c40abcdef0123", digest);
    expect(version).toBe("202610272205-4c2a4dc7c4-08eaadaaff2d");
    const later = rebakeVersion(new Date("2026-10-28T01:00:00Z"), "0000000000", digest);
    expect([later, version].sort()).toEqual([version, later]);
  });
});

describe("rebakeVersionOfSlug", () => {
  test("strips the size suffix and ignores snapshots the rebake did not make", () => {
    const v = "202610272205-4c2a4dc7c4-08eaadaaff2d";
    expect(rebakeVersionOfSlug(`${REBAKE_SLUG_PREFIX}${v}`)).toBe(v);
    for (const size of ["sm", "md", "lg", "lgx", "xl", "2xl"]) {
      expect(rebakeVersionOfSlug(`${REBAKE_SLUG_PREFIX}${v}-${size}`)).toBe(v);
    }
    expect(rebakeVersionOfSlug("cmux-devbox")).toBeNull();
    expect(rebakeVersionOfSlug("cmux-devbox-agents-1014b-md")).toBeNull();
    expect(rebakeVersionOfSlug(null)).toBeNull();
  });
});

describe("pruneSelection", () => {
  const versions = ["202610010000-aaaaaaaaaa-111111111111", "202610020000-bbbbbbbbbb-222222222222", "202610030000-cccccccccc-333333333333"];
  const snapshots: SnapshotRow[] = [
    ...versions.flatMap((v, i) => [
      { id: `sh-${i}-bake`, slug: `${REBAKE_SLUG_PREFIX}${v}` },
      { id: `sh-${i}-md`, slug: `${REBAKE_SLUG_PREFIX}${v}-md` },
    ]),
    { id: "sh-hand", slug: "cmux-devbox-agents-1014b-md" },
    { id: "sh-noslug", slug: null },
  ];

  test("keeps the newest versions, every manifest row (default or demoted) and every snapshot it did not make", () => {
    const manifest = { images: [{ imageId: "sh-0-md", defaultForKind: false }] } as never;
    const doomed = pruneSelection(snapshots, [manifest], 1).map((row) => row.id);
    expect(doomed.sort()).toEqual(["sh-0-bake", "sh-1-bake", "sh-1-md"]);
    expect(pruneSelection(snapshots, [manifest], 3)).toEqual([]);
  });

  test("refuses a keep below one", () => {
    expect(() => pruneSelection(snapshots, [{ images: [] }], 0)).toThrow();
  });
});

describe("listAllSnapshots", () => {
  test("reads every page", async () => {
    const all = Array.from({ length: 250 }, (_, i) => ({ id: `sh-${i}`, slug: null }));
    const seen: number[] = [];
    const rows = await listAllSnapshots(async ({ limit, offset }) => {
      seen.push(offset);
      return { snapshots: all.slice(offset, offset + limit), totalCount: all.length };
    });
    expect(rows.length).toBe(250);
    expect(seen).toEqual([0, 100, 200]);
  });
});

describe("settledAwaiting", () => {
  const pending: DevboxAwaitingRebake = { layers: "desktop", schema: 2, baked: "28fce1e49495", current: digest };
  const problem = `freestyle-x: baked from devbox sources 28fce1e49495… (schema 2), this checkout's desktop sources are ${digest.slice(0, 12)}…; promote a new bake`;

  test("keeps an entry while its drift remains and drops it once a promotion baked it", () => {
    expect(settledAwaiting([pending], [problem])).toEqual([pending]);
    expect(settledAwaiting([pending], [])).toEqual([]);
  });

  test("awaiting-rebake.json parses", () => {
    readDevboxAwaitingRebake();
  });
});

describe("rebake inputs", () => {
  const files = rebakeInputFiles();
  const paths = new Set(files.map((file) => file.path));

  test("cover the image sources and nothing a promotion writes", () => {
    for (const required of [
      "web/services/vms/images/devbox/Dockerfile",
      "web/services/vms/images/devbox/cmux-prompt-sync",
      "web/services/vms/images/devbox/cmux-vm-kind-sync",
      "web/services/vms/images/shell/cmux-shell.sh",
      "web/scripts/build-devbox-freestyle.ts",
    ]) {
      expect(paths.has(required)).toBe(true);
    }
    for (const written of ["web/services/vms/images/manifest.json", "web/services/vms/images/awaiting-rebake.json", "web/services/vms/images/devbox/README.md"]) {
      expect(paths.has(written)).toBe(false);
    }
    expect(rebakeInputsKey(files)).toMatch(/^[0-9a-f]{64}$/);
  });

  test("cover the whole relative-import closure of the bake script and its shared module", () => {
    const seen = new Set<string>();
    const todo = ["web/scripts/build-devbox-freestyle.ts", "web/scripts/devbox-image-common.ts"];
    while (todo.length > 0) {
      const file = todo.pop()!;
      if (seen.has(file)) continue;
      seen.add(file);
      if (!file.endsWith(".ts")) continue;
      const text = readFileSync(path.join(repoRoot, file), "utf8");
      for (const match of text.matchAll(/from "(\.{1,2}\/[^"]+)"/g)) {
        const base = path.relative(repoRoot, path.resolve(path.dirname(path.join(repoRoot, file)), match[1]));
        const resolved = [base, `${base}.ts`, `${base}/index.ts`].find((candidate) => existsSync(path.join(repoRoot, candidate)));
        if (resolved) todo.push(resolved);
      }
    }
    const uncovered = [...seen].filter((file) => !paths.has(file) && !(file in REBAKE_INPUT_EXEMPT)).sort();
    expect(uncovered).toEqual([]);
    for (const exempt of Object.keys(REBAKE_INPUT_EXEMPT)) expect(seen.has(exempt)).toBe(true);
  });

  test("are exactly the rebake workflow's push paths", () => {
    const workflow = YAML.parse(readFileSync(path.join(here, "../../.github/workflows/cloud-devbox-image-rebake.yml"), "utf8")) as {
      on: { push: { paths: string[] } };
      concurrency: { "cancel-in-progress": boolean };
      jobs: { rebake: { if: string } };
    };
    expect(workflow.on.push.paths).toEqual([
      ...REBAKE_INPUTS.include,
      ...REBAKE_INPUTS.exclude.map((glob) => `!${glob}`),
      "web/scripts/devbox-rebake.ts",
      ".github/workflows/cloud-devbox-image-rebake.yml",
    ]);
    expect(workflow.concurrency["cancel-in-progress"]).toBe(false);
    // The account and the devbox-rebake/* PRs are shared: one canonical branch bakes.
    expect(workflow.jobs.rebake.if).toContain("github.ref == 'refs/heads/feat-cmux-next'");
  });
});

describe("pinCmuxTuiManifest", () => {
  const sha = (c: string) => c.repeat(64);
  const manifest = (commit: string, acpmux: boolean) => ({
    commit,
    binaries: {
      "cmux-tui-x86_64-unknown-linux-musl": sha("a"),
      "cmux-tui-hook-x86_64-unknown-linux-musl": sha("b"),
      ...(acpmux ? { "cmux-tui-acpmux-x86_64-unknown-linux-musl": sha("c") } : {}),
    },
  });

  test("takes the newest published build that carries acpmux", async () => {
    const [unpublished, noAcpmux, good, older] = ["1", "2", "3", "4"].map((c) => c.repeat(40));
    const published: Record<string, unknown> = {
      [`${CMUX_TUI_FILES}/${noAcpmux}/manifest.json`]: manifest(noAcpmux, false),
      [`${CMUX_TUI_FILES}/${good}/manifest.json`]: manifest(good, true),
      [`${CMUX_TUI_FILES}/${older}/manifest.json`]: manifest(older, true),
    };
    const url = await pinCmuxTuiManifest([unpublished, noAcpmux, good, older], async (u) => published[u] ?? null);
    expect(url).toBe(`${CMUX_TUI_FILES}/${good}/manifest.json`);
  });

  test("returns null when no candidate has acpmux", async () => {
    expect(await pinCmuxTuiManifest(["5".repeat(40)], async () => null)).toBeNull();
  });
});
