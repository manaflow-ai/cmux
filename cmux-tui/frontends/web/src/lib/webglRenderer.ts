import { WebglAddon } from "@xterm/addon-webgl";
import type { ITerminalAddon } from "@xterm/xterm";

interface AddonHost {
  loadAddon(addon: ITerminalAddon): void;
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
