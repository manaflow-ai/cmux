// The picture viewer's rules (a port of the native HomePictureViewer, HomePictureGallery,
// HomePictureMarkup and HomePictureReply in MessagesLabHome/Cmux): which key does what, the order
// Escape undoes things in, the zoom steps, the gallery's steps and comparison partner, and the
// marks (arrow, box, pen, text) in the picture's own pixels, drawn the same way on screen and into
// the PNG that Send in Chat, Copy and Save take. Pure: no DOM, so the tests read it directly.

export type PictureTool = "move" | "arrow" | "box" | "pen" | "text";

/** The tools in the bar's order. */
export const PICTURE_TOOLS: readonly PictureTool[] = ["move", "arrow", "box", "pen", "text"];

export interface Point {
  x: number;
  y: number;
}

/** One mark, in the picture's pixels (top-left origin). */
export type PictureMark =
  | { kind: "arrow"; from: Point; to: Point }
  | { kind: "box"; x: number; y: number; width: number; height: number }
  | { kind: "pen"; points: readonly Point[] }
  | { kind: "text"; at: Point; text: string };

export interface Size {
  width: number;
  height: number;
}

/** The marks' ink: the native viewer's red (sRGB 1, 0.23, 0.19). */
export const INK = "rgb(255, 59, 48)";

/** A line's width for a picture of `size` (HomePictureMarkup.lineWidth). */
export function lineWidth(size: Size): number {
  return Math.round(Math.max(3, Math.min(size.width, size.height) / 150));
}

/** A text mark's font size for a picture of `size` (HomePictureMarkup.fontSize). */
export function fontSize(size: Size): number {
  return Math.round(Math.max(16, Math.min(size.width, size.height) / 22));
}

/** The mark a drag made, or undefined for one too small to mean anything (a click with the arrow
 * or box tool: an arrow under 4 px, a box under 3 px either way). */
export function finishedMark(mark: PictureMark): PictureMark | undefined {
  if (mark.kind === "arrow" && Math.hypot(mark.to.x - mark.from.x, mark.to.y - mark.from.y) < 4) return undefined;
  if (mark.kind === "box" && (mark.width < 3 || mark.height < 3)) return undefined;
  return mark;
}

/** A box from its drag's start to `to`, with a positive size whichever way the drag went. */
export function boxBetween(from: Point, to: Point): PictureMark {
  return {
    kind: "box",
    x: Math.min(from.x, to.x),
    y: Math.min(from.y, to.y),
    width: Math.abs(to.x - from.x),
    height: Math.abs(to.y - from.y),
  };
}

/** An arrow's shaft end and its head's two back corners (HomePictureMarkup's arrow). */
export function arrowGeometry(
  from: Point,
  to: Point,
  width: number,
): { base: Point; left: Point; right: Point } | undefined {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const length = Math.hypot(dx, dy);
  if (length <= 0.5) return undefined;
  const head = Math.min(length * 0.45, width * 5);
  const angle = Math.atan2(dy, dx);
  const spread = Math.PI / 7;
  return {
    base: { x: to.x - Math.cos(angle) * head * 0.8, y: to.y - Math.sin(angle) * head * 0.8 },
    left: { x: to.x - Math.cos(angle - spread) * head, y: to.y - Math.sin(angle - spread) * head },
    right: { x: to.x - Math.cos(angle + spread) * head, y: to.y - Math.sin(angle + spread) * head },
  };
}

/** What a key does in the viewer (HomePictureViewer.keyDown). */
export type ViewerKey = "left" | "right" | "escape" | "compare" | "undo" | "zoomIn" | "zoomOut" | "fit" | "copy";

/** The viewer's command for a key press, or undefined when the viewer leaves it alone. Command
 * (or Control) with Z undoes, with + or = zooms in, with - zooms out, with 0 fits, with C copies;
 * C alone toggles Compare; the arrows step; Escape steps back. */
export function viewerKey(event: { key: string; metaKey?: boolean; ctrlKey?: boolean }): ViewerKey | undefined {
  const command = event.metaKey === true || event.ctrlKey === true;
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  if (key === "Escape") return "escape";
  if (key === "ArrowLeft") return "left";
  if (key === "ArrowRight") return "right";
  if (!command) return key === "c" ? "compare" : undefined;
  switch (key) {
    case "z":
      return "undo";
    case "=":
    case "+":
      return "zoomIn";
    case "-":
      return "zoomOut";
    case "0":
      return "fit";
    case "c":
      return "copy";
    default:
      return undefined;
  }
}

/** What Escape does now: leave the words being typed (not added), then the comparison, then close. */
export function escapeStep(state: { typing: boolean; comparing: boolean }): "text" | "compare" | "close" {
  if (state.typing) return "text";
  if (state.comparing) return "compare";
  return "close";
}

/** The gallery's index after a step: it stops at either end (the native viewer does not wrap). */
export function steppedIndex(index: number, by: number, count: number): number {
  if (count <= 0) return 0;
  return Math.min(count - 1, Math.max(0, index + by));
}

/** The picture `index` compares with: the next one in its row, else the one before; undefined
 * alone (HomePictureGallery.partner; a message's pictures are one row). */
