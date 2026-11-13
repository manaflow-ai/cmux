// New Project's name in the location strip, after its folder control (ComposerContext
// `newProjectName`): the folder acpmux makes, read from the prompt as it is typed
// (newProject.ts projectNameFrom) until the person types one of their own here. Plain text in the
// strip's own type, so choosing New Project changes words and nothing moves; the field is as wide as
// its name. Return and Escape hand the keyboard back to the prompt. And the refusal above the card
// when acpmux makes no folder.
import "./newProject.css";
import { useT } from "../i18n";
import { projectNameTyping } from "./newProject";

export function NewProjectName({
  name,
  derived,
  onName,
  onDone,
}: {
  /// The name the person typed; undefined until they type one.
  name?: string;
  /// The prompt's name: the field's value until then, and its placeholder once they clear it.
  derived: string;
  onName(name: string): void;
  onDone(): void;
}) {
  const t = useT();
  const shown = name ?? derived;
  return (
    <span className="nt-project-name">
      <span className="nt-project-name__slash" aria-hidden="true">
        /
      </span>
      <input
        className="nt-project-name__field"
        aria-label={t("project.new.name")}
        spellCheck={false}
        autoComplete="off"
        value={shown}
        placeholder={derived}
        size={Math.max(4, (shown || derived).length)}
        maxLength={64}
        onChange={(event) => onName(projectNameTyping(event.currentTarget.value))}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === "Escape") {
            event.preventDefault();
            onDone();
          }
        }}
      />
    </span>
  );
}

export function NewProjectFailure({ error, onDismiss }: { error: string; onDismiss(): void }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice">
      <span role="alert">{t("project.new.failedBecause", { reason: error })}</span>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onDismiss}>
        {t("worktree.dismiss")}
      </button>
    </output>
  );
}
