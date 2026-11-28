import { copyFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Vercel functions only contain files that Next traces inside the project
// root. The changelog routes read CHANGELOG.md at request time for versions
// that are not prerendered, so copy the repository file into web/ before
// `next build` and let next.config.ts trace the copy.
const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const [sourceArg, destinationArg] = process.argv.slice(2);
const sourcePath = resolve(webRoot, sourceArg ?? "../CHANGELOG.md");
const destinationPath = resolve(webRoot, destinationArg ?? "CHANGELOG.md");

await mkdir(dirname(destinationPath), { recursive: true });
await copyFile(sourcePath, destinationPath);
console.log(`Synced ${sourcePath} -> ${destinationPath}`);
