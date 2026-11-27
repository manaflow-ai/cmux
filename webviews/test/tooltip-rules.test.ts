// Tooltips only where nothing else names the control (Leo, 2026-10-13, test/tooltip-rules.ts): an
// element whose text already shows (a row, a chip, a link, a path, a thought) carries no `title`,
// `data-tooltip` or ui/Tooltip. A cut-off pull request or link title opens a styled hover card
// instead (Leo, 2026-10-20). On a pull request only its own files' findings fail
// (test/support/prScope.ts); the rest print as warnings.
import { expect, test } from "bun:test";
import { scan } from "./tooltip-rules";
import { prScope } from "./support/prScope";

const scope = prScope({
  rules: ["webviews/test/tooltip-rules.ts", "webviews/test/tooltip-rules.test.ts", "webviews/test/support/prScope.ts"],
  lists: [],
});

test("no element whose text shows on screen also has a tooltip", () => {
  expect(
    scope.owned(
      scan(),
      (violation) => ({ files: [`webviews/src/${violation.file}`], names: [violation.file] }),
      (violation) => `${violation.file}:${violation.line} ${violation.text}`,
    ),
  ).toEqual([]);
});
