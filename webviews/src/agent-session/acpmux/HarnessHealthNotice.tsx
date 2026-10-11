import { useState } from "react";
import { useT } from "./i18n";

/// One row of acpmux's `_acpmux/harness/health` (cx-ny85), as the host hands it to the pane
/// (`harness.health`).
export type HarnessHealth = {
  id: string;
  version?: string | null;
  latest?: string | null;
  outdated?: boolean;
  /// Only from evidence (a profile's check, or a probe's sign-in error).
  auth?: "signedIn" | "signedOut" | "unknown";
  /// The command that signs it in.
  login?: string | null;
  /// How to update it; `elevated`: it needs sudo, so the pane never offers it.
  update?: { command: string; elevated: boolean } | null;
};

/// The agent CLI versions the person chose to skip, by harness id (this browser profile).
const SKIPPED = "cmux.acpmux.skippedUpdates";

function skipped(): Record<string, string> {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(SKIPPED) ?? "{}");
    return value && typeof value === "object" ? (value as Record<string, string>) : {};
  } catch {
    return {};
  }
}

function skip(id: string, version: string): void {
  try {
    globalThis.localStorage?.setItem(SKIPPED, JSON.stringify({ ...skipped(), [id]: version }));
  } catch {
    // No storage (a private window): skipped for this chat only.
  }
}

type Open = (params: { kind: "terminal"; text: string; cwd?: string; run: true }) => void;

/// Agent CLI health above the composer, quiet and inline: a signed-out agent says so with Log In,
/// an outdated one offers its own update with Not Now (this chat) and Skip This Version. Both run
/// in a terminal tab of the chat's folder (`open`, the host's `tab.open`), where the person sees
/// them. An update that needs sudo is left to Settings > Agents, which shows its command.
export function HarnessHealthNotice({
  health,
  harness,
  name,
  cwd,
  open,
}: {
  health: HarnessHealth | undefined;
  /// The chat's agent now; a row for another (fetched before a switch) shows nothing.
  harness: string | undefined;
  name: string;
  cwd?: string;
  open: Open;
}) {
  const t = useT();
  const [dismissed, setDismissed] = useState<string>();
  if (!health || health.id !== harness) return null;
  const run = (text: string) => open({ kind: "terminal", text, ...(cwd ? { cwd } : {}), run: true });
  const signedOut = health.auth === "signedOut" && health.login ? health.login : undefined;
  const update =
    health.outdated &&
    health.version &&
    health.latest &&
    health.update &&
    !health.update.elevated &&
    skipped()[health.id] !== health.latest
      ? health.update.command
      : undefined;
  const kind = signedOut ? "signedOut" : update ? "outdated" : undefined;
  // Not Now holds for what it was said to (a newer version or a sign-out asks again).
  const key = kind && `${health.id}:${kind}:${health.latest ?? ""}`;
  if (!kind || key === dismissed) return null;
  return (
    <output className="acpmux-host-error acpmux-harness-notice" data-harness-notice={kind}>
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">
          {kind === "signedOut"
            ? t("harness.signedOut", { agent: name })
            : t("harness.outdated", { agent: name, version: health.version ?? "", latest: health.latest ?? "" })}
        </p>
        <div className="acpmux-host-error-actions">
          {kind === "signedOut" ? (
            <button type="button" data-notice-action="login" onClick={() => run(signedOut!)}>
              {t("harness.logIn")}
            </button>
          ) : (
            <>
              <button type="button" data-notice-action="update" onClick={() => run(update!)}>
                {t("harness.update")}
              </button>
              <button
                type="button"
                data-notice-action="skip"
                onClick={() => {
                  skip(health.id, health.latest!);
                  setDismissed(key);
                }}
              >
                {t("harness.skipVersion")}
              </button>
            </>
          )}
          <button type="button" data-notice-action="dismiss" onClick={() => setDismissed(key)}>
            {t("harness.notNow")}
          </button>
        </div>
      </div>
    </output>
  );
}
