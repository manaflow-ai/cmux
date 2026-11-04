// l10n-allow-file: gallery fixture labels and session titles, not shipped UI.
//
// This is the legacy (variant-A) New Tab page that remains selectable while the newer
// NewTabScreen is dogfooded. Keep its keyboard and host receipts visible in the gallery: it is
// the first navigation surface a user sees before a tab becomes a terminal, browser, or chat.
import { useEffect, useState, type ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { CATALOG, manySessions, noChat } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";
import { NewTabPage } from "./NewTabPage";
import type { OmnibarContext } from "./omnibar";
import type { Project } from "./ProjectChooser";
import type { Play, PlayContext } from "../../gallery/play";
import type { MarkdownFieldElement } from "./MarkdownField";

import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";

type GlassPreview = "plain" | "lens" | "spectrum" | "reduce";
type Props = ComponentProps<typeof NewTabPage> & { glassPreview?: GlassPreview };

function useGlassPreview(mode?: GlassPreview) {
  useEffect(() => {
    if (!mode) return;
    const root = document.documentElement;
    const names = ["style", "data-glass", "data-reduce-transparency"];
    const saved = names.map((name) => root.getAttribute(name));
    root.setAttribute("data-glass", mode === "reduce" ? "plain" : mode);
    root.toggleAttribute("data-reduce-transparency", mode === "reduce");
    root.style.setProperty("--agent-page-bg", "transparent");
    root.style.setProperty("--cmux-surface-background", "transparent");
    root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
    const host = window as unknown as { cmuxTheme?: { backdrop?: (value: unknown) => void } };
    const send = () =>
      host.cmuxTheme?.backdrop?.({
        image: wallpaper,
        key: "gallery-omnibar-glass",
        rect: { x: 0, y: 0, width: root.clientWidth, height: root.clientHeight },
        blur: 0,
        tint: "transparent",
      });
    send();
    window.addEventListener("resize", send);
    return () => {
      window.removeEventListener("resize", send);
      host.cmuxTheme?.backdrop?.({ image: null, key: null });
      names.forEach((name, index) => {
        const value = saved[index];
        if (value === null) root.removeAttribute(name);
        else root.setAttribute(name, value);
      });
    };
  }, [mode]);
}

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
  projects,
  onSubmit: () => undefined,
  onJump: () => undefined,
  onOpenSession: () => undefined,
  onShowAll: () => undefined,
  onBrowseProject: async () => "/Users/you/src/relay",
};

function withReceipt(Component: typeof NewTabPage) {
  return function GalleryNewTabPage({ glassPreview, ...props }: Props) {
    useGlassPreview(glassPreview);
    const [receipt, setReceipt] = useState("");
    const record = (value: string) => setReceipt(value);
    return (
      // The pane's shell, as the app mounts the page: its composer tokens (styles.css) fill the box.
      <div className="acpmux-shell newtab-page-gallery" data-newtab-receipt={receipt}>
        <Component
          {...props}
          onSubmit={(kind, text, cwd) => {
            const result = props.onSubmit(kind, text, cwd);
            record(`submit:${kind}:${text}${cwd ? `:${cwd}` : ""}`);
            return result;
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
          onBrowseProject={async () => {
            record("browse-project");
            return props.onBrowseProject?.();
          }}
        />
      </div>
    );
  };
}

/// The page's field: the chat composer's prompt editor (MarkdownField), as on the New Tab screen.
const FIELD = ".acpmux-newtab-field [contenteditable=true]";
const fieldText = (ctx: PlayContext) =>
  ctx.document.querySelector<MarkdownFieldElement>(".acpmux-newtab-field")?.acpmuxMarkdownField?.plainText() ?? "";
async function typePrompt(ctx: PlayContext, text: string) {
  await ctx.waitFor(() => ctx.document.querySelector(FIELD));
  await ctx.type(text, { selector: FIELD });
}

const switchKinds: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Browser/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "browser");
  await ctx.click({ role: "button", name: /Agent/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent");
};

const prefixes: Play = async (ctx) => {
  // DIAG(cmux#35744): temporary, not for merge.
  const view = ctx.document.defaultView!;
  const seen: string[] = [];
  const diag = new view.PerformanceObserver((list) => {
    for (const entry of list.getEntries() as (PerformanceEntry & { value: number; sources?: { node?: Node; previousRect: DOMRectReadOnly; currentRect: DOMRectReadOnly }[] })[]) {
      for (const source of entry.sources ?? []) {
        const el = source.node instanceof view.Element ? source.node : undefined;
        if (!el?.closest(".acpmux-omni")) continue;
        const pop = el.closest(".acpmux-omni") as HTMLElement;
        const r = (b: DOMRectReadOnly) => [b.x, b.y, b.width, b.height].map((n) => Math.round(n)).join(",");
        const rows = [...pop.querySelectorAll(".acpmux-omni-row")];
        seen.push(`t=${Math.round(entry.startTime)} v=${entry.value.toFixed(4)} row#${rows.indexOf(el)}/${rows.length} "${(el.textContent ?? "").slice(0, 40)}" prev=${r(source.previousRect)} cur=${r(source.currentRect)} pop=${r(pop.getBoundingClientRect())} scroll=${pop.scrollTop}/${pop.clientHeight}/${pop.scrollHeight} kind=${ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind")} q="${fieldText(ctx)}" sw=${ctx.document.querySelector(".acpmux-newtab-under")?.getAttribute("data-kind-switch") ?? ""} vh=${view.innerHeight}`);
      }
    }
  });
  diag.observe({ type: "layout-shift", buffered: false });
  await typePrompt(ctx, "!git status");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "terminal" &&
      fieldText(ctx) === "git status",
  );
  await ctx.press("Escape");
  await typePrompt(ctx, "?review the cache");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent" &&
      fieldText(ctx) === "review the cache",
  );
  diag.disconnect();
  if (seen.length) throw new Error(`DIAG ${seen.join(" || ")}`);
};

