import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { sharedTextBoxSurfaceMode } from "../app/share/[shareId]/ShareWorkspaceClient";

const shareDirectory = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "app",
  "share",
  "[shareId]",
);

describe("shared TextBox terminal composition", () => {
  test("keeps the pure TextBox fallback until terminal VT arrives", () => {
    expect(sharedTextBoxSurfaceMode(false, true)).toBe("textbox");
    expect(sharedTextBoxSurfaceMode(true, true)).toBe("combined");
    expect(sharedTextBoxSurfaceMode(true, false)).toBe("terminal");
    expect(sharedTextBoxSurfaceMode(false, false)).toBe("waiting");
  });

  test("keeps libghostty primary with a compact flat bottom composer", async () => {
    const [source, css] = await Promise.all([
      readFile(join(shareDirectory, "ShareWorkspaceClient.tsx"), "utf8"),
      readFile(join(shareDirectory, "share-workspace.css"), "utf8"),
    ]);

    expect(source).toContain('<div className="share-terminal-textbox-surface">');
    expect(source).toMatch(/<GhosttyTerminal\s+terminal=\{terminal\}\s+embedded\s+/u);
    expect(source).toContain("compact");
    expect(source).not.toContain("useEffect(");
    expect(css).toMatch(/\.share-terminal-textbox-surface\s*\{[^}]*display: flex;[^}]*flex-direction: column;/u);
    expect(css).toMatch(/\.share-terminal-embedded\s*\{[^}]*flex: 1 1 auto;/u);
    expect(css).toMatch(/\.share-textbox-compact\s*\{[^}]*flex: 0 0 clamp\(44px, 22%, 88px\);/u);
    expect(css).toContain("border-top: 1px solid var(--cmux-separator)");
    expect(css).not.toMatch(/(?:linear|radial|conic)-gradient/u);
  });
});
