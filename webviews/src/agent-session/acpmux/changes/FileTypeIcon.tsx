// The file-type icon a diff header shows, from @pierre/trees's icon set (Apache-2.0), and the same
// set's language icons for a project badge with no favicon (ProjectBadge.tsx). Kept out of
// changeIcons, which the transcript imports, so the page's first script does not carry the tree
// package (bd cx-z9kz0); the pickers load it lazily (LazyFileIcons.tsx).
import React, { useLayoutEffect } from "react";
import { createFileTreeIconResolver, getBuiltInSpriteSheet } from "@pierre/trees";
import { iconHue } from "../../../file-icons";
import { LANGUAGE_ICONS } from "./languageIcons";

const SPRITE_ID = "acpmux-file-icon-sprite";
/// The tree draws its sprite inside its own shadow root; headers in the page need a copy.
/// It is checked in the DOM rather than a flag, so a replaced body gets it again.
function ensureSprite() {
  if (typeof document === "undefined" || !document.body || document.getElementById(SPRITE_ID)) return;
  const holder = document.createElement("div");
  holder.id = SPRITE_ID;
  // Out of sight but rendered: a gradient (Next.js's mark) in a display:none sprite draws nothing.
  holder.setAttribute("aria-hidden", "true");
  holder.style.cssText = "position:absolute;width:0;height:0;overflow:hidden;pointer-events:none";
  holder.innerHTML = getBuiltInSpriteSheet("complete");
  document.body.prepend(holder);
}

// The tree's own resolver, so a header shows the same icon as the file's tree row.
const icons = createFileTreeIconResolver({ set: "complete", colored: true });

/// The file-type icon @pierre/trees shows for `path`, so diff headers and tree rows match.
export function FileTypeIcon({ path }: { path: string }) {
  const resolved = icons.resolveIcon("file-tree-icon-file", path).name;
  return <BuiltInIcon id={resolved.startsWith("file-tree-builtin-") ? resolved : "file-tree-builtin-default"} />;
}

/// The icon of `language` (one of LANGUAGE_ICONS).
export function LanguageIcon({ language }: { language: string }) {
  return <BuiltInIcon id={`file-tree-builtin-${LANGUAGE_ICONS.has(language) ? language : "default"}`} />;
}

function BuiltInIcon({ id }: { id: string }) {
  useLayoutEffect(ensureSprite, []);
  return (
    <svg
      className="acpmux-file-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      aria-hidden
      data-icon={id.slice("file-tree-builtin-".length)}
      // The diff page's hue for the type (file-icons.tsx); a surface that colors icons maps it to a theme color.
      data-icon-hue={iconHue(id.slice("file-tree-builtin-".length))}
    >
      <use href={`#${id}`} />
    </svg>
  );
}
