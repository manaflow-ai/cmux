import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ReviewBriefBody, ReviewBriefStrip, type ReviewBriefLabels } from "./ReviewBrief";
import type { ReviewBrief } from "./model";

const LABELS: ReviewBriefLabels = {
  title: "Brief",
  loading: "Reading the chat…",
  failed: "The chat's brief could not be read.",
  empty: "No plan, dropped approaches or unsure spots in this chat.",
  goal: "Set out to",
  plan: "Plan",
  rejected: "Tried and dropped",
  unsure: "Unsure about",
  show: "Show brief",
  hide: "Hide brief",
  hedge: "Hedged",
  reverted: "Undone",
  redone: "Undone, then redone",
  reworked: "Rewritten",
  notInDiff: "Not in this diff",
};

const BRIEF: ReviewBrief = {
  goal: "Make the uploader retry failed chunks.",
  planText: "",
  plan: [{ content: "Add retry", status: "completed" }],
  rejected: [{ text: "A retry around the whole upload didn't work.", seq: 4 }],
  unsure: [
    { kind: "redone", text: "", path: "src/upload.rs", snippet: "retry(|| send(chunk))?;", count: 0, seq: 9 },
    { kind: "hedge", text: "Not sure about the cap.", path: "src/gone.rs", snippet: "", count: 0, seq: 11 },
  ],
};

const noop = () => {};

test("the row keeps its place while loading and names the goal and unsure count once ready", () => {
  const loading = renderToStaticMarkup(
    <ReviewBriefStrip state={{ kind: "loading" }} labels={LABELS} open={false} onOpenChange={noop} />,
  );
  expect(loading).toContain("review-brief-row");
  expect(loading).toContain("Reading the chat…");
  expect(loading).toContain("disabled");
  expect(loading).not.toContain("review-brief-panel");

  const ready = renderToStaticMarkup(
    <ReviewBriefStrip state={{ kind: "ready", brief: BRIEF }} labels={LABELS} open={false} onOpenChange={noop} />,
  );
  expect(ready).toContain("Make the uploader retry failed chunks.");
  expect(ready).toContain('class="review-brief-count"');
  // The panel is mounted closed (a transition, not a pop-in) and out of the tab order.
  expect(ready).toContain('data-open="false"');
  expect(ready).toContain("inert");
});

test("unsure spots come before dropped approaches and the plan; a spot outside the diff has no link", () => {
  const html = renderToStaticMarkup(
    <ReviewBriefBody
      brief={BRIEF}
      labels={LABELS}
      onOpenSpot={noop}
      inDiff={(spot) => spot.path === "src/upload.rs"}
    />,
  );
  const order = ["Set out to", "Unsure about", "Tried and dropped", "Plan"].map((h) => html.indexOf(`<h3>${h}</h3>`));
  expect(order.every((at, i) => at >= 0 && (i === 0 || at > order[i - 1]!))).toBe(true);
  expect(html.match(/<button type="button" class="review-brief-spot"/g)).toHaveLength(1);
  expect(html).toContain("Not in this diff");
  expect(html).toContain("Undone, then redone");
});

test("an empty brief says so instead of drawing empty sections", () => {
  const html = renderToStaticMarkup(
    <ReviewBriefBody brief={{ goal: "", planText: "", plan: [], rejected: [], unsure: [] }} labels={LABELS} />,
  );
  expect(html).toContain(LABELS.empty);
  expect(html).not.toContain("<h3>");
});
