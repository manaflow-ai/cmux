// Session Info's Outputs lists the documents the chat's finished replies drew (outputsSectionModel.ts
// `outputArtifacts`), read again on every update that reaches the pane while a reply streams, and an
// open document's panel reads its versions on each update too (App.tsx `artifactVersionList`). Their
// cost per update must not grow with the chat's history: a finished reply's Markdown is parsed once,
// when its row first shows, never again for a later token. A cache keyed by reply text that emptied
// itself at 512 replies parsed every reply of a longer chat again on each update.
//
// A chat of N finished replies, each drawing a titled HTML document, then updates: the streaming reply
// grows, then it finishes. Parses per update stay the same at N = 10 as at N = 1,000.
import { afterAll, expect, mock, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import * as markdown from "../conversation/markdownModel";

// mock.module replaces a module for the rest of the bun process: the real one goes back after this file.
const realMarkdown = { ...markdown };
afterAll(async () => {
  await mock.module("../conversation/markdownModel", () => realMarkdown);
});
const parses = { count: 0 };
await mock.module("../conversation/markdownModel", () => ({
  ...realMarkdown,
  parseMarkdown: (...args: Parameters<typeof markdown.parseMarkdown>) => {
    parses.count += 1;
    return realMarkdown.parseMarkdown(...args);
  },
}));
const { outputArtifacts } = await import("./outputsSectionModel");
const { artifactVersions, finishedReplyDocuments } = await import("../conversation/artifactVersions");

const reply = (
  n: number,
  text = `Here is page ${n}.\n\n\`\`\`html\n<title>Page ${n}</title><p>${n}</p>\n\`\`\`\n`,
): AcpmuxRow => ({
  id: `reply-${n}`,
  version: 1,
  at: n,
  kind: "assistant",
  text,
});
const streaming = (n: number, text: string): AcpmuxRow => ({ ...reply(n, text), streaming: true });

function updates(replies: number) {
  // A chat of its own: another chat's rows share none of the module's caches.
  const history = Array.from({ length: replies }, (_, n) => reply(n));
  const before = outputArtifacts([...history, streaming(replies, "Working on")]);
  parses.count = 0;
  const grown = outputArtifacts([...history, streaming(replies, "Working on it")]);
  const whileStreaming = parses.count;
  parses.count = 0;
  const finished = outputArtifacts([...history, reply(replies, "Done.")]);
  const onFinish = parses.count;
  return { before, grown, finished, whileStreaming, onFinish };
}

/// The document panel's version scan (App.tsx `artifactVersionList`), once per update while one is open.
function versionUpdate(replies: number) {
  const history = Array.from({ length: replies }, (_, n) => reply(n));
  const opened = outputArtifacts(history)[0]!.artifact;
  artifactVersions(finishedReplyDocuments([...history, streaming(replies, "Working")]), opened);
  parses.count = 0;
  const versions = artifactVersions(finishedReplyDocuments([...history, streaming(replies, "Working on")]), opened);
  return { versions, parses: parses.count, opened };
}

test("one streamed update parses no finished reply again, however long the chat", () => {
  const ten = updates(10);
  const thousand = updates(1000);
  console.log(
    `OUTPUTS-COST ${JSON.stringify({
      n10: { streaming: ten.whileStreaming, finish: ten.onFinish },
      n1000: { streaming: thousand.whileStreaming, finish: thousand.onFinish },
    })}`,
  );
  expect(thousand.before).toHaveLength(1000);
  expect(thousand.grown).toEqual(thousand.before);
  expect(thousand.finished).toEqual(thousand.before);
  expect(ten.whileStreaming, "parses for one streamed token, N = 10").toBe(0);
  expect(thousand.whileStreaming, "parses for one streamed token, N = 1,000").toBe(0);
  // The reply that finished is read once; no earlier one is.
  expect(ten.onFinish, "parses when a reply finishes, N = 10").toBe(1);
  expect(thousand.onFinish, "parses when a reply finishes, N = 1,000").toBe(1);
});

test("an open document's version scan parses no finished reply again, however long the chat", () => {
  const thousand = versionUpdate(1000);
  console.log(`VERSIONS-COST ${JSON.stringify({ n1000: thousand.parses })}`);
  expect(thousand.versions).toHaveLength(1);
  expect(thousand.versions[0]!.code).toBe(thousand.opened.code);
  expect(thousand.parses, "parses for an open document's versions, N = 1,000").toBe(0);
});