export function comparePartner(index: number, count: number): number | undefined {
  if (count < 2 || index < 0 || index >= count) return undefined;
  return index + 1 < count ? index + 1 : index - 1;
}

export const MIN_ZOOM = 0.05;
export const MAX_ZOOM = 8;
const ZOOM_STEP = 1.25;

/** The zoom that fits a picture of `size` (its own size at 1) in `room`, never larger than 1. */
export function fitZoom(size: Size, room: Size): number {
  if (size.width <= 0 || size.height <= 0 || room.width <= 0 || room.height <= 0) return 1;
  return Math.min(1, room.width / size.width, room.height / size.height);
}

/** A double-click: its own size from fitted, fitted from anything else. */
export function toggledZoom(zoom: number, fitted: number): number {
  return Math.abs(zoom - fitted) < 0.01 ? 1 : fitted;
}

export function zoomedIn(zoom: number): number {
  return Math.min(MAX_ZOOM, zoom * ZOOM_STEP);
}

export function zoomedOut(zoom: number): number {
  return Math.max(MIN_ZOOM, zoom / ZOOM_STEP);
}

/** A pinch's zoom (a trackpad pinch is a wheel event with Control, its `deltaY` the change). */
export function pinchedZoom(zoom: number, deltaY: number): number {
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom * Math.exp(-deltaY / 100)));
}

/** The marks of each picture of the gallery, by index, and their undo (one mark at a time). */
export class PictureMarkups {
  private marks = new Map<number, readonly PictureMark[]>();

  of(index: number): readonly PictureMark[] {
    return this.marks.get(index) ?? [];
  }

  add(index: number, mark: PictureMark): void {
    this.marks.set(index, [...this.of(index), mark]);
  }

  /** Takes the newest mark of `index` away; false when it had none. */
  undo(index: number): boolean {
    const list = this.of(index);
    if (list.length === 0) return false;
    this.marks.set(index, list.slice(0, -1));
    return true;
  }
}

/** The file Send in Chat attaches (HomePictureReply.write): the title's words joined with "-",
 * at most 40 characters, "-marked-" and a millisecond stamp. */
export function markedFileName(title: string, stamp: number): string {
  const safe = title
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean)
    .join("-");
  return `${safe ? safe.slice(0, 40) : "picture"}-marked-${Math.round(stamp)}.png`;
}

/** The name Save offers: the picture's own name without its extension, "-marked.png". */
export function savedFileName(name: string): string {
  const dot = name.lastIndexOf(".");
  const base = dot > 0 ? name.slice(0, dot) : name;
  return `${base || "picture"}-marked.png`;
}

/** The 2D context calls the marks draw with (a canvas's, or a test's recorder). */
export interface MarkContext {
  strokeStyle: unknown;
  fillStyle: unknown;
  lineWidth: number;
  lineCap: CanvasLineCap;
  lineJoin: CanvasLineJoin;
  font: string;
  textBaseline: CanvasTextBaseline;
  save(): void;
  restore(): void;
  beginPath(): void;
  moveTo(x: number, y: number): void;
  lineTo(x: number, y: number): void;
  closePath(): void;
  stroke(): void;
  fill(): void;
  strokeRect(x: number, y: number, width: number, height: number): void;
  strokeText(text: string, x: number, y: number): void;
  fillText(text: string, x: number, y: number): void;
}

/** Draws `marks` over a picture of `size` (its pixels), as the screen shows them: the PNG's marks. */
export function drawMarks(ctx: MarkContext, marks: readonly PictureMark[], size: Size): void {
  const width = lineWidth(size);
  const font = fontSize(size);
  for (const mark of marks) {
    ctx.save();
    ctx.strokeStyle = INK;
    ctx.fillStyle = INK;
    ctx.lineWidth = width;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    switch (mark.kind) {
      case "box":
        ctx.strokeRect(mark.x, mark.y, mark.width, mark.height);
        break;
      case "pen": {
        const [first, ...rest] = mark.points;
        if (!first) break;
        ctx.beginPath();
        ctx.moveTo(first.x, first.y);
        for (const point of rest) ctx.lineTo(point.x, point.y);
        if (rest.length === 0) ctx.lineTo(first.x + 0.01, first.y);
        ctx.stroke();
        break;
      }
      case "arrow": {
        const shape = arrowGeometry(mark.from, mark.to, width);
        if (!shape) break;
        ctx.beginPath();
        ctx.moveTo(mark.from.x, mark.from.y);
        ctx.lineTo(shape.base.x, shape.base.y);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(mark.to.x, mark.to.y);
        ctx.lineTo(shape.left.x, shape.left.y);
        ctx.lineTo(shape.right.x, shape.right.y);
        ctx.closePath();
        ctx.fill();
        break;
      }
      case "text":
        if (!mark.text) break;
        ctx.font = `bold ${font}px -apple-system, system-ui, sans-serif`;
        ctx.textBaseline = "top";
        // A white halo under the red words, so they read on any picture.
        ctx.strokeStyle = "white";
        ctx.lineWidth = font / 3;
        ctx.strokeText(mark.text, mark.at.x, mark.at.y);
        ctx.fillText(mark.text, mark.at.x, mark.at.y);
        break;
    }
    ctx.restore();
  }
}
