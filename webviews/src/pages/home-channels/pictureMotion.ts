// Whether a Chief's animated picture moves (home.chiefPictureMotion, backgrounds plan phase 5).
// The app sets data-picture-motion on <html> with the theme (WebTheme.pictureMotion): always,
// hover or never, never under Reduce Motion. A GIF or animated WebP shows its first frame,
// drawn once to a still, unless the motion says otherwise.
import { useEffect, useState } from "react";

export type PictureMotion = "always" | "hover" | "never";

/** The motion the app set; hover until it says. */
export function pictureMotion(root: Element = document.documentElement): PictureMotion {
  const value = root.getAttribute("data-picture-motion");
  return value === "always" || value === "never" ? value : "hover";
}

/** The current motion, following each theme the app applies. */
export function usePictureMotion(): PictureMotion {
  const [motion, setMotion] = useState(pictureMotion);
  useEffect(() => {
    const follow = () => setMotion(pictureMotion());
    window.addEventListener("cmux-theme", follow);
    follow();
    return () => window.removeEventListener("cmux-theme", follow);
  }, []);
  return motion;
}

/** Whether `src` may be animated: a GIF or WebP data URL or file. */
export function mayAnimate(src: string): boolean {
  return /^data:image\/(gif|webp)[;,]/i.test(src) || /\.(gif|webp)(?:$|[?#])/i.test(src);
}

const stills = new Map<string, Promise<string | null>>();
/** The stills kept: a page shows a few dozen Chiefs at most; the oldest drawing goes first. */
const MAX_STILLS = 64;

/** The first frame of `src` as a PNG data URL (once per picture); null when it cannot be drawn. */
export function stillFrame(src: string): Promise<string | null> {
  let still = stills.get(src);
  if (!still) {
    if (stills.size >= MAX_STILLS) stills.delete(stills.keys().next().value!);
    still = new Promise((resolve) => {
      const image = document.createElement("img");
      image.onload = () => {
        const canvas = document.createElement("canvas");
        canvas.width = image.naturalWidth;
        canvas.height = image.naturalHeight;
        const context = canvas.getContext("2d");
        if (!context || !canvas.width) return resolve(null);
        context.drawImage(image, 0, 0);
        resolve(canvas.toDataURL("image/png"));
      };
      image.onerror = () => resolve(null);
      image.src = src;
    });
    stills.set(src, still);
  }
  return still;
}

/** What to draw for `src`: itself when it may move now, else its still (null until drawn). */
export function useShownPicture(src: string | undefined, hovered: boolean): string | null | undefined {
  const motion = usePictureMotion();
  const moves = !src || !mayAnimate(src) || motion === "always" || (motion === "hover" && hovered);
  const [still, setStill] = useState<{ src: string; still: string | null } | null>(null);
  useEffect(() => {
    if (!src || moves || still?.src === src) return;
    let live = true;
    void stillFrame(src).then((drawn) => live && setStill({ src, still: drawn }));
    return () => {
      live = false;
    };
  }, [src, moves, still?.src]);
  if (moves) return src;
  // Not drawn yet: show nothing rather than a moment of motion; undrawable: the picture itself.
  return still?.src === src ? (still.still ?? src) : null;
}
