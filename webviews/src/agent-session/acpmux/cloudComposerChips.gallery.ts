// l10n-allow-file: gallery fixtures (team names, a mode name), not shipped UI.
// A new chat's composer with Cloud picked, the prompt empty: every chip of the location strip and
// the Mode chip shows its whole label, the Mode chip names a mode (never the bare "Mode" placeholder),
// and a team the account no longer has is never named in the team tag. This is the gallery half of
// scripts/cmux-next/cloud-composer-journey.py's matrix. Leo, 2026-11-10, of the nightly's Cloud
// composer ("Cl…", "Mode", a removed team still named): "how did NONE of these work/get tested?",
// "i already told you to test these", "did you guys not test these". Each play throws, naming the
// chip, when the composer shows any of them.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";

const FIELD = ".acpmux-composer-prompt [contenteditable='true']";
const STRIP = ".acpmux-composer-context";
const PLACEHOLDER = "Mode";
const LONG_TEAM = "leo@cmux.com's";
const PERSONAL_ID = "team_0123456789abcdef0123";

type Frame = Window & { cmuxAcpmuxDebug?: { runMode(mode?: string): { runMode?: string | null } } };
type Team = { name: string; personal: boolean };

/// A new chat in a trusted folder of the mock daemon, where the host offers Cloud.
const ready = { transport: "mock", newSession: true, sandboxState: true, cwd: "~/code/cmux" };

/// Set when the pane's `cloudMachine.list` was answered: the team it names has reached the page.
let listAnswered = false;

/// The app's `cloudMachine.list` reply: signed in, no machines, `team` the active team. `teams` is the
/// account's team list as the team menu has it (a removed team is not on it).
const cloudList = (team: Team, teams: { id: string; name: string }[]) => () => {
  listAnswered = true;
  return { signedIn: true, loaded: true, machines: [], team, teams };
};

const native = (team: Team, teams: { id: string; name: string }[]) => ({
  "sandbox.state": {},
  "transport.gesture": { ticket: "gallery" },
  "cloudMachine.list": cloudList(team, teams),
});

const visible = (element: Element) => {
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== "hidden";
};
const textOf = (element: Element) => (element.textContent ?? "").replace(/\s+/g, " ").trim();
const frames = (view: Window) =>
  new Promise<void>((resolve) => view.requestAnimationFrame(() => view.requestAnimationFrame(() => resolve())));

/// Cloud picked on a new chat, the prompt empty, the account's reply read.
async function pickCloud(ctx: PlayContext) {
  listAnswered = false;
  const frame = ctx.document.defaultView as Frame;
  await ctx.waitFor(() => ctx.document.querySelector(FIELD), { capMs: 10_000 });
  await ctx.waitFor(() => frame.cmuxAcpmuxDebug?.runMode("cloud").runMode === "cloud", { capMs: 10_000 });
  await ctx.waitFor(
    () =>
      [...ctx.document.querySelectorAll(`${STRIP} .acpmux-location-button`)].some((button) =>
        /cloud/i.test(button.getAttribute("aria-label") ?? ""),
      ),
    { capMs: 10_000 },
  );
  await ctx.waitFor(() => listAnswered, { capMs: 10_000 });
  await frames(frame);
}

/// Each chip's label text that is cut, ends in "…", or reads the bare placeholder.
function chipProblems(document: Document): string[] {
  const problems: string[] = [];
  const width = document.defaultView!.innerWidth;
  const cut = (chip: string, element: Element) => {
    const text = textOf(element);
    if (!text) return;
    if (element.scrollWidth > element.clientWidth + 1)
      problems.push(
        `${chip} chip is truncated at ${width}px: “${text}” needs ${element.scrollWidth}px, shows ${element.clientWidth}px`,
      );
    else if (text.endsWith("…")) problems.push(`${chip} chip is truncated at ${width}px: it reads “${text}”`);
  };
  for (const button of document.querySelectorAll(`${STRIP} .acpmux-location-button`)) {
    if (!visible(button)) continue;
    const chip = `the “${(button.getAttribute("aria-label") ?? textOf(button)).split(":")[0]}”`;
    const parts = [
      ...button.querySelectorAll(
        ".acpmux-location-label, .acpmux-location-head, .acpmux-location-tail, .acpmux-team-tag-name",
      ),
    ].filter(visible);
    for (const part of parts.length ? parts : [button]) cut(chip, part);
  }
  const modes = [...document.querySelectorAll(".acpmux-mode-text")].filter(
    (text) => visible(text) && !text.closest("[role='menu']"),
  );
  for (const text of modes) {
    cut("the Mode", text);
    if (textOf(text) === PLACEHOLDER)
      problems.push(`the Mode chip reads the bare placeholder “${PLACEHOLDER}” instead of a mode at ${width}px`);
  }
  if (modes.length === 0) problems.push(`the Mode chip is not shown at ${width}px`);
  return problems;
}

