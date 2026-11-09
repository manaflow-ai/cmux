// l10n-allow-file: gallery fixtures (sample setup states), not shipped UI.
// "Set Up cmux" on Home (goal next-first-run-setup): the card in each look, on a stage shaped like
// Home's chat column with the composer under it, in three states: a fresh Mac (nothing installed), a
// Mac with classic cmux's session, and one row left; and the cmux Classic row's own states (the launch's
// classic import asks there: still open, answered).
import { componentEntry } from "../../../../gallery/format";
import { cardStrings } from "../strings";
import { SetupCard, type SetupLook } from "./SetupCard";
import type { SetupState } from "./setupModel";

const strings = cardStrings();
// A fixed save time, so the stills do not change from run to run.
const savedAt = new Date(2026, 10, 5, 22, 26).getTime();

type Fixture = "fresh" | "classic" | "classicOpen" | "classicDeclined" | "mostlyDone" | "installing" | "unverified";

const FIXTURES: Record<Fixture, SetupState> = {
  fresh: {
    agents: [
      { id: "claude", name: "Claude Code", state: "missing" },
      { id: "codex", name: "Codex", state: "missing" },
    ],
    account: { signedIn: false },
    cli: "missing",
    classic: null,
  },
  classic: {
    agents: [
      { id: "claude", name: "Claude Code", state: "signedOut" },
      { id: "codex", name: "Codex", state: "missing" },
    ],
    history: { done: false },
    account: { signedIn: false },
    cli: "other",
    classic: { workspaces: 27, app: "cmux", savedAt, resumes: true },
  },
  classicOpen: {
    agents: [
      { id: "claude", name: "Claude Code", state: "missing" },
      { id: "codex", name: "Codex", state: "missing" },
    ],
    account: { signedIn: false },
    cli: "other",
    classic: { workspaces: 27, app: "cmux NIGHTLY", savedAt, running: true },
  },
  classicDeclined: {
    agents: [
      { id: "claude", name: "Claude Code", state: "signedOut" },
      { id: "codex", name: "Codex", state: "missing" },
    ],
    account: { signedIn: false },
    cli: "other",
    classic: { workspaces: 27, app: "cmux", savedAt, resumes: true, answered: "declined" },
  },
  mostlyDone: {
    agents: [
      { id: "claude", name: "Claude Code", state: "signedIn" },
      { id: "codex", name: "Codex", state: "missing" },
    ],
    account: { signedIn: true, email: "you@example.com" },
    cli: "missing",
    classic: { workspaces: 27, app: "cmux", savedAt, answered: "imported" },
  },
  installing: {
    agents: [
      { id: "claude", name: "Claude Code", state: "installing" },
      { id: "codex", name: "Codex", state: "missing" },
    ],
    account: { signedIn: false },
    cli: "missing",
    classic: null,
  },
  unverified: {
    agents: [
      { id: "claude", name: "Claude Code", state: "unverified" },
      { id: "codex", name: "Codex", state: "missing" },
    ],
    account: { signedIn: true, email: "you@example.com" },
    cli: "installed",
    classic: null,
  },
};

interface Props {
  look: SetupLook;
  fixture: Fixture;
}

function Stage({ look, fixture }: Props) {
  const card = (
    <SetupCard strings={strings} state={FIXTURES[fixture]} look={look} onAction={() => {}} onHide={() => {}} />
  );
  if (look === "window") return <div className="hm-gallery-setup-window">{card}</div>;
  return (
    <div className="hm-gallery-setup">
      <div className="hm-gallery-setup__chat">
        <div className="hm-gallery-setup__bubble">Welcome to cmux! I'm Chief.</div>
      </div>
      {card}
      <div className="hm-gallery-setup__composer">Ask Chief anything</div>
    </div>
  );
}

const states: [Fixture, string][] = [
  ["fresh", "fresh"],
  ["classic", "classic"],
  ["mostlyDone", "mostly-done"],
];

function variants(look: SetupLook, notes: Partial<Record<Fixture, string>>) {
  return Object.fromEntries(
    states.map(([fixture, name]) => [
      `${look}-${name}`,
      { ...(notes[fixture] && { note: notes[fixture] }), props: { look, fixture } },
    ]),
  );
}

export default componentEntry<Props>({
  id: "home.setup-card",
  title: "Set Up cmux",
  area: "Home and Chief",
  height: 520,
  widths: { narrow: 390, normal: 640, wide: 900 },
  covers: ["pages/home-messages/cards/setup/SetupCard.tsx"],
  load: async () => Stage,
  styles: () => import("../cards.gallery.css"),
  variants: {
    ...variants("next", {
      fresh:
        "Progress and only the next row's action, as a getting-started card: one ask at a time, but the later rows stay hidden until the earlier ones are done.",
      classic: "Classic's workspaces come first: the answer decides what Home holds.",
      mostlyDone: "One row left; the ring says how far.",
    }),
    "next-installing": {
      note: "An install runs: the spinner takes the button's slot, nothing moves.",
      props: { look: "next", fixture: "installing" },
    },
    "rows-unverified": {
      note: "Claude Code's login opened, but its Keychain sign-in cannot be read: the person confirms it or signs in again.",
      props: { look: "rows", fixture: "unverified" },
    },
    ...variants("rows", {
      fresh:
        "Recommended (ships): every row in one card, a Settings list. Everything visible at once, one card, nothing hidden behind earlier steps.",
      classic:
        "Ships: a Classic user's first run is this same card; the launch's classic import asks on its cmux Classic row (app, save time, what Import also does), not in a dialog beside it.",
    }),
    "rows-classic-open": {
      note: "The classic app that saved is still open: the row says this is its autosave and to quit it first, as the import dialog did.",
      props: { look: "rows", fixture: "classicOpen" },
    },
    "rows-classic-declined": {
      note: "Skip is a No the migration keeps: the row says where to import later, and its slot swaps to the done mark in place.",
      props: { look: "rows", fixture: "classicDeclined" },
    },
    "checklist-classic-open": {
      note: "The checklist look with the still-open classic app's row, for comparison.",
      props: { look: "checklist", fixture: "classicOpen" },
    },
    ...variants("checklist", {
      fresh: "A checklist on the chat column over the composer, no card: readiness before the first prompt.",
    }),
    ...variants("window", {
      fresh: "Comparison only: the same rows as the first-run window (not the direction).",
    }),
  },
});
