// What Settings > Agents reads from the harnesses' health (cx-ny85): shared by the Harnesses card
// and the section list's badge, so the list does not load the card.
import type { HarnessRow, HarnessesState, ProviderAccount } from "./ops";

/** Rows the page can update with one click (outdated, no sudo needed, a channel the owner runs). */
export function updatable(state: HarnessesState | null | undefined): HarnessRow[] {
  return (state?.harnesses ?? []).filter((row) => offersUpdate(row) && !updateUnsettled(state, row.id));
}

/** Whether a row shows Update: the owner refuses elevated plans and channels it cannot run. */
export function offersUpdate(row: HarnessRow): boolean {
  return !!row.outdated && !!row.update && !row.update.elevated && row.ownerUpdate === true;
}

/** A job still being created, running, or whose creation reply was lost blocks a second update;
 * any end observation (`exited`, even with an unknown outcome) settles it. */
export function updateUnsettled(state: HarnessesState | null | undefined, id: string): boolean {
  return (state?.jobs ?? []).some((job) => job.profiles.includes(id) && job.state !== "exited");
}

/** Whether Settings > Agents wants a look: a harness is outdated, signed out or its sign-in expired. */
export function harnessesNeedAttention(state: HarnessesState | null | undefined): boolean {
  return (state?.harnesses ?? []).some((row) => row.outdated || row.auth === "signedOut" || row.auth === "expired");
}

/** The provider family whose accounts a harness row lists (`codex`, `claude`), or null. */
export function harnessFamily(row: HarnessRow): string | null {
  if (row.id === "codex") return "codex";
  if (row.id === "claude" || row.kind === "claude-stdio") return "claude";
  return null;
}

/** The ids of the rows that carry their family's accounts: the first row of each family. */
export function accountRows(state: HarnessesState | null | undefined): Map<string, string> {
  const rows = new Map<string, string>();
  for (const row of state?.harnesses ?? []) {
    const family = harnessFamily(row);
    if (family && ![...rows.values()].includes(family)) rows.set(row.id, family);
  }
  return rows;
}

/** A family's accounts, the CLI's own login first; null when the daemon lists no accounts. */
export function accountsFor(state: HarnessesState | null | undefined, family: string): ProviderAccount[] | null {
  if (!state?.accounts) return null;
  const mine = state.accounts.filter((account) => account.family === family);
  return [...mine.filter((account) => account.builtin), ...mine.filter((account) => !account.builtin)];
}

/** The account a provider row's "Authenticated · plan" line speaks for: the CLI's own login. */
export function primaryAccount(accounts: ProviderAccount[] | null): ProviderAccount | null {
  return accounts?.find((account) => account.builtin) ?? null;
}

const PLAN_NAMES: Record<string, Record<string, string>> = {
  codex: {
    free: "ChatGPT Free",
    plus: "ChatGPT Plus",
    pro: "ChatGPT Pro",
    team: "ChatGPT Team",
    business: "ChatGPT Business",
    enterprise: "ChatGPT Enterprise",
    edu: "ChatGPT Edu",
  },
  claude: {
    free: "Claude Free",
    pro: "Claude Pro",
    max: "Claude Max",
    team: "Claude Team",
    enterprise: "Claude Enterprise",
  },
};

/** A plan as its product names it (`pro` from a Codex token is "ChatGPT Pro"); other text as given. */
export function planName(family: string, plan: string | null | undefined): string | null {
  if (!plan) return null;
  return PLAN_NAMES[family]?.[plan.toLowerCase()] ?? plan;
}

/** When acpmux last checked any harness (ms since the epoch), or null. */
export function newestCheck(state: HarnessesState | null | undefined): number | null {
  let newest: number | null = null;
  for (const row of state?.harnesses ?? []) {
    if (typeof row.checkedAt === "number" && (newest === null || row.checkedAt > newest)) newest = row.checkedAt;
  }
  return newest;
}

/** How long ago `then` was, in the page's locale ("5 min. ago"); null under a minute. */
export function agoText(then: number, now: number, locale: string): string | null {
  const minutes = Math.floor((now - then) / 60_000);
  if (minutes < 1) return null;
  const format = new Intl.RelativeTimeFormat(locale, { numeric: "always", style: "short" });
  if (minutes < 60) return format.format(-minutes, "minute");
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return format.format(-hours, "hour");
  return format.format(-Math.floor(hours / 24), "day");
}
