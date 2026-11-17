import { useCallback } from "react";
import { Button } from "../../ui/Button";
import { useT } from "./i18n";

/// The new Cloud chat's folder menu, before the cmux GitHub App is installed (githubRepos.ts): one
/// centered card in place of the list. The GitHub mark, what it is, that the person picks the
/// repositories, and one full-width Install on GitHub. After the click the button gives way to a quiet
/// Waiting for GitHub… until the status says ready (the menu then shows its list again). Back, like
/// Escape, returns to the list.
export function GitHubInstallCard({
  waiting,
  error,
  onInstall,
  onBack,
}: {
  waiting: boolean;
  /// `github.connect` was refused: the host's words, under the button.
  error?: string;
  onInstall(): void;
  onBack(): void;
}) {
  const t = useT();
  // The card replaces the menu's field: the keyboard moves to its one action, once, as it mounts.
  const focusOnMount = useCallback((node: HTMLButtonElement | null) => node?.focus(), []);
  return (
    <div className="acpmux-github-card" data-waiting={waiting ? "" : undefined}>
      <button
        type="button"
        className="acpmux-github-card-back ui-ghost ui-ghost-sm"
        aria-label={t("project.back")}
        onClick={onBack}
      >
        <BackIcon />
      </button>
      <span className="acpmux-github-card-mark">
        <GitHubMark size={24} />
      </span>
      <p className="acpmux-github-card-title">{t("composer.githubInstallTitle")}</p>
      <p className="acpmux-github-card-subtitle">{t("composer.githubInstallSubtitle")}</p>
      {waiting ? (
        <output className="acpmux-github-card-waiting">{t("composer.githubWaiting")}</output>
      ) : (
        <Button ref={focusOnMount} variant="solid" className="acpmux-github-card-install" onClick={onInstall}>
          {t("composer.githubInstall")}
        </Button>
      )}
      {error && !waiting && (
        <p className="acpmux-github-card-error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}

/// GitHub's mark (Primer Octicons mark-github, MIT, 16 px grid), in the text color.
export function GitHubMark({ size = 12 }: { size?: number }) {
  return (
    <svg
      className="acpmux-icon"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

/// A private repository's lock, drawn as the folder menu's other glyphs are.
export function LockIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <rect x="3.5" y="7" width="9" height="6.5" rx="1.5" />
      <path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M10 3.5 5.5 8l4.5 4.5" />
    </svg>
  );
}
