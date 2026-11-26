// l10n-allow-file: gallery fixtures (team names, a mode name), not shipped UI.
// A new chat's composer with Cloud picked, the prompt empty: every chip of the location strip and
// the Mode chip shows its whole label, the Mode chip names a mode (never the bare "Mode" placeholder),
// the Cloud chip says only Cloud (Austin, 2026-11-16: "get rid of the austin wang's team part just
// have cloud and that's it"), and the Environment menu's Cloud row says only Cloud too, never the
// active team (https://github.com/manaflow-ai/cmux/issues/45695). This is the gallery half of
// scripts/cmux-next/cloud-composer-journey.py's matrix. Leo, 2026-11-10, of the nightly's Cloud
// composer ("Cl…", "Mode", a removed team still named): "how did NONE of these work/get tested?",
// "i already told you to test these", "did you guys not test these". Each play throws, naming the
// chip, when the composer shows any of them.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";
import { COMPOSER_EDITOR, MODEL_PICKER } from "./composerSelectors";

const FIELD = COMPOSER_EDITOR;
const STRIP = ".acpmux-composer-context";
const PLACEHOLDER = "Mode";
const LONG_TEAM = "leo@cmux.com's";
const PERSONAL_ID = "team_0123456789abcdef0123";

type Frame = Window & { cmuxAcpmuxDebug?: { runMode(mode?: string): { runMode?: string | null } } };
type Team = { name: string; personal: boolean };
/// One team of the account's list as the reply's `teams` has it (the team menu's rows).
type TeamRow = { id: string; name: string; personal: boolean };

/// A new chat in a trusted folder of the mock daemon, where the host offers Cloud.
const ready = { transport: "mock", newSession: true, sandboxState: true, cwd: "~/code/cmux" };

/// Set when the pane's `cloudMachine.list` was answered (it asks once, on mount, before the play):
/// the team it names has reached the page.
let listAnswered = false;

/// The app's `cloudMachine.list` reply: signed in, no machines, `team` the active team. `teams` is the
/// account's team list as the team menu has it (a removed team is not on it).
const cloudList = (team: Team, teams: TeamRow[]) => () => {
  listAnswered = true;
  return { signedIn: true, loaded: true, machines: [], team, teams };
};

