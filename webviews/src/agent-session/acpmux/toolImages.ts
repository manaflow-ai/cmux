// The images a tool call produced, for the strip under its row (ToolRow): the images it returned
// (ACP `image` blocks, kept as data URLs, and those in a JSON result envelope) and the image files it wrote or printed (a screenshot
// it saved, a chart it rendered): the file it edited, its locations, and absolute image paths in
// its output. Files load through the host like a reply's local image (ReplyImage), so only files
// inside the session's folders show; a PDF shows its first page (the host draws it), and a video
// plays inline (ReplyMedia). A running call shows only its envelope's.
import type { AcpmuxActivity } from "./model";
import { editedPaths } from "./toolPaths";
import { cleanText } from "./conversation/mcpCalls";
import { envelopeImages, MAX_TOOL_IMAGES } from "./conversation/toolResult";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The most images a call's envelope gives the strip (toolResult.ts keeps the rest as JSON), and
/// the most of its own.
export { MAX_TOOL_IMAGES };
const IMAGE_FILE = /\.(png|jpe?g|gif|webp|svg|heic|tiff?|bmp|pdf|mp4|m4v|mov|webm)$/i;
/// An absolute image path in output text, ended by space, a quote or a bracket.
const IMAGE_PATH = /(?<![\w./:~-])\/[^\s"'`()<>[\]]+\.(?:png|jpe?g|gif|webp|svg|pdf|mp4|m4v|mov|webm)(?![\w-])/gi;

/// The call's images, each once: those its result envelope's text leaves out (at most
/// `MAX_TOOL_IMAGES`, see toolResult.ts), then its own returned images and image files, at most
/// `MAX_TOOL_IMAGES` of them, as before envelopes gave up theirs.
export function toolImages(tool: Tool): string[] {
  // Images inside a result a harness passed on as JSON text (an MCP result's `image` blocks), read
  // as ToolRow reads its text: without the context a host put around it. Its text no longer shows
  // them, so they all show here, a running call's too (they are in its output already). A shell
  // prints its output as it came, so an envelope it printed keeps its images there.
  const shell = tool.kind === "execute" && Boolean(tool.command);
  const envelope = shell ? [] : [...new Set(envelopeImages(tool.output, cleanText))];
  if (tool.status === "pending" || tool.status === "in_progress") return envelope;
  const own: string[] = [];
  const add = (source: string) => {
    if (own.length < MAX_TOOL_IMAGES && !own.includes(source)) own.push(source);
  };
  for (const image of tool.images ?? []) add(image);
  const file = (path: string) => {
    if (path.startsWith("/") && IMAGE_FILE.test(path)) add(path);
  };
  for (const path of editedPaths(tool)) file(path);
  for (const location of tool.locations ?? []) file(location.path);
  for (const match of tool.output?.matchAll(IMAGE_PATH) ?? []) file(match[0].replace(/[.,;:]+$/, ""));
  return [...envelope, ...own.filter((source) => !envelope.includes(source))];
}
