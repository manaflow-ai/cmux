// The diff's base picker lists the repo's other worktrees (cx-bopcl worktree polish): a worktree row
// draws the worktree glyph rather than a plain branch, names the worktree's folder rather than its
// whole path, and shows the whole path on hover.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { BranchPickerRowView } from "../src/BranchBasePicker";

const row = (worktreeDir?: string) =>
  renderToStaticMarkup(
    <BranchPickerRowView
      current={false}
      domId="row"
      entry={{
        row: { ref: "feat-x", label: "feat-x", ...(worktreeDir ? { worktreeDir } : {}) },
        groupId: worktreeDir ? "worktrees" : "branches",
        groupLabel: worktreeDir ? "Worktrees" : "Branches",
        firstInGroup: false,
        match: null,
        raw: false,
        moreCount: 0,
      }}
      label={(key) => key}
      onHover={() => {}}
      onSelect={() => {}}
      selected={false}
    />,
  );

test("a worktree row draws the worktree glyph, names its folder and and has no tooltip", () => {
  const html = row("/Users/you/src/worktrees/atlas-feat-x");
  expect(html).toContain('data-icon="worktree"');
  expect(html).not.toContain("title=");
  expect(html).toMatch(/base-picker-row-secondary">atlas-feat-x</);
});

test("a branch row keeps the branch glyph and no path", () => {
  const html = row();
  expect(html).toContain('data-icon="branch"');
  expect(html).not.toContain("title=");
});
