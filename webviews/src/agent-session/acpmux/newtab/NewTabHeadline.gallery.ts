// l10n-allow-file: gallery fixtures, not shipped UI.
// New Tab's optional headline (NewTabHeadline.tsx; Leo 2026-10-22: "new tab page let's have no
// greeting text by default... maybe as toggle but as useful toggle"): off, the page is the composer
// alone (agent-pane.new-tab, minimal-default); on (`tabs.newTabWidgets.greeting`), "What should we
// work on in <project ▾>?" with the project an inline picker. Its three looks are the
// `new-tab-headline` experiment (view Compare arms). Every variant here draws the headline: Compare
// arms starts from the first variant and the experiment matrix runs every one, so each has a picker.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";
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
/// Picks `name` from the headline's picker, as a click on the project's name and then on its row.
const pick = async (ctx: PlayContext, name: string) => {
  await ctx.waitFor(() => ctx.document.querySelector(button) !== null);
  // The computer pill sits beside the folder pill above the box, so a project name of another
  // width moves it sideways; only its row and size must hold.
  const stable: [selector: string, keepsX: boolean][] = [
    [".nt-composer", true],
    ['.nt-above .acpmux-location-picker[data-kind="computer"]', false],
    [".nt-foot .acpmux-access-trigger", true],
  ];
  const rects = () =>
    stable.map(([selector, keepsX]) => {
      const element = ctx.document.querySelector(selector);
      if (!element) throw new Error(`missing stable New Tab control: ${selector}`);
      const { x, y, width, height } = element.getBoundingClientRect();
      return [keepsX ? x : 0, y, width, height];
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
  if (ctx.document.querySelector(".acpmux-project-menu")) {
    await ctx.press("Escape");
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-project-menu") === null);
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
  },
});
