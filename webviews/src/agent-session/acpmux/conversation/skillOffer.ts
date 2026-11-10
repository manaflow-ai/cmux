// The skill distiller (acpmux `skill_offer` and `skill_resolved` records): once the person has had
// agents do the same kind of task three times in a project, acpmux drafts a skill from those chats
// (its name, when to use it, and a SKILL.md body of steps and commands) and offers it on the third
// chat's closing turn. The card under that turn (SkillOfferCard.tsx) shows the draft with Save, Edit
// and Not now; Save writes the skill through the daemon (`_acpmux/skill_resolve`), Not now tells the
// daemon never to offer it again. This module is the card's state, derived once per record
// (direct.ts) and never per token: an offer, then the one resolution that settles it.

/// The row kind that draws a skill offer (rows/registry.tsx).
export const SKILL_OFFER = "skillOffer";

/// A row's id for an offer: one row per offer, updated in place as it settles.
export const skillRowId = (offerId: string) => `skill-${offerId}`;

/// The daemon's limits on a saved skill, which Edit checks before Save.
export const SKILL_NAME = /^[a-z0-9][a-z0-9-]{0,63}$/;
export const MAX_SKILL_DESCRIPTION = 300;
export const MAX_SKILL_BODY_BYTES = 16 * 1024;
/// A source chat's first prompt is cut to this many characters (the daemon cuts it too).
const MAX_PROMPT = 160;
/// The most source chats the card names.
const MAX_CHATS = 5;

export type SkillChat = { sessionId: string; prompt: string };

export type SkillAction = "save" | "dismiss";

export type SkillDraft = { name: string; description: string; body: string };

export type SkillOutcome = { action: SkillAction; name?: string; path?: string };

export type SkillOffer = SkillDraft & {
  offerId: string;
  /// How many similar chats the person had (3 or more).
  count: number;
  chats: SkillChat[];
  /// `harness`: the chat's model drafted it; `shapes`: built from the recorded steps because no
  /// model could draft.
  drafted: "harness" | "shapes";
  harness?: string;
  /// How it was settled, here or from another client: the card is its one-line note.
  outcome?: SkillOutcome;
  /// The request in flight (client only): the buttons wait.
  busy?: SkillAction;
  /// The daemon's message for the last request that failed (client only); the offer stays open.
  error?: string;
};

const text = (value: unknown) => (typeof value === "string" ? value : "");

/// An offer from a `skill_offer` record's data, or undefined for one the card cannot draw (no id,
/// no name, no body).
export function skillOfferFromRecord(data: unknown): SkillOffer | undefined {
  if (!data || typeof data !== "object") return undefined;
  const record = data as Record<string, unknown>;
  const offerId = text(record.offerId);
  const name = text(record.name).trim();
  const description = text(record.description).trim().split("\n")[0].trim();
  const body = text(record.body).trim();
  if (!offerId || !name || !body) return undefined;
  const chats = (Array.isArray(record.chats) ? record.chats : [])
    .flatMap((chat): SkillChat[] => {
      if (!chat || typeof chat !== "object") return [];
      const entry = chat as Record<string, unknown>;
      const sessionId = text(entry.sessionId);
      const prompt = text(entry.prompt).trim().replace(/\s+/g, " ").slice(0, MAX_PROMPT);
      return sessionId ? [{ sessionId, prompt }] : [];
    })
    .slice(0, MAX_CHATS);
  const counted = typeof record.count === "number" && Number.isFinite(record.count) ? Math.floor(record.count) : 0;
  const harness = text(record.harness).trim();
  return {
    offerId,
    name,
    description,
    body,
    count: Math.max(counted, chats.length, 3),
    chats,
    drafted: record.drafted === "shapes" ? "shapes" : "harness",
    ...(harness ? { harness } : {}),
  };
}

/// The offer after its resolution (a `skill_resolved` record's data, or `_acpmux/skill_resolve`'s
/// result). The first one settles it for good; another offer's, one with no action, or one after the
/// offer settled changes nothing.
export function settleSkillOffer(offer: SkillOffer, data: unknown): SkillOffer {
  if (offer.outcome || !data || typeof data !== "object") return offer;
  const record = data as Record<string, unknown>;
  if (typeof record.offerId === "string" && record.offerId !== offer.offerId) return offer;
  const action = record.action;
  if (action !== "save" && action !== "dismiss") return offer;
  const name = text(record.name).trim();
  const path = text(record.path).trim();
  const outcome: SkillOutcome = {
    action,
    ...(action === "save" ? { name: name || offer.name } : {}),
    ...(path ? { path } : {}),
  };
  return { ...offer, outcome, busy: undefined, error: undefined };
}

/// The offer while a request settles it: the buttons wait, and the last error goes.
export const skillRequestStarted = (offer: SkillOffer, action: SkillAction): SkillOffer => ({
  ...offer,
  busy: action,
  error: undefined,
});

/// The offer after a request failed: actionable again, with the daemon's message.
export const skillRequestFailed = (offer: SkillOffer, message: string): SkillOffer => ({
  ...offer,
  busy: undefined,
  error: message || undefined,
});

/// Which fields of an edited draft the daemon would refuse (the card shows each one's hint), or `{}`
/// when it would take it.
export type SkillDraftProblems = Partial<Record<keyof SkillDraft, true>>;

export function skillDraftProblems(draft: SkillDraft): SkillDraftProblems {
  const problems: SkillDraftProblems = {};
  if (!SKILL_NAME.test(draft.name)) problems.name = true;
  const description = draft.description.trim();
  if (!description || description.includes("\n") || description.length > MAX_SKILL_DESCRIPTION)
    problems.description = true;
  if (!draft.body.trim() || new TextEncoder().encode(draft.body).length > MAX_SKILL_BODY_BYTES) problems.body = true;
  return problems;
}

/// The numbered steps of a draft's body (`## Steps`, else every numbered line), for the checklist
/// look.
export function skillSteps(body: string): string[] {
  const lines = body.split("\n");
  const heading = lines.findIndex((line) => /^#{1,3}\s+steps\b/i.test(line.trim()));
  const scope = heading >= 0 ? lines.slice(heading + 1) : lines;
  const end = heading >= 0 ? scope.findIndex((line) => /^#{1,3}\s/.test(line.trim())) : -1;
  return (end >= 0 ? scope.slice(0, end) : scope)
    .map((line) => /^\s*\d+[.)]\s+(.*)$/.exec(line)?.[1]?.trim() ?? "")
    .filter(Boolean);
}
