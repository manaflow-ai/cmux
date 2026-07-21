import type { TerminalVtFrame } from "./protocol";
import {
  MAX_FORMATTED_TERMINAL_HTML_BYTES,
  MAX_LIVE_TERMINAL_SURFACES,
  MAX_TERMINAL_CELLS,
  MAX_TOTAL_TERMINAL_CELLS,
} from "./terminalLimits";

const GHOSTTY_SUCCESS = 0;
const GHOSTTY_OUT_OF_SPACE = -3;
const GHOSTTY_FORMATTER_FORMAT_HTML = 2;
export const GHOSTTY_WASM_SHA256 = "8d56baad2c353299d1ec1dec38b69bc3915c7fe816f58b2b5365bbb6dbb3cdab";

export function ghosttyWasmAssetURL(): string {
  return `/ghostty-vt.wasm?v=${GHOSTTY_WASM_SHA256}`;
}

const RENDER_DATA_CURSOR_VISUAL_STYLE = 10;
const RENDER_DATA_CURSOR_VISIBLE = 11;
const RENDER_DATA_CURSOR_BLINKING = 12;
const RENDER_DATA_CURSOR_VIEWPORT_HAS_VALUE = 14;
const RENDER_DATA_CURSOR_VIEWPORT_X = 15;
const RENDER_DATA_CURSOR_VIEWPORT_Y = 16;
const RENDER_DATA_CURSOR_VIEWPORT_WIDE_TAIL = 17;

export type GhosttyTerminalCursor = {
  readonly column: number;
  readonly row: number;
  readonly style: "bar" | "block" | "underline" | "block_hollow";
  readonly color: string;
  readonly blinking: boolean;
  readonly wide: boolean;
};

export type RenderedGhosttyTerminal = {
  readonly surfaceId: string;
  readonly generation: number;
  readonly stateSeq: number;
  readonly columns: number;
  readonly rows: number;
  readonly html: string;
  readonly background: string;
  readonly foreground: string;
  readonly cursor: GhosttyTerminalCursor | null;
};

export type TerminalApplyResult =
  | { readonly status: "rendered"; readonly terminal: RenderedGhosttyTerminal }
  | { readonly status: "resync"; readonly surfaceId: string }
  | { readonly status: "waiting" | "ignored" };

export interface GhosttySurfaceHandle {
  write(data: Uint8Array): void;
  render(metadata: Omit<RenderedGhosttyTerminal, "html" | "background" | "foreground" | "cursor">): RenderedGhosttyTerminal;
  dispose(): void;
}

export interface GhosttyTerminalRuntime {
  createSurface(columns: number, rows: number): GhosttySurfaceHandle;
}

type SurfaceState = {
  readonly handle: GhosttySurfaceHandle;
  readonly generation: number;
  readonly stateSeq: number;
  readonly columns: number;
  readonly rows: number;
};

export class GhosttyTerminalRenderer {
  private readonly surfaces = new Map<string, SurfaceState>();
  private readonly awaitingResync = new Set<string>();
  private queue: Promise<void> = Promise.resolve();
  private disposed = false;

  constructor(
    private readonly loadRuntime: () => Promise<GhosttyTerminalRuntime> = loadSharedGhosttyRuntime,
  ) {}

  apply(frame: TerminalVtFrame): Promise<TerminalApplyResult> {
    const result = this.queue.then(() => this.applyNow(frame));
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }

  retainSurfaces(surfaceIds: Iterable<string>): Promise<void> {
    const retained = new Set(surfaceIds);
    const result = this.queue.then(() => this.retainSurfacesNow(retained));
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }

  dispose(): void {
    this.disposed = true;
    for (const surface of this.surfaces.values()) surface.handle.dispose();
    this.surfaces.clear();
    this.awaitingResync.clear();
  }

