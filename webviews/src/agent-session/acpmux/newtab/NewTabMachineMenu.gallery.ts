// l10n-allow-file: synthetic gallery fixture, not shipped UI.
// The New Tab page's machine menu and permission button (Leo 2026-11-07: "this cloud button, like
// the machine selection button, this padding is awkward in that new tab area. It's, like, it's just
// not centered"; "I can't click to adjust the bypass permissions button there in that new tab
// screen"; "Sign in for Cloud" showing and then vanishing as the menu opened).
// test/newtab-machine-menu.test.ts measures the menu's row insets, the button's padding, and
// whether the permission button opens its menu on a click.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, noChat } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { cloudLastSeenLook } from "../cloudLastSeen.experiment";

const newTab = (fields: Record<string, unknown> = {}) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: "/Users/you",
    home: "/Users/you",
    lastAgent: "claude",
    template: "minimal",
    startedProject: CWD,
    projects: [CWD],
    ...fields,
  },
  newSession: true,
});

const WHERE = '.nt-location .acpmux-location-picker[data-kind="computer"][data-rows="where"] button';

const ready = (ctx: PlayContext) =>
  ctx.waitFor(
    () =>
      ctx.document.querySelector(WHERE) !== null &&
      ctx.document.querySelector(".nt-foot .acpmux-access-trigger svg") !== null,
  );

const openWhere = async (ctx: PlayContext) => {
  await ready(ctx);
  await ctx.click({ selector: WHERE });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
};

const signedIn = { "cloudMachine.list": { signedIn: true, loaded: true, machines: [] } };
/// A cold start with the control plane slow or down: the app answers with the list it kept from the
/// last launch (`complete: false`), last answered by the server 4 minutes before the gallery clock.
const lastSeen = {
  "cloudMachine.list": {
    signedIn: true,
    loaded: true,
    complete: false,
    lastSeenAt: minutesAgo(4),
    machines: [
      { id: "m-dev", name: "dev box", stage: "ready" },
      { id: "m-build", name: "build box", stage: "paused" },
      { id: "m-eval", name: "eval box", stage: "paused" },
    ],
  },
};

const KEPT_ROWS = ".acpmux-env-popover.acpmux-env-machines [data-last-seen], .acpmux-env-last-seen-banner";

/// Machines… (the Where control's right-click menu): every machine, the account's Cloud ones included.
const openMachines = async (ctx: PlayContext) => {
  await ready(ctx);
  await ctx.contextMenu({ selector: WHERE });
  await ctx.click({ role: "menuitem", name: "Machines…" });
  await ctx.waitFor(() => ctx.document.querySelector(KEPT_ROWS));
};

/// One variant per look of the kept list's Cloud rows (cloudLastSeen.experiment.ts), Leo's pick.
const lastSeenVariant = (look: "dimmed-header" | "row-note" | "banner", note: string) => ({
  note,
  ready: newTab(),
  snapshot: noChat([], { listedSessions: true }),
  native: lastSeen,
  experiments: { [cloudLastSeenLook.id]: look },
  play: openMachines,
});
const signedOut = { "cloudMachine.list": { signedIn: false, loaded: true, machines: [] } };

export default agentPaneEntry({
  id: "agent-pane.new-tab-machine-menu",
  title: "New Tab machine menu",
  area: "New Tab",
  height: 420,
  covers: [
    "agent-session/acpmux/newtab/NewTabScreen.tsx#NewTabScreen",
    "agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentPicker",
    "agent-session/acpmux/cloudMachines.ts#useCloudLastSeenAt",
  ],
  variants: {
    closed: {
      note: "The strip at rest: the machine button's icon, name and chevron sit evenly in its hover pill.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      native: signedIn,
      play: ready,
    },
    where: {
      note: "Where open, signed in: This Mac, Cloud and Remote; each row's highlight is inset evenly from both edges.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      native: signedIn,
      play: openWhere,
    },
    "where-signed-out": {
      note: "Where open, signed out: still This Mac, Cloud and Another machine. Cloud signs in on Send; Sign in for Cloud is on the right-click menu, never a second Cloud row.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      native: signedOut,
      play: openWhere,
    },
    "where-slow-account": {
      note: "Where opened before the app's Cloud answer (a first launch with nothing kept): the same three rows before and after it lands.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      native: signedIn,
      nativeDelayMs: { "cloudMachine.list": 1500 },
      play: openWhere,
    },
    "where-signed-out-late": {
      note: "Where opened before the app's Cloud answer, which then says signed out: a new chat's Cloud row stays Cloud (Send signs in), and the menu keeps its rows and height.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      native: signedOut,
      nativeDelayMs: { "cloudMachine.list": 1500 },
      play: openWhere,
    },
    "last-seen-dimmed-header": lastSeenVariant(
      "dimmed-header",
      "Machines… on a cold start before the fresh Cloud list: the kept Cloud rows dimmed under one caption, Last seen 4 min ago.",
    ),
    "last-seen-row-note": lastSeenVariant(
      "row-note",
      "Machines… on a cold start before the fresh Cloud list: rows at normal weight, each one's stage reads last seen 4 min ago.",
    ),
    "last-seen-banner": lastSeenVariant(
      "banner",
      "Machines… on a cold start before the fresh Cloud list: rows unchanged, a Can't reach cmux Cloud notice with Retry over them.",
    ),
    permissions: {
      note: "The permission button under the box, clicked: its mode menu opens.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      native: signedIn,
      play: async (ctx) => {
        await ready(ctx);
        await ctx.click({ selector: ".nt-foot .acpmux-access-trigger" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-access-menu"));
      },
    },
  },
});
