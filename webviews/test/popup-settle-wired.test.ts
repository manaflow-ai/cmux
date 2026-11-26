import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

// Every `.ui-popup` surface follows one rule about its box (src/ui/popupSettle.ts). A popup that
// opens and waits for the person settles; this test holds each file that draws one to the hook or
// to a named way out. Text-based on purpose: no DOM, no build.
const SRC = path.join(import.meta.dir, "..", "src");

/** Files that only name `.ui-popup` (a selector, a comment, a class list in data), not draw one. */
const ALLOWED: Record<string, string> = {
  "ui/popupSettle.ts": "the rule itself",
  "ui/popupHost.ts": "a comment about the close fade",
  "ui/openOverlay.ts": "selector of overlays",
  "ui/titleTooltips.ts": "closest() query",
  "ui/FloatingRoles.tsx": "gallery sheet: static copies of the popups' markup, measured, never opened",
  "ui/Listbox.tsx": "a doc comment; the shell it draws carries data-popup-settle",
  "agent-session/acpmux/paneSurface.ts": "selector",
  "agent-session/acpmux/menuPressGuard.ts": "selector",
  "agent-session/acpmux/ComposerBox.tsx": "interactive-target selector",
  "agent-session/acpmux/session-info/sessionInfoModel.ts": "selector",
  "agent-session/acpmux/session-info/useSessionInfo.tsx": "selector",
  "agent-session/acpmux/session-info/native/overlays.ts": "selector and comment",
  "agent-session/acpmux/newtab/widgetEditingModel.ts": "selector",
  "pages/home-channels/useHomeKeys.ts": "closest() query",
  "pages/shared/webSwap.ts": "selector",
  "pages/onboarding/text.ts": "selector",
};

function sources(dir: string): string[] {
  const found: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) found.push(...sources(full));
    else if (/\.(ts|tsx)$/.test(entry.name) && !/\.(test|gallery)\.(ts|tsx)$/.test(entry.name)) found.push(full);
  }
  return found;
}

// `ui-popup` as a whole class: not `ui-popup-scroll`, `ui-popup-scroll-shell`, `--ui-popup-radius`.
const POPUP_CLASS = /(?<![\w-])ui-popup(?![\w-])/;
const FOLLOWS =
  /usePopupSettle|settlePopup|data-popup-settle|dataset\.popupSettle|popupSettle=|popupSettle[,:]|shellClassName=/;

test("every file that draws a .ui-popup follows the shared popup rule", () => {
  const missing: string[] = [];
  for (const file of sources(SRC)) {
    const relative = path.relative(SRC, file).split(path.sep).join("/");
    if (relative in ALLOWED) continue;
    const text = readFileSync(file, "utf8");
    // A class token on an element: inside a string or template, not a selector like ".ui-popup".
    const draws = text.split("\n").some((line) => {
      if (!POPUP_CLASS.test(line)) return false;
      const withoutSelectors = line.replace(/\.ui-popup(?![\w-])/g, "");
      return POPUP_CLASS.test(withoutSelectors) && !/^\s*(\/\/|\*|\/\*)/.test(line);
    });
    if (draws && !FOLLOWS.test(text)) missing.push(relative);
  }
  expect(
    missing,
    `These files draw a \`ui-popup\` class but follow no popup rule:\n  ${missing.join("\n  ")}\n\n` +
      "A popup opens at its final size and keeps it while data arrives (webviews/src/ui/popupSettle.ts).\n" +
      "In each file choose one:\n" +
      "  (a) a menu or popover that opens and waits for the person: attach `usePopupSettle` to the sized box\n" +
      "      (`ref={usePopupSettle(also)}`, `also` merges an existing ref);\n" +
      '  (b) a box that is the live answer to what is typed elsewhere (a results list): data-popup-settle="results";\n' +
      '  (c) a popup that sizes itself by stricter code of its own: data-popup-settle="own".\n' +
      "A file that only queries `.ui-popup` (closest, querySelector) goes on ALLOWED in this test with a reason.",
  ).toEqual([]);
});

test("the allowlist names files that still exist", () => {
  const present = new Set(sources(SRC).map((file) => path.relative(SRC, file).split(path.sep).join("/")));
  expect(Object.keys(ALLOWED).filter((file) => !present.has(file))).toEqual([]);
});
