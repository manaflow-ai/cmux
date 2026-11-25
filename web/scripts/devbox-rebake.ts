#!/usr/bin/env bun
/**
 * The steps of the devbox rebake workflow (.github/workflows/cloud-devbox-image-rebake.yml)
 * that are not the bake itself. The bake, verify, size derivation and manifest write stay
 * promote-devbox-image.ts's; this only decides, names, records, settles and prunes.
 *
 *   bun scripts/devbox-rebake.ts plan [--force]
 *       needed=true when the image inputs (REBAKE_INPUTS: every file the bake reads or
 *       ships) differ from the ones the last published rebake recorded in
 *       rebake-state.json, or a Freestyle default in the manifest was not baked from this
 *       checkout's devbox sources (devboxSourceDriftProblems, the check promote enforces).
 *       Also the version this run publishes, <UTC yyyymmddHHMM>-<commit 10>-<inputs key 12>,
 *       and the image-stamp line the bake writes. key=value lines for $GITHUB_OUTPUT.
 *   bun scripts/devbox-rebake.ts pin-cmux-tui
 *       cmux_tui_manifest=<url>: the newest published cmux-tui manifest of this branch's
 *       cmux-tui history with acpmux (pinCmuxTuiManifest), for CMUX_VM_CMUX_TUI_MANIFEST_URL.
 *   bun scripts/devbox-rebake.ts record --version V
 *       Write rebake-state.json for this checkout's inputs (the publish commit carries it).
 *   bun scripts/devbox-rebake.ts settle
 *       After a promotion: drop every awaiting-rebake.json entry the new defaults satisfy
 *       (its drift is gone), so the manifest check and test pass with the promotion.
 *   FREESTYLE_API_KEY=... bun scripts/devbox-rebake.ts prune --keep N [--also-manifest F]... [--dry-run]
 *       Keep the newest N rebake versions' snapshots (slug cmux-devbox-ci-<version>[-<size>])
 *       and every snapshot any manifest row names (the base branch's rows are a subset of
 *       this checkout's); delete the other rebake snapshots. Never touches a snapshot
 *       without the rebake prefix.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { VM_IMAGE_SIZE_NAMES } from "../services/vms/images/sizes";
import { parseCmuxTuiManifest } from "../services/vms/drivers/cmuxTuiDaemon";
import {
  devboxAwaitingRebakePath,
  devboxImageEpoch,
  devboxSourceDriftProblems,
  hasFlag,
  argValue,
  isAwaitingRebake,
  readDevboxAwaitingRebake,
  readImageManifest,
  repoRoot,
  webRoot,
  type DevboxAwaitingRebake,
  type DevboxImageManifest,
} from "./devbox-image-common";

export const REBAKE_SLUG_PREFIX = "cmux-devbox-ci-";

/**
 * Every file the bake reads or ships, as repo-root globs. The workflow's push paths are
 * exactly these (plus the workflow and this script, which change how, not what, it bakes),
 * and tests/vm-devbox-rebake.test.ts checks that the whole relative-import closure of the
 * bake script and devbox-image-common.ts is covered (REBAKE_INPUT_EXEMPT aside).
 */
export const REBAKE_INPUTS = {
  include: [
    "web/services/vms/images/devbox/**",
    "web/services/vms/images/shell/**",
    "web/services/vms/images/desktop.ts",
    "web/services/vms/images/identity.ts",
    "web/services/vms/images/metadataGuard.ts",
    "web/services/vms/images/sizes.ts",
    "web/services/vms/images/workUser.ts",
    "web/services/vms/drivers/cmuxTuiDaemon.ts",
    "web/services/vms/drivers/types.ts",
    "web/services/vms/clientGrant.ts",
    "web/services/vms/guest*.ts",
    "web/services/vms/guestCliDistribution.json",
    "web/services/vms/networkPolicy.ts",
    "web/services/vms/promptName.ts",
    "web/services/vms/hygiene/**",
    "web/services/coderouter/vmGuestEnv.ts",
    "web/scripts/build-devbox-freestyle.ts",
    "web/scripts/devbox-image-common.ts",
    "web/scripts/cmux-vm-image/machine-health.ts",
    "web/scripts/cmux-vm-image/dns.ts",
    "images/cmux-vm/machine-health/**",
  ],
  // Prose.
  exclude: ["web/services/vms/images/**/*.md"],
} as const;

/**
 * Imported by the bake but not image inputs, each with its reason. The app's UI strings
 * (guestCliMessages.ts reads them) change on most UI PRs; a guest CLI string change rides
 * the next real rebake rather than baking the whole ladder on its own.
 */
export const REBAKE_INPUT_EXEMPT: Readonly<Record<string, string>> = {
  "web/messages/en.json": "app UI strings; the next rebake picks guest CLI strings up",
  "web/messages/ja.json": "app UI strings; the next rebake picks guest CLI strings up",
};

export const rebakeStatePath = path.join(webRoot, "services/vms/images/rebake-state.json");

export type RebakeState = { inputsKey: string; version: string; commit: string };