  private async applyNow(frame: TerminalVtFrame): Promise<TerminalApplyResult> {
    if (this.disposed) return { status: "ignored" };
    const previous = this.surfaces.get(frame.surfaceId);

    if (frame.columns * frame.rows > MAX_TERMINAL_CELLS) return { status: "ignored" };

    if (frame.kind === "patch") {
      if (this.awaitingResync.has(frame.surfaceId)) return { status: "waiting" };
      if (
        !previous ||
        frame.generation !== previous.generation ||
        frame.stateSeq !== previous.stateSeq + 1 ||
        frame.columns !== previous.columns ||
        frame.rows !== previous.rows
      ) return this.requireResync(frame.surfaceId);
    } else if (
      previous && (
        frame.generation < previous.generation ||
        (frame.generation === previous.generation && frame.stateSeq <= previous.stateSeq)
      )
    ) {
      return { status: "ignored" };
    }

    let data: Uint8Array;
    try {
      data = decodeBase64(frame.dataB64);
    } catch {
      return this.requireResync(frame.surfaceId);
    }

    if (frame.kind === "snapshot") {
      const activeCells = [...this.surfaces.values()].reduce(
        (total, surface) => total + surface.columns * surface.rows,
        0,
      );
      const projectedCells = activeCells - (previous ? previous.columns * previous.rows : 0) + frame.columns * frame.rows;
      if ((!previous && this.surfaces.size >= MAX_LIVE_TERMINAL_SURFACES) ||
          projectedCells > MAX_TOTAL_TERMINAL_CELLS) return { status: "ignored" };
      let handle: GhosttySurfaceHandle | null = null;
      try {
        const runtime = await this.loadRuntime();
        if (this.disposed) return { status: "ignored" };
        handle = runtime.createSurface(frame.columns, frame.rows);
        handle.write(data);
        const terminal = handle.render(metadata(frame));
        previous?.handle.dispose();
        this.surfaces.set(frame.surfaceId, state(handle, frame));
        this.awaitingResync.delete(frame.surfaceId);
        return { status: "rendered", terminal };
      } catch {
        handle?.dispose();
        return this.requireResync(frame.surfaceId);
      }
    }

    try {
      previous!.handle.write(data);
      const terminal = previous!.handle.render(metadata(frame));
      this.surfaces.set(frame.surfaceId, state(previous!.handle, frame));
      return { status: "rendered", terminal };
    } catch {
      previous!.handle.dispose();
      this.surfaces.delete(frame.surfaceId);
      return this.requireResync(frame.surfaceId);
    }
  }

  private requireResync(surfaceId: string): TerminalApplyResult {
    if (this.awaitingResync.has(surfaceId)) return { status: "waiting" };
    this.awaitingResync.add(surfaceId);
    return { status: "resync", surfaceId };
  }

  private retainSurfacesNow(retained: ReadonlySet<string>): void {
    if (this.disposed) return;
    for (const [surfaceId, surface] of this.surfaces) {
      if (retained.has(surfaceId)) continue;
      surface.handle.dispose();
      this.surfaces.delete(surfaceId);
    }
    for (const surfaceId of this.awaitingResync) {
      if (!retained.has(surfaceId)) this.awaitingResync.delete(surfaceId);
    }
  }
}

function metadata(frame: TerminalVtFrame): Omit<RenderedGhosttyTerminal, "html" | "background" | "foreground" | "cursor"> {
  return {
    surfaceId: frame.surfaceId,
    generation: frame.generation,
    stateSeq: frame.stateSeq,
    columns: frame.columns,
    rows: frame.rows,
  };
}

function state(handle: GhosttySurfaceHandle, frame: TerminalVtFrame): SurfaceState {
  return {
    handle,
    generation: frame.generation,
    stateSeq: frame.stateSeq,
    columns: frame.columns,
    rows: frame.rows,
  };
}

let sharedRuntimePromise: Promise<GhosttyTerminalRuntime> | null = null;

export function loadSharedGhosttyRuntime(): Promise<GhosttyTerminalRuntime> {
  if (!sharedRuntimePromise) {
    sharedRuntimePromise = GhosttyWasmRuntime.load().catch((error) => {
      sharedRuntimePromise = null;
      throw error;
    });
  }
  return sharedRuntimePromise;
}

export function instantiateGhosttyRuntime(wasmBytes: BufferSource): Promise<GhosttyTerminalRuntime> {
  return GhosttyWasmRuntime.instantiate(wasmBytes);
}

type FieldLayout = {
  readonly offset: number;
  readonly size: number;
  readonly type: string;
};

type StructLayout = {
  readonly size: number;
  readonly align: number;
  readonly fields: Readonly<Record<string, FieldLayout>>;
};

