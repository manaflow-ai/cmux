import { cp, mkdir, rm, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The What's New pages (decision WHATS-NEW-AFTER-UPDATE) render the
// repository's whats-new/<version>.json, the same files the app bundles.
// Copy them (with media) into public/whats-new/ before `next build`: the
// pages read them at build time, and the site serves the raw files at
// /whats-new/<version>.json and /whats-new/media/... for the app and agents.
const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = resolve(webRoot, process.argv[2] ?? "../whats-new");
const destination = resolve(webRoot, process.argv[3] ?? "public/whats-new");

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
const exists = await stat(source).then(() => true, () => false);
if (exists) {
  await cp(source, destination, { recursive: true });
  console.log(`Synced ${source} -> ${destination}`);
} else {
  console.log(`No ${source}; ${destination} is empty`);
}
