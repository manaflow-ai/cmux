import { expect, test } from "bun:test";
import { chmod, mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parsePatchFiles, processFile } from "@pierre/diffs";
import { decodeGitQuotedPath, streamPatch, type DiffItem, type FileTreeSource } from "../src/diff-stream";
import { createDiffViewerLabelResolver } from "../src/labels";

type GitFileSemantics = {
  added: number | null;
  deleted: number | null;
  oldPath?: string;
  path: string;
  status: string;
};

test("production stream parser matches Git for real repository diff semantics", async () => {
  const repo = await mkdtemp(join(tmpdir(), "cmux-diff-oracle-"));
  try {
    git(repo, ["init", "-q", "-b", "main"]);
    git(repo, ["config", "user.name", "cmux diff oracle"]);
    git(repo, ["config", "user.email", "cmux-diff@example.invalid"]);
    git(repo, ["config", "core.fileMode", "true"]);
    await writeFile(join(repo, "modified.txt"), numberedLines(12));
    await writeFile(join(repo, "delete.txt"), "gone\n");
    await writeFile(join(repo, "pure-old.txt"), "same\nlines\nhere\n");
    await writeFile(join(repo, "changed-old.txt"), numberedLines(20));
    await writeFile(join(repo, "mode.txt"), "mode\n");
    await writeFile(join(repo, "binary.bin"), Uint8Array.from([0, 1, 2, 3]));
    await writeFile(join(repo, 'space ü "quote".txt'), "unicode\n");
    await writeFile(join(repo, "no-newline.txt"), "old no newline");
    await writeFile(join(repo, "scope.txt"), "base\n");
    git(repo, ["add", "."]);
    git(repo, ["commit", "-qm", "base"]);

    const empty = await parseProductionStream(gitText(repo, diffArgs("--")));
    expect(empty.items).toEqual([]);
    expect(empty.treeSources).toEqual([]);

    git(repo, ["switch", "-qc", "feature"]);
    await writeFile(join(repo, "modified.txt"), numberedLines(12, new Map([[2, "two changed"], [10, "ten changed"]])));
    await rm(join(repo, "delete.txt"));
    await rename(join(repo, "pure-old.txt"), join(repo, "pure-new.txt"));
    await rename(join(repo, "changed-old.txt"), join(repo, "changed-new.txt"));
    await writeFile(join(repo, "changed-new.txt"), `${numberedLines(20)}21\n`);
    await chmod(join(repo, "mode.txt"), 0o755);
    await writeFile(join(repo, "binary.bin"), Uint8Array.from([0, 1, 9, 3, 4]));
    await writeFile(join(repo, 'space ü "quote".txt'), "unicode\nunicode changed\n");
    await writeFile(join(repo, "no-newline.txt"), "new no newline");
    await writeFile(join(repo, "added.txt"), "new\n");
    git(repo, ["add", "."]);

    const stagedPatch = gitText(repo, diffArgs("--cached", "--"));
    const staged = await parseProductionStream(stagedPatch, [1, 2, 5, 13, 29]);
    const stagedOracle = readGitOracle(repo, ["--cached", "--"]);
    expectParsedSemantics(staged.items, stagedOracle);
    const wholeParsed = parsePatchFiles(stagedPatch, "whole").flatMap((parsedPatch) => parsedPatch.files ?? []);
    expect(staged.items.map((item) => normalizedPierreFile(item.fileDiff))).toEqual(
      wholeParsed.map(normalizedPierreFile),
    );
    expect(staged.treeSources.at(-1)?.paths).toEqual(stagedOracle.map((entry) => entry.path));
    expect(staged.items.find((item) => item.fileDiff.name === "modified.txt")?.fileDiff.hunks).toHaveLength(2);
    expect(staged.items.find((item) => item.fileDiff.name === "binary.bin")?.fileDiff).toMatchObject({
      cmuxDiffMetadataKind: "binary",
      hunks: [],
      mode: "100644",
    });
    expect(staged.items.find((item) => item.fileDiff.name === "mode.txt")?.fileDiff).toMatchObject({
      cmuxDiffMetadataKind: "mode",
      mode: "100755",
      prevMode: "100644",
    });
    expect(staged.items.find((item) => item.fileDiff.name === "no-newline.txt")?.fileDiff.hunks[0]).toMatchObject({
      noEOFCRAdditions: true,
      noEOFCRDeletions: true,
    });
    expect(staged.items.find((item) => item.fileDiff.name === 'space ü "quote".txt')).toBeDefined();

    git(repo, ["commit", "-qm", "feature shapes"]);
    await writeFile(join(repo, "scope.txt"), "base\nstaged\n");
    git(repo, ["add", "scope.txt"]);
    await writeFile(join(repo, "scope.txt"), "base\nstaged\nworking\n");

    const stagedOnly = await parseProductionStream(gitText(repo, diffArgs("--cached", "--")));
    const unstagedOnly = await parseProductionStream(gitText(repo, diffArgs("--")));
    expectParsedSemantics(stagedOnly.items, readGitOracle(repo, ["--cached", "--"]));
    expectParsedSemantics(unstagedOnly.items, readGitOracle(repo, ["--"]));
    expect(stagedOnly.items.map((item) => item.fileDiff.additionLines.at(-1))).toEqual(["staged\n"]);
    expect(unstagedOnly.items.map((item) => item.fileDiff.additionLines.at(-1))).toEqual(["working\n"]);

    const mergeBase = gitText(repo, ["merge-base", "HEAD", "main"]).trim();
    const branch = await parseProductionStream(gitText(repo, diffArgs(mergeBase, "--")));
    expectParsedSemantics(branch.items, readGitOracle(repo, [mergeBase, "--"]));
    expect(branch.items.some((item) => item.fileDiff.name === "added.txt")).toBe(true);
    expect(branch.items.some((item) => item.fileDiff.name === "scope.txt")).toBe(true);
  } finally {
    await rm(repo, { force: true, recursive: true });
  }
}, 30_000);

