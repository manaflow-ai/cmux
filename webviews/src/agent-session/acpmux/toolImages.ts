// The images a tool call produced, for the strip under its row (ToolRow): the images it returned
// (ACP `image` blocks, kept as data URLs, and those of an MCP envelope its text then leaves out,
// toolResult.ts) and the image files it wrote or printed (a screenshot
// it saved, a chart it rendered): the file it edited, its locations, and absolute image paths in
// its output. Files load through the host like a reply's local image (ReplyImage), so only files
// inside the session's folders show; a PDF shows its first page (the host draws it), and a video
// plays inline (ReplyMedia). A running call can show envelope images before it finishes.
import type { AcpmuxActivity } from "./model";
import { editedPaths } from "./toolPaths";
import { envelopeImages, MAX_TOOL_IMAGES } from "./conversation/toolResult";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The most images a call's envelope gives its strip, and the most of its own besides.
export { MAX_TOOL_IMAGES };
const IMAGE_FILE = /\.(png|jpe?g|gif|webp|svg|heic|tiff?|bmp|pdf|mp4|m4v|mov|webm)$/i;
/// An absolute image path in output text, ended by space, a quote or a bracket.
const IMAGE_PATH = /(?<![\w./:~-])\/[^\s"'`()<>[\]]+\.(?:png|jpe?g|gif|webp|svg|pdf|mp4|m4v|mov|webm)(?![\w-])/gi;

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
    if (path.startsWith("/") && IMAGE_FILE.test(path)) add(path);
  };
  for (const path of editedPaths(tool)) file(path);
  for (const location of tool.locations ?? []) file(location.path);
  for (const match of tool.output?.matchAll(IMAGE_PATH) ?? []) file(match[0].replace(/[.,;:]+$/, ""));
  return [...envelope, ...found.filter((source) => !envelope.includes(source))];
}
