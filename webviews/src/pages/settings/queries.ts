// TanStack Query over the settings transport: the page's only copy of settings data. One query
// key per scope (`["settings", "scope", "user"]`), plus the host's own lists. Writes are
// mutations with an optimistic update and a rollback on error; the owner's change event
// invalidates the scope, so another writer's change (CLI, hand edit, MDM) shows at once. No
// component keeps its own copy of a value: components read the cache (useSettingsState).
import { QueryClient } from "@tanstack/react-query";
import type { GhosttyTheme } from "../../theme/ghosttyTheme";
import type {
  AccountsState,
  Diagnostic,
  Domains,
  HarnessesState,
  HostLists,
  ListRow,
  ManagedInfo,
  SnapshotResult,
} from "./ops";
import { revisionNumber } from "./ops";
import { rowsByKey } from "./schema";
import type { ScopeRead, SettingsScope } from "./transport";

export const settingsKeys = {
  all: ["settings"] as const,
  scope: (scope: SettingsScope) => ["settings", "scope", scope] as const,
  host: ["settings", "host"] as const,
  accounts: ["settings", "accounts"] as const,
  harnesses: ["settings", "harnesses"] as const,
  themeColors: ["settings", "theme-colors"] as const,
  write: ["settings", "write"] as const,
};

/** One scope's data as the page uses it. */
export type ScopeData = {
  revision: number;
  rows: ReadonlyMap<string, ListRow>;
  managed: ReadonlyMap<string, ManagedInfo>;
  diagnostics: ReadonlyMap<string, string[]>;
  /** Every problem of the read, in file order (Advanced lists them). */
  problems: ReadonlyArray<{ path: string; message: string }>;
  domains: Domains;
};

export type HostData = HostLists;
export type AccountsData = AccountsState;
export type HarnessesData = HarnessesState;
export type ThemeColorsData = ReadonlyMap<string, GhosttyTheme>;

export function createSettingsQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      // The owner pushes every change (settings-changed, host-changed): data is fresh until then,
      // and a failed read is shown, not retried behind the user's back.
      queries: {
        staleTime: Number.POSITIVE_INFINITY,
        retry: false,
        refetchOnWindowFocus: false,
        structuralSharing: false,
      },
      mutations: { retry: false },
    },
  });
}

/** A transport read as the page's scope data. */
export function scopeData({ rows, snapshot }: ScopeRead): ScopeData {
  return {
    revision: revisionNumber(snapshot.revision),
    rows: new Map(rows.map((row) => [row.key, row])),
    managed: new Map(Object.entries(snapshot.managed ?? {})),
    diagnostics: diagnosticsByKey(snapshot.diagnostics ?? []),
    problems: (snapshot.diagnostics ?? []).map((diagnostic) => ({
      path: Array.isArray(diagnostic.path) ? diagnostic.path.join(".") : diagnostic.path,
      message: diagnostic.message,
    })),
    domains: publishedDomains(snapshot),
  };
}

export type Write =
  | { kind: "set"; key: string; value: unknown }
  | { kind: "reset"; key: string }
  | { kind: "resetAll" };

/** The scope as it reads once `write` lands, shown while the owner confirms it. */
export function optimistic(data: ScopeData, write: Write): ScopeData {
  const rows = new Map(data.rows);
  const apply = (key: string, value: unknown) => {
    const row = rows.get(key);
    if (!row || row.managed) return;
    rows.set(key, { ...row, value, customized: JSON.stringify(value) !== JSON.stringify(row.default) });
  };
  if (write.kind === "set") apply(write.key, write.value);
  else if (write.kind === "reset") apply(write.key, rows.get(write.key)?.default);
  else for (const [key, row] of rows) if (!rowsByKey.get(key)?.kept_on_reset_all) apply(key, row.default);
  return { ...data, rows };
}

function publishedDomains(snapshot: SnapshotResult): Domains {
  const domains = snapshot.domains ?? {};
  return { themes: domains.themes ?? [], font_families: domains.font_families ?? [], sounds: domains.sounds ?? [] };
}

/** Diagnostics keyed by schema row: the row whose key equals the path or is its prefix. */
function diagnosticsByKey(diagnostics: Diagnostic[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const diagnostic of diagnostics) {
    const path = Array.isArray(diagnostic.path) ? diagnostic.path.join(".") : diagnostic.path;
    let key = path;
    while (key && !rowsByKey.has(key)) key = key.includes(".") ? key.slice(0, key.lastIndexOf(".")) : "";
    if (!key) continue;
    out.set(key, [...(out.get(key) ?? []), diagnostic.message]);
  }
  return out;
}
