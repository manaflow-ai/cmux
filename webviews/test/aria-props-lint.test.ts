import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// cmux-a11y/role-supports-aria-props (scripts/lint/aria-props.mjs) stands in for jsx-a11y's: aria-description,
// global in ARIA 1.3, passes on every role; an aria-* prop the element's role does not support still fails.
const directory = mkdtempSync(join(tmpdir(), "cmux-aria-rule-"));
afterAll(() => rmSync(directory, { recursive: true, force: true }));
const config = resolve(import.meta.dir, "../scripts/lint/aria-props.json");
const vp = resolve(import.meta.dir, "../node_modules/.bin/vp");

type Diagnostic = { filename: string; code: string; message: string };

function lint(files: string[]): Diagnostic[] {
  const result = Bun.spawnSync([vp, "lint", "--config", config, "--format", "json", ...files], {
    cwd: resolve(import.meta.dir, ".."),
    stdout: "pipe",
    stderr: "pipe",
  });
  const output = new TextDecoder().decode(result.stdout);
  return (JSON.parse(output) as { diagnostics: Diagnostic[] }).diagnostics;
}

// [name, JSX, findings]
const cases: Array<[string, string, number]> = [
  ["aria-description on an implicit button", `<button aria-description="Opens the file" />`, 0],
  ["aria-description on an implicit link", `<a href="/x" aria-description="Opens the page">x</a>`, 0],
  ["aria-description on an explicit row", `<div role="row" aria-description="Saved today" />`, 0],
  ["aria-description on output and li", `<ul><li aria-description="a" /><output aria-description="b" /></ul>`, 0],
  ["a supported prop on its role", `<button aria-pressed="true" aria-expanded="false" />`, 0],
  ["aria-checked on an implicit button", `<button aria-checked="true" />`, 1],
  ["aria-selected on an implicit link", `<a href="/x" aria-selected="true">x</a>`, 1],
  ["aria-sort on an explicit button role", `<div role="button" aria-sort="ascending" />`, 1],
  ["aria-checked under a computed role is not judged", `<button role={pick ? "checkbox" : "radio"} aria-checked />`, 0],
  ["no role: the global set", `<div aria-checked="true" />`, 0],
  ["a component's props are its own", `<Row aria-checked="true" />`, 0],
];

test.each(cases)("%s", (name, jsx, findings) => {
  const file = join(directory, `${name.replace(/[^a-z]+/gi, "-")}.tsx`);
  writeFileSync(
    file,
    `declare const pick: boolean;\ndeclare function Row(p: Record<string, unknown>): null;\nexport const x = ${jsx};\n`,
  );
  const found = lint([file]).filter((d) => d.code.includes("role-supports-aria-props"));
  expect(found.map((d) => d.message)).toHaveLength(findings);
});