/** The files REBAKE_INPUTS selects in this checkout, with their blob ids (git ls-files -s). */
export function rebakeInputFiles(cwd = repoRoot): { path: string; blob: string }[] {
  const specs = [
    ...REBAKE_INPUTS.include.map((glob) => `:(glob)${glob}`),
    ...REBAKE_INPUTS.exclude.map((glob) => `:(glob,exclude)${glob}`),
  ];
  const out = execFileSync("git", ["ls-files", "-s", "--", ...specs], { cwd, encoding: "utf8" });
  return out
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [meta, file] = line.split("\t");
      return { path: file, blob: meta.split(" ")[1] };
    })
    .sort((a, b) => a.path.localeCompare(b.path));
}

/** sha256 over the selected paths and blob ids: changes exactly when an input does. */
export function rebakeInputsKey(files: readonly { path: string; blob: string }[]): string {
  return createHash("sha256").update(files.map((file) => `${file.path}\t${file.blob}`).join("\n")).digest("hex");
}

/** `<yyyymmddHHMM>-<commit 10>-<inputs key 12>`: sortable by time, names its commit and its inputs. */
export function rebakeVersion(now: Date, commit: string, key: string): string {
  const stamp = now.toISOString().replace(/[-:T]/g, "").slice(0, 12);
  return `${stamp}-${commit.slice(0, 10)}-${key.slice(0, 12)}`;
}

export function readRebakeState(file = rebakeStatePath): RebakeState | null {
  if (!existsSync(file)) return null;
  return JSON.parse(readFileSync(file, "utf8")) as RebakeState;
}

/** The awaiting entries a manifest still needs; the rest were baked by the promotion. */
export function settledAwaiting(
  awaiting: readonly DevboxAwaitingRebake[],
  drift: readonly string[],
): DevboxAwaitingRebake[] {
  return awaiting.filter((pending) => drift.some((problem) => isAwaitingRebake(problem, pending)));
}

export type SnapshotRow = { id: string; slug?: string | null };

/** The rebake version a snapshot slug belongs to, or null for any snapshot the rebake did not make. */
export function rebakeVersionOfSlug(slug: string | null | undefined): string | null {
  if (!slug || !slug.startsWith(REBAKE_SLUG_PREFIX)) return null;
  const rest = slug.slice(REBAKE_SLUG_PREFIX.length);
  const sizes = [...VM_IMAGE_SIZE_NAMES].sort((a, b) => b.length - a.length);
  for (const size of sizes) {
    if (rest.endsWith(`-${size}`)) return rest.slice(0, -size.length - 1);
  }
  return rest;
}

/**
 * Which rebake snapshots to delete: not among the newest `keep` versions and not named by
 * any manifest row. Promoted rows are never removed from the manifest, so a merged
 * promotion's snapshots (and so rollback by revert) are never pruned; what goes is
 * unpromoted rebakes beyond the newest `keep`.
 */
export function pruneSelection(
  snapshots: readonly SnapshotRow[],
  manifests: readonly Pick<DevboxImageManifest, "images">[],
  keep: number,
): SnapshotRow[] {
  if (!Number.isInteger(keep) || keep < 1) throw new Error(`--keep must be a positive integer, got ${keep}`);
  const referenced = new Set(manifests.flatMap((manifest) => manifest.images.map((entry) => entry.imageId)));
  const versions = [...new Set(snapshots.map((row) => rebakeVersionOfSlug(row.slug)).filter((v): v is string => v !== null))]
    .sort()
    .reverse();
  const kept = new Set(versions.slice(0, keep));
  return snapshots.filter((row) => {
    const version = rebakeVersionOfSlug(row.slug);
    return version !== null && !kept.has(version) && !referenced.has(row.id);
  });
}

type SnapshotLister = (options: { limit: number; offset: number }) => Promise<{ snapshots: SnapshotRow[]; totalCount: number }>;

/** Every snapshot on the account, page by page. */
export async function listAllSnapshots(list: SnapshotLister, pageSize = 100): Promise<SnapshotRow[]> {
  const rows: SnapshotRow[] = [];
  for (let offset = 0; ; offset += pageSize) {
    const page = await list({ limit: pageSize, offset });
    rows.push(...page.snapshots);
    if (page.snapshots.length === 0 || rows.length >= page.totalCount) return rows;
  }
}

export const CMUX_TUI_FILES = "https://files.cmux.com/cmux-tui";

/**
 * The bake installs cmux-tui and acpmux from a files.cmux.com manifest. The rolling
 * `latest` follows main, whose builds carry no acpmux, and the bake refuses an image
 * without it (requireCmuxTuiAcpmux). So the rebake pins the newest commit-addressed
 * manifest of this branch's cmux-tui history that parses with acpmux.
 */