type TypeLayout = Readonly<Record<string, StructLayout>>;

type GhosttyExports = {
  readonly memory: WebAssembly.Memory;
  readonly ghostty_type_json: () => number;
  readonly ghostty_wasm_alloc_opaque: () => number;
  readonly ghostty_wasm_free_opaque: (pointer: number) => void;
  readonly ghostty_wasm_alloc_u8_array: (length: number) => number;
  readonly ghostty_wasm_free_u8_array: (pointer: number, length: number) => void;
  readonly ghostty_wasm_alloc_usize: () => number;
  readonly ghostty_wasm_free_usize: (pointer: number) => void;
  readonly ghostty_terminal_new: (allocator: number, output: number, options: number) => number;
  readonly ghostty_terminal_free: (terminal: number) => void;
  readonly ghostty_terminal_vt_write: (terminal: number, data: number, length: number) => void;
  readonly ghostty_formatter_terminal_new: (allocator: number, output: number, terminal: number, options: number) => number;
  readonly ghostty_formatter_format_buf: (formatter: number, output: number, capacity: number, written: number) => number;
  readonly ghostty_formatter_free: (formatter: number) => void;
  readonly ghostty_render_state_new: (allocator: number, output: number) => number;
  readonly ghostty_render_state_update: (state: number, terminal: number) => number;
  readonly ghostty_render_state_get: (state: number, data: number, output: number) => number;
  readonly ghostty_render_state_colors_get: (state: number, output: number) => number;
  readonly ghostty_render_state_free: (state: number) => void;
};

class GhosttyWasmRuntime implements GhosttyTerminalRuntime {
  private liveSurfaceCount = 0;
  private liveCellCount = 0;

  private constructor(
    private readonly wasm: GhosttyExports,
    private readonly layout: TypeLayout,
  ) {}

  static async load(): Promise<GhosttyWasmRuntime> {
    const response = await fetch(ghosttyWasmAssetURL(), { cache: "force-cache" });
    if (!response.ok) throw new Error(`ghostty_vt_fetch_${response.status}`);
    return GhosttyWasmRuntime.instantiate(await response.arrayBuffer());
  }

  static async instantiate(wasmBytes: BufferSource): Promise<GhosttyWasmRuntime> {
    const source = await WebAssembly.instantiate(wasmBytes, {
      env: {
        log: () => {
          // Terminal contents can appear in parser logs, so shared workspaces discard them.
        },
      },
    });
    const wasm = normalizeExports(source.instance.exports);
    const layout = readTypeLayout(wasm);
    return new GhosttyWasmRuntime(wasm, layout);
  }

  createSurface(columns: number, rows: number): GhosttySurfaceHandle {
    const cells = columns * rows;
    if (!Number.isSafeInteger(columns) || !Number.isSafeInteger(rows) ||
        columns <= 0 || rows <= 0 || cells > MAX_TERMINAL_CELLS) {
      throw new Error("ghostty_terminal_dimensions_exceeded");
    }
    if (this.liveSurfaceCount >= MAX_LIVE_TERMINAL_SURFACES ||
        this.liveCellCount + cells > MAX_TOTAL_TERMINAL_CELLS) {
      throw new Error("ghostty_terminal_capacity_exceeded");
    }
    const surface = new GhosttyWasmSurface(this.wasm, this.layout, columns, rows, () => {
      this.liveSurfaceCount -= 1;
      this.liveCellCount -= cells;
    });
    this.liveSurfaceCount += 1;
    this.liveCellCount += cells;
    return surface;
  }
}

class GhosttyWasmSurface implements GhosttySurfaceHandle {
  private readonly terminal: number;
  private readonly formatter: number;
  private readonly renderState: number;
  private disposed = false;

  constructor(
    private readonly wasm: GhosttyExports,
    private readonly layout: TypeLayout,
    columns: number,
    rows: number,
    private readonly onDispose: () => void,
  ) {
    this.terminal = this.createTerminal(columns, rows);
    try {
      this.formatter = this.createFormatter(this.terminal);
    } catch (error) {
      wasm.ghostty_terminal_free(this.terminal);
      throw error;
    }
    try {
      this.renderState = this.createRenderState();
    } catch (error) {
      wasm.ghostty_formatter_free(this.formatter);
      wasm.ghostty_terminal_free(this.terminal);
      throw error;
    }
  }

