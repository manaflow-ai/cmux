// l10n-allow-file: gallery fixtures (sample folders and rows), not shipped UI.
// Staged late data in open popups (ui/popupSettle.ts; Leo, 2026-11-22: "the shifting projects and
// sizing of stuff. and the shifting of the inner content. we need to prevent this once and for all").
// Each variant's play opens one real popup; then, with no input, the stage feeds it new data on a
// timer, as a list read again, a count or a late icon does in the app. The stage root's
// `data-stage` names the step that last landed ("done" after the last), so a test waits on it.
// test/popup-settle-browser.test.ts records every painted frame of the popup and holds it still.
import { type ReactNode, useEffect, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { FolderPopover, type FolderChoice } from "../agent-session/acpmux/FolderPopover";
import type { ProjectRepo } from "../agent-session/acpmux/projectRepos";
import { Combobox } from "./Combobox";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";
import { Menu, MenuButton, MenuItem, MenuPopup, Submenu } from "./Menu";
import { Popover } from "./Popover";

type Scene = "combobox" | "combobox-typed" | "menu-slots" | "loading" | "context-late-row" | "submenu-late" | "folders";

type Props = { scene: Scene };

/** The steps of a stage: each lands this long after the one before, once a popup is open (ms). */
const STEP_MS = 280;

/** The stage: `closed` until a popup is open, then each of `steps` in turn, then `done`. With
 *  `onInput`, the steps start only after `go()` (the person typed), and run fast (within the
 *  input window, ui/popupSettle.ts POPUP_INPUT_MS). */
function useStages(steps: readonly string[], afterInput = false) {
  const [stage, setStage] = useState("closed");
  const [started, setStarted] = useState(false);
  const [typed, setTyped] = useState(false);
  useEffect(() => {
    if (started) return;
    const seen = () => {
      if (!document.querySelector(".ui-popup")) return false;
      setStarted(true);
      setStage("open");
      return true;
    };
    if (seen()) return;
    const watch = new MutationObserver(() => {
      if (seen()) watch.disconnect();
    });
    watch.observe(document.body, { childList: true, subtree: true });
    return () => watch.disconnect();
  }, [started]);
  useEffect(() => {
    if (!started || (afterInput && !typed)) return;
    const gap = afterInput ? 120 : STEP_MS;
    // gallery-capture: the stage's steps run after the play opens the popup, and the variant's play waits for the popup it names.
    const timers = [...steps, "done"].map((step, index) => setTimeout(() => setStage(step), gap * (index + 1)));
    return () => timers.forEach(clearTimeout);
  }, [started, typed, afterInput, steps]);
  return { stage, go: () => setTyped(true) };
}

const SHORT = ["atlas-web", "cmux", "relay", "notes", "infra", "docs"];
const LONG = [
  ...SHORT.map((name) => (name === "notes" ? "notes-and-a-much-longer-folder-name" : name)),
  "billing",
  "mobile",
  "design-system",
  "playground",
  "scripts",
  "website",
  "dotfiles",
  "sandbox",
];

/** (a), (f): a popover over an inline Combobox whose rows go 6 -> 14 -> 6, the longest label doubled. */
function ComboboxScene({ typed }: { typed: boolean }) {
  const [open, setOpen] = useState(false);
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  const { stage, go } = useStages(["large", "small"], typed);
  const rows = stage === "large" ? LONG : SHORT;
  return (
    <div className="popup-settle-stage" data-stage={stage} style={{ padding: 24 }}>
      <button ref={setAnchor} type="button" aria-label="Projects" onClick={() => setOpen(true)}>
        Projects
      </button>
      <Popover open={open} onOpenChange={setOpen} anchor={anchor} label="Projects" className="popup-settle-projects">
        <Combobox
          suggestions={rows}
          onQuery={() => go()}
          onSubmit={() => undefined}
          onCancel={() => setOpen(false)}
          label="Search projects"
          placeholder="Search projects"
          inline
          renderItem={(value) => (
            <span style={{ display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {value}
            </span>
          )}
        />
      </Popover>
    </div>
  );
}

function Glyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      <circle cx="7" cy="7" r="5" fill="currentColor" />
    </svg>
  );
}

/** A menu row whose icon and count arrive late, each in a slot kept for it from the start. */
function SlotRow({ late, label, count }: { late: boolean; label: string; count: number }) {
  return (
    <span style={{ display: "flex", alignItems: "center", gap: "var(--ds-space-2)", minWidth: 0, flex: 1 }}>
      <span style={{ display: "inline-flex", width: 14, height: 14, flex: "none" }}>{late && <Glyph />}</span>
      <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
        {label}
      </span>
      <span
        style={{ flex: "none", minWidth: "3ch", textAlign: "end", fontVariantNumeric: "tabular-nums" }}
        aria-hidden="true"
      >
        {late ? count : ""}
      </span>
    </span>
  );
}

/** (b): menu rows gain a leading icon, a trailing count and a longer label late. */
function MenuSlotsScene() {
  const { stage } = useStages(["late"]);
  const late = stage === "late" || stage === "done";
  return (
    <div className="popup-settle-stage" data-stage={stage} style={{ padding: 24 }}>
      <Menu>
        <MenuButton label="Open chat menu">Chat</MenuButton>
        <MenuPopup label="Chat menu" className="popup-settle-slots">
          <MenuItem>
            <SlotRow late={late} label="Open in new tab" count={3} />
          </MenuItem>
          <MenuItem>
            <SlotRow late={late} label={late ? "Rename this chat and its worktree" : "Rename"} count={12} />
          </MenuItem>
          <MenuItem>
            <SlotRow late={late} label="Duplicate" count={7} />
          </MenuItem>
          <MenuItem>
            <SlotRow late={late} label="Archive" count={1} />
          </MenuItem>
        </MenuPopup>
      </Menu>
    </div>
  );
}

/** (c): a short faded popover that holds one Loading line, then twelve rows. */
function LoadingScene() {
  const [open, setOpen] = useState(false);
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  const { stage } = useStages(["loaded"]);
  const loaded = stage === "loaded" || stage === "done";
  return (
    <div className="popup-settle-stage" data-stage={stage} style={{ padding: 24 }}>
      <button ref={setAnchor} type="button" aria-label="Branches" onClick={() => setOpen(true)}>
        Branches
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={anchor}
        label="Branches"
        className="popup-settle-loading"
        fade
      >
        <ul aria-label="Branches" style={{ margin: 0, padding: 0, listStyle: "none" }}>
          {loaded ? (
            Array.from({ length: 12 }, (_, index) => (
              <li key={index} style={{ padding: "4px 8px" }}>
                feature/branch-{index + 1}
              </li>
            ))
          ) : (
            <li style={{ padding: "4px 8px" }}>Loading…</li>
          )}
        </ul>
      </Popover>
    </div>
  );
}

/** (d): a context menu whose last row arrives late. */
function ContextLateRowScene() {
  const { stage } = useStages(["late"]);
  const late = stage === "late" || stage === "done";
  const names = ["Open", "Open in new tab", "Copy link", "Copy path", "Rename", "Duplicate", "Move to…"];
  const items: ContextMenuItem[] = [
    ...names.map((name) => ({ id: name, label: name, onSelect: () => undefined })),
    ...(late ? [{ id: "pr", label: "Open pull request #49879", onSelect: () => undefined }] : []),
    { id: "delete", label: "Delete", destructive: true, separatorBefore: true, onSelect: () => undefined },
  ];
  return (
    <div className="popup-settle-stage" data-stage={stage} style={{ padding: 24 }}>
      <ContextMenu items={items} popupClassName="popup-settle-context">
        <button type="button" data-testid="popup-settle-target">
          Right-click this file
        </button>
      </ContextMenu>
    </div>
  );
}

/** (e): a submenu whose rows arrive late (more rows, a longer one). */
function SubmenuLateScene() {
  const { stage } = useStages(["late"]);
  const late = stage === "late" || stage === "done";
  const rows = [
    "main",
    "release",
    "develop",
    "staging",
    "hotfix",
    "docs",
    ...(late ? ["feature/a-much-longer-branch-name", "spike", "wip"] : []),
  ];
  return (
    <div className="popup-settle-stage" data-stage={stage} style={{ padding: 24 }}>
      <Menu>
        <MenuButton label="Open branch menu">Branch</MenuButton>
        <MenuPopup label="Branch menu" className="popup-settle-branch">
          <MenuItem>New branch</MenuItem>
          <Submenu label="Switch to" popupClassName="popup-settle-switch">
            {rows.map((name) => (
              <MenuItem key={name}>{name}</MenuItem>
            ))}
          </Submenu>
        </MenuPopup>
      </Menu>
    </div>
  );
}

const CMUX: ProjectRepo = { root: "/Users/you/src/cmux", top: "/Users/you/src/cmux", name: "cmux", branch: "main" };
const ATLAS: ProjectRepo = {
  root: "/Users/you/src/atlas-web",
  top: "/Users/you/src/atlas-web",
  name: "atlas-web",
  branch: "main",
};

/** One repository's main checkout and `count - 1` worktrees. */
function repoFolders(repo: ProjectRepo, count: number): FolderChoice[] {
  return [
    { id: repo.root, label: repo.name, repo },
    ...Array.from({ length: count - 1 }, (_, index) => {
      const id = `/Users/you/wt/${repo.name}-task-${index + 1}`;
      return { id, label: repo.name, repo: { ...repo, top: id, branch: `task-${index + 1}` } };
    }),
  ];
}

const SMALL_FOLDERS: FolderChoice[] = [
  ...repoFolders(CMUX, 5),
  ...repoFolders(ATLAS, 15),
  { id: "/Users/you/src/relay", label: "relay" },
  { id: "/Users/you/src/notes", label: "notes" },
];
const LARGE_FOLDERS: FolderChoice[] = [
  ...repoFolders(CMUX, 13),
  ...repoFolders(ATLAS, 59),
  { id: "/Users/you/src/relay", label: "relay" },
  { id: "/Users/you/src/notes", label: "notes" },
  // A second clone named like the first: both cmux rows gain a suffix that tells them apart.
  { id: "/Users/you/cmux", label: "cmux", repo: { root: "/Users/you/cmux", top: "/Users/you/cmux", name: "cmux" } },
];

/** (folders): the real folder menu while the project list is read again: small, large, small. */
function FoldersScene() {
  const { stage } = useStages(["large", "small"]);
  return (
    <div className="popup-settle-stage" data-stage={stage} style={{ padding: 24 }}>
      <FolderPopover
        label="Folder"
        menu="PopupSettleFolder"
        face={<span>cmux</span>}
        folders={stage === "large" ? LARGE_FOLDERS : SMALL_FOLDERS}
        current="/Users/you/src/cmux"
        onPick={() => undefined}
        onBrowse={() => undefined}
        onNoProject={() => undefined}
      />
    </div>
  );
}

function PopupSettleStage({ scene }: Props): ReactNode {
  switch (scene) {
    case "combobox":
      return <ComboboxScene typed={false} />;
    case "combobox-typed":
      return <ComboboxScene typed />;
    case "menu-slots":
      return <MenuSlotsScene />;
    case "loading":
      return <LoadingScene />;
    case "context-late-row":
      return <ContextLateRowScene />;
    case "submenu-late":
      return <SubmenuLateScene />;
    case "folders":
      return <FoldersScene />;
  }
}

const openButton =
  (name: string, popup: string): Play =>
  async (ctx) => {
    await ctx.click({ role: "button", name });
    await ctx.waitFor(() => ctx.document.querySelector(popup));
  };

const openSubmenu: Play = async (ctx) => {
  await openButton("Open branch menu", ".popup-settle-branch")(ctx);
  await ctx.focus({ role: "menuitem", name: "Switch to" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelector(".popup-settle-switch"));
};

const openContext: Play = async (ctx) => {
  await ctx.contextMenu({ testId: "popup-settle-target" });
  await ctx.waitFor(() => ctx.document.querySelector(".popup-settle-context"));
};

// The stages move the open popup's data on purpose: the gallery's own play checks would count it.
const staged = {
  layoutShiftMax: {
    value: 1,
    reason: "The stage feeds the open popup late data on purpose; popup-settle-browser.test.ts judges it.",
  },
};

export default componentEntry<Props>({
  id: "ui.popup-settle",
  title: "Popup settle (late data)",
  area: "UI primitives",
  pane: true,
  height: 640,
  widths: { narrow: 420, normal: 620, wide: 760 },
  covers: ["ui/popupSettle.ts", "agent-session/acpmux/FolderPopover.tsx#FolderPopover"],
  styles: () =>
    Promise.all([
      import("./popupSurface.css"),
      import("../agent-session/acpmux/styles.css"),
      import("../agent-session/acpmux/composerLocation.css"),
    ]),
  load: async () => PopupSettleStage,
  checks: staged,
  variants: {
    combobox: {
      note: "A popover over an inline list whose rows go 6 -> 14 -> 6 and whose longest name doubles, with no input: the box holds.",
      props: { scene: "combobox" },
      play: openButton("Projects", ".popup-settle-projects"),
    },
    "combobox-typed": {
      note: "The same list, but the rows change right after a typed letter: the box may follow.",
      props: { scene: "combobox-typed" },
      play: openButton("Projects", ".popup-settle-projects"),
    },
    "menu-slots": {
      note: "Menu rows gain a leading icon, a trailing count and a longer label late, each in a slot kept from the start.",
      props: { scene: "menu-slots" },
      play: openButton("Open chat menu", ".popup-settle-slots"),
    },
    loading: {
      note: "Known shape: a short faded popover with one Loading line grows when twelve rows arrive; its data must load before open.",
      props: { scene: "loading" },
      play: openButton("Branches", ".popup-settle-loading"),
    },
    "context-late-row": {
      note: "A context menu whose pull request row arrives late.",
      props: { scene: "context-late-row" },
      play: openContext,
    },
    "submenu-late": {
      note: "A submenu whose rows arrive late, one of them long.",
      props: { scene: "submenu-late" },
      play: openSubmenu,
    },
    folders: {
      note: "The real folder menu while the list is read again: 5 -> 13 -> 5 and 15 -> 59 -> 15 worktrees, a second cmux clone adds a suffix.",
      props: { scene: "folders" },
      play: openButton("Folder", ".acpmux-folder-popover"),
    },
  },
});