const assertChips: Play = async (ctx) => {
  const problems = chipProblems(ctx.document);
  if (problems.length) throw new Error(problems.join("; "));
};

/// Bypass permissions picked from the Mode menu, as a click picks it.
const pickBypass: Play = async (ctx) => {
  const trigger = ctx.document.querySelector("button.acpmux-access-trigger");
  if (!trigger) {
    const shown = textOf(ctx.document.querySelector(".acpmux-mode-text") ?? ctx.document.body);
    throw new Error(`the Mode chip is not a menu with Cloud picked (it reads “${shown}”): Bypass permissions cannot be picked`);
  }
  await ctx.click({ selector: "button.acpmux-access-trigger" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-access-menu"), { capMs: 5_000 });
  const row = [...ctx.document.querySelectorAll(".acpmux-access-menu [role='menuitemradio']")].find((item) =>
    /bypass permissions/i.test(textOf(item)),
  );
  if (!row) throw new Error("the Mode menu with Cloud picked has no Bypass permissions row");
  await ctx.click({ role: "menuitemradio", name: /bypass permissions/i });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-access-menu"), { capMs: 5_000 });
};

const variant = (note: string, team: Team, teams: { id: string; name: string }[], play: Play): AgentPaneVariant => ({
  note,
  ready,
  native: native(team, teams),
  snapshot: noChat([]),
  play,
});

export default agentPaneEntry({
  id: "agent-pane.cloud-composer-chips",
  title: "Cloud composer chips",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  anchors: [{ selector: STRIP }, { selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/ComposerPickers.tsx",
    "agent-session/acpmux/TeamTag.tsx#TeamTag",
    "agent-session/acpmux/cloudMachines.ts",
  ],
  keywords: ["cloud", "composer", "chips", "truncation", "mode", "team", "bypass", "removed team"],
  variants: {
    "personal-default": variant(
      "Cloud picked in the person's own team, the default mode: the Cloud chip, its team and the Mode chip show whole, and the Mode chip names a mode.",
      { name: "Personal", personal: true },
      [{ id: PERSONAL_ID, name: "Personal" }],
      async (ctx) => {
        await pickCloud(ctx);
        await assertChips(ctx);
      },
    ),
    "team-bypass": variant(
      `Cloud picked in a shared team with a long name (“${LONG_TEAM}”), Bypass permissions picked from the Mode menu: every chip shows whole.`,
      { name: LONG_TEAM, personal: false },
      [
        { id: PERSONAL_ID, name: "Personal" },
        { id: "team_stack_leo", name: LONG_TEAM },
      ],
      async (ctx) => {
        await pickCloud(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(`${STRIP} .acpmux-team-tag`), { capMs: 10_000 });
        await pickBypass(ctx);
        await assertChips(ctx);
      },
    ),
    "removed-team": variant(
      `The app's reply names an active team (“${LONG_TEAM}”) the account's team list no longer has, as a removal leaves it: the team tag never names it.`,
      { name: LONG_TEAM, personal: false },
      [{ id: PERSONAL_ID, name: "Personal" }],
      async (ctx) => {
        await pickCloud(ctx);
        const named = [...ctx.document.querySelectorAll(".acpmux-team-tag")].filter((tag) =>
          textOf(tag).includes(LONG_TEAM),
        );
        if (named.length)
          throw new Error(
            `the team tag names the removed team “${LONG_TEAM}” (${named.length} tag${named.length > 1 ? "s" : ""}); it is not in the account's team list`,
          );
        await assertChips(ctx);
      },
    ),
  },
});
