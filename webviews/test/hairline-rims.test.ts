// Every rounded rim draws one device pixel (cx-o9yox, follow-up to #20481): macOS WebKit snaps a
// sub-pixel rim's inner edge to device pixels but not its rounded clip, so a raw `0.5px` rim on a
// rounded box loses edges and corner arcs on a 1x display and at fractional zoom. A rounded rim
// names its width with `var(--cmux-hairline)` (pages/shared/desktop.css). Rims not yet moved are
// listed in hairline-rims.pending.json with their count, which may only go down. On a pull
// request only its own files' findings fail (test/support/prScope.ts); the rest print as warnings.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import pendingFile from "./hairline-rims.pending.json";
import { counts, scan } from "./hairline-rims";
import { prScope } from "./support/prScope";

const { "//": _note, ...pending } = pendingFile as Record<string, string | number>;
const scope = prScope({
  rules: ["webviews/test/hairline-rims.ts", "webviews/test/hairline-rims.test.ts", "webviews/test/support/prScope.ts"],
  lists: ["webviews/test/hairline-rims.pending.json"],
});
const at = (file: string) => ({ files: [`webviews/src/${file}`], names: [file] });

function tree(files: Record<string, string>): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hairline-rims-"));
  for (const [name, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
    fs.writeFileSync(path.join(root, name), text);
  }
  return root;
}

describe("hairline rims", () => {
  const rims = scan();
  const actual = counts(rims);

  test("no rounded rim outside the pending list is a raw sub-pixel width", () => {
    const fresh = rims.filter((rim) => !(rim.file in pending));
    expect(
      scope.owned(
        fresh,
        (rim) => at(rim.file),
        (rim) => `${rim.file}:${rim.line} ${rim.selector} { ${rim.text} } -> use var(--cmux-hairline)`,
      ),
    ).toEqual([]);
  });

  test("a pending file never gains raw rims", () => {
    const grown = Object.entries(actual).filter(([file, count]) => file in pending && count > Number(pending[file]));
    expect(
      scope.owned(
        grown,
        ([file]) => at(file),
        ([file, count]) => `${file}: ${count} > ${pending[file]}`,
      ),
    ).toEqual([]);
  });

  test("the pending list shrinks (lower a count, delete a clean file)", () => {
    const stale = Object.entries(pending).filter(([file, count]) => (actual[file] ?? 0) < Number(count));
    expect(
      scope.owned(
        stale,
        ([file]) => at(file),
        ([file, count]) => `${file}: ${actual[file] ?? 0} < ${count}`,
      ),
    ).toEqual([]);
  });

  test("the scanner flags rounded sub-pixel rims and tokens, and passes hairline tokens and straight lines", () => {
    const root = tree({
      "a.css": [
        ".card { border-radius: 8px; box-shadow: inset 0 0 0 .5px red, 0 4px 8px black; }",
        ".pill { box-shadow: inset 0 0 0 0.5px red; }",
        ".pill:hover { border-radius: 6px; }",
        ".chip { border-radius: 4px; border: 0.5px solid red; }",
        ".tile { border-radius: 4px; outline: 0.5px solid red; }",
        ":root { --pop: 0 2px 6px black, inset 0 0 0 0.5px red; }",
        ".ok { border-radius: 8px; box-shadow: inset 0 0 0 var(--cmux-hairline, .5px) red; }",
        ".mixed { border-radius: 8px; box-shadow: inset 0 0 0 var(--cmux-hairline) red, 0 0 0 .5px blue; }",
        ".ok2 { border-radius: 8px; border: var(--cmux-hairline) solid red; }",
        ".line { border-top: .5px solid red; }",
        ".flat { box-shadow: inset 0 0 0 .5px red; }",
        ".blur { border-radius: 8px; box-shadow: 0 0.5px 2px black; }",
        "/* hairline-allow: a test */ .allowed { border-radius: 8px; border: .5px solid red; }",
      ].join("\n"),
      "b.tsx": [
        'const a = <span className="rounded border-[0.5px] border-edge" />;',
        'const b = <span className="border-t-[0.5px] border-edge" />;',
        'const c = <span className="rounded border-[length:var(--cmux-hairline)]" />;',
      ].join("\n"),
    });
    try {
      expect(scan(root).map((rim) => `${rim.file}:${rim.line} ${rim.selector}`)).toEqual([
        "a.css:1 .card",
        "a.css:2 .pill",
        "a.css:4 .chip",
        "a.css:5 .tile",
        "a.css:6 :root",
        "a.css:8 .mixed",
        "b.tsx:1 className",
      ]);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});
