// l10n-allow-file: gallery fixtures (sample folders and machines), not shipped UI.
//
// Where the composer's project and machine menus open (locationPopover.ts). Leo, 2026-10-29:
// "project and cloudness at the top. make them open away from teh chat, which is obviously up if
// it's up, down if it's down. and stop making them take up so much space." Both pickers head the
// composer in the chat pane and on New Tab, and a menu opens on the side away from the
// conversation: down from a composer at the window's foot (the chat is above it), up from one high
// on the page (New Tab, where the chats are under it). Each play fails when a menu opens toward the
// conversation or leaves the window (composer-location-away.test.ts).
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { CWD, manySessions, noChat } from "../../gallery/fixtures/acpmux";
import { setComposerLook } from "./composerLook";

const PEERS = {
  peers: ["gpu-box", "build-mini", "eval box"],
  peerKinds: { "gpu-box": "ssh", "build-mini": "ssh", "eval box": "cloud" } as Record<string, "ssh" | "cloud">,
  peerConnected: { "gpu-box": true, "build-mini": false, "eval box": true },
  peerStates: { "gpu-box": "connected", "build-mini": "offline", "eval box": "connected" },
};

/// The account's Cloud machines (`cloudMachine.list`), one paused and one still booting.
const CLOUD_LIST = {
  signedIn: true,
  loaded: true,
  machines: [
    { id: "m-build", name: "build box", stage: "paused" },
    { id: "m-fresh", name: "fresh box", stage: "booting" },
  ],
};

const newChat = () => noChat(manySessions(4), { summary: { sessionId: "", cwd: CWD, harness: "claude" }, ...PEERS });

const newTab = () => ({
  newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude" },
  newSession: true,
});

const nextFrames = (ctx: PlayContext) =>
  new Promise<void>((done) =>
    ctx.document.defaultView!.requestAnimationFrame(() =>
      ctx.document.defaultView!.requestAnimationFrame(() => done()),
    ),
  );

/// Claude look, the strip drawn.
const claudeLook = async (ctx: PlayContext) => {
  setComposerLook("claude", { remember: false });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-context"));
};

const MENU = ".acpmux-location-menu[data-side], .acpmux-env-popover[data-side]";

/// Opens the named location control (Folder, or the Computer / Environment control) and checks
/// the menu opened away from the conversation and stays in the window.
function opensAway(control: "Folder" | "Computer", expected: "top" | "bottom") {
  return async (ctx: PlayContext) => {
    setComposerLook("claude", { remember: false });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-context"));
    await ctx.click({ role: "button", name: control === "Folder" ? "Folder" : /^(Computer|Environment)/ });
    await ctx.waitFor(() => ctx.document.querySelector(MENU));
    await nextFrames(ctx);
    const view = ctx.document.defaultView!;
    const popup = ctx.document.querySelector(MENU)!;
    const box = popup.getBoundingClientRect();
    const side = popup.getAttribute("data-side");
    const text = `side ${side}, popup ${Math.round(box.top)}-${Math.round(box.bottom)}, viewport ${view.innerHeight}`;
    if (side !== expected) throw new Error(`the ${control} menu should open ${expected}, away from the chat: ${text}`);
    if (box.top < 0 || box.bottom > view.innerHeight + 1)
      throw new Error(`the ${control} menu left the window: ${text}`);
  };
}

const NOTE = "Leo 2026-10-29: project and machine head the composer, and their menus open away from the chat.";

export default agentPaneEntry({
  id: "agent-pane.composer-context-away",
  title: "Composer project and machine menus open away from the chat",
  area: "Agent pane",
  covers: ["agent-session/acpmux/ComposerContext.tsx#ComposerContext"],
  keywords: ["project picker", "machine picker", "cloud", "location strip", "placement"],
  height: 560,
  checks: {
    longFrameFailMs: {
      value: 200,
      reason:
        "These plays test the menus' side, not their timing; a first open on a cold page loads the menu's code (50-100 ms seen). agent-pane.composer-context keeps the 33 ms bar.",
    },
  },
  variants: {
    "chat-folder": {
      note: `${NOTE} A new chat's composer sits at the pane's foot, so the folder menu opens down over the composer.`,
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      native: { "cloudMachine.list": CLOUD_LIST },
      play: opensAway("Folder", "bottom"),
    },
    "chat-computer": {
      note: `${NOTE} The machine menu of a new chat opens down too, with the account's Cloud machines and their stage.`,
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      native: { "cloudMachine.list": CLOUD_LIST },
      play: opensAway("Computer", "bottom"),
    },
    "newtab-folder": {
      note: `${NOTE} New Tab's composer sits high on the page with the chats under it, so the folder menu opens up.`,
      height: 720,
      ready: newTab(),
      snapshot: noChat(manySessions(6), PEERS),
      native: { "cloudMachine.list": CLOUD_LIST },
      play: opensAway("Folder", "top"),
    },
    "newtab-computer": {
      note: `${NOTE} New Tab's machine menu opens up as well.`,
      height: 720,
      ready: newTab(),
      snapshot: noChat(manySessions(6), PEERS),
      native: { "cloudMachine.list": CLOUD_LIST },
      play: opensAway("Computer", "top"),
    },
    // The strip's surface, the design choice (the Debug setting agentPane.debug.topStripStyle that
    // the app sets as <html data-top-strip>). Picked: the default, plain text over the box, the
    // least height and no second surface; the others stay a Debug choice.
    "strip-plain-text": {
      note: "Picked: folder and machine as plain text a few px over the box, side by side, content-sized.",
      height: 360,
      ready: newTab(),
      snapshot: noChat(manySessions(6), PEERS),
      play: claudeLook,
    },
    "strip-bump": {
      note: "Alternate (Debug): the strip as a bump of the box's fill over its top edge, a hairline round it.",
      height: 360,
      ready: newTab(),
      snapshot: noChat(manySessions(6), PEERS),
      documentAttributes: { "top-strip": "bump" },
      play: claudeLook,
    },
    "strip-tray": {
      note: "Alternate (Debug): a filled tray tucked under the box's top edge.",
      height: 360,
      ready: newTab(),
      snapshot: noChat(manySessions(6), PEERS),
      documentAttributes: { "top-strip": "tray" },
      play: claudeLook,
    },
    "strip-plus-edge": {
      note: "Alternate (Debug): plain text whose first icon stands on the + glyph's edge, not on the quiet row's icon column.",
      height: 360,
      ready: newTab(),
      snapshot: noChat(manySessions(6), PEERS),
      documentAttributes: { "top-strip": "plain" },
      play: claudeLook,
    },
  },
});
