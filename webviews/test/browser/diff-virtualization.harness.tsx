// Browser harness for test/diff-virtualization.test.ts: the real diff viewer
// (toolbar, files tree, CodeView, header bars, find) over a generated
// 2,000-file patch, two of them 20,000-line files with 1,429 changed lines
// each (large enough that the viewer defers them behind "Load diff"). The
// patch is served from a blob URL through the viewer's own patchURL path, so
// it streams and parses exactly as a patch from the host does.
// As src/diff/dev.ts does: the stylesheet imported normally, the English labels.
import "../../src/styles.css";
import { diffViewerLabelsFor } from "../../src/labels";
import { mountDiffSurface } from "../../src/surfaces/diffSurface";

export const SMALL_FILES = 1998;
export const HUGE_FILES = 2;

/** `count` lines where every line in `changed` is replaced, as the app's patch input. */
function filePatch(
  name: string,
  count: number,
  line: (index: number, changed: boolean) => string,
  changed: (index: number) => boolean,
) {
  const context = 3;
  const hunks: string[] = [];
  let index = 0;
  while (index < count) {
    if (!changed(index)) {
      index += 1;
      continue;
    }
    const start = Math.max(0, index - context);
    let end = index;
    // Extend the hunk while the next change is within the shared context.
    for (let next = index + 1; next < count && next <= end + context * 2 + 1; next += 1) {
      if (changed(next)) {
        end = next;
      }
    }
    const stop = Math.min(count, end + context + 1);
    const body: string[] = [];
    for (let k = start; k < stop; k += 1) {
      if (changed(k)) {
        body.push(`-${line(k, false)}`, `+${line(k, true)}`);
      } else {
        body.push(` ${line(k, false)}`);
      }
    }
    const size = stop - start;
    hunks.push(`@@ -${start + 1},${size} +${start + 1},${size} @@\n${body.join("\n")}`);
    index = stop;
  }
  return `diff --git a/${name} b/${name}\nindex 1111111..2222222 100644\n--- a/${name}\n+++ b/${name}\n${hunks.join("\n")}\n`;
}

function buildPatch(): string {
  const patches: string[] = [];
  for (let index = 0; index < HUGE_FILES; index += 1) {
    patches.push(
      filePatch(
        `big/huge${index}.ts`,
        20_000,
        (k, changed) => `const huge_${index}_${k} = compute(${k}); // ${changed ? "changed" : "line"} ${k}`,
        (k) => k % 14 === 5,
      ),
    );
  }
  for (let index = 0; index < SMALL_FILES; index += 1) {
    patches.push(
      filePatch(
        `src/mod${String(Math.floor(index / 100)).padStart(2, "0")}/file${String(index).padStart(4, "0")}.ts`,
        40,
        (k, changed) => `export const v_${index}_${k} = ${changed ? k * 2 : k};`,
        (k) => k % 13 === 3,
      ),
    );
  }
  return patches.join("");
}

/** An added file of `count` lines, as one hunk. */
function addedFilePatch(name: string, count: number, line: (index: number) => string): string {
  const body = Array.from({ length: count }, (_, k) => `+${line(k)}`).join("\n");
  return `diff --git a/${name} b/${name}\nnew file mode 100644\nindex 0000000..2222222\n--- /dev/null\n+++ b/${name}\n@@ -0,0 +1,${count} @@\n${body}\n`;
}

function smallFiles(count: number): string[] {
  return Array.from({ length: count }, (_, index) =>
    filePatch(
      `src/mod${String(Math.floor(index / 100)).padStart(2, "0")}/file${String(index).padStart(4, "0")}.ts`,
      40,
      (k, changed) => `export const v_${index}_${k} = ${changed ? k * 2 : k};`,
      (k) => k % 13 === 3,
    ),
  );
}

/**
 * `?fixture=large`: five 20,000-line files rewritten (deferred, 1.6 MB of
 * patch each) ahead of 50 small files. `?fixture=huge`: one generated
 * 1,000,000-line bundle (about 60 MB of patch) ahead of 50 small files.
 * Default: the 2,000-file patch above.
 */
function fixturePatch(): string {
  const fixture = new URLSearchParams(location.search).get("fixture");
  if (fixture === "large") {
    const rewritten = Array.from({ length: 5 }, (_, index) =>
      filePatch(
        `big/rewritten${index}.ts`,
        20_000,
        (k, changed) => `const rewritten_${index}_${k} = compute(${k}, "${changed ? "after" : "before"}");`,
        () => true,
      ),
    );
    return [...rewritten, ...smallFiles(50)].join("");
  }
  if (fixture === "huge") {
    const bundle = addedFilePatch(
      "dist/generated/bundle.js",
      1_000_000,
      (k) => `var bundle_${k} = function () { return ${k} * 2; };`,
    );
    return [bundle, ...smallFiles(50)].join("");
  }
  return buildPatch();
}

const patchText = fixturePatch();
performance.mark("patch-ready");
const patchURL = URL.createObjectURL(new Blob([patchText], { type: "text/plain" }));
const config = document.createElement("script");
config.id = "cmux-diff-viewer-config";
config.type = "application/json";
config.textContent = JSON.stringify({
  payload: {
    title: "Virtualization harness",
    patchURL,
    layout: "unified",
    layoutSource: "explicit",
    labels: diffViewerLabelsFor("en"),
  },
});
document.head.append(config);
void mountDiffSurface(document.getElementById("root")!);
