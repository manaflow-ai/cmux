// Every web dialog drawn by its page is the sheet surface role (Leo, 2026-11-07, on the agent chat's
// Share dialog: "this is bad bc it's too transparent and it's also hard corners and all the buttons
// are weird"). One material for all of them: the shared glass (.ui-glass) with the Chromium underlay
// of a surface that floats over the page (.ui-glass-floats), the sheet role's veil and corner radius
// (glass.css surface-roles block) from one rule (popupSurface.css `.ui-dialog.ui-glass`), and the
// shared controls (ui/controls.css) for every button and select. A dialog's own class sets its size
// and layout, never its own fill, border or radius.
import { expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const SRC = join(import.meta.dir, "../src");
const read = (path: string) => readFileSync(join(SRC, path), "utf8");

/** The decision and form dialogs (not media lightboxes or pickers): each one's popup class. */
const SHEETS: Record<string, string> = {
  "share-dialog-popup": "agent-session/acpmux/share/ShareControl.tsx",
  "acpmux-delete-dialog": "agent-session/acpmux/header/DeleteChatDialog.tsx",
  "acpmux-add-account": "agent-session/acpmux/AddAccountDialog.tsx",
  "acpmux-add-project-dialog": "agent-session/acpmux/AddProjectPanel.tsx",
  "acpmux-pdf-viewer": "agent-session/acpmux/composer/attachmentIntake.tsx",
  "activity-viewer-dialog": "agent-activity/viewer.tsx",
  "machines-dialog": "pages/machines/MachinesSection.tsx",
  "cloud-environment-sheet": "pages/cloud/EnvironmentSheet.tsx",
  "cloud-create-sheet": "pages/cloud/CreateSheet.tsx",
  "lg-form": "pages/home-channels/FormDialog.tsx",
};

function cssFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === "node_modules" || name === "generated" ? [] : cssFiles(path);
    return name.endsWith(".css") && !name.includes(".gallery.") ? [path] : [];
  });
}

/** Each rule's selectors and declarations (comments dropped; nested blocks are read flat). */
function rules(css: string): { selectors: string[]; body: string }[] {
  const clean = css.replace(/\/\*[\s\S]*?\*\//g, "");
  return [...clean.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((match) => ({
    selectors: match[1]!.split(",").map((selector) => selector.trim()),
    body: match[2]!,
  }));
}

/** The selector's subject (its last compound) names the class. */
const subjectIs = (selector: string, cls: string) =>
  new RegExp(`\\.${cls}(?![\\w-])[^\\s>+~]*$`).test(selector.replace(/:{1,2}[\w-]+(\([^)]*\))?/g, ""));

test("the sheet role is one rule: veil, radius, depth and the Reduce Transparency fill", () => {
  const sheet = rules(read("ui/popupSurface.css")).find((rule) => rule.selectors.includes(".ui-dialog.ui-glass"));
  expect(sheet).toBeDefined();
  expect(sheet!.body).toContain("--glass-tint: var(--surface-sheet-veil)");
  expect(sheet!.body).toContain("border-radius: var(--surface-sheet-radius)");
  expect(sheet!.body).toContain("--glass-elevation: var(--elevation-2)");
  expect(sheet!.body).toContain("--glass-opaque: var(--surface-popup)");
});

test("every decision and form dialog draws on the sheet glass that floats over the page", () => {
  for (const [cls, file] of Object.entries(SHEETS)) {
    const source = read(file);
    const named = [...source.matchAll(/className=(?:"([^"]*)"|\{`([^`]*)`\})/g)]
      .map((match) => match[1] ?? match[2] ?? "")
      .find((value) => value.split(/[\s$]/).includes(cls));
    expect({ cls, className: named ?? null }).toEqual({
      cls,
      className: expect.stringContaining("ui-glass ui-glass-floats"),
    });
  }
});

/** Each host that draws one of SHEETS, by the entry that loads its stylesheets. The agent pane ships
 * dev.tsx's sheets ahead of its own (scripts/cmux-next/build-agent-pane-web.sh). */
const HOST_ENTRIES = [
  "agent-session/acpmux/dev.tsx",
  "agent-activity/main.tsx",
  "pages/machines/main.tsx",
  "pages/cloud/main.tsx",
  "pages/home-channels/main.tsx",
];

test("every host of a sheet loads the sheet rule (ui/popupSurface.css, directly or through ui.css)", () => {
  const missing = HOST_ENTRIES.filter(
    (entry) => !/import\s+"[./]*\/?(?:ui\/)?(?:popupSurface|ui)\.css";/.test(read(entry)),
  );
  expect(missing).toEqual([]);
});

test("no dialog paints its own fill, border colour or corner radius over the role's", () => {
  const offenders: string[] = [];
  for (const path of cssFiles(SRC)) {
    for (const rule of rules(readFileSync(path, "utf8"))) {
      for (const cls of Object.keys(SHEETS)) {
        if (!rule.selectors.some((selector) => subjectIs(selector, cls))) continue;
        for (const line of rule.body.split(";").map((part) => part.trim())) {
          const own =
            /^border-radius\s*:/.test(line) ||
            (/^background(-color)?\s*:/.test(line) && !/var\(--glass-tint\)/.test(line)) ||
            (/^border\s*:/.test(line) && !/transparent|^border\s*:\s*0$/.test(line));
          if (own) offenders.push(`${relative(SRC, path)} .${cls}: ${line}`);
        }
      }
    }
  }
  expect(offenders).toEqual([]);
});

test("the Share dialog's buttons and selects are the shared controls, one height, one primary", () => {
  const dialog = read("agent-session/acpmux/share/ShareDialog.tsx");
  // The add row's role select is a shared button (controls.css draws `.ui-select-button.ui-btn`), so it
  // reads as a control with its chevron in the pane, which loads no ui.css; the big rows (General
  // access, each person) are whole-row pickers (ShareDialog.test.tsx).
  const selects = dialog.match(/<Select\b[\s\S]*?\/>/g) ?? [];
  expect(selects.length).toBe(1);
  for (const select of selects) expect(select).toContain('buttonClassName="ui-btn"');
  expect(read("ui/controls.css")).toMatch(/\.ui-button\.ui-btn\.ui-select-button\s*\{/);
  // One solid button (Done); no size other than the default row height.
  expect(dialog.match(/variant="solid"/g)?.length).toBe(1);
  expect(dialog).not.toMatch(/size="(sm|lg)"/);
});

test("the Delete chat dialog's buttons are the shared buttons", () => {
  const dialog = read("agent-session/acpmux/header/DeleteChatDialog.tsx");
  const buttons = dialog.match(/<DialogButton\b[\s\S]*?>/g) ?? [];
  expect(buttons.length).toBe(2);
  for (const button of buttons) {
    expect(button).toContain('className="ui-button ui-btn"');
    expect(button).toMatch(/data-variant="(subtle|solid)"/);
  }
  expect(read("agent-session/acpmux/header/header.css")).not.toContain(".acpmux-delete-dialog-confirm");
});
