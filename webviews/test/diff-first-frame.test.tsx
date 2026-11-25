// The diff tab's first frame while its diff streams is its final layout: the skeleton rows alone, with no
// floating "Loading diff..." card over them, and the source pill's counts in place but not a made-up
// "+0 -0" (Leo's screenshot of 2026-11-04: "Unstaged +0 -0" over a "Loading diff..." card).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { SourceMenu } from "../src/DiffToolbar";
import { LoadingLayer } from "../src/diff-viewer/Loading";
import type { DiffViewerLabelResolver } from "../src/labels";
import { createDiffViewerStatus } from "../src/status";

const label: DiffViewerLabelResolver = (key) =>
  key === "loadingDiff" ? "Loading diff..." : key === "parsingDiff" ? "Parsing diff..." : key;

test("a streaming diff shows its skeleton with the loading message for screen readers only", () => {
  const html = renderToStaticMarkup(
    <LoadingLayer label={label} status={createDiffViewerStatus(label("loadingDiff"), { pending: true })} />,
  );
  expect(html).toContain('id="status" class="visually-hidden"');
  expect(html).toContain("diff-loading-placeholder");
});

test("a status of its own still shows its card", () => {
  const error = renderToStaticMarkup(
    <LoadingLayer label={label} status={createDiffViewerStatus("No repository", { error: true })} />,
  );
  expect(error).not.toContain("visually-hidden");
  const host = renderToStaticMarkup(
    <LoadingLayer label={label} status={createDiffViewerStatus("Fetching origin", { pending: true })} />,
  );
  expect(host).not.toContain("visually-hidden");
});

test("the source pill's counts are blank until the diff is known", () => {
  const model = { sections: [], selected: null };
  const loading = renderToStaticMarkup(
    <SourceMenu additions={null} deletions={null} label={label} model={model} onSelect={() => {}} />,
  );
  expect(loading).toContain('class="source-pill-stats invisible" aria-hidden="true"');
  const known = renderToStaticMarkup(
    <SourceMenu additions={12} deletions={3} label={label} model={model} onSelect={() => {}} />,
  );
  expect(known).toContain("+12");
  expect(known).not.toContain("invisible");
});

test("the parse before the first batch is quiet too", () => {
  const html = renderToStaticMarkup(
    <LoadingLayer label={label} status={createDiffViewerStatus(label("parsingDiff"), { loading: true })} />,
  );
  expect(html).toContain('id="status" class="visually-hidden"');
});