  write(data: Uint8Array): void {
    this.assertLive();
    if (data.byteLength === 0) return;
    const pointer = this.wasm.ghostty_wasm_alloc_u8_array(data.byteLength);
    if (!pointer) throw new Error("ghostty_vt_alloc_failed");
    try {
      new Uint8Array(this.wasm.memory.buffer, pointer, data.byteLength).set(data);
      this.wasm.ghostty_terminal_vt_write(this.terminal, pointer, data.byteLength);
    } finally {
      this.wasm.ghostty_wasm_free_u8_array(pointer, data.byteLength);
    }
  }

  render(metadata: Omit<RenderedGhosttyTerminal, "html" | "background" | "foreground" | "cursor">): RenderedGhosttyTerminal {
    this.assertLive();
    checkResult(this.wasm.ghostty_render_state_update(this.renderState, this.terminal), "render_state_update");
    const colors = this.readColors();
    return {
      ...metadata,
      html: sanitizeGhosttyHtml(this.formatHtml(), colors.palette),
      background: colors.background,
      foreground: colors.foreground,
      cursor: this.readCursor(colors.cursor ?? colors.foreground),
    };
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    try {
      this.wasm.ghostty_render_state_free(this.renderState);
      this.wasm.ghostty_formatter_free(this.formatter);
      this.wasm.ghostty_terminal_free(this.terminal);
    } finally {
      this.onDispose();
    }
  }

  private createTerminal(columns: number, rows: number): number {
    const options = this.allocateStruct("GhosttyTerminalOptions");
    const output = this.wasm.ghostty_wasm_alloc_opaque();
    try {
      this.setField(options, "GhosttyTerminalOptions", "cols", columns);
      this.setField(options, "GhosttyTerminalOptions", "rows", rows);
      this.setField(options, "GhosttyTerminalOptions", "max_scrollback", 0);
      checkResult(this.wasm.ghostty_terminal_new(0, output, options), "terminal_new");
      return readU32(this.wasm, output);
    } finally {
      this.freeStruct(options, "GhosttyTerminalOptions");
      this.wasm.ghostty_wasm_free_opaque(output);
    }
  }

  private createFormatter(terminal: number): number {
    const options = this.allocateStruct("GhosttyFormatterTerminalOptions");
    const output = this.wasm.ghostty_wasm_alloc_opaque();
    try {
      this.setField(options, "GhosttyFormatterTerminalOptions", "size", this.struct("GhosttyFormatterTerminalOptions").size);
      this.setField(options, "GhosttyFormatterTerminalOptions", "emit", GHOSTTY_FORMATTER_FORMAT_HTML);
      this.setField(options, "GhosttyFormatterTerminalOptions", "unwrap", 0);
      this.setField(options, "GhosttyFormatterTerminalOptions", "trim", 0);

      const root = this.struct("GhosttyFormatterTerminalOptions");
      const extraPointer = options + requiredField(root, "extra").offset;
      this.setField(extraPointer, "GhosttyFormatterTerminalExtra", "size", this.struct("GhosttyFormatterTerminalExtra").size);
      const extra = this.struct("GhosttyFormatterTerminalExtra");
      const screenPointer = extraPointer + requiredField(extra, "screen").offset;
      this.setField(screenPointer, "GhosttyFormatterScreenExtra", "size", this.struct("GhosttyFormatterScreenExtra").size);

      checkResult(this.wasm.ghostty_formatter_terminal_new(0, output, terminal, options), "formatter_new");
      return readU32(this.wasm, output);
    } finally {
      this.freeStruct(options, "GhosttyFormatterTerminalOptions");
      this.wasm.ghostty_wasm_free_opaque(output);
    }
  }

  private createRenderState(): number {
    const output = this.wasm.ghostty_wasm_alloc_opaque();
    try {
      checkResult(this.wasm.ghostty_render_state_new(0, output), "render_state_new");
      return readU32(this.wasm, output);
    } finally {
      this.wasm.ghostty_wasm_free_opaque(output);
    }
  }

  private formatHtml(): string {
    return formatGhosttyHtmlBounded(this.wasm, this.formatter);
  }