const native = (team: Team, teams: TeamRow[]) => ({
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
  await environmentSettled(ctx);
}

/// The strip has settled after Cloud was picked, so each label is measured at rest.
async function environmentSettled(ctx: PlayContext) {
  await frames(ctx.document.defaultView!);
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
    if (button.querySelector(".acpmux-team-tag"))
      problems.push(`${chip} chip names the team (“${textOf(button.querySelector(".acpmux-team-tag")!)}”)`);
    const parts = [
      ...button.querySelectorAll(".acpmux-location-label, .acpmux-location-head, .acpmux-location-tail"),
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
  problems.push(...environmentProblems(document));
  return problems;
}

/// Cloud's environment is a Settings choice (Settings > Cloud, Default image; cmux#51731), not a
/// composer chip: with Cloud picked the strip shows no Environment chip at any width.
function environmentProblems(document: Document): string[] {
  const width = document.defaultView!.innerWidth;
  const chip = document.querySelector(`${STRIP} .acpmux-cloud-env, ${STRIP} [aria-label^="Cloud environment"]`);
  return chip ? [`the composer shows an Environment chip with Cloud picked at ${width}px`] : [];
}

/// The chips at the stage's width, then at the narrow 400 px a split leaves (the health check renders
/// the normal width only, so the play narrows the pane itself).
const NARROW = 400;
/// The entry's normal stage, where every chip shows whole.
const WIDE_ENOUGH = 760;
/// The full width a wide pane gives the composer.
const FULL = 1100;
async function assertChips(ctx: PlayContext, before: string[] = []) {
  const problems = [...before, ...chipProblems(ctx.document)];
  if ((ctx.document.defaultView?.innerWidth ?? NARROW) > NARROW) {
    await ctx.resize(NARROW);
    await environmentSettled(ctx);
    problems.push(...chipProblems(ctx.document));
  }
  if (problems.length) throw new Error(problems.join("; "));
}

/// The Environment menu's Cloud row, the menu opened, then closed: what is wrong if it names a team
/// or its label reads anything but Cloud (https://github.com/manaflow-ai/cmux/issues/45695).
async function cloudRowProblems(ctx: PlayContext): Promise<string[]> {
  await ctx.click({ role: "button", name: /^Environment/ });
  const row = () => ctx.document.querySelector('.acpmux-env-popover [data-mode="cloud"]');
  await ctx.waitFor(row, { capMs: 5_000 });
  const problems: string[] = [];
  const tag = row()!.querySelector(".acpmux-team-tag");
  if (tag) problems.push(`the Environment menu's Cloud row names the team (“${textOf(tag)}”)`);
  const label = textOf(row()!.querySelector(".acpmux-menu-label") ?? row()!);
  if (label !== "Cloud") problems.push(`the Environment menu's Cloud row reads “${label}”, not Cloud`);
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-env-popover"), { capMs: 5_000 });
  return problems;
}

/// Bypass permissions picked from the Mode menu, as a click picks it.
const pickBypass: Play = async (ctx) => {
  const trigger = ctx.document.querySelector("button.acpmux-access-trigger");
  if (!trigger) {
    const shown = textOf(ctx.document.querySelector(".acpmux-mode-text") ?? ctx.document.body);
    throw new Error(
      `the Mode chip is not a menu with Cloud picked (it reads “${shown}”): Bypass permissions cannot be picked`,
    );
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

const variant = (note: string, team: Team, teams: TeamRow[], play: Play): AgentPaneVariant => ({
  note,
  ready,
  native: native(team, teams),
  snapshot: noChat([]),
  play,
});

/// One Cloud state of the strip: the account's reply, and the steps that reach it (each returns the
/// problems it found on the way, which the play reports with the chips').
type State = { note: string; team: Team; teams: TeamRow[]; reach(ctx: PlayContext): Promise<string[]> };

const STATES: Record<"personal-default" | "team-bypass" | "removed-team", State> = {
  "personal-default": {
    note: "Cloud picked in the person's own team, the default mode: the Cloud chip says only Cloud, it and the Mode chip show whole, and the Mode chip names a mode.",
    team: { name: "Personal", personal: true },
    teams: [{ id: PERSONAL_ID, name: "Personal", personal: true }],
    async reach(ctx) {
      await pickCloud(ctx);
      return [];
    },
  },
  "team-bypass": {
    note: `Cloud picked in a shared team with a long name (“${LONG_TEAM}”), Bypass permissions picked from the Mode menu: the Cloud chip and the Environment menu's Cloud row say only Cloud and every chip shows whole.`,
    team: { name: LONG_TEAM, personal: false },
    teams: [
      { id: PERSONAL_ID, name: "Personal", personal: true },
      { id: "team_stack_leo", name: LONG_TEAM, personal: false },
    ],
    async reach(ctx) {
      await pickCloud(ctx);
      const refused = await pickBypass(ctx).then(
        () => [],
        (error: unknown) => [(error as Error).message],
      );
      return [...refused, ...(await cloudRowProblems(ctx))];
    },
  },
  "removed-team": {
    note: `The app's reply names an active team (“${LONG_TEAM}”) the account's team list no longer has, as a removal leaves it: nothing names it, and the Environment menu's Cloud row says only Cloud.`,
    team: { name: LONG_TEAM, personal: false },
    teams: [{ id: PERSONAL_ID, name: "Personal", personal: true }],
    async reach(ctx) {
      await pickCloud(ctx);
      const named = [...ctx.document.querySelectorAll(".acpmux-team-tag")].filter((tag) =>
        textOf(tag).includes(LONG_TEAM),
      );
      const removed = named.length
        ? [
            `the team tag names the removed team “${LONG_TEAM}” (${named.length} tag${named.length > 1 ? "s" : ""}); it is not in the account's team list`,
          ]
        : [];
      return [...removed, ...(await cloudRowProblems(ctx))];
    },
  },
};

/// Each state at the stage's width and then 400 px (the original plays).
const atStage = (state: State) =>
  variant(state.note, state.team, state.teams, async (ctx) => assertChips(ctx, await state.reach(ctx)));

/// Each state with the pane resized to one width and left there, so the stage shows the strip as it
/// rests at that width: full (1100 px), the 760 px stage, and the 400 px a split leaves.
const WIDTHS = { full: FULL, "760": WIDE_ENOUGH, "400": NARROW } as const;
const atWidth = (name: string, state: State, label: keyof typeof WIDTHS) => {
  const width = WIDTHS[label];
  const shows = "no Environment chip, and every chip shows whole";
  return variant(
    `${name} at ${label === "full" ? "full width" : `${width} px`}: ${shows}.`,
    state.team,
    state.teams,
    async (ctx) => {
      const before = await state.reach(ctx);
      if (ctx.document.defaultView!.innerWidth !== width) {
        await ctx.resize(width);
        await environmentSettled(ctx);
      }
      const problems = [...before, ...chipProblems(ctx.document)];
      if (problems.length) throw new Error(problems.join("; "));
    },
  );
};

const widthVariants = Object.fromEntries(
  Object.entries(STATES).flatMap(([name, state]) =>
    (Object.keys(WIDTHS) as (keyof typeof WIDTHS)[]).map((label) => [`${name}-${label}`, atWidth(name, state, label)]),
  ),
);

/// The model chip holds still (cmux#53226, the person: "we need to make sure that the model picker doesn't move
/// around and stuff when i select cloud, change modes and stuff"). Every frame from This Mac at rest through Cloud,
/// a Mode pick and back to This Mac, the model chip's box is where it was at rest (within rounding), and the
/// location strip's chips keep their row. A frame with no model chip is a move too.
const MODEL = MODEL_PICKER;
const SHIFT_PX = 1;
type Box = { x: number; y: number; width: number; height: number };
const boxOf = (element: Element | null): Box | null => {
  if (!element) return null;
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0
    ? { x: rect.left, y: rect.top, width: rect.width, height: rect.height }
    : null;
};
const moved = (box: Box | null, rest: Box) =>
  !box ||
  Math.abs(box.x - rest.x) > SHIFT_PX ||
  Math.abs(box.y - rest.y) > SHIFT_PX ||
  Math.abs(box.width - rest.width) > SHIFT_PX ||
  Math.abs(box.height - rest.height) > SHIFT_PX;
const shown = (box: Box | null) =>
  box ? `${Math.round(box.x)},${Math.round(box.y)} ${Math.round(box.width)}x${Math.round(box.height)}` : "gone";

const modelHoldsStill: Play = async (ctx) => {
  const view = ctx.document.defaultView as Frame;
  await ctx.waitFor(() => ctx.document.querySelector(FIELD), { capMs: 10_000 });
  await ctx
    .waitFor(() => boxOf(ctx.document.querySelector(MODEL)) && ctx.document.querySelector(".acpmux-mode-text"), {
      capMs: 10_000,
    })
    .catch((error: Error) => {
      const has = (selector: string) => (ctx.document.querySelector(selector) ? "shown" : "missing");
      throw new Error(`at rest: model chip ${has(MODEL)}, Mode text ${has(".acpmux-mode-text")}: ${error.message}`);
    });
  // At rest: the model chip's box unchanged for 5 frames running (its label can arrive after the chip shows).
  let rest = boxOf(ctx.document.querySelector(MODEL))!;
  for (let still = 0, frame = 0; still < 5 && frame < 120; frame++) {
    await frames(view);
    const now = boxOf(ctx.document.querySelector(MODEL));
    if (now && !moved(now, rest)) still++;
    else {
      still = 0;
      if (now) rest = now;
    }
  }
  const stripTop = () => boxOf(ctx.document.querySelector(STRIP))?.y;
  const restStrip = stripTop();
  // Each frame's model box, by the step it belongs to.
  let step = "This Mac";
  const problems: string[] = [];
  let sampling = true;
  const sample = () => {
    if (!sampling) return;
    const box = boxOf(ctx.document.querySelector(MODEL));
    if (moved(box, rest) && problems.length < 6)
      problems.push(`${step}: the model chip is at ${shown(box)}, it rested at ${shown(rest)}`);
    const top = stripTop();
    if (restStrip !== undefined && top !== undefined && Math.abs(top - restStrip) > SHIFT_PX && problems.length < 6)
      problems.push(`${step}: the location strip's row moved from y ${Math.round(restStrip)} to ${Math.round(top)}`);
    view.requestAnimationFrame(sample);
  };
  view.requestAnimationFrame(sample);
  try {
    step = "Cloud picked";
    await pickCloud(ctx);
    await frames(view);
    step = "a Mode picked with Cloud";
    await pickBypass(ctx);
    await frames(view);
    step = "This Mac picked again";
    await ctx.waitFor(() => view.cmuxAcpmuxDebug?.runMode("persistent").runMode === "persistent", { capMs: 10_000 });
    // The Environment chip stays mounted as it closes (its slot's data-shown turns false), so wait on the slot.
    await ctx.waitFor(() => !ctx.document.querySelector(`${STRIP} .acpmux-cloud-env-slot[data-shown="true"]`), {
      capMs: 10_000,
    });
    await frames(view);
    await frames(view);
  } catch (error) {
    // Name the step a wait stalled in, and where the composer was then.
    const mode = String(view.cmuxAcpmuxDebug?.runMode().runMode ?? "unknown");
    throw new Error(`${step} (run mode ${mode}): ${(error as Error).message}`);
  } finally {
    sampling = false;
  }
  if (problems.length) throw new Error(problems.join("; "));
};

const holdsStill = (width: number): AgentPaneVariant => ({
  ...variant(
    `The model chip holds still at ${width} px: This Mac, Cloud, a Mode pick and This Mac again move it by no pixel (cmux#53226).`,
    STATES["personal-default"].team,
    STATES["personal-default"].teams,
    async (ctx) => {
      if (ctx.document.defaultView!.innerWidth !== width) await ctx.resize(width);
      await modelHoldsStill(ctx);
    },
  ),
});

export default agentPaneEntry({
  id: "agent-pane.cloud-composer-chips",
  title: "Cloud composer chips",
  area: "Agent pane",
  height: 420,
  widths: { narrow: NARROW, normal: WIDE_ENOUGH, wide: FULL },
  anchors: [{ selector: STRIP }, { selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/ComposerPickers.tsx",
    "agent-session/acpmux/EnvironmentPicker.tsx",
    "agent-session/acpmux/cloudMachines.ts",
  ],
  keywords: [
    "cloud",
    "composer",
    "chips",
    "truncation",
    "mode",
    "team",
    "bypass",
    "removed team",
    "environment",
    "narrow",
  ],
  variants: {
    "personal-default": atStage(STATES["personal-default"]),
    "team-bypass": atStage(STATES["team-bypass"]),
    "removed-team": atStage(STATES["removed-team"]),
    ...widthVariants,
    "model-holds-still-full": holdsStill(FULL),
    "model-holds-still-760": holdsStill(WIDE_ENOUGH),
    "model-holds-still-400": holdsStill(NARROW),
  },
});
