// l10n-allow-file: gallery fixtures (sample prompts, paths and editor names), not shipped UI.
// Open in Editor on the agent pane's surfaces (folderActions.ts): the chat's ··· menu, whose Folder ▸
// row holds Open in Editor, Open In ▸, Reveal in Finder, Open Terminal Here and Copy Path with Edit
// CLAUDE.md and Add Files to Project, the header's Open in Editor waiting at the top of "...", and the
// changed-files card's Open in Editor row and its files' right-click menu. Each runs on the real pane;
// the editors come from the mock host's `editors.list` (Zed, then Visual Studio Code and Cursor) unless
// the variant answers its own.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";

const NO_EDITORS = { "editors.list": { default: null, others: [] } };
const LONG_EDITOR = {
  "editors.list": {
    default: { id: "intellij", name: "IntelliJ IDEA Ultimate 2026.3 Early Access Preview" },
    others: [
      { id: "webstorm", name: "WebStorm" },
      { id: "rustrover", name: "RustRover" },
      { id: "vscode", name: "Visual Studio Code - Insiders" },
      { id: "sublime", name: "Sublime Text" },
      { id: "nova", name: "Nova" },
    ],
  },
};

const FILES = [
  {
    path: "src/net/client.ts",
    oldText: "export const fetchJSON = fetch;\n",
    newText: `import { withRetry } from "./retry";\nexport const fetchJSON = withRetry(fetch);\n`,
  },
  { path: "src/net/retry.ts", newText: "export const tries = 3;\nexport const delayMs = 250;\n" },
  { path: "test/net/retry.test.ts", oldText: "", newText: `test("tries", () => expect(3).toBe(3));\n` },
];

const snapshot = chat([
  user("Add retries with backoff to the fetch helper", 6),
  activity(
    FILES.map((file) => tool(`Edit ${file.path}`, "edit", "completed", { diffs: [file] })),
    5.9,
  ),
  assistant("Done: the client retries through withRetry, with tests.", 5.2),
  summary(5.2, { status: "completed", toolCount: FILES.length }),
]);

/// Waits until the open popups stop moving (Base UI places a submenu over a frame or two).
async function settled(ctx: PlayContext, selector: string): Promise<void> {
  const now = () => ctx.document.defaultView?.performance.now() ?? 0;
  let last = "";
  let since = 0;
  await ctx.waitFor(() => {
    const at = [...ctx.document.querySelectorAll(selector)]
      .map((node) => {
        const box = node.getBoundingClientRect();
        return `${box.left},${box.top},${box.width},${box.height}`;
      })
      .join(";");
    if (at !== last || !at) {
      last = at;
      since = now();
      return false;
    }
    return now() - since >= 50;
  });
}

/// The open chat menu shows Archive without a scroll: the Folder row took two rows' place.
function archiveInView(ctx: PlayContext): void {
  const popup = ctx.document.querySelector<HTMLElement>(".acpmux-chat-menu-popover");
  const archive = [...(popup?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])].find((row) =>
    row.textContent?.trim().startsWith("Archive"),
  );
  if (!popup || !archive) throw new Error("the chat menu has no Archive row");
  const shown = popup.getBoundingClientRect();
  const row = archive.getBoundingClientRect();
  if (popup.scrollTop !== 0 || row.bottom > shown.bottom + 0.5)
    throw new Error(`Archive is out of view: row to ${Math.round(row.bottom)}, menu to ${Math.round(shown.bottom)}`);
}

const openMenu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
  await settled(ctx, ".acpmux-chat-menu-popover");
};

const openFolder: Play = async (ctx) => {
  await openMenu(ctx);
  archiveInView(ctx);
  await ctx.click({ role: "menuitem", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-chat-menu-popover").length >= 2);
  await settled(ctx, ".acpmux-chat-menu-popover");
};

const openEditors: Play = async (ctx) => {
  await openFolder(ctx);
  await ctx.click({ role: "menuitem", name: "Open In" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-chat-menu-popover").length >= 3);
  await settled(ctx, ".acpmux-chat-menu-popover");
};

const fileMenu: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-edited-folder"));
  await ctx.contextMenu({ selector: ".acpmux-edited-entry .acpmux-edited-file" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
};

const card: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-edited-folder"));
};

const variants: Record<string, AgentPaneVariant> = {
  "chat-menu": {
    note: "The ··· menu: Open in Zed waits at its top (a quick action no button shows by default), and Folder ▸ takes Edit CLAUDE.md's and Add Files to Project's two rows, so Archive stays in view.",
    snapshot,
    play: async (ctx) => {
      await openMenu(ctx);
      archiveInView(ctx);
    },
  },
  "chat-menu-folder": {
    note: "Folder ▸ open: Open in Zed, Open In ▸, Reveal in Finder, Open Terminal Here, Copy Path, then Edit CLAUDE.md and Add Files to Project under one line.",
    snapshot,
    play: openFolder,
  },
  "chat-menu-open-in": {
    note: "Open In ▸ lists the other editors installed, in the app's order.",
    snapshot,
    play: openEditors,
  },
  "chat-menu-no-editors": {
    note: "No editor installed: the row reads Open in Editor (the app opens the folder with its default app or says why not), and there is no Open In.",
    snapshot,
    native: NO_EDITORS,
    play: openFolder,
  },
  "chat-menu-long-editor": {
    note: "A long default editor name and five others: the rows end in an ellipsis inside the menu's width.",
    snapshot,
    native: LONG_EDITOR,
    play: openEditors,
  },
  "edited-files": {
    note: "The changed-files card ends with Open in Zed for the chat's folder (the chat's latest card only).",
    snapshot,
    play: card,
  },
  "edited-files-file-menu": {
    note: "Right-click a changed file: Open in Zed, Reveal in Finder, Copy Path.",
    snapshot,
    play: fileMenu,
  },
  "edited-files-no-editors": {
    note: "No editor installed: the card's row and the file menu read Open in Editor.",
    snapshot,
    native: NO_EDITORS,
    play: fileMenu,
  },
  "edited-files-long-editor": {
    note: "A long default editor name on the card's row.",
    snapshot,
    native: LONG_EDITOR,
    play: card,
  },
};

export default agentPaneEntry({
  id: "agent-pane.open-in-editor",
  title: "Open in Editor: chat menu and changed files",
  area: "Agent pane",
  // The transcript view gallery's height: the whole chat menu with no scroll.
  height: 700,
  covers: [
    "agent-session/acpmux/folderActions.ts",
    "agent-session/acpmux/header/folderRow.ts#folderRow",
    "agent-session/acpmux/conversation/EditedFilesCard.tsx#EditedFilesCard",
  ],
  variants,
});
