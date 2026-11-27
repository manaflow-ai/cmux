// bun scripts/cmux-next/check-release-notes.ts NOTES.json [PREVIOUS.json ...]
//
// The nightly-next pre-publish check (nightly.yml check-release-notes): reads this build's notes
// the way the What's New page (1 and 10 nightlies) and the update card will show them, and fails
// with one error annotation per defect (internal work among the machine lines only warns) (webviews/src/pages/changelog/notesCheck.ts). PREVIOUS are
// the nightlies published before it, newest first.
import { readFileSync } from "node:fs";
import { annotation, blocksPublish, checkNightlyNotes, RANGE } from "../../webviews/src/pages/changelog/notesCheck";
import type { ReleaseNotes } from "../../webviews/src/pages/changelog/types";

const [path, ...previousPaths] = process.argv.slice(2);
if (!path) {
  console.error("usage: check-release-notes.ts NOTES.json [PREVIOUS.json ...]");
  process.exit(2);
}
const read = (file: string) => JSON.parse(readFileSync(file, "utf8")) as ReleaseNotes;
const notes = read(path);
const previous = previousPaths.slice(0, RANGE - 1).map(read);
const defects = checkNightlyNotes(notes, previous);
for (const defect of defects) console.log(annotation(notes.build, defect));
if (defects.some(blocksPublish)) process.exit(1);
console.log(`${notes.build}: notes, page (1 and ${previous.length + 1} nightlies) and card read clean`);
