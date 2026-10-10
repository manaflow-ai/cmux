// l10n-allow-file: gallery fixture labels and session titles, not shipped UI.
//
// This is the legacy (variant-A) New Tab page that remains selectable while the newer
// NewTabScreen is dogfooded. Keep its keyboard and host receipts visible in the gallery: it is
// the first navigation surface a user sees before a tab becomes a terminal, browser, or chat.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { CATALOG, manySessions, noChat } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";
import { NewTabPage } from "./NewTabPage";
import type { OmnibarContext } from "./omnibar";
import type { Project } from "./ProjectChooser";
import type { Play } from "../../gallery/play";

type Props = ComponentProps<typeof NewTabPage>;

const projects: Project[] = [
  { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
  { cwd: "/Users/you/src/cmux", label: "cmux" },
  { cwd: "/Users/you/src/relay", label: "relay" },
];

const omnibar: OmnibarContext = {
  tabs: [
    { id: "tab-release", kind: "browser", title: "Release notes", detail: "cmux.dev" },
    { id: "tab-terminal", kind: "terminal", title: "Release build", detail: "~/src/release" },
  ],
  workspaces: [{ id: "workspace-release", name: "Release", detail: "~/src/release" }],
  sessions: [],
  folders: ["/Users/you/src/cmux", "/Users/you/src/relay"],
  commands: ["bun test", "bun run gallery:build"],
  history: [{ url: "https://cmux.dev/release", title: "cmux release notes" }],
};

const Chips = ({ snapshot }: { snapshot: AcpmuxSnapshot }) => (
  <span className="newtab-gallery-chips" data-harness={snapshot.catalog[0]?.id ?? "agent"}>
    Opus 5.5 · High
  </span>
);

const snapshot = noChat(manySessions(8), { catalog: CATALOG });

const base: Props = {
  snapshot,
  hotkeys: { terminal: "⌘T", browser: "⌘L", agent: "⇧⌘I" },
  initialKind: "agent",
  cwd: "/Users/you/src/atlas-web",
  host: "This Mac",
  chips: Chips,
  omnibar,
  defaultKind: "same-kind",
  projects,
  onSubmit: () => undefined,
  onJump: () => undefined,
  onOpenSession: () => undefined,
  onShowAll: () => undefined,
  onSetDefaultKind: () => undefined,
  onBrowseProject: async () => "/Users/you/src/relay",
  onAddHarness: () => undefined,
};

function withReceipt(Component: typeof NewTabPage) {
  return function GalleryNewTabPage(props: Props) {
    const [receipt, setReceipt] = useState("");
    const record = (value: string) => setReceipt(value);
    return (
      <div className="newtab-page-gallery" data-newtab-receipt={receipt}>
        <Component
          {...props}
          onSubmit={(kind, text, cwd) => {
            props.onSubmit(kind, text, cwd);
            record(`submit:${kind}:${text}${cwd ? `:${cwd}` : ""}`);
          }}
          onJump={(target, id) => {
            props.onJump?.(target, id);
            record(`jump:${target}:${id}`);
          }}
          onOpenSession={(sessionId) => {
            props.onOpenSession(sessionId);
            record(`open-session:${sessionId}`);
          }}
          onShowAll={() => {
            props.onShowAll();
            record("show-all");
          }}
          onSetDefaultKind={(kind) => {
            props.onSetDefaultKind?.(kind);
            record(`default:${kind}`);
          }}
          onBrowseProject={async () => {
            record("browse-project");
            return props.onBrowseProject?.();
          }}
          onAddHarness={() => {
            props.onAddHarness?.();
            record("add-harness");
          }}
        />
      </div>
    );
  };
}

const switchKinds: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Browser/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "browser");
  await ctx.click({ role: "button", name: /Agent/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent");
};

const prefixes: Play = async (ctx) => {
  await ctx.type("!git status", { selector: ".acpmux-newtab-field" });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "terminal" &&
      ctx.document.querySelector<HTMLInputElement>(".acpmux-newtab-field")?.value === "git status",
  );
  await ctx.press("Escape");
  await ctx.type("?review the cache", { selector: ".acpmux-newtab-field" });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent" &&
      ctx.document.querySelector<HTMLInputElement>(".acpmux-newtab-field")?.value === "review the cache",
  );
};