test("production stream parser handles mbox repeats, malformed input, and truncated final files", async () => {
  const repo = await mkdtemp(join(tmpdir(), "cmux-diff-mbox-"));
  try {
    git(repo, ["init", "-q", "-b", "main"]);
    git(repo, ["config", "user.name", "cmux diff oracle"]);
    git(repo, ["config", "user.email", "cmux-diff@example.invalid"]);
    await writeFile(join(repo, "repeat.txt"), "base\n");
    git(repo, ["add", "."]);
    git(repo, ["commit", "-qm", "base"]);
    await writeFile(join(repo, "repeat.txt"), "base\none\n");
    git(repo, ["commit", "-qam", "one"]);
    await writeFile(join(repo, "repeat.txt"), "base\none\ntwo\n");
    git(repo, ["commit", "-qam", "two"]);

    const mbox = gitText(repo, ["format-patch", "--stdout", "HEAD~2..HEAD"]);
    const parsedMbox = await parseProductionStream(mbox, [3, 17, 41]);
    expect(parsedMbox.items).toHaveLength(2);
    expect(parsedMbox.items.map((item) => item.fileDiff.name)).toEqual(["repeat.txt", "repeat.txt"]);
    expect(new Set(parsedMbox.items.map((item) => item.id)).size).toBe(2);
    expect(parsedMbox.renames).toHaveLength(0);
    expect(parsedMbox.treeSources.at(-1)?.paths).toHaveLength(2);

    const malformed = await parseProductionStream("this is not a Git patch\n");
    expect(malformed.items).toEqual([]);
    const truncatedPatch = [
      "diff --git a/truncated.txt b/truncated.txt",
      "index 1111111..2222222 100644",
      "--- a/truncated.txt",
      "+++ b/truncated.txt",
      "@@ -1 +1 @@",
      "-before",
      "+after",
    ].join("\n");
    const truncated = await parseProductionStream(truncatedPatch, [1]);
    expect(truncated.items).toHaveLength(1);
    expect(truncated.items[0]?.fileDiff).toMatchObject({
      name: "truncated.txt",
      type: "change",
    });
  } finally {
    await rm(repo, { force: true, recursive: true });
  }
}, 30_000);

function diffArgs(...tail: string[]): string[] {
  // Keep this byte-for-byte aligned with CLI/cmux_open.swift gitDiffPatchArguments.
  return ["diff", "--no-ext-diff", "--no-color", "--binary", ...tail];
}

