// The images a tool call produced, for the strip under its row (ToolRow): the images it returned
// (ACP `image` blocks, kept as data URLs, and those of an MCP envelope its text then leaves out,
// toolResult.ts) and the image files it wrote or printed (a screenshot
// it saved, a chart it rendered): the file it edited, its locations, and absolute image paths in
// its output. Files load through the host like a reply's local image (ReplyImage), so only files
// inside the session's folders show; a PDF shows its first page (the host draws it), and a video
// or audio file plays inline (ReplyMedia). A running call can show envelope images before it finishes.
import type { AcpmuxActivity } from "./model";
import { editedPaths } from "./toolPaths";
import { envelopeImages, MAX_TOOL_IMAGES } from "./conversation/toolResult";
import { MEDIA_EXTENSIONS } from "./chips/mediaKind";
import { isTemplatePath } from "./chips/paths";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The most images a call's envelope gives its strip, and the most of its own besides.
export { MAX_TOOL_IMAGES };
const mediaExtensions = MEDIA_EXTENSIONS.join("|");
const IMAGE_FILE = new RegExp(`\\.(png|jpe?g|gif|webp|svg|heic|tiff?|bmp|pdf|${mediaExtensions})$`, "i");
/// An absolute image or media path in output text, ended by space, a quote or a bracket.
const IMAGE_PATH = new RegExp(
  "(?<![\\w./:~-])/[^\\s\"'`()<>[\\]]+\\.(?:png|jpe?g|gif|webp|svg|heic|pdf|" + mediaExtensions + ")(?![\\w-])",
  "gi",
);

/// Whether the call's strip shows the images its result's envelope holds, which its text then
/// leaves out (toolResult.ts): running and finished calls, never a shell's, whose output shows as
/// it came.
export function stripsEnvelopeImages(tool: Tool): boolean {
  const shell = tool.kind === "execute" && Boolean(tool.command);
  return !shell;
}

/// The call's images, each once: its envelope's (at most `MAX_TOOL_IMAGES`), then the ones it
/// returned and the files it wrote, at most `MAX_TOOL_IMAGES` of those, as without an envelope.
export function toolImages(tool: Tool): string[] {
  const envelope = stripsEnvelopeImages(tool) ? envelopeImages(tool.output) : [];
  // A running call has no completed ACP image list or file paths yet, but its result envelope can
  // already contain a screenshot. Keep that early image visible without treating later files as
  // finished output.
  if (tool.status === "pending" || tool.status === "in_progress") return envelope;
  const found: string[] = [];
  const add = (source: string) => {
    if (found.length < MAX_TOOL_IMAGES && !found.includes(source)) found.push(source);
  };
  for (const image of tool.images ?? []) add(image);
  const file = (path: string) => {
    // A template in code or a command line (`/src/${variant}-320.png`) names no file.
    if (path.startsWith("/") && IMAGE_FILE.test(path) && !isTemplatePath(path)) add(path);
  };
  // A read that returned its image (Claude Code's Read of a PNG) already shows that file: its path
  // would draw it again, as "Image unavailable" when the chat runs on another machine.
  const readItsImage = tool.kind === "read" && Boolean(tool.images?.length);
  if (!readItsImage) {
    for (const path of editedPaths(tool)) file(path);
    for (const location of tool.locations ?? []) file(location.path);
  }
  for (const match of tool.output?.matchAll(IMAGE_PATH) ?? []) file(match[0].replace(/[.,;:]+$/, ""));
  return [...envelope, ...found.filter((source) => !envelope.includes(source))];
}
