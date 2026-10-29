// l10n-allow-file: gallery fixtures, not shipped UI.
// New Tab's optional headline (NewTabHeadline.tsx; Leo 2026-10-22: "new tab page let's have no
// greeting text by default... maybe as toggle but as useful toggle"): off, the page is the composer
// alone (agent-pane.new-tab, minimal-default); on (`tabs.newTabWidgets.greeting`), "What should we
// work on in <project ▾>?" with the project an inline picker. Its three looks are the
// `new-tab-headline` experiment (view Compare arms). Every variant here draws the headline: Compare
// arms starts from the first variant and the experiment matrix runs every one, so each has a picker.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, manySessions, noChat, session } from "../../../gallery/fixtures/acpmux";
import { newTabHeadline } from "./headline.experiment";

const PROJECTS = [CWD, "/Users/you/src/cmux", "/Users/you/src/manaflow"];
const page = (pageWidgets: string[]) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    template: "minimal",
    projects: PROJECTS,
    pageWidgets,
  },
  newSession: true,
});

const button = ".nt-headline .acpmux-project-button";
const machineButton = '.nt-headline-machine-picker button[aria-haspopup="dialog"]';
const composerMachineButton = '.acpmux-composer-strip [data-kind="computer"] button';
const machinePage = () => ({
  ...page(["greeting"]),
  newTab: { ...page(["greeting"]).newTab, cwd: "/Users/you", host: "studio" },
});
const machineSnapshot = () =>
  noChat(
    [
      session({
        sessionId: "remote-api",
        title: "API request retries",
        cwd: "/home/dev/api",
        peer: "devbox",
        host: "devbox",
      }),
    ],
    {
      peers: ["devbox"],
      peerKinds: { devbox: "ssh" },
      peerConnected: { devbox: true },
      peerStates: { devbox: "connected" },
    },
  );

// The head fixture can overlay the base for a before/after: the base opens its existing
// composer computer picker, while the head opens the new inline machine picker.
const openMachine = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-headline") !== null);
  await ctx.click({ selector: ctx.document.querySelector(machineButton) ? machineButton : composerMachineButton });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]') !== null);
};
const pickRemoteMachine = async (ctx: PlayContext) => {
  const stable = [".nt-headline", ".nt-headline-text", ".nt-headline-choose", ".nt-composer"];
  const rects = () => stable.map((selector) => ctx.document.querySelector(selector)?.getBoundingClientRect().toJSON());
  const before = JSON.stringify(rects());
  await openMachine(ctx);
  await ctx.click({ role: "option", name: /^devbox/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu") === null);
  await ctx.waitFor(
    () =>
      (ctx.document.querySelector(machineButton) ?? ctx.document.querySelector(composerMachineButton))
        ?.getAttribute("aria-label")
        ?.includes("devbox") ?? false,
  );
  if (JSON.stringify(rects()) !== before) throw new Error("Machine selection moved the headline or composer");
};
/// Picks `name` from the headline's picker, as a click on the project's name and then on its row.
const pick = async (ctx: PlayContext, name: string) => {
  await ctx.waitFor(() => ctx.document.querySelector(button) !== null);
  const stable = [
    ".nt-composer",
    '.nt-foot .acpmux-location-picker[data-kind="computer"]',
    ".nt-foot .acpmux-access-trigger",
  ];
  const rects = () =>
    stable.map((selector) => {
      const element = ctx.document.querySelector(selector);
      if (!element) throw new Error(`missing stable New Tab control: ${selector}`);
      const { x, y, width, height } = element.getBoundingClientRect();
      return [x, y, width, height];
    });
  const before = rects();
  await ctx.click({ selector: button });
  await ctx.click({ role: "option", name: new RegExp(`^${name} /`) });
  await ctx.waitFor(() => ctx.document.querySelector(".nt-headline-text")?.textContent?.includes(name) ?? false);
  const after = rects();
  if (after.some((rect, i) => rect.some((value, j) => Math.abs(value - before[i]![j]!) > 0.5)))
    throw new Error("project selection moved a stable New Tab control");
};
/// The compare view's start, from any variant's played state: the menu closed and cmux picked. A
/// variant that already picked cmux (or left its menu open) is brought there without a second pick.
const start = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(button) !== null);
  if (ctx.document.querySelector(".acpmux-project-menu, .acpmux-location-menu")) {
    await ctx.press("Escape");
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-menu, .acpmux-location-menu") === null);
  }
  if (ctx.document.querySelector(machineButton)?.textContent?.includes("devbox")) {
    await openMachine(ctx);
    await ctx.click({ role: "option", name: /^studio/ });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu") === null);
  }
  if (!ctx.document.querySelector(".nt-headline-text")?.textContent?.includes("cmux")) await pick(ctx, "cmux");
};