export async function pinCmuxTuiManifest(
  commits: readonly string[],
  fetchJson: (url: string) => Promise<unknown | null>,
): Promise<string | null> {
  for (const commit of commits) {
    const url = `${CMUX_TUI_FILES}/${commit}/manifest.json`;
    const manifest = await fetchJson(url);
    if (manifest === null) continue;
    try {
      const source = parseCmuxTuiManifest(url, manifest);
      if (source.acpmuxUrl && source.acpmuxSha256) return url;
    } catch {
      // Not a usable Linux build; try the previous commit.
    }
  }
  return null;
}

async function pinCmuxTui(): Promise<void> {
  const commits = execFileSync("git", ["log", "--format=%H", "-80", "HEAD", "--", "cmux-tui"], { cwd: repoRoot, encoding: "utf8" })
    .split("\n")
    .filter(Boolean);
  const url = await pinCmuxTuiManifest(commits, async (candidate) => {
    const res = await fetch(candidate, { signal: AbortSignal.timeout(20_000) }).catch(() => null);
    return res?.ok ? res.json() : null;
  });
  if (!url) {
    console.error(`no published cmux-tui manifest with acpmux among the last ${commits.length} cmux-tui commits`);
    process.exit(1);
  }
  console.log(`cmux_tui_manifest=${url}`);
}

function gitHead(): string {
  return execFileSync("git", ["rev-parse", "HEAD"], { cwd: repoRoot, encoding: "utf8" }).trim();
}

function plan(): void {
  const drift = devboxSourceDriftProblems(readImageManifest());
  const key = rebakeInputsKey(rebakeInputFiles());
  const recorded = readRebakeState();
  const commit = gitHead();
  const version = rebakeVersion(new Date(), commit, key);
  for (const problem of drift) console.error(`drift: ${problem}`);
  console.error(`inputs: ${key} (last published: ${recorded?.inputsKey ?? "none"})`);
  const needed = hasFlag("--force") || drift.length > 0 || recorded?.inputsKey !== key;
  console.log(`needed=${needed}`);
  console.log(`version=${version}`);
  console.log(`slug=${REBAKE_SLUG_PREFIX}${version}`);
  console.log(`key=${key}`);
  console.log(`commit=${commit}`);
  // The known-good marker the smoke test reads back from a booted machine.
  console.log(`stamp=cmux-devbox ${devboxImageEpoch()} desktop`);
}

function record(): void {
  const version = argValue("--version");
  if (!version) throw new Error("record needs --version");
  const state: RebakeState = { inputsKey: rebakeInputsKey(rebakeInputFiles()), version, commit: gitHead() };
  writeFileSync(rebakeStatePath, `${JSON.stringify(state, null, 2)}\n`);
  console.log(`rebake-state: ${state.version} (${state.inputsKey.slice(0, 12)})`);
}

function settle(): void {
  const awaiting = readDevboxAwaitingRebake();
  const keep = settledAwaiting(awaiting, devboxSourceDriftProblems(readImageManifest()));
  if (keep.length === awaiting.length) {
    console.log(`awaiting-rebake: nothing settled (${awaiting.length} entries)`);
    return;
  }
  writeFileSync(devboxAwaitingRebakePath, `${JSON.stringify(keep, null, 2)}\n`);
  console.log(`awaiting-rebake: settled ${awaiting.length - keep.length} entries, ${keep.length} left`);
}

async function prune(): Promise<void> {
  const keep = Number(argValue("--keep") ?? "5");
  const dryRun = hasFlag("--dry-run");
  const { Freestyle } = await import("freestyle");
  const fs = new Freestyle({ baseUrl: process.env.FREESTYLE_API_URL?.trim() || undefined });
  const snapshots = await listAllSnapshots((options) => fs.vms.snapshots.list(options) as unknown as ReturnType<SnapshotLister>);
  // --also-manifest (repeatable): deployed branches' manifests as they are now, so their rows are kept too.
  const also = process.argv.flatMap((arg, index) => (arg === "--also-manifest" && process.argv[index + 1] ? [process.argv[index + 1]] : []));
  const doomed = pruneSelection(snapshots, [readImageManifest(), ...also.map((file) => readImageManifest(file))], keep);
  console.log(`prune: ${snapshots.length} snapshots; keeping the newest ${keep} rebake versions and every manifest image; ${doomed.length} to delete`);
  let failed = 0;
  for (const row of doomed) {
    if (dryRun) {
      console.log(`would delete ${row.id} (${row.slug})`);
      continue;
    }
    try {
      await fs.vms.snapshots.delete(row.id);
      console.log(`deleted ${row.id} (${row.slug})`);
    } catch (error) {
      failed += 1;
      console.error(`could not delete ${row.id} (${row.slug}): ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (failed > 0) process.exit(1);
}

const isEntryPoint = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntryPoint) {
  const command = process.argv[2];
  if (command === "plan") plan();
  else if (command === "record") record();
  else if (command === "settle") settle();
  else if (command === "prune") await prune();
  else if (command === "pin-cmux-tui") await pinCmuxTui();
  else {
    console.error("usage: bun scripts/devbox-rebake.ts plan [--force] | pin-cmux-tui | record --version V | settle | prune --keep N [--dry-run]");
    process.exit(2);
  }
}
