// What `/` lists in a Chief chat's message box (the user, 2026-11-09: "/ calls suggestions in
// chief", as the agent chats do). The Chief's host names its skills in `chief.engine.get`
// `offered.skills` (optchat-chief engine_control.rs: the Chief's own skills, then Claude's, then
// plugins'), and the app answers `chief.skills` with them (CmuxNextHome HomeMessagesChiefTurn) for
// local and paired-server Chiefs alike. The list is read on a fresh `/` (the menu was closed), never
// on each key, and a failed read says so instead of showing an empty list. The native transcript's
// `/` menu (MessagesLab SlashSkillMenu) went with it in #37777; this is its place on the page.
import type { PageClient } from "../../shared/pageClient";
import { slashMatches, type SlashCommand, type SlashMatch, type SlashTrigger } from "../../../agent-session/acpmux/slashCommands";

export const CHIEF_SKILLS_OP = "cmux.home.messages.chief.skills";

/** One skill the host offered: `source` is `chief`, `claude` or `plugin:<plugin>`. */
export interface ChiefSkill {
  name: string;
  description: string;
  source: string;
}

export type ChiefSkillList =
  | { kind: "none" }
  | { kind: "loading" }
  | { kind: "failed" }
  | { kind: "loaded"; skills: readonly ChiefSkill[] };

/** The `{skills}` answer, each row checked; a malformed row is left out, never the list. */
export function parseChiefSkills(raw: unknown): ChiefSkill[] {
  const rows = (raw as { skills?: unknown } | null)?.skills;
  if (!Array.isArray(rows)) return [];
  const skills: ChiefSkill[] = [];
  for (const row of rows) {
    const fields = (row ?? {}) as Record<string, unknown>;
    const name = typeof fields.name === "string" ? fields.name.replace(/^\//, "").trim() : "";
    if (!name) continue;
    skills.push({
      name,
      description: typeof fields.description === "string" ? fields.description : "",
      source: typeof fields.source === "string" ? fields.source : "chief",
    });
  }
  return skills;
}

/** A skill as the agent pane's `/` matching reads it (slashCommands.ts): a command the Chief runs
 * when its message starts with it. */
export const skillCommand = (skill: ChiefSkill): SlashCommand => ({
  name: skill.name,
  description: skill.description,
  source: "skill",
});

/** The rows `/word` shows: only at the message's start (the Chief's host runs a skill only there,
 * slash_skills.rs), ranked as the agent pane ranks its commands. */
export function chiefSkillMatches(skills: readonly ChiefSkill[], trigger: SlashTrigger): SlashMatch[] {
  if (!trigger.leading) return [];
  return slashMatches(skills.map(skillCommand), trigger);
}

/** One Chief conversation's skills: read on demand, kept while it shows, read again on a fresh `/`
 * after a failure (a Chief that was starting may answer now). */
export class ChiefSkills {
  private list: ChiefSkillList = { kind: "none" };
  private readonly listeners = new Set<() => void>();
  private asking = false;

  constructor(
    private readonly host: PageClient | null,
    private readonly conversation: string,
  ) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): ChiefSkillList => this.list;

  /** A fresh `/`: asks the host unless the list is here or on its way. */
  load(): void {
    if (!this.host || this.asking || this.list.kind === "loaded") return;
    this.asking = true;
    this.publish({ kind: "loading" });
    void this.host.call<unknown>(CHIEF_SKILLS_OP, { conversation: this.conversation }).then(
      (answer) => {
        this.asking = false;
        this.publish({ kind: "loaded", skills: parseChiefSkills(answer) });
      },
      () => {
        this.asking = false;
        this.publish({ kind: "failed" });
      },
    );
  }

  dispose(): void {
    this.listeners.clear();
  }

  private publish(list: ChiefSkillList): void {
    this.list = list;
    for (const listener of this.listeners) listener();
  }
}
