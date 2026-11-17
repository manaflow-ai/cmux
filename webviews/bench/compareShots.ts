// l10n-allow-file: benchmark output, not shipped UI.
// Scratch: bun bench/compareShots.ts <dirA> <dirB> prints, per PNG both hold, the differing pixels.
import { readdirSync, readFileSync } from "node:fs";
import { PNG } from "pngjs";
import pixelmatch from "pixelmatch";

const [a, b] = process.argv.slice(2);
let differing = 0;
let files = 0;
for (const name of readdirSync(a!).sort()) {
  if (!name.endsWith(".png")) continue;
  files += 1;
  const one = PNG.sync.read(readFileSync(`${a}/${name}`));
  const two = PNG.sync.read(readFileSync(`${b}/${name}`));
  const diff =
    one.width === two.width && one.height === two.height
      ? pixelmatch(one.data, two.data, undefined, one.width, one.height, { threshold: 0 })
      : -1;
  if (diff !== 0) differing += 1;
  console.log(`SHOT-DIFF ${name} ${diff}`);
}
console.log(`SHOT-DIFF-SUMMARY ${files} shots, ${differing} differ`);
