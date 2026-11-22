// l10n-allow-file: gallery fixtures (sample words), not shipped UI.
// One material (Leo, 2026-11-21: "our shitty multi layer glass + web view. we need to properly do that
// once and for all." and "where is our proper glass redesign? does it look better? at various
// backgrounds?"): every floating web surface of a new chat in one stage, on the real components, so one
// capture shows how they read together over a picture. The new chat's composer ("Type a question,
// command, or URL" with its folder, machine, access and model chips) is the real New Tab page in the
// real agent pane; each variant opens one more surface on it:
//
// - folder-picker: the folder chip's popover ("Search folders or type a path").
// - access-menu: the access (permission) menu under the box.
// - hover-preview: a title tooltip on the composer's own control, and a hover card (ui/Tooltip.tsx
//   AnchoredCard, the card every hover preview takes) beside the folder chip.
// - toast: a toast (ui/NoticeStack, the page's stack) and the chat's Delete dialog (DeleteChatDialog).
//
// The candidate materials are arms of webviews/scripts/gallery/one-material.capture.json (CSS injected
// over this stage), not code here. Over a picture the gallery paints the window's art and tint behind
// the see-through page (frame/background.ts); the App's native host glass under a popup does not exist
// in a browser, so every surface here draws the page's own glass.
import type { ReactNode } from "react";
import { agentPaneEntry } from "../../gallery/format";
import type { Play, PlayContext } from "../../gallery/play";
import { CWD, manySessions, noChat } from "../../gallery/fixtures/acpmux";

const newTab = () => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    template: "minimal",
    startedProject: CWD,
    projects: [CWD],
  },
  newSession: true,
});

const signedIn = { "cloudMachine.list": { signedIn: true, loaded: true, machines: [] } };

const FOLDER = '.nt-location [aria-label="Folder"]';
const ACCESS = ".nt-foot .acpmux-access-trigger";

/** The composer and its chips are on screen. */
const ready = (ctx: PlayContext) =>
  ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null && ctx.document.querySelector(ACCESS) !== null);

/** Mounts real components beside the pane, in its document (so over the same picture and tokens). */
async function mountBeside(ctx: PlayContext, node: ReactNode): Promise<HTMLElement> {
  const { createRoot } = await import("react-dom/client");
  const host = ctx.document.createElement("div");
  host.className = "one-material-gallery-host";
  ctx.document.body.append(host);
  createRoot(host).render(node);
  return host;
}

const folderPicker: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: FOLDER });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu input"));
};

const accessMenu: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: ACCESS });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-access-menu"));
};

const PREVIEW_PROMPT = "Why does cancel keep retrying the request?";
const PREVIEW_REPLY =
  "The retry wrapper caught AbortError and retried it like a network error. Now an abort ends the loop at once, and retries count only network failures. The tests cover both paths.";

const hoverPreview: Play = async (ctx) => {
  await ready(ctx);
  const { AnchoredCard } = await import("../Tooltip");
  const anchor = ctx.document.querySelector<HTMLElement>(FOLDER);
  await mountBeside(
    ctx,
    <AnchoredCard anchor={anchor} side="top" open>
      <div style={{ display: "grid", gap: "var(--ds-space-1)", maxWidth: 320 }}>
        <span style={{ fontWeight: "var(--weight-emphasis)" }}>{PREVIEW_PROMPT}</span>
        <span style={{ color: "var(--cmux-text-secondary)" }}>{PREVIEW_REPLY}</span>
      </div>
    </AnchoredCard>,
  );
  await ctx.waitFor(() => ctx.document.querySelector(".ui-tooltip.ui-card"));
  // The composer's own control with a tooltip (ui/titleTooltips.ts moves its title to data-tooltip).
  const control = ctx.document.querySelector(".nt-composer [data-tooltip], .nt-composer [title]");
  if (!control) throw new Error("no composer control with a tooltip");
  control.setAttribute("data-one-material-hover", "");
  await ctx.hover({ selector: "[data-one-material-hover]" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-title-tooltip, .ui-tooltip:not(.ui-card)"), { capMs: 5000 });
};

const toast: Play = async (ctx) => {
  await ready(ctx);
  const [{ NoticeStack, createNoticeQueue }, { DeleteChatDialog }] = await Promise.all([
    import("../NoticeStack"),
    import("../../agent-session/acpmux/header/DeleteChatDialog"),
  ]);
  const queue = createNoticeQueue();
  queue.show({ message: "Copied the link.", duration: 0, anchor: "bottom" });
  queue.show({ message: "Move to Cloud wasn't run. Try again from the chat's menu.", duration: 0, anchor: "bottom" });
  const noop = () => undefined;
  await mountBeside(
    ctx,
    <>
      {/* The stack stands on the line above the composer, as the pane's toast layer draws it. */}
      <div style={{ position: "fixed", insetInline: 0, top: 0, height: "38%", pointerEvents: "none" }}>
        <NoticeStack queue={queue} layout="list" dismissLabel="Dismiss" label="Notifications" />
      </div>
      <DeleteChatDialog
        open
        onOpenChange={noop}
        onDismiss={noop}
        onConfirm={noop}
        title="Delete Chat"
        body="This chat and its messages are deleted from this Mac. This can't be undone."
        closeLabel="Close"
      />
    </>,
  );
  await ctx.waitFor(
    () => ctx.document.querySelector(".ui-notice") !== null && ctx.document.querySelector(".ui-dialog") !== null,
  );
};

export default agentPaneEntry({
  id: "ui.one-material",
  title: "One material: composer, popups, tooltips, toasts",
  area: "Pages",
  height: 620,
  widths: { narrow: 720, normal: 1000, wide: 1200 },
  covers: ["ui/glass/glass.css", "ui/popupSurface.css"],
  keywords: ["glass", "material", "background", "wallpaper", "popover", "tooltip", "toast", "dialog"],
  variants: {
    "folder-picker": {
      note: "The new chat's composer with the folder chip's popover open (Search folders or type a path).",
      ready: newTab(),
      snapshot: noChat(manySessions(3), { listedSessions: true }),
      native: signedIn,
      play: folderPicker,
    },
    "access-menu": {
      note: "The new chat's composer with the access (permission) menu open under the box.",
      ready: newTab(),
      snapshot: noChat(manySessions(3), { listedSessions: true }),
      native: signedIn,
      play: accessMenu,
    },
    "hover-preview": {
      note: "A tooltip on the composer's own control, and a hover card (the card every hover preview takes) over the folder chip.",
      ready: newTab(),
      snapshot: noChat(manySessions(3), { listedSessions: true }),
      native: signedIn,
      play: hoverPreview,
    },
    toast: {
      note: "Two toasts in the page's stack and the chat's Delete dialog over the composer.",
      ready: newTab(),
      snapshot: noChat(manySessions(3), { listedSessions: true }),
      native: signedIn,
      play: toast,
    },
  },
});
