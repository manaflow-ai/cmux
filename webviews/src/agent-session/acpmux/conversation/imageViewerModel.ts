export const MIN_SCALE = 1;
export const MAX_SCALE = 8;
export type View = { scale: number; x: number; y: number };
export const FIT: View = { scale: 1, x: 0, y: 0 };

/**
 * Base UI can restore focus to a Dialog.Trigger, but the viewer is opened by a markdown or
 * attachment button through ImageViewerContext and therefore has no Trigger of its own. Capture
 * the active opener before the portaled dialog moves focus so closing the viewer remains a local,
 * keyboard-friendly interaction.
 */
export function activeElementToRestore(): HTMLElement | null {
  if (typeof document === "undefined") return null;
  const active = document.activeElement;
  return active instanceof HTMLElement && active !== document.body ? active : null;
}

/// `view` zoomed to `scale` about `point` (relative to the stage's center), so the pixel under
/// the point stays there. Back at the fitted size the image is centered again.
export function zoomAbout(view: View, scale: number, point: { x: number; y: number }): View {
  const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
  if (next === MIN_SCALE) return FIT;
  const ratio = next / view.scale;
  return { scale: next, x: point.x - (point.x - view.x) * ratio, y: point.y - (point.y - view.y) * ratio };
}

/// The image as a `data:` URL, the form the host's image actions take (a composer attachment can be
/// a `blob:` URL).
export async function dataUrl(src: string): Promise<string> {
  if (src.startsWith("data:")) return src;
  const blob = await (await fetch(src)).blob();
  return await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}
