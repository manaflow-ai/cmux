// The account's Cloud plan as the server's plan view says it (`cloudMachine.list` `plan`), the plans the
// pricing card offers, and the machine sizes in plain words. Only an explicit `none` gates a Cloud send:
// `unknown`, and a reply with no `plan` (an older app), never do, so a company or stub team is never
// locked out by the page; the answer is always the server's, never read from a plan's name here.
//   cloudMachine.list   { fresh?: true }    -> { …, plan: { state, id, max_size } } (fresh: read again, not kept)
//   cloud.plan.subscribe { plan: next_plus | next_pro | next_max | pro | max } -> { opened: true } (the host runs the upgrade)
// A team with no plan is offered cmux NEXT's own plans (`next_plus`, `next_pro`, `next_max`); a refusal that names the classic ones
// (`pro`, `max`) still shows them.
// A start the platform refuses for its size (`cloud_size_locked`) carries what it needed and what the plan
// allows (`details`); the card names the needed size in vCPU and memory, never the ladder's name.
import { translate, type Translate } from "./i18n";

export type CloudPlanState = "active" | "none" | "unknown";
/// The ladder's sizes, smallest first (cmux-platform domain/Sizes.ts).
export const CLOUD_SIZES = ["sm", "md", "lg", "xl", "2xl"] as const;
export type CloudSize = (typeof CLOUD_SIZES)[number];
export type CloudPlanView = { state: CloudPlanState; id: string | null; maxSize: CloudSize | null };

/// Every plan the cards may name: cmux NEXT's own, and the classic ones a server may still send.
const CLOUD_PLAN_NAMES = ["next_plus", "next_pro", "next_max", "pro", "max"] as const;
export type CloudPlanId = (typeof CLOUD_PLAN_NAMES)[number];
/// The plans the pricing card offers a team with no plan, in its order (smallest first).
export const CLOUD_PLAN_IDS: readonly CloudPlanId[] = ["next_plus", "next_pro", "next_max"];

const UNKNOWN: CloudPlanView = { state: "unknown", id: null, maxSize: null };

/// vCPUs and memory (GB) of each ladder size (cmux-platform domain/Sizes.ts; disk is not shown).
const SIZE_SPECS: Record<CloudSize, { cpu: number; memory: number }> = {
  sm: { cpu: 2, memory: 4 },
  md: { cpu: 4, memory: 8 },
  lg: { cpu: 8, memory: 16 },
  xl: { cpu: 16, memory: 32 },
  "2xl": { cpu: 32, memory: 64 },
};

/// What each plan offers: its name (a product name, never translated), its monthly price, and the largest
/// machine it includes in vCPUs and memory (GB), which need not be a ladder size (cmux-platform domain/Plan.ts
/// limits: cmux NEXT Plus up to 4 vCPU and 16 GB, the machine every chat starts on; cmux NEXT Pro up to 8 and 32;
/// classic Pro up to 8 and 16; Max up to 32 and 64).
export const CLOUD_PLANS: Record<CloudPlanId, { name: string; price: string; cpu: number; memory: number }> = {
  // l10n-allow: a product name, never translated.
  next_plus: { name: "cmux NEXT Plus", price: "$20", cpu: 4, memory: 16 },
  // l10n-allow: a product name, never translated.
  next_pro: { name: "cmux NEXT Pro", price: "$50", cpu: 8, memory: 32 },
  // l10n-allow: a product name, never translated.
  next_max: { name: "cmux NEXT Max", price: "$200", cpu: 32, memory: 64 },
  // l10n-allow: a product name, never translated.
  pro: { name: "Pro", price: "$50", cpu: 8, memory: 16 },
  // l10n-allow: a product name, never translated.
  max: { name: "Max", price: "$200", cpu: 32, memory: 64 },
};