  private readColors(): { background: string; foreground: string; cursor: string | null; palette: readonly string[] } {
    const struct = this.struct("GhosttyRenderStateColors");
    const pointer = this.allocateStruct("GhosttyRenderStateColors");
    try {
      this.setField(pointer, "GhosttyRenderStateColors", "size", struct.size);
      checkResult(this.wasm.ghostty_render_state_colors_get(this.renderState, pointer), "render_state_colors");
      const background = readRgb(this.wasm, this.layout, pointer + requiredField(struct, "background").offset);
      const foreground = readRgb(this.wasm, this.layout, pointer + requiredField(struct, "foreground").offset);
      const cursorHasValue = readBoolean(this.wasm, pointer + requiredField(struct, "cursor_has_value").offset);
      const cursor = cursorHasValue
        ? readRgb(this.wasm, this.layout, pointer + requiredField(struct, "cursor").offset)
        : null;
      const paletteField = requiredField(struct, "palette");
      const stride = paletteField.size / 256;
      if (!Number.isSafeInteger(stride) || stride < 3) throw new Error("ghostty_palette_layout_invalid");
      const palette = Array.from({ length: 256 }, (_, index) =>
        readRgb(this.wasm, this.layout, pointer + paletteField.offset + index * stride));
      return { background, foreground, cursor, palette };
    } finally {
      this.freeStruct(pointer, "GhosttyRenderStateColors");
    }
  }

  private readCursor(color: string): GhosttyTerminalCursor | null {
    const visible = this.readRenderBoolean(RENDER_DATA_CURSOR_VISIBLE);
    const inViewport = this.readRenderBoolean(RENDER_DATA_CURSOR_VIEWPORT_HAS_VALUE);
    if (!visible || !inViewport) return null;
    const column = this.readRenderU16(RENDER_DATA_CURSOR_VIEWPORT_X);
    const row = this.readRenderU16(RENDER_DATA_CURSOR_VIEWPORT_Y);
    const style = this.readRenderI32(RENDER_DATA_CURSOR_VISUAL_STYLE);
    return {
      column,
      row,
      style: ["bar", "block", "underline", "block_hollow"][style] as GhosttyTerminalCursor["style"] ?? "block",
      color,
      blinking: this.readRenderBoolean(RENDER_DATA_CURSOR_BLINKING),
      wide: this.readRenderBoolean(RENDER_DATA_CURSOR_VIEWPORT_WIDE_TAIL),
    };
  }

  private readRenderBoolean(data: number): boolean {
    return this.readRenderScalar(data, 1, (view) => view.getUint8(0) !== 0);
  }

  private readRenderU16(data: number): number {
    return this.readRenderScalar(data, 2, (view) => view.getUint16(0, true));
  }

  private readRenderI32(data: number): number {
    return this.readRenderScalar(data, 4, (view) => view.getInt32(0, true));
  }

  private readRenderScalar<T>(data: number, size: number, read: (view: DataView) => T): T {
    const pointer = this.wasm.ghostty_wasm_alloc_u8_array(size);
    if (!pointer) throw new Error("ghostty_render_value_alloc_failed");
    try {
      checkResult(this.wasm.ghostty_render_state_get(this.renderState, data, pointer), `render_state_get_${data}`);
      return read(new DataView(this.wasm.memory.buffer, pointer, size));
    } finally {
      this.wasm.ghostty_wasm_free_u8_array(pointer, size);
    }
  }

  private allocateStruct(name: string): number {
    const size = this.struct(name).size;
    const pointer = this.wasm.ghostty_wasm_alloc_u8_array(size);
    if (!pointer) throw new Error(`ghostty_${name}_alloc_failed`);
    new Uint8Array(this.wasm.memory.buffer, pointer, size).fill(0);
    return pointer;
  }

  private freeStruct(pointer: number, name: string): void {
    this.wasm.ghostty_wasm_free_u8_array(pointer, this.struct(name).size);
  }

  private setField(pointer: number, structName: string, fieldName: string, value: number): void {
    const field = requiredField(this.struct(structName), fieldName);
    const view = new DataView(this.wasm.memory.buffer, pointer + field.offset, field.size);
    switch (field.type) {
      case "u8":
      case "bool": view.setUint8(0, value); break;
      case "u16": view.setUint16(0, value, true); break;
      case "u32":
      case "enum":
      case "pointer": view.setUint32(0, value, true); break;
      case "u64": view.setBigUint64(0, BigInt(value), true); break;
      default: throw new Error(`ghostty_unsupported_field_${structName}_${fieldName}_${field.type}`);
    }
  }

