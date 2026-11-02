// l10n-allow-file: gallery fixtures (a sample file path and a painted image), not shipped UI.
// A Claude Code Read of a PNG, folded from the ACP updates acpmux sends (mergeToolItem, as the pane
// folds them): the call, then its completion. Its file is not on this machine (the chat runs on
// another one), so the host answers the path as missing. Before acpmux kept a tool result's images,
// the completion held only empty text, the row fell back to the path and said Image unavailable;
// now the completion carries the image and the row draws it.
import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import { mergeToolItem } from "../direct";
import { ImageViewerContext } from "./imageViewerContext";
import type { ToolRow as ToolRowComponent } from "./ToolRow";

type Props = { returnsImage: boolean };

const path = "/tmp/after-tray-expanded-1100-light.png";

/// A screenshot-like PNG: a title bar, a sidebar, a tray and lines of text.
function paint(): string {
  const [width, height] = [880, 520];
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  ink.fillStyle = "hsl(220 18% 96%)";
  ink.fillRect(0, 0, width, height);
  ink.fillStyle = "hsl(220 14% 88%)";
  ink.fillRect(0, 0, width, 34);
  ink.fillRect(0, 0, 190, height);
  ink.fillStyle = "hsl(220 60% 56%)";
  for (let line = 0; line < 8; line += 1) ink.fillRect(222, 70 + line * 34, 260 + ((line * 53) % 280), 12);
  ink.fillStyle = "hsl(220 14% 82%)";
  ink.fillRect(222, height - 120, width - 254, 88);
  ink.fillStyle = "hsl(150 45% 48%)";
  for (let chip = 0; chip < 4; chip += 1) ink.fillRect(240 + chip * 140, height - 92, 120, 32);
  return canvas.toDataURL("image/png");
}

/// The call as the pane folds it from its ACP updates: the Read, then its completion.
function readItem(returnsImage: boolean) {
  const call = mergeToolItem(
    undefined,
    {
      sessionUpdate: "tool_call",
      toolCallId: "gallery-read-image",
      title: `Read ${path}`,
      kind: "read",
      status: "in_progress",
      rawInput: { file_path: path },
      locations: [{ path }],
    },
    "gallery-read-image",
    "",
  );
  const text = { type: "content", content: { type: "text", text: "" } };
  const data = paint();
  const image = {
    type: "content",
    content: { type: "image", mimeType: "image/png", data: data.slice(data.indexOf(",") + 1) },
  };
  return mergeToolItem(
    call,
    {
      sessionUpdate: "tool_call_update",
      toolCallId: "gallery-read-image",
      status: "completed",
      content: returnsImage ? [text, image] : [text],
    },
    "gallery-read-image",
    "",
  );
}

/// The row as the pane draws it.
function galleryReadImage(ToolRow: typeof ToolRowComponent) {
  return function GalleryReadImage({ returnsImage }: Props) {
    const item = useMemo(() => readItem(returnsImage), [returnsImage]);
    return (
      <ImageViewerContext.Provider value={() => {}}>
        <div style={{ padding: 16 }}>
          <ToolRow item={item} />
        </div>
      </ImageViewerContext.Provider>
    );
  };
}

const remoteFile = { paths: { [path]: { place: "missing" as const, folder: false } } };

export default componentEntry<Props>({
  id: "agent-pane.read-image-result",
  title: "Read of an image",
  area: "Agent pane",
  pane: true,
  height: 420,
  covers: ["agent-session/acpmux/toolImages.ts#toolImages", "agent-session/acpmux/conversation/ToolRow.tsx#ToolImages"],
  load: async () => galleryReadImage((await import("./ToolRow")).ToolRow),
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../chips/chips.css")]),
  widths: { narrow: 420, normal: 720 },
  variants: {
    "returned-image": {
      note: "Claude Code read a PNG on another machine; acpmux's completion carries the image, and the row draws it.",
      chipHost: remoteFile,
      props: { returnsImage: true },
    },
    "path-only": {
      note: "A completion with no image (a daemon before this fix): the row falls back to the path, which is not on this machine: Image unavailable.",
      chipHost: remoteFile,
      props: { returnsImage: false },
    },
  },
});