/// The largest machine a plan includes, in plain words ("4 vCPU and 16 GB memory"), in the person's language.
export function cloudPlanMachineWords(plan: CloudPlanId, t: Translate = translate): string {
  const offer = CLOUD_PLANS[plan];
  return t("cloudStart.machineSize", { cpu: String(offer.cpu), memory: String(offer.memory) });
}

export function isCloudSize(value: unknown): value is CloudSize {
  return typeof value === "string" && (CLOUD_SIZES as readonly string[]).includes(value);
}

export function isCloudPlanId(value: unknown): value is CloudPlanId {
  return typeof value === "string" && (CLOUD_PLAN_NAMES as readonly string[]).includes(value);
}

/// The plans a `cloud_plan_required` refusal's `details.plans` names, in its order (the app's own offer, or classic
/// plans an older server named); undefined when it names none the cards know, so the card offers `CLOUD_PLAN_IDS`.
export function cloudPlansNamed(details: unknown): CloudPlanId[] | undefined {
  if (!details || typeof details !== "object" || Array.isArray(details)) return undefined;
  const listed = (details as { plans?: unknown }).plans;
  if (!Array.isArray(listed)) return undefined;
  const plans = [...new Set(listed.filter(isCloudPlanId))];
  return plans.length > 0 ? plans : undefined;
}

/// The `plan` of a `cloudMachine.list` reply; `unknown` for a reply without one (an older app) or a malformed one.
export function cloudPlanFromReply(reply: unknown): CloudPlanView {
  const raw = (reply as { plan?: unknown } | null | undefined)?.plan;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return UNKNOWN;
  const { state, id, max_size: maxSize } = raw as Record<string, unknown>;
  if (state !== "active" && state !== "none") return UNKNOWN;
  return {
    state,
    id: typeof id === "string" && id ? id : null,
    maxSize: isCloudSize(maxSize) ? maxSize : null,
  };
}

/// Whether a Cloud send waits on a plan (the pricing card in its place): only an explicit `none`.
export function cloudPlanHoldsSend(plan: CloudPlanView): boolean {
  return plan.state === "none";
}

/// Whether a size fits under a plan's largest: a plan that names none is taken to fit (the server decides).
export function sizeFits(size: CloudSize, maxSize: CloudSize | null): boolean {
  return maxSize === null || CLOUD_SIZES.indexOf(size) <= CLOUD_SIZES.indexOf(maxSize);
}

/// A size in plain words ("8 vCPU and 16 GB memory"), in the person's language.
export function cloudSizeWords(size: CloudSize, t: Translate = translate): string {
  const spec = SIZE_SPECS[size];
  return t("cloudStart.machineSize", { cpu: String(spec.cpu), memory: String(spec.memory) });
}

/// A `cloud_size_locked` refusal's details (`{ needed, allowed, upgrade_plan, folder_bytes }`): the size the
/// folder needs, the plan's largest, and the plan to upgrade to (none: already on the largest).
export type CloudSizeLocked = { needed: CloudSize; allowed: CloudSize | null; upgradePlan: CloudPlanId | null };

export function cloudSizeLocked(details: unknown): CloudSizeLocked | undefined {
  if (!details || typeof details !== "object" || Array.isArray(details)) return undefined;
  const { needed, allowed, upgrade_plan: upgrade } = details as Record<string, unknown>;
  if (!isCloudSize(needed)) return undefined;
  return {
    needed,
    allowed: isCloudSize(allowed) ? allowed : null,
    upgradePlan: isCloudPlanId(upgrade) ? upgrade : null,
  };
}

/// The card's one line for a size refusal: the size it needs and that the plan does not include it, or, on the
/// largest plan already, that the folder is too large for Cloud.
export function cloudSizeLockedMessage(locked: CloudSizeLocked): string {
  const size = cloudSizeWords(locked.needed);
  return locked.upgradePlan
    ? translate("cloudStart.sizeLocked.message", { size })
    : translate("cloudStart.sizeLocked.tooLarge", { size });
}
