import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { baseReader, type EntryRoots, entryInputs } from "../scripts/gallery/touched";

// The files an entry's picture is made of key the UI preview worker's shot cache: its gallery file's and covers'
// relative imports, its host's stage module and stylesheets, and the src files vite.config.ts aliases to.
const ROOT = "/r";
const SRC = `${ROOT}/webviews/src`;
const files: Record<string, string> = {
  "webviews/vite.config.ts": `const shift = fileURLToPath(new URL("./src/pages/editor/vimShiftCommand.ts", import.meta.url));`,
  "webviews/src/pages/editor/vimShiftCommand.ts": "export {};",
  "webviews/src/card/Card.gallery.ts": `import { Card } from "./Card";`,
  "webviews/src/card/Card.tsx": `import "./card.css";\nimport { edge } from "../shared/edge";`,
  "webviews/src/card/card.css": ".card {}",
  "webviews/src/shared/edge.ts": "export const edge = 1;",
  "webviews/src/shared/unrelated.ts": "export const u = 1;",
  "webviews/src/gallery/frame/component.tsx": `import "../../app.css";`,
  "webviews/src/app.css": "body {}",
};
const read = (file: string) => files[path.relative(ROOT, file)];
const card: EntryRoots = { id: "card", host: "component", file: `${SRC}/card/Card.gallery.ts`, covers: [] };

test("an entry's inputs are what it reaches, its host's frame and sheets, and vite's aliased src files", () => {
  expect(entryInputs(card, { src: SRC, repoRoot: ROOT, read, paneStylesheets: () => [] })).toEqual([
    "webviews/src/app.css",
    "webviews/src/card/Card.gallery.ts",
    "webviews/src/card/Card.tsx",
    "webviews/src/card/card.css",
    "webviews/src/gallery/frame/component.tsx",
    "webviews/src/pages/editor/vimShiftCommand.ts",
    "webviews/src/shared/edge.ts",
  ]);
});

test("a cover widens the inputs; a file nothing reaches stays out", () => {
  const covered = { ...card, covers: ["shared/unrelated.ts"] };
  const inputs = entryInputs(covered, { src: SRC, repoRoot: ROOT, read, paneStylesheets: () => [] });
  expect(inputs).toContain("webviews/src/shared/unrelated.ts");
  expect(entryInputs(card, { src: SRC, repoRoot: ROOT, read, paneStylesheets: () => [] })).not.toContain(
    "webviews/src/shared/unrelated.ts",
  );
});

test("the base reader reads what the base differs in from git and refuses a base whose gallery differs", () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "touched-base-"));
  const git = (...args: string[]) =>
    execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", ...args], { cwd: repo }).toString().trim();
  const write = (rel: string, text: string) => {
    fs.mkdirSync(path.dirname(path.join(repo, rel)), { recursive: true });
    fs.writeFileSync(path.join(repo, rel), text);
  };
  try {
    git("init", "-q");
    write("webviews/src/a.ts", `import "./b";`);
    write("webviews/src/b.ts", "1");
    git("add", "-A");
    git("commit", "-qm", "base");
    const base = git("rev-parse", "HEAD");
    write("webviews/src/a.ts", "export {};");
    write("webviews/src/new.ts", "2");
    git("add", "-A");
    git("commit", "-qm", "head");
    const atBase = baseReader(base, repo)!;
    expect(atBase(path.join(repo, "webviews/src/a.ts"))).toBe(`import "./b";`); // from git: the head changed it
    expect(atBase(path.join(repo, "webviews/src/new.ts"))).toBeUndefined(); // the head adds it
    expect(atBase(path.join(repo, "webviews/src/b.ts"))).toBe("1"); // the same at both: from disk
    write("webviews/src/gallery/frame.ts", "f");
    git("add", "-A");
    git("commit", "-qm", "gallery");
    expect(baseReader(base, repo)).toBeUndefined();
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});
