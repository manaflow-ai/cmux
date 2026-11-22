import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { mergeToolItem } from "../direct";
import type { AcpmuxActivity } from "../model";
import { toolImages } from "../toolImages";
import { ImageViewerContext } from "./imageViewerContext";
import { ToolRow } from "./ToolRow";

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const tool = (fields: Partial<Tool>): Tool => ({ id: "t", title: "Tool", status: "completed", ...fields });

describe("image outputs of a tool call", () => {
  /// ACP image content blocks (`{type: "image", data, mimeType}`), bare or in a `content` wrapper.
  test("a call keeps the images its content returns", () => {
    const item = mergeToolItem(
      undefined,
      {
        toolCallId: "t",
        kind: "other",
        status: "completed",
        content: [
          { type: "content", content: { type: "text", text: "Took a screenshot" } },
          { type: "content", content: { type: "image", mimeType: "image/png", data: PNG } },
          { type: "image", mimeType: "image/gif", data: PNG },
          { type: "image", mimeType: "text/html", data: PNG },
        ],
      },
      "t",
      "Took a screenshot",
    );
    expect(item.tool?.images).toEqual([`data:image/png;base64,${PNG}`, `data:image/gif;base64,${PNG}`]);
    expect(item.tool?.output).toBe("Took a screenshot");
    // A later update without content keeps them.
    expect(mergeToolItem(item, { toolCallId: "t", status: "completed" }, "t", "").tool?.images).toHaveLength(2);
  });

  test("an image past the size cap is left out", () => {
    const huge = "A".repeat(9 * 1024 * 1024);
    const item = mergeToolItem(
      undefined,
      { toolCallId: "t", content: [{ type: "image", mimeType: "image/png", data: huge }] },
      "t",
      "",
    );
    expect(item.tool?.images ?? []).toEqual([]);
  });

  /// Implicit outputs: the image file a tool wrote, or a screenshot path it printed.
  test("image files a call wrote or printed show, at most four, each once", () => {
    expect(
      toolImages(tool({ kind: "edit", inputSummary: JSON.stringify({ file_path: "/repo/out/chart.svg" }) })),
    ).toEqual(["/repo/out/chart.svg"]);
    expect(
      toolImages(tool({ kind: "execute", output: "Saved screenshot to /tmp/shots/login.png (1280x800)\n" })),
    ).toEqual(["/tmp/shots/login.png"]);
    expect(toolImages(tool({ locations: [{ path: "/repo/demo.gif" }, { path: "/repo/demo.ts" }] }))).toEqual([
      "/repo/demo.gif",
    ]);
    const many = Array.from({ length: 6 }, (_, index) => `/tmp/frame-${index}.png`).join("\n");
    expect(toolImages(tool({ output: `${many}\n/tmp/frame-0.png` }))).toEqual([
      "/tmp/frame-0.png",
      "/tmp/frame-1.png",
      "/tmp/frame-2.png",
      "/tmp/frame-3.png",
    ]);
    // A PDF shows as its first page (the host renders the thumbnail).
    expect(toolImages(tool({ kind: "execute", output: "Wrote report to /repo/out/report.pdf\n" }))).toEqual([
      "/repo/out/report.pdf",
    ]);
    // Not images, relative paths and a running call show nothing.
    expect(toolImages(tool({ output: "wrote /repo/notes.md and out/rel.png and https://x.dev/a.png" }))).toEqual([]);
    expect(toolImages(tool({ status: "in_progress", output: "/tmp/a.png" }))).toEqual([]);
  });

  test("returned images come before files, and both show under the row without opening it", () => {
    const opened: string[] = [];
    const item: AcpmuxActivity = {
      kind: "tool",
      text: "Screenshot",
      tool: tool({ title: "Screenshot", images: [`data:image/png;base64,${PNG}`], output: "saved /tmp/shot.png" }),
    };
    const html = renderToStaticMarkup(
      createElement(
        ImageViewerContext.Provider,
        { value: (src) => opened.push(src) },
        createElement(ToolRow, { item }),
      ),
    );
    expect(html).toContain('class="cv-tool-images"');
    expect(html).toContain(`<button type="button" class="cv-img-open"`);
    expect(html).toContain(`src="data:image/png;base64,${PNG}"`);
    // The file loads through the host (ReplyImage): before the host answers it shows its name.
    expect(html).toContain("shot.png");
    expect(html.indexOf("data:image/png")).toBeLessThan(html.indexOf("shot.png"));
    // The output itself stays folded.
    expect(html).not.toContain("cv-tool-output");
  });
});
