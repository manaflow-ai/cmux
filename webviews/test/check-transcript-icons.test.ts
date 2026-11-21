import { describe, expect, test } from "bun:test";
import { inlineSvgs, newInlineSvgs } from "../scripts/check-transcript-icons";

describe("transcript inline icon guard", () => {
  test("finds opening and self-closing SVG elements, not strings or comments", () => {
    const source = `// <svg />
const example = "<svg />";
const Icon = () => <svg><path d="M0 0" /></svg>;
const Empty = () => <svg />;`;
    expect(inlineSvgs("Example.tsx", source)).toEqual([
      { file: "Example.tsx", line: 3 },
      { file: "Example.tsx", line: 4 },
    ]);
  });

  test("a new transcript component cannot add its own SVG", () => {
    expect(newInlineSvgs("NewCard.tsx", "export const Mark = () => <svg />;")).toHaveLength(1);
    expect(newInlineSvgs("NewCard.tsx", 'export const Mark = () => <Icon name="action.copy" />;')).toEqual([]);
  });

  test("an existing exception cannot grow or be reused in a different directory", () => {
    expect(newInlineSvgs("NoticeMark.tsx", "const Mark = () => <svg />;")).toEqual([]);
    expect(newInlineSvgs("NoticeMark.tsx", "const Mark = () => <><svg /><svg /></>;")).toHaveLength(1);
    expect(newInlineSvgs("nested/NoticeMark.tsx", "const Mark = () => <svg />;")).toHaveLength(1);
  });

  test("the shared spinner and two brands are the only icons-file exceptions", () => {
    expect(newInlineSvgs("icons.tsx", "const Icons = () => <><svg /><svg /><svg /></>;")).toEqual([]);
    expect(newInlineSvgs("icons.tsx", "const Icons = () => <><svg /><svg /><svg /><svg /></>;")).toHaveLength(1);
  });
});