const keyboard: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(FIELD));
  await ctx.focus({ selector: FIELD });
  await ctx.press("Tab");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "terminal");
  await ctx.press("Shift+Tab");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent");
  await typePrompt(ctx, "release");
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".newtab-page-gallery")?.getAttribute("data-newtab-receipt") ===
      "jump:tab:tab-release",
  );
};

const openOmnibar: Play = async (ctx) => {
  await typePrompt(ctx, "release");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-omni"));
};

const escapeClear: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(FIELD));
  await ctx.focus({ selector: FIELD });
  await ctx.press("Escape");
  await ctx.waitFor(() => fieldText(ctx) === "");
};

const folderChooser: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-project-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="combobox"]') !== null);
  await ctx.type("relay", { role: "combobox", name: "Search projects" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-button")?.textContent?.includes("relay"));
};

// New Tab always lands on the page and offers no default-kind toggle (cx-39b5r, #20127).
const noDefaultToggle: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab-field") !== null);
  if (ctx.document.querySelector(".acpmux-newtab-default")) {
    throw new Error("the New Tab page still shows the default-kind toggle");
  }
};

const openSession: Play = async (ctx) => {
  await typePrompt(ctx, "retries");
  await ctx.press("ArrowUp");
  await ctx.press("Enter");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".newtab-page-gallery")?.getAttribute("data-newtab-receipt") ===
      "open-session:gallery-session-0",
  );
};

// The field is the chat composer's prompt editor: a long prompt wraps and the box grows with it,
// as in a chat, instead of scrolling sideways in a one-line input (Leo 2026-10-21: "I STILL DONT HAVE
// THE GOOD COMPOSER EVERYWHERE").
const LONG_PROMPT =
  "Look at the retry loop in the sync worker and tell me why a dropped connection restarts the whole batch instead of the one request that failed";
const longPrompt: Play = async (ctx) => {
  await typePrompt(ctx, LONG_PROMPT);
  await ctx.waitFor(() => {
    const field = ctx.document.querySelector<HTMLElement>(".acpmux-newtab-field");
    return fieldText(ctx) === LONG_PROMPT && (field?.getBoundingClientRect().height ?? 0) > 56;
  });
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
    "omnibar-overflow": {
      note: "Capped omnibar suggestions fade at the edge with more rows in a short pane.",
      props: {
        ...base,
        omnibar: {
          ...omnibar,
          tabs: Array.from({ length: 20 }, (_, index) => ({
            id: `tab-release-${index}`,
            kind: "terminal" as const,
            title: `Release build ${index}`,
            detail: "~/src/release",
          })),
        },
      },
      play: openOmnibar,
    },
    "omnibar-plain": {
      note: "Chosen default: the shared popup frost shows the fixture wallpaper through the suggestions and selected row.",
      props: { ...base, glassPreview: "plain" },
      play: openOmnibar,
    },
    "omnibar-lens": {
      note: "The same popup in the opt-in Lens mode; no extra edge or elevation.",
      props: { ...base, glassPreview: "lens" },
      play: openOmnibar,
    },
    "omnibar-spectrum": {
      note: "The same popup with the opt-in Spectrum rim, using shared glass tokens.",
      props: { ...base, glassPreview: "spectrum" },
      play: openOmnibar,
    },
    "omnibar-reduce-transparency": {
      note: "Reduce Transparency makes the popup solid over the same fixture wallpaper and disables blur.",
      props: { ...base, glassPreview: "reduce" },
      play: openOmnibar,
    },
    idle: {
      note: "The classic page opens on Agent with recent sessions, project context, model chips, and the three-kind switch.",
      props: base,
    },
    "long-project": {
      note: "A long project name truncates inside its content-sized chip while the chevron stays visible.",
      props: {
        ...base,
        cwd: "/Users/you/src/atlas-web-platform-integration-workspace",
        projects: [
          {
            cwd: "/Users/you/src/atlas-web-platform-integration-workspace",
            label: "atlas-web-platform-integration-workspace",
          },
          ...projects,
        ],
      },
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
    "no-default-toggle": {
      note: "New Tab offers no default-kind toggle: it always lands on this page, and a terminal opens only when picked (cx-39b5r).",
      props: base,
      play: noDefaultToggle,
    },
    "open-session": {
      note: "An omnibar session match activates the host's existing chat instead of opening a duplicate.",
      props: base,
      play: openSession,
    },
    "composer-field": {
      note: "The field is the chat composer's prompt editor (MarkdownField), not a plain input: a long prompt wraps and the box grows; the kind switch and Send stay in its row.",
      props: base,
      play: longPrompt,
    },
    "show-all": {
      note: "The All sessions action hands navigation back to the host.",
      props: base,
      play: showAll,
    },
  },
});
