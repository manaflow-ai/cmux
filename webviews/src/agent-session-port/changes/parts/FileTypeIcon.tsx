// File-type icon from @pierre/trees' built-in sprite, so diff headers and tree rows share
// one icon set.
import { getBuiltInSpriteSheet } from "@pierre/trees-port";

let spriteInjected = false;
// The tree injects its sprite inside its own shadow root; headers live in the light DOM
// and need a document-level copy. Injected once, on first use.
function ensureSprite() {
  if (spriteInjected || typeof document === "undefined") return;
  spriteInjected = true;
  const holder = document.createElement("div");
  holder.style.display = "none";
  holder.innerHTML = getBuiltInSpriteSheet("complete");
  document.body.prepend(holder);
}

const ICON_BY_EXT: Record<string, { id: string; color: string }> = {
  md: { id: "file-tree-builtin-markdown", color: "#7bca7a" },
  sh: { id: "file-tree-builtin-bash", color: "#7bca7a" },
};

export function FileTypeIcon({ path, size = 16 }: { path: string; size?: number }) {
  ensureSprite();
  const name = path.split("/").pop()!;
  const ext = name.includes(".") ? name.split(".").pop()! : "";
  const hit = name === "CLAUDE.md" ? { id: "file-tree-builtin-claude", color: "#f2a767" } : ICON_BY_EXT[ext];
  const id = hit?.id ?? "file-tree-builtin-default";
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" style={{ color: hit?.color ?? "#adadb1" }} aria-hidden>
      <use href={`#${id}`} />
    </svg>
  );
}
