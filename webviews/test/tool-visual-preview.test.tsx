// l10n-allow-file: synthetic capture fixtures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { tool } from "../src/gallery/fixtures/acpmux";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { McpCallRows } from "../src/agent-session/acpmux/conversation/McpCallRows";

const image = "data:image/png;base64,iVBORw0KGgo=";
const envelope = JSON.stringify([{ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }]);

export const captureCases = () => [
  renderToStaticMarkup(<ToolRow item={tool("Capture page", "fetch", "completed", { images: [image] })} />),
  renderToStaticMarkup(<ToolRow item={tool("Capture page", "fetch", "in_progress", { output: envelope })} />),
  renderToStaticMarkup(
    <McpCallRows
      items={[tool("mcp__browser__capture", "other", "completed", { output: envelope })]}
      disclosureKey="capture"
    />,
  ),
];

test("completed, running and MCP captures have a trailing thumbnail without removing the image strip", () => {
  const cases = captureCases();
  console.info(
    `PERF capture_thumbnail_cases=${cases.filter((html) => html.includes('class="cv-tool-visual"')).length}/3`,
  );
  for (const html of cases) {
    expect(html).toContain('class="cv-tool-visual"');
    expect(html).toContain('class="cv-tool-images"');
    expect(html.match(/<img /g)).toHaveLength(2);
    expect(html).not.toContain('class="cv-tool-visual-card__body"');
  }
});

test("plain tool rows retain their markup without a visual wrapper", () => {
  const html = renderToStaticMarkup(<ToolRow item={tool("Read README", "read", "completed", { output: "Read it" })} />);
  expect(html).not.toContain("cv-tool-with-visual");
});

test("inline audio is never treated as a screenshot", () => {
  const audio = JSON.stringify([{ type: "audio", mimeType: "audio/wav", data: "AAAA" }]);
  const html = renderToStaticMarkup(
    <McpCallRows items={[tool("mcp__audio__speak", "other", "completed", { output: audio })]} disclosureKey="audio" />,
  );
  expect(html).not.toContain("cv-tool-visual");
});
