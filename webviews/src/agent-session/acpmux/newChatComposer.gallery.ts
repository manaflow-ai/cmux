// l10n-allow-file: gallery fixtures (sample prompts, folders and machines), not shipped UI.
// The new chat's composer (Cmd-I's chat, Leo 2026-10-25: "what is going on with the composer area in
// the Command I section? Like, why is that a different style from everything else? It's just kind of
// strange."). It is the chat's own composer (Composer.tsx, ComposerBox.tsx): the same glass card,
// spacing and quiet row as a started chat, and the folder and computer are the location strip's chips
// (ComposerContext.tsx) a few px over the card, as the New Tab draws them. The card keeps its own
// four corners and whole rim. A chat in the workspace's private folder says so in the folder chip's
// menu, whose Choose folder… is the host's workspace folder sheet; no sentence stands over the card.
// `started` and `started-codex` are chats after their first send, to set beside; the `alt-*`
// variants are the strip's Debug styles (agentPane.debug.topStripStyle) over the same component.
// test/new-chat-composer.test.ts measures it.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, CWD, manySessions, noChat, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { setComposerLook } from "./composerLook";
import type { AcpmuxSnapshot } from "./model";

const AGENT_HOME = "/Users/you/Library/Application Support/cmux/agent-home/6b16a112-289d-4467-9675-8e6feee99481";

/// A new chat whose session has started (the prewarmed process) and reported, before its first send.
function fresh(fields: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {}, extra: Partial<AcpmuxSnapshot> = {}) {
  return noChat(manySessions(3), {
    sessionId: "prewarmed",
    summary: {
      sessionId: "prewarmed",
      cwd: AGENT_HOME,
      harness: "claude",
      model: "claude-opus-5-5",
      effort: "high",
      turnCount: 0,
      host: "This Mac",
      hostKind: "local",
      ...fields,
    },
    ...extra,
  });
}

/// Cmd-I's chat (`palette.newAgentChat`) in a workspace with no folder: a new chat for its
/// workspace (`workspaceContext`), in its private folder, whose host offers Choose Folder…
/// (`workspace.chooseFolder`).
const PRIVATE = { newSession: true, cwd: AGENT_HOME, chooseFolder: true, workspaceContext: true };

const codexLook = async (ctx: PlayContext) => {
  setComposerLook("codex", { remember: false });
  await ctx.waitFor(() => ctx.document.querySelector('[data-composer-look="codex"]'));
};

const openFolderMenu = async (ctx: PlayContext) => {
  await ctx.click({ selector: '.acpmux-composer-strip [aria-label="Folder"]' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu"));
};

/// A started chat on `harness`, after its first send.
const startedChat = (harness: "claude" | "codex" = "claude") =>
  chat(
    [
      user("Add retries to the fetch helper, with a backoff.", 12),
      assistant("Added `withRetry` to `fetchJson`: three tries with jittered backoff.", 11),
    ],
    harness === "codex" ? { harness, model: "gpt-6-astra" } : {},
  );

const LOG = (ctx: PlayContext) =>
  (ctx.document.defaultView as unknown as { cmuxGalleryLog: { method: string; params?: unknown }[] }).cmuxGalleryLog;

export default agentPaneEntry({
  id: "agent-pane.new-chat-composer",
  title: "New chat composer",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 360, normal: 720, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/FolderPopover.tsx#FolderPopover"],
  variants: {
    claude: {
      note: "Cmd-I's new chat in the workspace's private folder, Claude's look: the chat's own card, the folder and computer chips over it, no sentence above.",
      ready: PRIVATE,
      snapshot: fresh(),
    },
    codex: {
      note: "The same new chat on Codex, in Codex's look: the folder and computer tray tucked under the same card.",
      ready: PRIVATE,
      snapshot: fresh({ harness: "codex", model: "gpt-6-astra" }),
      play: codexLook,
    },
    project: {
      note: "A new chat in a project on this Mac: the folder chip names it, the branch at the strip's end.",
      ready: { newSession: true, cwd: CWD },
      snapshot: fresh({ cwd: CWD, branch: "main" }),
    },
    remote: {
      note: "A new chat on another machine: its computer chip in that machine's color; no private folder there.",
      ready: { newSession: true, cwd: "/home/dev/src/relay" },
      snapshot: fresh(
        { cwd: "/home/dev/src/relay", peer: "studio-mac", host: "studio-mac" },
        { peers: ["studio-mac"], peerKinds: { "studio-mac": "ssh" } },
      ),
    },
    "folder-menu": {
      note: "Play: open the folder chip: the private-folder note and Choose folder… are in its menu.",
      ready: PRIVATE,
      snapshot: fresh(),
      play: openFolderMenu,
    },
    "choose-folder": {
      note: "Play: the folder chip's Choose folder… opens the host's workspace folder sheet, as the old sentence's link did.",
      ready: PRIVATE,
      snapshot: fresh(),
      native: { "workspace.chooseFolder": { cwd: CWD } },
      play: async (ctx) => {
        await openFolderMenu(ctx);
        await ctx.click({ selector: '.acpmux-location-menu [data-choose=""]' });
        await ctx.waitFor(() => LOG(ctx).some(({ method }) => method === "workspace.chooseFolder"));
      },
    },
    "first-send": {
      note: "Play: on the real client, type a prompt, paste a long log (a Pasted text chip) and send: the chat starts with both.",
      ready: { transport: "mock", newSession: true, workspaceContext: true },
      snapshot: noChat([]),
      checks: {
        anchorMovePx: { value: 160, reason: "The pasted chip grows the card, then the first send clears it." },
        layoutShiftMax: { value: 0.2, reason: "The hero leaves and the first turn mounts on the send." },
        longFrameFailMs: { value: 150, reason: "The mock daemon's first session and the first turn share a frame." },
      },
      play: async (ctx) => {
        const doc = ctx.document;
        await ctx.waitFor(() => doc.querySelector(".acpmux-model"));
        await ctx.type("Why does the build fail?", { selector: ".acpmux-md" });
        const view = doc.defaultView!;
        const data = new view.DataTransfer();
        data.setData(
          "text/plain",
          Array.from({ length: 40 }, (_, index) => `[build] step ${index + 1}: compiling module ${index + 1}`).join(
            "\n",
          ),
        );
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: data });
        ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
        await ctx.waitFor(() => doc.querySelector(".acpmux-attachment-pasted"));
        await ctx.press("Enter");
        await ctx.waitFor(() => LOG(ctx).some(({ method }) => method === "acpmux session/prompt"), { capMs: 10_000 });
      },
    },
    started: {
      note: "The same composer after a chat's first send, to set beside the new chat: the same card.",
      snapshot: startedChat(),
    },
    "started-codex": {
      note: "A started Codex chat in Codex's look, to set beside `codex`: the same card.",
      snapshot: startedChat("codex"),
      play: codexLook,
    },
    "alt-bump": {
      note: "Alternative (Debug: Composer top strip style Bump): the chips in a closed rim of their own over the card.",
      ready: PRIVATE,
      snapshot: fresh(),
      documentAttributes: { "top-strip": "bump" },
    },
    "alt-tray": {
      note: "Alternative (Debug: Composer top strip style Tray): the chips in a tray tucked under the card's top edge.",
      ready: PRIVATE,
      snapshot: fresh(),
      documentAttributes: { "top-strip": "tray" },
    },
  },
});
