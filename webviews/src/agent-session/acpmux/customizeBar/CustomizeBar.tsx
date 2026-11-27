import { useId, useState, type FormEvent } from "react";
import { ChevronDown } from "../conversation/icons";
import { useT, type StringKey } from "../i18n";
import { Button } from "../../ui/Button";
import { profileName, type CustomizeBarState, type CustomizePart, type CustomizeVerb } from "./customizeBarModel";
import "./CustomizeBar.css";

export type CustomizeBarLook = "strip" | "card" | "chip";

/** What the bar shows besides the status: the last action's outcome. */
export type CustomizeBarOutcome =
  | { kind: "none" }
  | { kind: "busy"; verb: CustomizeVerb }
  | { kind: "applied" }
  | { kind: "saved"; name: string }
  | { kind: "failed"; message: string };

const PART_KEY: Record<CustomizePart, StringKey> = {
  settings: "customizeBar.part.settings",
  keybindings: "customizeBar.part.keybindings",
  themes: "customizeBar.part.themes",
  views: "customizeBar.part.views",
  styles: "customizeBar.part.styles",
  automations: "customizeBar.part.automations",
};

/** Whether the bar draws anything: a preview, or the outcome of the person's last click. */
export function customizeBarShows(state: CustomizeBarState, outcome: CustomizeBarOutcome): boolean {
  return (
    state.kind === "preview" || outcome.kind === "applied" || outcome.kind === "saved" || outcome.kind === "failed"
  );
}

/// A live customization's preview in the chat, with the CLI's own verbs as buttons: Apply keeps
/// it, Discard drops it, Undo rolls back one applied generation, Save as profile names it
/// (CustomizeChatPage.swift runs `cmux --json customize VERB`). Nothing shows when nothing previews
/// and nothing was just applied. The look is the `chat-customize-bar` experiment's arm.
export function CustomizeBar({
  state,
  outcome,
  look,
  run,
  initiallyOpen = false,
}: {
  state: CustomizeBarState;
  outcome: CustomizeBarOutcome;
  look: CustomizeBarLook;
  run: (verb: CustomizeVerb, arg?: string) => void;
  /** The chip's popover open at first (the gallery). */
  initiallyOpen?: boolean;
}) {
  const t = useT();
  const bodyId = useId();
  const [open, setOpen] = useState(initiallyOpen);
  const [naming, setNaming] = useState(false);
  const [typed, setTyped] = useState("");
  const busy = outcome.kind === "busy";
  const previewing = state.kind === "preview";
  if (!customizeBarShows(state, outcome)) return null;

  const name = profileName(typed);
  const save = (event: FormEvent) => {
    event.preventDefault();
    if (!name) return;
    run("save", name);
    setNaming(false);
    setTyped("");
  };

  const title = previewing
    ? state.wish || t("customizeBar.preview")
    : outcome.kind === "saved"
      ? t("customizeBar.saved", { name: outcome.name })
      : outcome.kind === "applied"
        ? t("customizeBar.applied")
        : t("customizeBar.label");
  const parts = previewing
    ? state.parts.map((part) => (
        <span key={part} className="acpmux-customize-bar-part">
          {t(PART_KEY[part])}
        </span>
      ))
    : null;
  const problems =
    previewing && state.problems.length > 0 ? (
      <ul className="acpmux-customize-bar-problems">
        {state.problems.map((problem, index) => (
          <li key={`${problem.path}:${index}`}>
            <code>{problem.line === undefined ? problem.path : `${problem.path}:${problem.line}`}</code>{" "}
            {problem.message}
          </li>
        ))}
      </ul>
    ) : null;
  const failure = outcome.kind === "failed" ? <p className="acpmux-customize-bar-failed">{outcome.message}</p> : null;
  const nameForm = naming ? (
    <form className="acpmux-customize-bar-name" onSubmit={save}>
      <input
        // biome-ignore lint/a11y/noAutofocus: the field opens on the person's own click on Save as profile.
        autoFocus
        value={typed}
        placeholder={t("customizeBar.saveName")}
        aria-label={t("customizeBar.saveName")}
        onChange={(event) => setTyped(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Escape") setNaming(false);
        }}
      />
      <Button type="submit" variant="solid" size="sm" disabled={!name || busy}>
        {t("customizeBar.saveConfirm")}
      </Button>
    </form>
  ) : null;
  const buttons = (
    <div className="acpmux-customize-bar-actions">
      {previewing && (
        <>
          <Button
            variant="solid"
            size="sm"
            disabled={busy || !state.canApply}
            title={state.canApply ? undefined : t("customizeBar.problems")}
            onClick={() => run("apply", state.wish.slice(0, 200).replace(/\n/g, " ") || undefined)}
          >
            {t("customizeBar.apply")}
          </Button>
          <Button variant="ghost" size="sm" disabled={busy} onClick={() => run("discard")}>
            {t("customizeBar.discard")}
          </Button>
        </>
      )}
      {!previewing && (
        <Button variant="ghost" size="sm" disabled={busy} onClick={() => run("rollback")}>
          {t("customizeBar.undo")}
        </Button>
      )}
      {!naming && (
        <Button variant="ghost" size="sm" disabled={busy} onClick={() => setNaming(true)}>
          {t("customizeBar.save")}
        </Button>
      )}
    </div>
  );

  if (look === "chip") {
    return (
      <section className="acpmux-customize-bar" data-look="chip" data-open={open ? "true" : undefined}>
        <button
          type="button"
          className="acpmux-customize-bar-chip"
          aria-expanded={open}
          aria-controls={bodyId}
          onClick={() => setOpen((was) => !was)}
        >
          <span className="acpmux-customize-bar-dot" data-state={previewing ? "preview" : "applied"} />
          {previewing ? t("customizeBar.label") : title}
          <ChevronDown aria-hidden="true" />
        </button>
        {open && (
          <div id={bodyId} className="ui-glass ui-glass-floats acpmux-stack-material acpmux-customize-bar-popover">
            <p className="acpmux-customize-bar-title">{title}</p>
            {parts && <div className="acpmux-customize-bar-parts">{parts}</div>}
            {problems}
            {failure}
            {nameForm}
            {buttons}
          </div>
        )}
      </section>
    );
  }

  return (
    <section
      className="ui-glass ui-glass-floats acpmux-stack-material acpmux-customize-bar"
      data-look={look}
      aria-label={t("customizeBar.label")}
    >
      <div className="acpmux-customize-bar-head">
        <span className="acpmux-customize-bar-dot" data-state={previewing ? "preview" : "applied"} />
        <span className="acpmux-customize-bar-title">{title}</span>
        {look === "strip" && parts && <span className="acpmux-customize-bar-parts">{parts}</span>}
        {look === "strip" && buttons}
      </div>
      {look === "card" && parts && <div className="acpmux-customize-bar-parts">{parts}</div>}
      {problems}
      {failure}
      {nameForm}
      {look === "card" && buttons}
    </section>
  );
}
