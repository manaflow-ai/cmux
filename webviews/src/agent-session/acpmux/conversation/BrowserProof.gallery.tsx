// l10n-allow-file: gallery fixture data (a synthetic preview screenshot and report), not shipped UI.
// A browser preview proof returns a screenshot attachment beside the console-error report.
import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import { mergeToolItem } from "../direct";
import { ImageViewerContext } from "./imageViewerContext";
import type { ToolRow as ToolRowComponent } from "./ToolRow";

type Props = { clean: boolean };

const path = "/tmp/cmux-preview-proof.png";

function paint(): string {
  const [width, height] = [900, 520];
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  ink.fillStyle = "hsl(220 18% 96%)";
  ink.fillRect(0, 0, width, height);
  ink.fillStyle = "hsl(220 14% 88%)";
  ink.fillRect(0, 0, width, 42);
  ink.fillStyle = "hsl(220 60% 56%)";
  ink.fillRect(56, 108, width - 112, 52);
  ink.fillStyle = "hsl(220 14% 70%)";
  for (let line = 0; line < 5; line += 1) ink.fillRect(56, 210 + line * 42, 420 + line * 48, 14);
  ink.fillStyle = "hsl(150 45% 48%)";
  ink.fillRect(56, height - 72, 180, 26);
  return canvas.toDataURL("image/png");
}

function proofItem(clean: boolean) {
  const id = "gallery-browser-proof";
  const call = mergeToolItem(
    undefined,
    {
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: "previewProof(5173)",
      kind: "fetch",
      status: "in_progress",
      rawInput: { port: 5173, path: "/" },
    },
    id,
    "",
  );
  const report = JSON.stringify(
    {
      url: "http://127.0.0.1:5173/",
      screenshot: `[Image 900x520 png: ${path}]`,
      consoleErrors: clean ? [] : [{ type: "error", text: "Preview reported a hydration error" }],
      pageErrors: [],
    },
    null,
    2,
  );
  const data = paint();
  const image = {
    type: "content",
    content: { type: "image", mimeType: "image/png", data: data.slice(data.indexOf(",") + 1) },
  };
  const text = { type: "content", content: { type: "text", text: report } };
  return mergeToolItem(
    call,
    { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed", content: [text, image] },
    id,
    report,
  );
}

function galleryBrowserProof(ToolRow: typeof ToolRowComponent) {
  return function GalleryBrowserProof({ clean }: Props) {
    const item = useMemo(() => proofItem(clean), [clean]);
    return (
      <ImageViewerContext.Provider value={() => {}}>
        <div style={{ padding: 16 }}>
          <ToolRow item={item} />
        </div>
      </ImageViewerContext.Provider>
    );
  };
}

export default componentEntry<Props>({
  id: "agent-pane.browser-preview-proof",
  title: "Browser preview proof",
  area: "Agent pane",
  pane: true,
  height: 520,
  covers: [
    "cmux-tui/crates/cmux-browser-host/js/api.js#previewProof",
    "agent-session/acpmux/toolImages.ts#toolImages",
    "agent-session/acpmux/conversation/ToolRow.tsx#ToolImages",
  ],
  load: async () => galleryBrowserProof((await import("./ToolRow")).ToolRow),
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../chips/chips.css")]),
  widths: { narrow: 420, normal: 720 },
  variants: {
    "with-console-error": {
      note: "The preview screenshot is attached to the same result as a captured console.error, so the user can inspect the rendered UI and its browser evidence together.",
      props: { clean: false },
    },
    clean: {
      note: "A preview with no console or page errors still returns the screenshot attachment and empty evidence lists.",
      props: { clean: true },
    },
  },
});
