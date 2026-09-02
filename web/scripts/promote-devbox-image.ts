#!/usr/bin/env bun
/**
 * Bake, verify, and record a cmux Cloud devbox image in one command. The
 * checked-in manifest (web/services/vms/images/manifest.json) is the source
 * of truth for the image users get, so the output of this script is a
 * manifest diff to commit; the LAST stdout line is `IMAGE_ID <id>`.
 *
 * Usage:
 *   bun scripts/promote-devbox-image.ts freestyle [--slug cmux-devbox-<tag>]
 *       [--kinds desktop,base] [--pointer-slug cmux-devbox]
 *       [--image <existing snapshot id>] [--skip-verify] [--out <json>]
 *       [--replace-slug] [--no-desktop] [--dry-run]
 *
 *   --image     promote an already-baked image (still verified) instead of baking.
 *   --bake-result <json>  adopt a bake script's --out file (its manifest entry
 *               and image id) instead of baking; still verified.
 *   --sizes     ladder sizes to derive from the verified bake (default
 *               sm,md,lg,xl,2xl; "none" records a single size-less entry):
 *               derive-devbox-sizes.ts boots the bake, resizes, snapshots and
 *               re-boots each one; the manifest gets one entry per kind and
 *               size, each the default for that kind+size. The bake must be
 *               on the smallest requested size (the default builder is
 *               freestyle/ubuntu-sm).
 *   --kinds     machine kinds the image serves; each gets a manifest entry
 *               flagged defaultForKind (default: desktop,base for a desktop
 *               bake, base for --no-desktop). A desktop image is a superset
 *               of a base one, so one snapshot can serve both.
 *   --pointer-slug  After promotion, move this account-local
 *               snapshot slug onto the new id (default cmux-devbox; "none"
 *               disables). A human/dashboard convenience: production boots
 *               from the immutable id in the manifest, never from the slug.
 *   --skip-verify   record validationStatus "unknown" instead of verifying.
 *               The entry is appended but NOT flagged as any default.
 *   --dry-run   print the manifest diff without writing it.
 *
 * Steps: bakePreflight (stale checkout guard) -> bake script (--out) ->
 * verify-devbox-image.ts (boots one VM, deletes it) -> manifest write ->
 * slug pointer. A failed verify writes nothing and exits 1.
 *
 * Run it from web/ with FREESTYLE_API_KEY in the environment of the Freestyle
 * account the deployment uses, then commit the manifest diff in a PR.
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { VM_IMAGE_SIZE_NAMES, isVmImageSizeName, type VmImageSize } from "../services/vms/images/sizes";
import {
  argValue,
  bakeMetadata,
  bakePreflight,
  defaultBakeTag,
  hasFlag,
  imageManifestPath,
  imageManifestProblems,
  manifestEntrySkeleton,
  promoteImageManifestEntry,
  readImageManifest,
  webRoot,
  writeImageManifest,
  type DevboxBakeResult,
  type DevboxImageKind,
  type DevboxManifestEntry,
  type DevboxProvider,
} from "./devbox-image-common";

const provider = process.argv[2] as DevboxProvider | undefined;
if (provider !== "freestyle") {
  throw new Error("usage: bun scripts/promote-devbox-image.ts freestyle [options]");
}

const withDesktop = !hasFlag("--no-desktop");
const requestedKinds = (argValue("--kinds") ?? (withDesktop ? "desktop,base" : "base"))
  .split(",")
  .map((kind) => kind.trim())
  .filter(Boolean);
for (const kind of requestedKinds) {
  if (kind !== "desktop" && kind !== "base") throw new Error(`--kinds: unknown kind ${kind}`);
}
const kinds = requestedKinds as DevboxImageKind[];
if (kinds.includes("desktop") && !withDesktop) {
  throw new Error("--kinds desktop needs a desktop bake (drop --no-desktop)");
}
const pointerSlug = argValue("--pointer-slug") ?? "cmux-devbox";
const skipVerify = hasFlag("--skip-verify");
const sizesArg = argValue("--sizes") ?? VM_IMAGE_SIZE_NAMES.join(",");
const sizeNames = sizesArg === "none" ? [] : sizesArg.split(",").map((name) => name.trim()).filter(Boolean);
for (const name of sizeNames) {
  if (!isVmImageSizeName(name)) throw new Error(`--sizes: unknown size ${name}; expected ${VM_IMAGE_SIZE_NAMES.join(", ")} or none`);
}
const dryRun = hasFlag("--dry-run");
const existingImage = argValue("--image");
const tag = defaultBakeTag();
const slug = argValue("--slug") ?? `cmux-${tag}`;

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const workDir = mkdtempSync(path.join(tmpdir(), "cmux-devbox-promote-"));

function run(label: string, args: string[]): number {
  console.log(`\n===== ${label}: bun ${args.join(" ")} =====`);
  const result = spawnSync("bun", args, { cwd: webRoot, stdio: "inherit", env: process.env });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

// 1. Bake (or adopt an existing image / a previous bake's result file).
let entry: DevboxManifestEntry;
let imageId: string;
const bakeResultPath = argValue("--bake-result");
if (bakeResultPath) {
  const bake = JSON.parse(readFileSync(bakeResultPath, "utf8")) as DevboxBakeResult;
  if (bake.provider !== provider) {
    throw new Error(`--bake-result is a ${bake.provider} bake, not ${provider}`);
  }
  entry = bake.manifestEntry;
  imageId = bake.imageId;
  console.log(`adopting bake result ${bakeResultPath}: ${imageId}`);
} else if (existingImage) {
  const preflight = bakePreflight({ desktop: withDesktop });
  const metadata = bakeMetadata(preflight, path.join(scriptsDir, `build-devbox-${provider}.ts`));
  imageId = existingImage;
  entry = manifestEntrySkeleton(
    provider,
    `${provider}-${argValue("--slug") ?? existingImage}`,
    existingImage,
    "FREESTYLE_SANDBOX_SNAPSHOT",
    metadata,
    `Promoted from an existing ${provider} image by promote-devbox-image.ts --image.`,
    withDesktop ? "desktop" : "base",
  );
} else {
  const bakeOut = path.join(workDir, "bake.json");
  const bakeArgs = [
    "scripts/build-devbox-freestyle.ts",
    slug,
    "--out",
    bakeOut,
    ...(hasFlag("--replace-slug") ? ["--replace-slug"] : []),
    ...(withDesktop ? [] : ["--no-desktop"]),
  ];
  const bakeStatus = run("bake", bakeArgs);
  if (bakeStatus !== 0) {
    console.error(`bake failed (exit ${bakeStatus}); nothing promoted`);
    process.exit(bakeStatus);
  }
  const bake = JSON.parse(readFileSync(bakeOut, "utf8")) as DevboxBakeResult;
  entry = bake.manifestEntry;
  imageId = bake.imageId;
}

// 2. Verify: the only path to validationStatus "passed".
let validationNotes: string;
if (skipVerify) {
  entry = { ...entry, validationStatus: "unknown" };
  validationNotes = "NOT VERIFIED (promote --skip-verify); verify before flagging as a default.";
} else {
  // The bake result or --no-desktop says which layer the image should carry;
  // verify reads the baked stamp and fails on a mismatch, so a base image can
  // never land as the desktop default.
  const expectedKind: DevboxImageKind = entry.kind ?? (withDesktop ? "desktop" : "base");
  const verifyStatus = run("verify", ["scripts/verify-devbox-image.ts", provider, imageId, "--expect-kind", expectedKind]);
  if (verifyStatus !== 0) {
    console.error(`verify failed (exit ${verifyStatus}) for ${provider} ${imageId}; nothing promoted`);
    process.exit(verifyStatus);
  }
  entry = { ...entry, validationStatus: "passed" };
  validationNotes =
    `Validated ${new Date().toISOString().slice(0, 10)} with verify-devbox-image.ts by promote-devbox-image.ts` +
    (withDesktop ? " (toolchain, agent pins, daemon contract, desktop on 5901/6901)." : " (toolchain, agent pins, daemon contract).");
}

// 2b. Sizes: derive the ladder from the verified bake, each booted and checked.
let sizes: Array<{ imageId: string; size: VmImageSize }> | undefined;
if (!skipVerify && sizeNames.length > 0) {
  const sizesOut = path.join(workDir, "sizes.json");
  const deriveStatus = run("derive sizes", [
    "scripts/derive-devbox-sizes.ts",
    imageId,
    argValue("--pointer-slug") ?? "cmux-devbox",
    "--sizes",
    sizeNames.join(","),
    "--out",
    sizesOut,
    ...(hasFlag("--replace-slug") ? ["--replace-slug"] : []),
  ]);
  if (deriveStatus !== 0) {
    console.error(`derive sizes failed (exit ${deriveStatus}); nothing promoted`);
    process.exit(deriveStatus);
  }
  const derived = JSON.parse(readFileSync(sizesOut, "utf8")) as { sizes: Record<string, { imageId: string; size: VmImageSize }> };
  sizes = Object.values(derived.sizes).map((row) => ({ imageId: row.imageId, size: row.size }));
  validationNotes += ` Sizes derived and re-booted by derive-devbox-sizes.ts: ${sizes.map((row) => `${row.size.name}=${row.imageId}`).join(", ")}.`;
}

// 3. Manifest: append and flip defaults (pure edit), then re-check invariants.
const manifest = readImageManifest();
const next = skipVerify
  ? { ...manifest, images: [...manifest.images, { ...entry, kind: kinds[0], notes: [entry.notes, validationNotes].filter(Boolean).join(" ") }] }
  : promoteImageManifestEntry(manifest, entry, { kinds, sizes, validationNotes });
const problems = imageManifestProblems(next);
if (problems.length > 0) {
  throw new Error(`refusing to write an inconsistent manifest:\n  ${problems.join("\n  ")}`);
}
const added = next.images.slice(manifest.images.length);
console.log(`\n===== manifest =====\n${JSON.stringify(added, null, 2)}`);
if (dryRun) {
  console.log(`--dry-run: not writing ${imageManifestPath}`);
} else {
  writeImageManifest(next);
  console.log(`wrote ${imageManifestPath} (+${added.length} entries)`);
}

// 4. Pointer slug: a readable "current" handle on the platform. With sizes,
// derive-devbox-sizes.ts already named each snapshot `<pointer>[-<size>]`.
let pointer: string | null = null;
if (!dryRun && !skipVerify && pointerSlug !== "none" && !sizes) {
  const { Freestyle } = await import("freestyle");
  const fs = new Freestyle({ baseUrl: process.env.FREESTYLE_API_URL?.trim() || undefined });
  try {
    await fs.vms.snapshots.update(imageId, { slug: pointerSlug });
  } catch {
    const { snapshots } = await fs.vms.snapshots.list();
    const holder = snapshots.find((candidate) => candidate.slug === pointerSlug && candidate.id !== imageId);
    if (holder) {
      await fs.vms.snapshots.update(holder.id, { slug: "" });
      console.log(`pointer slug ${pointerSlug} released from ${holder.id}`);
    }
    await fs.vms.snapshots.update(imageId, { slug: pointerSlug });
  }
  pointer = pointerSlug;
  console.log(`pointer slug ${pointerSlug} -> ${imageId}`);
}

const result = {
  provider,
  imageId,
  kinds,
  versions: added.map((row) => row.version),
  sizes: sizes?.map((row) => row.size.name) ?? [],
  validationStatus: entry.validationStatus,
  pointerSlug: pointer,
  manifest: dryRun ? null : imageManifestPath,
};
console.log(JSON.stringify(result, null, 2));
const out = argValue("--out");
if (out) writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
console.log(`IMAGE_ID ${imageId}`);
