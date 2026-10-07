// The images a tool call produced, for the strip under its row (ToolRow): the images it returned
// (ACP `image` blocks, kept as data URLs) and the image files it wrote or printed (a screenshot
// it saved, a chart it rendered): the file it edited, its locations, and absolute image paths in
// its output. Files load through the host like a reply's local image (ReplyImage), so only files
// inside the session's folders show; a PDF shows its first page (the host draws it). A running
// call shows none yet.
import type { AcpmuxActivity } from "./model";
import { editedPaths } from "./toolPaths";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The most images one call shows.
export const MAX_TOOL_IMAGES = 4;
const IMAGE_FILE = /\.(png|jpe?g|gif|webp|svg|heic|tiff?|bmp|pdf)$/i;
/// An absolute image path in output text, ended by space, a quote or a bracket.
const IMAGE_PATH = /(?<![\w./:~-])\/[^\s"'`()<>[\]]+\.(?:png|jpe?g|gif|webp|svg|pdf)(?![\w-])/gi;

/// The call's images, returned ones first, each once, at most `MAX_TOOL_IMAGES`.
export function toolImages(tool: Tool): string[] {
  if (tool.status === "pending" || tool.status === "in_progress") return [];
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
  return found;
}