  private struct(name: string): StructLayout {
    const value = this.layout[name];
    if (!value) throw new Error(`ghostty_missing_layout_${name}`);
    return value;
  }

  private assertLive(): void {
    if (this.disposed) throw new Error("ghostty_surface_disposed");
  }
}

export type GhosttyFormatterBufferExports = {
  readonly memory: WebAssembly.Memory;
  readonly ghostty_wasm_alloc_u8_array: (length: number) => number;
  readonly ghostty_wasm_free_u8_array: (pointer: number, length: number) => void;
  readonly ghostty_wasm_alloc_usize: () => number;
  readonly ghostty_wasm_free_usize: (pointer: number) => void;
  readonly ghostty_formatter_format_buf: (formatter: number, output: number, capacity: number, written: number) => number;
};

export function formatGhosttyHtmlBounded(
  wasm: GhosttyFormatterBufferExports,
  formatter: number,
  maximumBytes = MAX_FORMATTED_TERMINAL_HTML_BYTES,
): string {
  const outputLength = wasm.ghostty_wasm_alloc_usize();
  let pointer = 0;
  let capacity = 0;
  try {
    const queryResult = wasm.ghostty_formatter_format_buf(formatter, 0, 0, outputLength);
    if (queryResult !== GHOSTTY_OUT_OF_SPACE && queryResult !== GHOSTTY_SUCCESS) {
      throw new Error(`ghostty_formatter_size_${queryResult}`);
    }
    capacity = readU32(wasm, outputLength);
    if (capacity > maximumBytes) throw new Error("ghostty_formatted_html_too_large");
    if (capacity === 0) return "";

    pointer = wasm.ghostty_wasm_alloc_u8_array(capacity);
    if (!pointer) throw new Error("ghostty_formatter_buffer_alloc_failed");
    checkResult(wasm.ghostty_formatter_format_buf(formatter, pointer, capacity, outputLength), "formatter_format");
    const written = readU32(wasm, outputLength);
    if (written > capacity) throw new Error("ghostty_formatter_output_overflow");
    return new TextDecoder("utf-8", { fatal: true }).decode(
      new Uint8Array(wasm.memory.buffer, pointer, written),
    );
  } finally {
    if (pointer) wasm.ghostty_wasm_free_u8_array(pointer, capacity);
    wasm.ghostty_wasm_free_usize(outputLength);
  }
}

export function sanitizeGhosttyHtml(html: string, palette: readonly string[]): string {
  let output = "";
  let offset = 0;
  for (const match of html.matchAll(/<[^>]*>/gu)) {
    const index = match.index;
    output += escapeRawAngles(html.slice(offset, index));
    output += sanitizeTag(match[0], palette);
    offset = index + match[0].length;
  }
  return output + escapeRawAngles(html.slice(offset));
}

function sanitizeTag(tag: string, palette: readonly string[]): string {
  if (tag === "</div>") return tag;
  if (tag === "</a>") return "</span>";
  if (/^<a href="[^"]*">$/u.test(tag)) return "<span>";
  const div = /^<div style="([^"]*)">$/u.exec(tag);
  if (div) return `<div style="${sanitizeStyle(div[1] ?? "", palette)}">`;
  return escapeHtml(tag);
}

function sanitizeStyle(style: string, palette: readonly string[]): string {
  const safe: string[] = [];
  for (const rawDeclaration of style.split(";")) {
    const declaration = rawDeclaration.trim();
    if (!declaration) continue;
    const colon = declaration.indexOf(":");
    if (colon <= 0) continue;
    const property = declaration.slice(0, colon).trim();
    let value = declaration.slice(colon + 1).trim();
    if (property === "font-family" && value === "monospace") value = "inherit";
    value = value.replace(/var\(--vt-palette-(\d{1,3})\)/gu, (_match, rawIndex: string) => {
      const index = Number(rawIndex);
      return index >= 0 && index < 256 ? palette[index] ?? "#000000" : "#000000";
    });
    if (safeStyleDeclaration(property, value)) safe.push(`${property}: ${value};`);
  }
  return safe.join("");
}

