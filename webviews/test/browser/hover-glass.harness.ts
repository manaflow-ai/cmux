// Every hover tooltip and hover preview the web UI draws, as its root renders it (ui/Tooltip.tsx
// gives a Tooltip `ui-tooltip ui-glass` and an AnchoredCard `ui-tooltip ui-card ui-glass` before the
// caller's classes), under the stylesheets of the pages that draw them, loaded after the liquid glass
// as the pages load them, so a page's own class that paints a solid fill or drops the blur shows in
// the cascade (hover-glass.test.ts reads each one's computed fill and backdrop-filter).
import "../../src/pages/shared/desktop";
import "../../src/ui/popupSurface.css";
import { HOVER_SURFACES } from "./hoverSurfaces";

import.meta.glob(
  [
    "../../src/agent-session/**/*.css",
    "../../src/ui/**/*.css",
    "../../src/pages/markdown/**/*.css",
    "../../src/pages/home-messages/**/*.css",
    "../../src/pages/chief-usage/**/*.css",
    "!**/*.gallery.css",
    // Tailwind entries are built by their own pages (theme.generated.css), not served here.
    "!**/tailwind.css",
  ],
  { eager: true },
);

document.body.style.margin = "0";
for (const surface of HOVER_SURFACES) {
  const node = document.createElement("div");
  node.className = surface.className;
  node.dataset.surface = surface.name;
  if (surface.role) node.setAttribute("role", surface.role);
  node.textContent = "Rerun the parser suite at the new head";
  Object.assign(node.style, { position: "static", width: "240px", margin: "8px" });
  document.body.append(node);
}
document.documentElement.dataset.harnessReady = "1";
