// What Settings > Developer (DeveloperTokensCard) shows about an API token: when it ends, when it
// was last used, and the lines a person pastes after creating one. Pure, so the card and its tests
// share it; every request and refusal is the CLI's (`cmux token ...`, through SettingsDeveloperTokens).
import { intl } from "../../ui/intl";
import type { ApiToken, TokenScope } from "./ops";
import { t } from "./strings";

/** The scopes in the order the page lists them. */
export const TOKEN_SCOPES: readonly TokenScope[] = ["machines", "chats", "usage"];

/** The Expiration choices, in days; null never expires. 90 is the platform's default. */
export const TOKEN_EXPIRATIONS: ReadonlyArray<number | null> = [30, 90, 365, null];
export const DEFAULT_EXPIRATION = 90;

/** Where a curl example points when the list named no platform (the CLI's production origin). */
export const PRODUCTION_PLATFORM = "https://cmux-platform-production.debussy.workers.dev";

/** "Expires Mar 2, 2027", "Expired", or "Never expires". */
export function expiresText(token: Pick<ApiToken, "expiresAt">, now: number, locale: string): string {
  if (!token.expiresAt) return t("settingsWindow.tokens.row.neverExpires");
  const at = Date.parse(token.expiresAt);
  if (!Number.isFinite(at)) return t("settingsWindow.tokens.row.neverExpires");
  if (at <= now) return t("settingsWindow.tokens.row.expired");
  return t("settingsWindow.tokens.row.expires", intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(at));
}

/** "Never used", "Used just now", or "Used 3 days ago". */
export function lastUsedText(lastUsedAt: string | null, now: number, locale: string): string {
  const at = lastUsedAt ? Date.parse(lastUsedAt) : Number.NaN;
  if (!Number.isFinite(at)) return t("settingsWindow.tokens.row.neverUsed");
  const minutes = Math.floor((now - at) / 60_000);
  if (minutes < 1) return t("settingsWindow.tokens.row.usedJustNow");
  const format = intl.RelativeTimeFormat(locale, { numeric: "always", style: "long" });
  const ago =
    minutes < 60
      ? format.format(-minutes, "minute")
      : minutes < 1440
        ? format.format(-Math.floor(minutes / 60), "hour")
        : minutes < 60 * 1440
          ? format.format(-Math.floor(minutes / 1440), "day")
          : intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(at);
  return t("settingsWindow.tokens.row.used", ago);
}

/** "$50" in the page's locale. */
export function capText(usd: number, locale: string): string {
  const whole = Number.isInteger(usd);
  const amount = intl
    .NumberFormat(locale, {
      style: "currency",
      currency: "USD",
      maximumFractionDigits: whole ? 0 : 2,
    })
    .format(usd);
  return t("settingsWindow.tokens.row.cap", amount);
}

/** The new token's shell line. */
export function exportLine(token: string): string {
  return `export CMUX_TOKEN='${token.replaceAll("'", "'\"'\"'")}'`;
}

/** A first request the new token can make, or null when its scopes have no list to read. */
export function curlExample(scopes: readonly TokenScope[], platform: string | null): string | null {
  const origin = (platform ?? PRODUCTION_PLATFORM).replace(/\/+$/, "");
  if (scopes.includes("machines")) return `curl -H "Authorization: Bearer $CMUX_TOKEN" ${origin}/v1/machines`;
  return null;
}

/** A workflow job that signs in with GitHub's identity token: later steps get CMUX_TOKEN. */
export function workflowSnippet(team: string | null, platform: string | null): string {
  const origin = (platform ?? PRODUCTION_PLATFORM).replace(/\/+$/, "");
  const lines = [
    "jobs:",
    "  cmux:",
    "    runs-on: ubuntu-latest",
    "    permissions:",
    "      id-token: write",
    "      contents: read",
    "    steps:",
    "      - name: Sign in to cmux",
    "        shell: bash",
    "        env:",
    `          CMUX_PLATFORM: ${JSON.stringify(origin)}`,
    `          CMUX_TEAM: ${JSON.stringify(team ?? "")}`,
    "        run: |",
    "          set -euo pipefail",
    '          oidc=$(curl -fsS --max-time 30 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=cmux" | jq -er \'.value | select(type == "string" and length > 0)\')',
    '          echo "::add-mask::$oidc"',
    '          body=$(jq -nc --arg idToken "$oidc" --arg team "$CMUX_TEAM" \'{idToken: $idToken} + (if $team == "" then {} else {team: $team} end)\')',
    '          token=$(curl -fsS --max-time 60 -X POST -H "Content-Type: application/json" "$CMUX_PLATFORM/v1/tokens/github/exchange" --data-binary "$body" | jq -er \'.token | select(type == "string" and test("^cmux_pat_[A-Za-z0-9_-]+$"))\')',
    '          echo "::add-mask::$token"',
    '          echo "CMUX_TOKEN=$token" >> "$GITHUB_ENV"',
  ];
  return lines.join("\n");
}

/** `owner/name` as GitHub spells a repository, or null. */
export function repositoryOf(text: string): string | null {
  const value = text
    .trim()
    .replace(/^https?:\/\/github\.com\//i, "")
    .replace(/\.git$/i, "")
    .replace(/\/+$/, "");
  return /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/.test(value) ? value : null;
}

/** A branch as the rule's ref: `main` is `refs/heads/main`; a full ref or a `*` prefix stays. Empty: any. */
export function refOf(branch: string): string | undefined {
  const value = branch.trim();
  if (!value) return undefined;
  return value.startsWith("refs/") ? value : `refs/heads/${value}`;
}

/** The branch a rule's ref names, for its row ("main", "release/*"). */
export function branchOf(ref: string | undefined): string | null {
  if (!ref) return null;
  return ref.startsWith("refs/heads/") ? ref.slice("refs/heads/".length) : ref;
}

/** A spend cap typed in the form: a positive amount with at most two decimals, or null for none. */
export function spendCapOf(text: string): number | null {
  const input = text.trim();
  const match = input.match(/^\$?(\d+)(?:\.(\d{1,2}))?$/);
  if (!match) return null;
  const cents = BigInt(match[1]) * 100n + BigInt((match[2] ?? "").padEnd(2, "0"));
  return cents > 0n && cents <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(cents) / 100 : null;
}
