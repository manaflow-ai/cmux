// The Plain English gallery's prose variant (PlainEnglish.gallery.tsx), drawn as its gallery stage
// draws it: the entry's own props, styles and size. It draws each file as a `.plain-english-file`
// section in plain flow, with no windowed list around it. `window.__proseSections` is each section's
// box, in page order, once it is laid out (plain-english-prose.test.ts reads it).
import "../../src/pages/shared/desktop.css";
import { createRoot } from "react-dom/client";
import entry from "../../src/diff-viewer/PlainEnglish.gallery";

declare global {
  interface Window {
    __proseSections?: Array<{ top: number; bottom: number }>;
  }
}

await entry.styles?.();
const Stage = await entry.load();
const root = document.getElementById("root")!;
root.style.cssText = `position: relative; width: ${entry.widths?.normal ?? 760}px; height: ${entry.height ?? 520}px`;
createRoot(root).render(<Stage {...entry.variants.prose!.props} />);
await document.fonts.ready;
requestAnimationFrame(() =>
  requestAnimationFrame(() => {
    window.__proseSections = [...document.querySelectorAll<HTMLElement>(".plain-english-file")].map((section) => {
      const { top, bottom } = section.getBoundingClientRect();
      return { top, bottom };
    });
  }),
);
