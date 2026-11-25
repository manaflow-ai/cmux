// l10n-allow-file: gallery fixture data (a synthetic preview screenshot and report), not shipped UI.
// A browser preview proof returns a screenshot attachment beside the console-error report.
import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import { LOGIN_SCREENSHOT_PNG } from "../../../gallery/fixtures/toolImages";
import { mergeToolItem } from "../direct";
import { ImageViewerContext } from "./imageViewerContext";
import type { ToolRow as ToolRowComponent } from "./ToolRow";

type Props = { clean: boolean };

const path = "/tmp/cmux-preview-proof.png";
const chipHost = { images: { [path]: `data:image/png;base64,${LOGIN_SCREENSHOT_PNG}` } };

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
      screenshot: `[Image 640x400 png: ${path}]`,
      consoleErrors: clean ? [] : [{ type: "error", text: "Preview reported a hydration error" }],
      pageErrors: [],
    },
    null,
    2,
  );
  const text = { type: "content", content: { type: "text", text: report } };
  return mergeToolItem(
    call,
    { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed", content: [text] },
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
  covers: ["agent-session/acpmux/conversation/ToolRow.tsx#ToolImages"],
  load: async () => galleryBrowserProof((await import("./ToolRow")).ToolRow),
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../chips/chips.css")]),
  widths: { narrow: 420, normal: 720 },
  variants: {
    "with-console-error": {
      note: "The preview screenshot is attached to the same result as a captured console.error, so the user can inspect the rendered UI and its browser evidence together.",
      props: { clean: false },
      chipHost,
    },
    clean: {
      note: "A preview with no console or page errors still returns the screenshot attachment and empty evidence lists.",
      props: { clean: true },
      chipHost,
    },
  },
});