function safeStyleDeclaration(property: string, value: string): boolean {
  switch (property) {
    case "font-family": return value === "inherit";
    case "white-space": return value === "pre";
    case "display": return value === "inline";
    case "font-weight": return value === "bold";
    case "font-style": return value === "italic";
    case "opacity": return value === "0.5";
    case "visibility": return value === "hidden";
    case "filter": return value === "invert(100%)";
    case "text-decoration-line": return /^(?:underline|line-through|overline|blink)(?: (?:underline|line-through|overline|blink))*$/u.test(value);
    case "text-decoration-style": return /^(?:solid|double|wavy|dotted|dashed)$/u.test(value);
    case "color":
    case "background-color":
    case "text-decoration-color": return safeColor(value);
    default: return false;
  }
}

function safeColor(value: string): boolean {
  if (/^#[0-9a-f]{6}$/iu.test(value)) return true;
  const rgb = /^rgb\((\d{1,3}), (\d{1,3}), (\d{1,3})\)$/u.exec(value);
  return !!rgb && rgb.slice(1).every((channel) => Number(channel) <= 255);
}

function escapeRawAngles(value: string): string {
  return value.replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function decodeBase64(value: string): Uint8Array {
  const decoded = atob(value);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function normalizeExports(exports: WebAssembly.Exports): GhosttyExports {
  const required = [
    "memory",
    "ghostty_type_json",
    "ghostty_wasm_alloc_opaque",
    "ghostty_wasm_free_opaque",
    "ghostty_wasm_alloc_u8_array",
    "ghostty_wasm_free_u8_array",
    "ghostty_wasm_alloc_usize",
    "ghostty_wasm_free_usize",
    "ghostty_terminal_new",
    "ghostty_terminal_free",
    "ghostty_terminal_vt_write",
    "ghostty_formatter_terminal_new",
    "ghostty_formatter_format_buf",
    "ghostty_formatter_free",
    "ghostty_render_state_new",
    "ghostty_render_state_update",
    "ghostty_render_state_get",
    "ghostty_render_state_colors_get",
    "ghostty_render_state_free",
  ] as const;
  for (const name of required) {
    if (!(name in exports)) throw new Error(`ghostty_missing_export_${name}`);
  }
  if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error("ghostty_invalid_memory_export");
  return exports as unknown as GhosttyExports;
}

function readTypeLayout(wasm: GhosttyExports): TypeLayout {
  const pointer = wasm.ghostty_type_json();
  const bytes = new Uint8Array(wasm.memory.buffer, pointer);
  const end = bytes.indexOf(0);
  if (end < 0 || end > 1_000_000) throw new Error("ghostty_type_json_invalid");
  const value: unknown = JSON.parse(new TextDecoder().decode(bytes.subarray(0, end)));
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("ghostty_type_json_invalid");
  return value as TypeLayout;
}

function requiredField(struct: StructLayout, name: string): FieldLayout {
  const field = struct.fields[name];
  if (!field) throw new Error(`ghostty_missing_field_${name}`);
  return field;
}

function readU32(wasm: { readonly memory: WebAssembly.Memory }, pointer: number): number {
  return new DataView(wasm.memory.buffer, pointer, 4).getUint32(0, true);
}

function readBoolean(wasm: GhosttyExports, pointer: number): boolean {
  return new DataView(wasm.memory.buffer, pointer, 1).getUint8(0) !== 0;
}

function readRgb(wasm: GhosttyExports, layout: TypeLayout, pointer: number): string {
  const rgb = layout.GhosttyColorRgb;
  if (!rgb) throw new Error("ghostty_missing_layout_GhosttyColorRgb");
  const view = new DataView(wasm.memory.buffer);
  const r = view.getUint8(pointer + requiredField(rgb, "r").offset);
  const g = view.getUint8(pointer + requiredField(rgb, "g").offset);
  const b = view.getUint8(pointer + requiredField(rgb, "b").offset);
  return `#${hex(r)}${hex(g)}${hex(b)}`;
}

function hex(value: number): string {
  return value.toString(16).padStart(2, "0");
}

function checkResult(result: number, operation: string): void {
  if (result !== GHOSTTY_SUCCESS) throw new Error(`ghostty_${operation}_${result}`);
}
