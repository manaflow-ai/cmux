import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  REBAKE_SLUG_PREFIX,
  pruneSelection,
  rebakeVersion,
  rebakeVersionOfSlug,
  settledAwaiting,
} from "../scripts/devbox-rebake";
import { readDevboxAwaitingRebake, type DevboxAwaitingRebake } from "../scripts/devbox-image-common";

const digest = "08eaadaaff2d2bae9b06f0ab85925fcbbfc8b35eea8da89088b58ea92842b0ee";

describe("rebakeVersion", () => {
  test("sorts by time and names the commit and the sources", () => {
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
  const snapshots = [
    ...versions.flatMap((v, i) => [
      { id: `sh-${i}-bake`, slug: `${REBAKE_SLUG_PREFIX}${v}` },
      { id: `sh-${i}-md`, slug: `${REBAKE_SLUG_PREFIX}${v}-md` },
    ]),
    { id: "sh-hand", slug: "cmux-devbox-agents-1014b-md" },
    { id: "sh-noslug", slug: null },
  ];

  test("keeps the newest versions, the manifest defaults and every snapshot it did not make", () => {
    const manifest = { images: [{ imageId: "sh-0-md", defaultForKind: true }, { imageId: "sh-1-md", defaultForKind: false }] } as never;
    const doomed = pruneSelection(snapshots, manifest, 1).map((row) => row.id);
    expect(doomed.sort()).toEqual(["sh-0-bake", "sh-1-bake", "sh-1-md"]);
    expect(pruneSelection(snapshots, manifest, 3)).toEqual([]);
  });

  test("refuses a keep below one", () => {
    expect(() => pruneSelection(snapshots, { images: [] }, 0)).toThrow();
  });
});

describe("settledAwaiting", () => {
  const pending: DevboxAwaitingRebake = { layers: "desktop", schema: 2, baked: "28fce1e49495", current: digest };
  const problem = `freestyle-x: baked from devbox sources 28fce1e49495… (schema 2), this checkout's desktop sources are ${digest.slice(0, 12)}…; promote a new bake`;

  test("keeps an entry while its drift remains and drops it once a promotion baked it", () => {
    expect(settledAwaiting([pending], [problem])).toEqual([pending]);
    expect(settledAwaiting([pending], [])).toEqual([]);
  });
});

describe("awaiting-rebake.json", () => {
  test("parses, and the rebake workflow bakes from the sources it watches", () => {
    readDevboxAwaitingRebake();
    const workflow = readFileSync(path.join(import.meta.dir, "../../.github/workflows/cloud-devbox-image-rebake.yml"), "utf8");
    for (const watched of ["web/services/vms/images/devbox/**", "web/scripts/build-devbox-freestyle.ts", "web/scripts/devbox-image-common.ts"]) {
      expect(workflow).toContain(`- ${watched}`);
    }
    expect(workflow).toContain("cancel-in-progress: false");
  });
});
