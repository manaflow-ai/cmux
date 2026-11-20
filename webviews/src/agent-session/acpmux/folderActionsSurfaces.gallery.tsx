// l10n-allow-file: gallery fixtures (sample folders, branches and editor names), not shipped UI.
// Open in Editor in Session Info and on the worktree pill (folderActions.ts): the project row's ⋯
// menu (Open in Editor, Open In ▸, Reveal in Finder, Open Terminal Here, Copy Path) and the worktree
// pill's popover rows (the same without Open In). A stand-in for the App's FolderHost runs nothing.
import { useLayoutEffect, useMemo } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { chat } from "../../gallery/fixtures/acpmux";
import { FolderHostContext, setEditors, type EditorList, type FolderHost } from "./folderActions";
import { EnvironmentSection } from "./session-info/EnvironmentSection";
import { SessionInfoPanel } from "./session-info/SessionInfo";
import { WorktreePill } from "./header/WorktreePill";

const FOLDER = "/Users/demo/.cmux/worktrees/atlas/fix-login";

const EDITORS: EditorList = {
  default: { id: "zed", name: "Zed" },
  others: [
    { id: "vscode", name: "Visual Studio Code" },
    { id: "cursor", name: "Cursor" },
    { id: "xcode", name: "Xcode" },
  ],
};
const NONE: EditorList = { default: null, others: [] };
const LONG: EditorList = {
  default: { id: "intellij", name: "IntelliJ IDEA Ultimate 2026.3 Early Access Preview" },
  others: [
    { id: "webstorm", name: "WebStorm" },
    { id: "vscode", name: "Visual Studio Code - Insiders" },
  ],
};

type Props = { surface: "session-info" | "worktree"; editors: EditorList };

function Surfaces({ surface, editors }: Props) {
  useLayoutEffect(() => setEditors(editors), [editors]);
  const host = useMemo<FolderHost>(
    () => ({
      folder: FOLDER,
      session: "gallery-session",
      run: () => undefined,
      openFile: () => undefined,
      copy: () => undefined,
    }),
    [],
  );
  return (
    <FolderHostContext.Provider value={host}>
      {surface === "session-info" ? (
        <div className="acpmux-shell" style={{ height: "100%" }}>
          <SessionInfoPanel width={300} placement="overlay">
            <EnvironmentSection
              summary={{ ...chat([]).summary!, cwd: FOLDER, worktree: FOLDER, branch: "atlas/fix-login" }}
              machineName="Studio"
              onOpenFolder={() => undefined}
            />
          </SessionInfoPanel>
        </div>
      ) : (
        <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", padding: 12 }}>
          <div className="acpmux-header-tools">
            <WorktreePill
              folder={FOLDER}
              worktree={{ branch: "atlas/fix-login", base: "main", mainRoot: "/Users/demo/Projects/atlas" }}
            />
          </div>
        </div>
      )}
    </FolderHostContext.Provider>
  );
}

const folderMenu: Play = async (ctx) => {
  await ctx.hover({ selector: ".acpmux-session-info-folder" });
  await ctx.click({ selector: ".acpmux-session-info-folder__more" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
};

const folderEditors: Play = async (ctx) => {
  await folderMenu(ctx);
  await ctx.click({ role: "menuitem", name: "Open In" });
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length >= 2);
};

const pill: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-header-worktree" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-worktree-open"));
};

export default componentEntry<Props>({
  id: "agent-pane.open-in-editor-panels",
  title: "Open in Editor: Session Info and worktree pill",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 320, normal: 600 },
  covers: [
    "agent-session/acpmux/session-info/EnvironmentSection.tsx#EnvironmentSection",
    "agent-session/acpmux/header/WorktreePill.tsx#WorktreePill",
    "agent-session/acpmux/header/worktreePillModel.ts#worktreeFolderActions",
  ],
  load: async () => Surfaces,
  variants: {
    "session-info-folder": {
      note: "Session Info's project row: its ⋯ shows on hover and stays lit while its menu is open. Open in Zed, Open In ▸, Reveal in Finder, Open Terminal Here, Copy Path.",
      props: { surface: "session-info", editors: EDITORS },
      play: folderMenu,
    },
    "session-info-folder-open-in": {
      note: "Open In ▸ lists the other editors installed.",
      props: { surface: "session-info", editors: EDITORS },
      play: folderEditors,
    },
    "session-info-folder-no-editors": {
      note: "No editor installed: Open in Editor, and no Open In.",
      props: { surface: "session-info", editors: NONE },
      play: folderMenu,
    },
    "session-info-folder-long-editor": {
      note: "A long default editor name ends in an ellipsis inside the menu.",
      props: { surface: "session-info", editors: LONG },
      play: folderMenu,
    },
    "worktree-pill": {
      note: "The worktree pill's popover: Open in Zed, Reveal in Finder, Open Terminal Here and Copy Path for the worktree folder.",
      props: { surface: "worktree", editors: EDITORS },
      play: pill,
    },
    "worktree-pill-no-editors": {
      note: "No editor installed: the first row reads Open in Editor.",
      props: { surface: "worktree", editors: NONE },
      play: pill,
    },
    "worktree-pill-long-editor": {
      note: "A long default editor name ends in an ellipsis inside the popover.",
      props: { surface: "worktree", editors: LONG },
      play: pill,
    },
  },
});
