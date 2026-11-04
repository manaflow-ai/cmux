// l10n-allow-file: checklist fixture labels, not shipped UI.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ProgressSection } from "./ProgressSection";

const plan = [
  { content: "Inspect the transcript", status: "completed" as const },
  { content: "Update Session Info", status: "in_progress" as const },
  { content: "Run checks", status: "pending" as const },
];

test("live Progress renders the current checklist and count", () => {
  const html = renderToStaticMarkup(<ProgressSection plan={plan} />);
  expect(html).toContain("Inspect the transcript");
  expect(html).toContain("Update Session Info");
  expect(html).toContain("Run checks");
  expect(html).toContain('data-status="in_progress"');
  expect(html).not.toContain('data-ended=""');
});

test("ended Progress stops the active spinner", () => {
  const html = renderToStaticMarkup(<ProgressSection plan={plan} ended />);
  expect(html).toContain('data-ended=""');
  expect(html).toContain('data-status="in_progress"');
});
