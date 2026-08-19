import { WebglAddon } from "@xterm/addon-webgl";
import type { ITerminalAddon } from "@xterm/xterm";

interface AddonHost {
  loadAddon(addon: ITerminalAddon): void;
}

/**
 * Retag xterm's WebGL drawing buffer as Display P3.
 *
 * Desktop Ghostty writes terminal color bytes into a Display P3 surface with
 * no conversion, so the same bytes look more saturated there than in an sRGB
 * canvas. Retagging the buffer (same bytes, P3 interpretation) reproduces the
 * desktop rendering on wide-gamut displays. `getContext` on a canvas that
 * already has a context returns that existing context, which is how we reach
 * the addon's private WebGL2 context. Browsers without
 * `drawingBufferColorSpace` (Firefox) keep sRGB; per spec an unsupported
 * assignment leaves the value unchanged, so we report what the buffer
 * actually is.
 */
export function retagWebglDisplayP3(
  host: HTMLElement,
  getCanvas: (root: HTMLElement) => HTMLCanvasElement | null = (root) =>
    root.querySelector<HTMLCanvasElement>(".xterm-screen canvas"),
): "display-p3" | "srgb" | null {
  const canvas = getCanvas(host);
  if (canvas === null) return null;
  let gl: (WebGL2RenderingContext & { drawingBufferColorSpace?: string }) | null = null;
  try {
    gl = canvas.getContext("webgl2") as typeof gl;
  } catch {
    return null;
  }
  if (gl === null || !("drawingBufferColorSpace" in gl)) return null;
  try {
    gl.drawingBufferColorSpace = "display-p3";
  } catch {
    return "srgb";
  }
  return gl.drawingBufferColorSpace === "display-p3" ? "display-p3" : "srgb";
}

/** Prefer xterm's WebGL renderer, but keep its built-in renderer on failure. */
export function tryLoadWebglRenderer(
  terminal: AddonHost,
  create: () => ITerminalAddon = () => new WebglAddon(),
): ITerminalAddon | null {
  let addon: ITerminalAddon | null = null;
  try {
    addon = create();
    terminal.loadAddon(addon);
    return addon;
  } catch {
    // loadAddon registers before activate(), so dispose also removes an addon
    // whose WebGL context creation failed partway through activation.
    try {
      addon?.dispose();
    } catch {
      // Rendering still falls back to xterm's built-in renderer.
    }
    return null;
  }
}
