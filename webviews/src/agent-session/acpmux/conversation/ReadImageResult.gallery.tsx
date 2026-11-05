// l10n-allow-file: gallery fixtures (a sample file path and a painted image), not shipped UI.
// A Claude Code Read of a PNG, folded from the ACP updates acpmux sends (mergeToolItem, as the pane
// folds them): the call, then its completion. Its file is not on this machine (the chat runs on
// another one), so the host answers the path as missing. Before acpmux kept a tool result's images,
// the completion held only empty text, the row fell back to the path and said Image unavailable;
// now the completion carries the image and the row draws it. Codex's View of an image (`view_image`)
// completes with no content at all; acpmux now reads the file on the session's machine and adds it
// to the completion (hub/tool_read_images.rs), so its row draws the image the same way.
import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import { mergeToolItem } from "../direct";
import { ImageViewerContext } from "./imageViewerContext";
import type { ToolRow as ToolRowComponent } from "./ToolRow";

type Props = { returnsImage: boolean; harness?: "claude" | "codex"; text?: boolean };

const path = "/tmp/after-tray-expanded-1100-light.png";
const textPath = "/tmp/notes.md";

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

/// The call as the pane folds it from its ACP updates: the Read (Claude Code) or View (Codex),
/// then its completion. Codex's completion repeats its kind and location and, before acpmux read
/// the file, held no content.
function readItem({ returnsImage, harness = "claude", text = false }: Props) {
  const file = text ? textPath : path;
  const codex = harness === "codex";
  const name = file.slice(file.lastIndexOf("/") + 1);
  const start = codex
    ? { title: `View ${name}`, kind: "read", locations: [{ path: file }] }
    : { title: `Read ${file}`, kind: "read", rawInput: { file_path: file }, locations: [{ path: file }] };
  const call = mergeToolItem(
    undefined,
    { sessionUpdate: "tool_call", toolCallId: "gallery-read-image", status: "in_progress", ...start },
    "gallery-read-image",
    "",
  );
  const data = paint();
  const image = {
    type: "content",
    content: { type: "image", mimeType: "image/png", data: data.slice(data.indexOf(",") + 1) },
  };
  const said = { type: "content", content: { type: "text", text: text ? "# Notes\n\nThe tray opens upward." : "" } };
  const content = codex ? (returnsImage ? [image] : undefined) : returnsImage ? [said, image] : [said];
  return mergeToolItem(
    call,
    {
      sessionUpdate: "tool_call_update",
      toolCallId: "gallery-read-image",
      status: "completed",
      ...(codex ? { kind: "read", title: start.title, locations: start.locations } : {}),
      ...(content ? { content } : {}),
    },
    "gallery-read-image",
    "",
  );
}

/// The row as the pane draws it.
function galleryReadImage(ToolRow: typeof ToolRowComponent) {
  return function GalleryReadImage({ returnsImage, harness, text }: Props) {
    const item = useMemo(() => readItem({ returnsImage, harness, text }), [returnsImage, harness, text]);
    return (
      <ImageViewerContext.Provider value={() => {}}>
        <div style={{ padding: 16 }}>
          <ToolRow item={item} />
        </div>
      </ImageViewerContext.Provider>
    );
  };
}

const remoteFile = {
  paths: {
    [path]: { place: "missing" as const, folder: false },
    [textPath]: { place: "missing" as const, folder: false },
  },
};

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
    "codex-view-image": {
      note: "Codex viewed a PNG on another machine (view_image); acpmux read the file there and added it to the completion, so the row draws the image.",
      chipHost: remoteFile,
      props: { returnsImage: true, harness: "codex" },
    },
    "codex-view-missing": {
      note: "A Codex View whose file acpmux could not read (gone, too large, not an image): the completion has no image, the file is not on this machine, and the row is its label alone.",
      chipHost: remoteFile,
      props: { returnsImage: false, harness: "codex" },
    },
    "text-read": {
      note: "A Read of a text file: no image strip; the row opens to the file's text.",
      chipHost: remoteFile,
      props: { returnsImage: false, text: true },
    },
  },
});