export default agentPaneEntry({
  id: "agent-pane.new-tab-headline",
  title: "New Tab headline",
  area: "New Tab",
  height: 560,
  checks: {
    layoutShiftMax: {
      value: 0.001,
      reason:
        "The content-sized footer project chevron follows a newly selected label. The play separately requires unchanged composer, machine and mode rectangles; reopening preserves the selected headline menu anchor.",
    },
  },
  covers: ["agent-session/acpmux/newtab/NewTabHeadline.tsx#NewTabHeadline"],
  experiment: {
    definition: newTabHeadline,
    setup: start,
    script: [
      {
        name: "open the picker",
        run: async (ctx) => {
          await ctx.click({ selector: button });
          await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-menu") !== null);
        },
      },
    ],
  },
  variants: {
    on: {
      note: 'Ask What to Work On turned on, before a pick: "What should we work on?" over the composer, Choose project under it.',
      ready: page(["greeting"]),
      snapshot: noChat(manySessions(12)),
      play: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".nt-headline") !== null),
    },
    picked: {
      note: 'A project picked in the headline: "What should we work on in cmux?", cmux underlined with a chevron; the composer\'s strip names the same folder.',
      ready: page(["greeting"]),
      snapshot: noChat(manySessions(12)),
      play: (ctx) => pick(ctx, "cmux"),
    },
    "picker-open": {
      note: "The headline's picker open under the question: the recent projects with a search field, Browse and Do not work in a project.",
      ready: page(["greeting"]),
      snapshot: noChat(manySessions(12)),
      play: async (ctx) => {
        await pick(ctx, "cmux");
        const anchor = ctx.document.querySelector(button)!.getBoundingClientRect();
        await ctx.click({ selector: button });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-menu") !== null);
        const opened = ctx.document.querySelector(button)!.getBoundingClientRect();
        if ((["x", "y", "width", "height"] as const).some((key) => Math.abs(opened[key] - anchor[key]) > 0.5))
          throw new Error("reopening moved the selected headline menu anchor");
      },
    },
    "machine-no-project": {
      note: "Optional greeting on, no project selected: studio is the inline machine picker; Choose project stays below the question.",
      ready: machinePage(),
      snapshot: machineSnapshot(),
      play: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".nt-headline-choose") !== null),
    },
    "machine-picker-open": {
      note: "The no-project machine picker lists studio and a connected SSH peer, devbox. The base capture opens the composer's computer picker.",
      ready: machinePage(),
      snapshot: machineSnapshot(),
      play: openMachine,
    },
    "machine-remote": {
      note: "Pick devbox from the machine picker: the no-project headline scopes work to devbox, whose session supplies the /home/dev/api project.",
      ready: machinePage(),
      snapshot: machineSnapshot(),
      checks: {
        layoutShiftMax: {
          value: 0.0001,
          reason:
            "Changing studio to devbox resizes the invisible button hit-area ::before (Chromium measured 0.0000875; base 0.0000433). The play asserts unchanged headline, text, project chooser and composer rectangles.",
        },
      },
      play: pickRemoteMachine,
    },
  },
});
