// The chat's transcript as the agent pane lays it out (App.tsx): VirtualTranscript fills a fixed
// height. The test hands it rows (`window.__showRows`), as a chat's snapshots do while a reply streams.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { VirtualTranscript, type ScrollAnchor } from "../../src/agent-session/acpmux/App";
import { followTrace } from "../../src/agent-session/acpmux/followTrace";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import type { TurnFile } from "../../src/agent-session/acpmux/diff";
import { toggleTurnFold, turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { clearShadowHighlight, prepareShadowHighlight } from "./transcript-shadow-highlight.fixture";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/previewCard/previewCard.css";
import "../../src/agent-session/acpmux/changes/changes.css";
import "../../src/agent-session/acpmux/turnChanges/turnChanges.css";
import "../../src/agent-session/acpmux/summary/summary.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import "../../src/agent-session/acpmux/header/header.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/composerAttachments.css";
import "../../src/agent-session/acpmux/markdownField.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/keys.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/newtab/history.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

const view = createRoot(root);
// "Worked for" lines open and close as the pane's do: a click toggles the turn in `expanded`.
let shown: AcpmuxRow[] = [];
let rawRows = false;
// A running turn as the pane draws it by default (`__showLiveRows`): the Codex-style runs and the one
// live line at the bottom (conversation/turns.ts codexLiveTurn).
let live = false;
let expanded = new Set<string>();
// Prompts "sent" from the pane's composer (App's `chat.send`), which put the view at its latest message.
let sends = 0;
// Where the chat reopens (`__openAt`, the reader's saved place). Its row is in an older page that never
// lands, so the open keeps paging back for it, unseen, until it gives up or a prompt is sent.
let openAt: ScrollAnchor | undefined;
// The chat shown (`__showSession`), as the pane's tab switches chats.
let sessionId = "session-1";
let dock: HTMLElement | null = null;
let working = false;
const shadowMounts: Array<{ root: ReturnType<typeof createRoot>; host: HTMLElement }> = [];
let mediaMount: { root: ReturnType<typeof createRoot>; host: HTMLElement } | undefined;
const draw = () =>
  view.render(
    <VirtualTranscript
      rows={
        rawRows
          ? shown
          : live
            ? turnView(shown, expanded, { working: true, liveRuns: true, lineBelow: true })
            : turnView(shown, expanded)
      }
      sessionId={sessionId}
      onToggleActivity={(id) => {
        expanded = toggleTurnFold(shown, expanded, id);
        draw();
      }}
      expanded={expanded}
      sends={sends}
      dock={dock}
      working={working}
      openAt={openAt}
      canLoadOlder={openAt !== undefined}
      onLoadOlder={() => new Promise<void>(() => {})}
    />,
  );
(window as unknown as { __showRows: (rows: AcpmuxRow[]) => void }).__showRows = (rows) => {
  rawRows = false;
  live = false;
  shown = rows;
  draw();
};

// Focused browser regressions mount the same Pierre-backed transcript surfaces the app uses. They
// live outside the row renderer only for the test's lifetime, so the fixture can press an open shadow
// text host and verify that the transcript-level handler leaves native selection in charge.
(
  window as unknown as {
    __mountShadowSurface(rowId: string, kind: "highlighted-code" | "edit-diff-hunks"): Promise<void>;
  }
).__mountShadowSurface = async (rowId, kind) => {
  prepareShadowHighlight();
  const row = document.querySelector<HTMLElement>(`[data-row-id="${rowId}"]`);
  if (!row) throw new Error(`No row for shadow fixture: ${rowId}`);
  const mount = document.createElement("div");
  mount.id = `shadow-surface-${kind}`;
  mount.className = "selectable";
  mount.addEventListener("pointerdown", (event) => {
    mount.dataset.shadowPrevented = String(event.defaultPrevented);
  });
  (row.querySelector<HTMLElement>(".cv-md") ?? row).append(mount);
  const root = createRoot(mount);
  shadowMounts.push({ root, host: mount });
  if (kind === "highlighted-code") {
    const { HighlightedCode } = await import("../../src/agent-session/acpmux/conversation/HighlightedCode");
    root.render(<HighlightedCode code={'const keeper = "shadow code";\nreturn keeper;'} lang="ts" />);
  } else {
    const [{ EditDiffHunks }, { editPatch }] = await Promise.all([
      import("../../src/agent-session/acpmux/conversation/EditDiffHunks"),
      import("../../src/agent-session/acpmux/diff"),
    ]);
    const file: TurnFile = {
      path: "shadow-fixture.ts",
      displayPath: "shadow-fixture.ts",
      edits: [
        {
          toolId: "shadow-edit",
          numbered: false,
          hunks: [
            {
              lines: [
                { type: "context", text: 'const keeper = "shadow code";' },
                { type: "add", text: "return keeper;" },
              ],
            },
          ],
        },
      ],
      additions: 1,
      deletions: 0,
      created: false,
    };
    root.render(<EditDiffHunks file={file} patches={[editPatch(file, file.edits[0]!)]} wrap={false} />);
  }
};
(window as unknown as { __unmountShadowSurfaces(): void }).__unmountShadowSurfaces = () => {
  for (const { root, host } of shadowMounts.splice(0)) {
    root.unmount();
    host.remove();
  }
  clearShadowHighlight();
};
// Actual ReplyMedia and its native controls, inside the transcript selection event surface.
(window as unknown as { __mountReplyMedia(rowId: string): Promise<void> }).__mountReplyMedia = async (rowId) => {
  const [{ ReplyMedia }, { seedLinkStore }, { setChipHost }, { LOGIN_TESTS_MP4 }] = await Promise.all([
    import("../../src/agent-session/acpmux/chips/ReplyMedia"),
    import("../../src/agent-session/acpmux/chips/linkStore"),
    import("../../src/agent-session/acpmux/chips/host"),
    import("../../src/gallery/fixtures/toolImages"),
  ]);
  const path = "/tmp/project/gap-selection.mp4";
  seedLinkStore({ paths: { [path]: { place: "root", folder: false } } });
  setChipHost(async (method) => (method === "media.load" ? { src: `data:video/mp4;base64,${LOGIN_TESTS_MP4}` } : {}));
  const host = document.createElement("div");
  host.id = "gap-reply-media";
  host.style.cssText = "width:360px;max-width:100%";
  document.querySelector(`[data-row-id="${rowId}"] .cv-md`)!.append(host);
  const root = createRoot(host);
  mediaMount = { root, host };
  root.render(<ReplyMedia path={path} alt="Selection fixture video" />);
};
(window as unknown as { __unmountReplyMedia(): Promise<void> }).__unmountReplyMedia = async () => {
  mediaMount?.root.unmount();
  mediaMount?.host.remove();
  mediaMount = undefined;
  const { setChipHost } = await import("../../src/agent-session/acpmux/chips/host");
  setChipHost(undefined);
};
(window as unknown as { __showRawRows: (rows: AcpmuxRow[]) => void }).__showRawRows = (rows) => {
  rawRows = true;
  shown = rows;
  draw();
};
// The pane's English strings, for a test that reads the words a row draws (the rest read keys).
(window as unknown as { __loadStrings: () => Promise<void> }).__loadStrings = async () => {
  globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;
  const { setPaneLanguage } = await import("../../src/agent-session/acpmux/i18n");
  setPaneLanguage("en");
};
(window as unknown as { __showLiveRows: (rows: AcpmuxRow[]) => void }).__showLiveRows = (rows) => {
  rawRows = false;
  live = true;
  shown = rows;
  flushSync(draw);
};
(window as unknown as { __showRowsSync: (rows: AcpmuxRow[]) => void }).__showRowsSync = (rows) => {
  shown = rows;
  flushSync(draw);
};
(window as unknown as { __showSession: (id: string, rows: AcpmuxRow[]) => void }).__showSession = (id, rows) => {
  sessionId = id;
  shown = rows;
  draw();
};
(window as unknown as { __send: () => void }).__send = () => {
  sends += 1;
  draw();
};
(window as unknown as { __openAt: (anchor: ScrollAnchor) => void }).__openAt = (anchor) => {
  openAt = anchor;
  draw();
};
(window as unknown as { __followSnapshot: () => ReturnType<typeof followTrace.snapshot> }).__followSnapshot = () =>
  followTrace.snapshot();
(window as unknown as { __touchDock: (queued: boolean) => void }).__touchDock = (queued) => {
  if (!dock) {
    dock = document.createElement("div");
    Object.assign(dock.style, { position: "fixed", bottom: "0", width: "100%", pointerEvents: "none" });
    document.body.append(dock);
  }
  dock.innerHTML = queued
    ? '<div class="acpmux-queued" data-prompt-id="touch-queued" style="height:100px"></div><div class="acpmux-composer-box" style="height:80px"></div>'
    : '<div class="acpmux-composer-box" style="height:80px"></div>';
  working = true;
  flushSync(draw);
};
