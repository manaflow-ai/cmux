// R92 diagnostics (Terminal): the Ghostty config keys and keybind actions of the user's files that
// cmux does not apply, each with its reason, cmux replacement and file:line, and the lines Ghostty
// could not read. Data: the host lists' `ghostty_diagnostics`, the same list as the app socket's
// `ghostty.diagnostics`; live through cmux.settings.host.changed. Read-only.
import { useSettingsState } from "../context";
import type { GhosttyDiagnostic } from "../ops";
import { t } from "../strings";

function reasonText(diagnostic: GhosttyDiagnostic): string {
  switch (diagnostic.reason) {
    case "superseded":
      return diagnostic.replacement
        ? t("settingsWindow.ghosttyDiagnostics.superseded", diagnostic.replacement)
        : t("settingsWindow.ghosttyDiagnostics.supersededPlain");
    case "not-applicable":
      return t("settingsWindow.ghosttyDiagnostics.notApplicable");
    case "later":
      return t("settingsWindow.ghosttyDiagnostics.later");
    default:
      return t("settingsWindow.ghosttyDiagnostics.invalid");
  }
}

function title(diagnostic: GhosttyDiagnostic): string {
  if (diagnostic.kind === "keybind-action") return t("settingsWindow.ghosttyDiagnostics.keybind", diagnostic.name);
  return diagnostic.name;
}

export function GhosttyDiagnostics() {
  const { host } = useSettingsState();
  const diagnostics = host?.ghostty_diagnostics;
  if (!diagnostics) return null;
  return (
    <section className="group" data-card="ghostty-diagnostics">
      <h3 className="group-title">{t("settingsWindow.ghosttyDiagnostics.title")}</h3>
      <div className="row-help">{t("settingsWindow.ghosttyDiagnostics.help")}</div>
      <div className="rows">
        {diagnostics.length === 0 ? (
          <div className="row">
            <div className="empty">{t("settingsWindow.ghosttyDiagnostics.none")}</div>
          </div>
        ) : (
          diagnostics.map((diagnostic, index) => (
            <div
              className="row selectable"
              key={`${diagnostic.kind}-${diagnostic.name}-${index}`}
              data-ghostty-diagnostic={diagnostic.name}
            >
              <div className="row-title">{title(diagnostic)}</div>
              <div className="row-help">{reasonText(diagnostic)}</div>
              {diagnostic.file && (
                <div className="row-help">
                  {diagnostic.line != null
                    ? t("settingsWindow.ghosttyDiagnostics.source", diagnostic.file, diagnostic.line)
                    : diagnostic.file}
                </div>
              )}
            </div>
          ))
        )}
      </div>
    </section>
  );
}