const keyboard: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-newtab-field" });
  await ctx.press("Tab");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "terminal");
  await ctx.press("Shift+Tab");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent");
  await ctx.type("release", { selector: ".acpmux-newtab-field" });
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".newtab-page-gallery")?.getAttribute("data-newtab-receipt") ===
      "jump:tab:tab-release",
  );
};

const escapeClear: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-newtab-field" });
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector<HTMLInputElement>(".acpmux-newtab-field")?.value === "");
};

const folderChooser: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-project-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="combobox"]') !== null);
  await ctx.type("relay", { role: "combobox", name: "Search projects" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-button")?.textContent?.includes("relay"));
};

const defaultKind: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-newtab-default" });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".newtab-page-gallery")?.getAttribute("data-newtab-receipt") === "default:terminal",
  );
};

const openSession: Play = async (ctx) => {
  await ctx.type("retries", { selector: ".acpmux-newtab-field" });
  await ctx.press("ArrowUp");
  await ctx.press("Enter");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".newtab-page-gallery")?.getAttribute("data-newtab-receipt") ===
      "open-session:gallery-session-0",
  );
};

const showAll: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-newtab-all" });
  await ctx.waitFor(
    () => ctx.document.querySelector(".newtab-page-gallery")?.getAttribute("data-newtab-receipt") === "show-all",
  );
};

export default componentEntry<Props>({
  id: "agent-pane.new-tab-page",
  title: "New Tab page (classic)",
  area: "New Tab",
  height: 560,
  widths: { narrow: 420, normal: 680, wide: 880 },
  anchors: [{ selector: ".newtab-page-gallery" }],
  covers: ["agent-session/acpmux/NewTabPage.tsx#NewTabPage", "agent-session/acpmux/NewTabPage.tsx#KindIcon"],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Changing the new-tab kind or opening a project menu must preserve the page frame geometry.",
    },
    layoutShiftMax: {
      value: 0.4,
      reason: "Omnibar suggestions are in flow below the field and may move the action row while typing.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Kind switching and local omnibar navigation should stay below one display frame.",
    },
  },
  load: () => import("./NewTabPage").then(({ NewTabPage: Component }) => withReceipt(Component)),
  variants: {
    idle: {
      note: "The classic page opens on Agent with recent sessions, project context, model chips, and the three-kind switch.",
      props: base,
    },
    "switch-kinds": {
      note: "The Terminal, Browser, and Agent buttons switch the page without losing the field.",
      props: base,
      play: switchKinds,
    },
    prefixes: {
      note: "! changes an empty field to Terminal and ? changes it to Agent while preserving the typed text.",
      props: base,
      play: prefixes,
    },
    keyboard: {
      note: "Tab and Shift+Tab cycle kinds; ArrowDown then Enter jumps to a matching open tab.",
      props: base,
      play: keyboard,
    },
    "escape-clear": {
      note: "Cmd-L-style location text clears with Escape before the page can dismiss.",
      props: { ...base, location: "https://cmux.dev/release" },
      play: escapeClear,
    },
    "folder-chooser": {
      note: "The project chooser filters real recent folders and commits a keyboard-selected project.",
      props: base,
      play: folderChooser,
    },
    "default-kind": {
      note: "The default-kind affordance cycles the kind opened by Cmd-T and records the host setting change.",
      props: base,
      play: defaultKind,
    },
    "open-session": {
      note: "An omnibar session match activates the host's existing chat instead of opening a duplicate.",
      props: base,
      play: openSession,
    },
    "show-all": {
      note: "The All sessions action hands navigation back to the host.",
      props: base,
      play: showAll,
    },
  },
});
