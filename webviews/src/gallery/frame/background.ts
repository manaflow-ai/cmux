// The background axis (env.ts BACKGROUNDS): the stage over a picture, as the app draws a window
// whose background the user set (appearance.background, "Set Background…"). In the app the picture
// and the window's one theme tint over it are native layers behind the clear web view
// (WindowBackdrop: the art, then the tint at ThemeTokens.wallpaperTintOpacity; panes paint nothing).
// Here the document root paints the same two layers, the page background stays clear
// (webThemePayload's `seeThrough`), and the same still goes to the page's glass lens through
// `cmuxTheme.backdrop`, as GlassBackdropFeed sends it. The pictures are synthetic and bundled: no
// photo, no capture.
import busy from "../fixtures/backgrounds/busy.svg?inline";
import dark from "../fixtures/backgrounds/dark.svg?inline";
import light from "../fixtures/backgrounds/light.svg?inline";
import type { GalleryBackground, GalleryEnv } from "../env";
import { css, wallpaperTintOpacity, withAlpha, type ThemeTokens } from "../theme/tokens";
import { entryPane, windowGeometry, windowSize, type ChromeMetrics, type Rect } from "../window";

export const BACKGROUND_PICTURES: Record<Exclude<GalleryBackground, "none">, string> = { light, dark, busy };
/** Every picture's own size (its SVG width and height). */
const PICTURE = { width: 1600, height: 1000 };

/** The window's tint over a picture: the theme's window color at its wallpaper tint opacity. */
export const pictureTint = (tokens: ThemeTokens): string =>
  css(withAlpha(tokens.windowBackground, wallpaperTintOpacity(tokens)));

/**
 * A picture not bundled here, supplied at capture time (scripts/gallery/capture-states.mjs: a spec
 * env names it, CMUX_GALLERY_PICTURE_<NAME> gives its file, and the capture puts it on the page as a
 * data URL before the stage loads). It replaces the bundled picture of the stage's background and is
 * drawn the same way: aspect-filled, then the window tint. Never in the repo: a person's own
 * wallpaper stays on the machine that captures.
 */
export type ExternalPicture = { name: string; image: string; width: number; height: number };
const externalPicture = (): ExternalPicture | undefined =>
  (window as unknown as { cmuxGalleryPicture?: ExternalPicture }).cmuxGalleryPicture;

/** The picture aspect-filled into a `width` x `height` box, centred, as the window's art view fills. */
export function aspectFill(
  width: number,
  height: number,
  picture: { width: number; height: number } = externalPicture() ?? PICTURE,
): Rect {
  const scale = Math.max(width / picture.width, height / picture.height);
  const w = picture.width * scale;
  const h = picture.height * scale;
  return { x: (width - w) / 2, y: (height - h) / 2, width: w, height: h };
}

/**
 * Where the picture lies relative to the stage's viewport. In window mode the stage is one pane of a
 * real-size window and the picture fills the whole window, so the pane shows the part behind it;
 * otherwise the picture fills the stage.
 */
export function pictureRect(
  env: GalleryEnv,
  windowed: boolean,
  metrics: ChromeMetrics,
  viewport: { width: number; height: number },
): Rect {
  if (!windowed) return aspectFill(viewport.width, viewport.height);
  const geometry = windowGeometry(windowSize(env.window), env.layout, env.density, metrics);
  const { content } = entryPane(geometry);
  const art = aspectFill(geometry.width, geometry.height);
  return { ...art, x: art.x - content.x, y: art.y - content.y };
}

type BackdropHost = { cmuxTheme?: { backdrop?: (partial: unknown) => void } };

/** Paints `env.background` behind the stage and hands its still to the glass lens. Once per stage:
 * the frame reloads for any change of the controls. A component stage follows its own resizes. */
export function applyGalleryBackground(
  env: GalleryEnv,
  tokens: ThemeTokens,
  options: { windowed: boolean; metrics: ChromeMetrics },
): void {
  const name = env.background;
  if (!name || name === "none") return;
  const external = externalPicture();
  const image = external?.image ?? BACKGROUND_PICTURES[name];
  const key = external ? `external-${external.name}` : name;
  const root = document.documentElement;
  const tint = pictureTint(tokens);
  const base = css(withAlpha(tokens.windowBackground, 1));
  root.dataset.galleryBackground = external ? external.name : name;
  const paint = () => {
    const rect = pictureRect(env, options.windowed, options.metrics, {
      width: root.clientWidth,
      height: root.clientHeight,
    });
    // Over WebTheme's `html{background:var(--cmux-surface-background) !important}`: the tint, the
    // picture, and the theme color under both (never seen, the picture fills the window).
    root.style.setProperty(
      "background",
      `linear-gradient(${tint}, ${tint}) fixed, url("${image}") ${rect.x}px ${rect.y}px / ${rect.width}px ${rect.height}px no-repeat fixed, ${base}`,
      "important",
    );
    (window as unknown as BackdropHost).cmuxTheme?.backdrop?.({
      image,
      key: `gallery-background-${key}`,
      rect,
      blur: 0,
      tint,
    });
  };
  paint();
  if (!options.windowed) window.addEventListener("resize", paint);
}