function git(repo: string, args: string[]): Uint8Array {
  const result = Bun.spawnSync(["git", "-C", repo, ...args], {
    env: { ...process.env, LC_ALL: "C" },
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${new TextDecoder().decode(result.stderr)}`);
  }
  return result.stdout;
}

function gitText(repo: string, args: string[]): string {
  return new TextDecoder().decode(git(repo, args));
}

function readGitOracle(repo: string, tail: string[]): GitFileSemantics[] {
  const nameStatus = splitNul(git(repo, ["diff", "--name-status", "-z", "--find-renames", ...tail]));
  const stats = parseNumstat(git(repo, ["diff", "--numstat", "-z", "--find-renames", ...tail]));
  const result: GitFileSemantics[] = [];
  for (let index = 0; index < nameStatus.length;) {
    const rawStatus = nameStatus[index++] ?? "";
    const status = rawStatus[0] ?? "";
    if (status === "R" || status === "C") {
      const oldPath = nameStatus[index++] ?? "";
      const path = nameStatus[index++] ?? "";
      result.push({ ...stats.get(path)!, oldPath, path, status });
    } else {
      const path = nameStatus[index++] ?? "";
      result.push({ ...stats.get(path)!, path, status });
    }
  }
  return result;
}

function parseNumstat(output: Uint8Array): Map<string, Pick<GitFileSemantics, "added" | "deleted">> {
  const fields = splitNul(output);
  const result = new Map<string, Pick<GitFileSemantics, "added" | "deleted">>();
  for (let index = 0; index < fields.length;) {
    const header = fields[index++] ?? "";
    const [rawAdded, rawDeleted, pathInHeader] = header.split("\t");
    let path = pathInHeader ?? "";
    if (path.length === 0) {
      index += 1;
      path = fields[index++] ?? "";
    }
    result.set(path, {
      added: rawAdded === "-" ? null : Number(rawAdded),
      deleted: rawDeleted === "-" ? null : Number(rawDeleted),
    });
  }
  return result;
}

function splitNul(output: Uint8Array): string[] {
  const fields = new TextDecoder().decode(output).split("\0");
  if (fields.at(-1) === "") {
    fields.pop();
  }
  return fields;
}

function expectParsedSemantics(items: DiffItem[], oracle: GitFileSemantics[]): void {
  const actual = items.map((item) => {
    const additions = item.fileDiff.hunks.reduce((sum: number, hunk: any) => sum + (hunk.additionLines ?? 0), 0);
    const deletions = item.fileDiff.hunks.reduce((sum: number, hunk: any) => sum + (hunk.deletionLines ?? 0), 0);
    return {
      added: additions,
      deleted: deletions,
      oldPath: item.fileDiff.prevName,
      path: item.fileDiff.name,
      status: pierreStatus(item.fileDiff.type),
    };
  });
  expect(actual).toEqual(oracle.map((entry) => ({
    added: entry.added ?? 0,
    deleted: entry.deleted ?? 0,
    oldPath: entry.oldPath,
    path: entry.path,
    status: entry.status,
  })));
}

function normalizedPierreFile(fileDiff: any): unknown {
  const normalizePath = (value: unknown) => typeof value === "string" ? decodeGitQuotedPath(value) : value;
  return {
    additionLines: fileDiff.additionLines,
    deletionLines: fileDiff.deletionLines,
    hunks: (fileDiff.hunks ?? []).map((hunk: any) => ({
      additionCount: hunk.additionCount,
      additionLines: hunk.additionLines,
      additionStart: hunk.additionStart,
      deletionCount: hunk.deletionCount,
      deletionLines: hunk.deletionLines,
      deletionStart: hunk.deletionStart,
      noEOFCRAdditions: hunk.noEOFCRAdditions,
      noEOFCRDeletions: hunk.noEOFCRDeletions,
      splitLineCount: hunk.splitLineCount,
      splitLineStart: hunk.splitLineStart,
      unifiedLineCount: hunk.unifiedLineCount,
      unifiedLineStart: hunk.unifiedLineStart,
    })),
    mode: fileDiff.mode,
    name: normalizePath(fileDiff.name),
    newName: normalizePath(fileDiff.newName),
    newObjectId: fileDiff.newObjectId,
    oldName: normalizePath(fileDiff.oldName),
    prevMode: fileDiff.prevMode,
    prevName: normalizePath(fileDiff.prevName),
    prevObjectId: fileDiff.prevObjectId,
    type: fileDiff.type,
  };
}

function pierreStatus(type: string): string {
  switch (type) {
  case "new":
    return "A";
  case "deleted":
    return "D";
  case "rename-pure":
  case "rename-changed":
    return "R";
  default:
    return "M";
  }
}

async function parseProductionStream(
  patch: string,
  chunkPattern: number[] = [64 * 1024],
): Promise<{ items: DiffItem[]; renames: unknown[]; treeSources: FileTreeSource[] }> {
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;
  const originalWindow = globalThis.window;
  const bytes = new TextEncoder().encode(patch);
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let offset = 0;
      let chunkIndex = 0;
      while (offset < bytes.length) {
        const chunkSize = chunkPattern[chunkIndex % chunkPattern.length] ?? bytes.length;
        controller.enqueue(bytes.slice(offset, Math.min(offset + chunkSize, bytes.length)));
        offset += chunkSize;
        chunkIndex += 1;
      }
      controller.close();
    },
  });
  const items: DiffItem[] = [];
  const renames: unknown[] = [];
  const treeSources: FileTreeSource[] = [];
  Object.assign(globalThis, {
    document: { visibilityState: "hidden", hasFocus: () => false },
    window: globalThis,
    fetch: async () => new Response(stream, { status: 200 }),
  });
  try {
    await streamPatch({
      getCollapsed: () => false,
      initialFileTreeRowCount: 2,
      label: createDiffViewerLabelResolver(undefined),
      onBatch: (batch) => items.push(...batch),
      onComplete: () => {},
      onMetrics: () => {},
      onRename: (rename) => renames.push(rename),
      onTreeSource: (source) => treeSources.push(source),
      parsePatchFiles,
      patchURL: "oracle.patch",
      processFile,
    });
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
    globalThis.window = originalWindow;
  }
  return { items, renames, treeSources };
}

function numberedLines(count: number, replacements = new Map<number, string>()): string {
  return Array.from({ length: count }, (_, index) => replacements.get(index + 1) ?? String(index + 1)).join("\n") + "\n";
}
