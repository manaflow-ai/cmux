// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Auto mode's states on a chat (plans/cmux-next/auto-mode/DESIGN.md, UI-NOTES.md): a chat with Auto
// on keeps running in the Cloud when this Mac sleeps or goes offline, and comes back when the Mac
// returns. Each variant is the real pane on a chat whose row carries that `autoSession`, so every
// state can be captured without a live Cloud.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { AutoSession } from "./autoSession";

const rows = [
  user("The upload test fails about one run in ten. Find out why and fix it.", 48),
  assistant(
    "The test races the progress callback: it asserts on the final byte count before the last chunk's callback runs. I made the assertion wait for the upload's completion event and ran it 200 times with no failure.",
    46,
  ),
  user("Good. Now do the same for the download tests.", 12),
];

const auto = (over: Partial<AutoSession> = {}): AutoSession => ({
  auto: true,
  state: "local",
  here: true,
  keepInCloud: false,
  ...over,
});

const on = (autoSession: AutoSession | undefined, working = false) => {
  const snapshot = chat(rows, { title: "Retry the flaky upload test", isWorking: working });
  return { ...snapshot, summary: { ...snapshot.summary!, ...(autoSession ? { autoSession } : {}) } };
};

/// A line that waits before it shows (afterDelay.ts): a resume for 1.5 s, a dropped network for 10 s.
const shown: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-peer-copy-slot[data-shown]"), { capMs: 12_000 });
};

/// The chat menu open on the chat's Cloud rows, where Auto and Keep in Cloud sit. The submenu is
/// "Move to…" when the host names a place the chat can move, else "Environment".
const menu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.click({ role: "menuitem", name: /^(Environment|Move to…)$/ });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemcheckbox"]'));
};

/// The menu plays show which rows the menu has, not its frame time (transcript.gallery.ts loosens
/// its menu plays for the same cause).
const menuChecks = {
  longFrameFailMs: {
    value: 150,
    reason:
      "The mock daemon's attach and the first transcript mount share the menu's first frame on the CPU-only gallery VM (53 ms measured in one of four runs, begun before the click).",
  },
};

export default agentPaneEntry({
  id: "agent-pane.auto-session",
  title: "Auto: a chat that keeps running in the Cloud",
  area: "Agent pane",
  height: 520,
  covers: [
    "agent-session/acpmux/autoSession/AutoSessionBanner.tsx#AutoSessionBanner",
    "agent-session/acpmux/header/autoRow.ts#autoRows",
  ],
  variants: {
    "no-auto": {
      note: "A chat whose acpmux says nothing of Auto: nothing is drawn and the menu has no Auto row, as before.",
      snapshot: on(undefined),
    },
    local: {
      note: "Auto on, the chat runs on this Mac: nothing new is drawn.",
      snapshot: on(auto()),
    },
    cloud: {
      note: "The Cloud runs the chat (this Mac slept, or the chat started on the phone).",
      snapshot: on(auto({ state: "cloud", here: false }), true),
    },
    resuming: {
      note: "The Cloud machine is starting: said only once it has taken longer than 1.5 s.",
      snapshot: on(auto({ state: "resuming", here: false })),
      play: shown,
    },
    "coming-back": {
      note: "This Mac is back: the chat returns to it when the turn the Cloud is running ends.",
      snapshot: on(auto({ state: "coming_back", here: false }), true),
    },
    parked: {
      note: "Nobody runs the chat and nothing was sent: nothing is drawn.",
      snapshot: on(auto({ state: "parked", here: false })),
    },
    "parked-sending": {
      note: "Nobody ran the chat and the person sent: Resuming, as any paused Cloud machine says.",
      snapshot: on(auto({ state: "parked", here: false }), true),
      play: shown,
    },
    "blocked-no-machine": {
      note: "Auto is on and there is no Cloud machine: one line, with the existing Cloud start flow as its action.",
      snapshot: on(auto({ blocked: "no_machine" })),
    },
    "blocked-too-large": {
      note: "The chat's folder is too large for the Cloud to keep a copy.",
      snapshot: on(auto({ blocked: "too_large" })),
    },
    "blocked-offline": {
      note: "This Mac has had no network for a while (said after 10 s, as every dropped link is).",
      snapshot: on(auto({ blocked: "offline" })),
      play: shown,
    },
    leftover: {
      note: "This Mac made changes after the chat moved to the Cloud: they were kept aside, with Show, Apply and Discard.",
      snapshot: on(auto({ leftover: { files: 3 } })),
    },
    "leftover-in-cloud": {
      note: "The kept-changes notice under the line of a chat the Cloud still runs.",
      snapshot: on(auto({ state: "coming_back", here: false, leftover: { files: 3 } }), true),
    },
    "menu-auto-off": {
      note: "The chat menu's Cloud rows: Auto, off.",
      snapshot: on(auto({ auto: false })),
      play: menu,
      checks: menuChecks,
    },
    "menu-in-cloud": {
      note: "While the Cloud runs the chat: Auto is on and cannot be turned off, and Keep in Cloud is offered.",
      snapshot: on(auto({ state: "cloud", here: false, keepInCloud: true }), true),
      play: menu,
      checks: menuChecks,
    },
  },
});
