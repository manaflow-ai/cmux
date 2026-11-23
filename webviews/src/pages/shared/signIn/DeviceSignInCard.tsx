// The device sign-in card: one provider's sign-in in place, pure props (accountSignIn.ts has the
// wire; the caller runs every step). Leo, 2026-11-22: "it's similar to the chatgpt device with the
// code login thing ... WE ABSOLUELY MUST ERR ON THE SIDE OF BEING NOT ANNOYING". So: the code shows
// large and is already on the clipboard, the page is already open beside the window, the card waits
// and turns into the account by itself, and each state has one action (Cancel stays as a quiet way
// out while it waits). Three placements share it: `inline` (inside the account row), `sheet` (a
// dialog over Settings, with steps) and `strip` (one line over the account list).
// The code reaches only the visible text: no data attribute, label or log carries it. A pasted code
// lives in this component's state until it is sent and is cleared then.
import { useId, useState, type ReactNode } from "react";
import { Button } from "../../../ui/Button";
import { Dialog } from "../../../ui/Dialog";
import { StatusGlyph } from "../../../ui/StatusGlyph";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { GitHubMark } from "../../../agent-session/acpmux/GitHubIcons";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import type { Strings } from "../i18n";
import { FAMILY_BRAND, FAMILY_CLI, type AccountFamily, type SignInView } from "./accountSignIn";
import { useSignInStrings } from "./strings";
import "./signIn.css";

export type SignInLook = "inline" | "sheet" | "strip";

/** The one action a state offers (and Cancel while it waits). */
export type SignInAction = "cancel" | "copy" | "continue" | "done" | "newCode" | "tryAgain" | "install";

export type DeviceSignInCardProps = {
  family: AccountFamily;
  view: SignInView;
  look?: SignInLook;
  /** Copies the code again (it was copied on the start). */
  onCopy?(): void;
  onCancel?(): void;
  /** New code (expired) or Try again (failed): a fresh sign-in. */
  onRetry?(): void;
  /** Closes a finished or refused sign-in. */
  onDone?(): void;
  onInstall?(): void;
  /** Claude's page showed a code to paste back: sends it once. */
  onSubmitCode?(code: string): void;
};

/** The action a state shows first (tests and the gallery read it). */
export function primaryAction(view: SignInView): SignInAction {
  switch (view.state) {
    case "starting":
      return "cancel";
    case "waiting":
      return view.way.kind === "code" ? "copy" : view.way.kind === "paste" ? "continue" : "cancel";
    case "signedIn":
      return "done";
    case "expired":
      return "newCode";
    case "notInstalled":
      return "install";
    case "failed":
      return view.reason === "shared_machine" ? "done" : "tryAgain";
  }
}

export function ProviderMark({ family, size = 16 }: { family: AccountFamily; size?: number }) {
  return (
    <span className="signin-mark" aria-hidden="true">
      {family === "github" ? <GitHubMark size={size} /> : <AgentMark agent={family} size={size} />}
    </span>
  );
}

const TITLE_KEY: Record<AccountFamily, string> = {
  github: "signIn.title.github",
  codex: "signIn.title.codex",
  claude: "signIn.title.claude",
};

/** The state's one line under (or beside) the code. */
function statusLine(strings: Strings, family: AccountFamily, view: SignInView): string {
  switch (view.state) {
    case "starting":
      return strings.t("signIn.starting");
    case "waiting":
      if (view.way.kind === "code") return strings.t(view.copied ? "signIn.code.lead" : "signIn.code.leadNotCopied");
      return strings.t(view.way.kind === "approve" ? "signIn.approve.lead" : "signIn.paste.lead");
    case "signedIn":
      return view.account ? strings.format("signIn.signedIn", view.account) : strings.t("signIn.signedInPlain");
    case "expired":
      return strings.t("signIn.expired");
    case "notInstalled":
      return strings.format("signIn.notInstalled", FAMILY_CLI[family]);
    case "failed":
      return strings.t(
        view.reason === "cancelled"
          ? "signIn.failed.cancelled"
          : view.reason === "shared_machine"
            ? "signIn.failed.sharedMachine"
            : "signIn.failed.other",
      );
  }
}

function ActionButtons({
  view,
  strings,
  props,
  canSubmit,
  submit,
}: {
  view: SignInView;
  strings: Strings;
  props: DeviceSignInCardProps;
  canSubmit: boolean;
  submit(): void;
}) {
  const primary = primaryAction(view);
  const button = (action: SignInAction, label: string, onClick: (() => void) | undefined, solid: boolean) => (
    <Button
      key={action}
      size="sm"
      variant={solid ? "solid" : "subtle"}
      className="signin-action"
      data-sign-in-action={action}
      disabled={!onClick || (view.state === "waiting" && view.busy === true)}
      onClick={onClick}
    >
      {label}
    </Button>
  );
  const out: ReactNode[] = [];
  switch (primary) {
    case "copy":
      out.push(
        // Always "Copy": the line above says it is already copied, and a primary button reading
        // "Copied" looks like a state, not an action.
        button("copy", strings.t("signIn.copy"), props.onCopy, true),
      );
      break;
    case "continue":
      out.push(button("continue", strings.t("signIn.paste.continue"), canSubmit ? submit : undefined, true));
      break;
    case "done":
      out.push(button("done", strings.t("signIn.done"), props.onDone, true));
      break;
    case "newCode":
      out.push(button("newCode", strings.t("signIn.newCode"), props.onRetry, true));
      break;
    case "tryAgain":
      out.push(button("tryAgain", strings.t("signIn.tryAgain"), props.onRetry, true));
      break;
    case "install":
      // No installer here: the card closes instead of offering a button that does nothing.
      out.push(
        props.onInstall
          ? button("install", strings.t("signIn.install"), props.onInstall, true)
          : button("done", strings.t("signIn.done"), props.onDone, true),
      );
      break;
    case "cancel":
      break;
  }
  // While it waits, Cancel is the way out (the only button while there is nothing else to do).
  if (view.state === "starting" || view.state === "waiting")
    out.push(button("cancel", strings.t("signIn.cancel"), props.onCancel, false));
  return <span className="signin-actions">{out}</span>;
}

function Code({ code, strings, size }: { code: string; strings: Strings; size: "large" | "small" }) {
  return (
    <code className="signin-code selectable" data-size={size} aria-label={strings.t("signIn.code.label")}>
      {code}
    </code>
  );
}

function PasteField({
  strings,
  code,
  setCode,
  onSubmit,
  busy,
}: {
  strings: Strings;
  code: string;
  setCode(code: string): void;
  onSubmit(): void;
  busy: boolean;
}) {
  return (
    <form
      className="signin-paste"
      onSubmit={(event) => {
        event.preventDefault();
        onSubmit();
      }}
    >
      <input
        className="field signin-paste-field"
        aria-label={strings.t("signIn.code.label")}
        type="password"
        autoComplete="off"
        autoCorrect="off"
        autoCapitalize="off"
        spellCheck={false}
        maxLength={4096}
        value={code}
        disabled={busy}
        onChange={(event) => setCode(event.currentTarget.value)}
      />
    </form>
  );
}

function StateGlyph({ view }: { view: SignInView }) {
  if (view.state === "starting" || (view.state === "waiting" && view.way.kind !== "paste"))
    return <Spinner size={14} loading />;
  if (view.state === "signedIn") return <StatusGlyph name="done" size={14} />;
  if (view.state === "failed" || view.state === "expired" || view.state === "notInstalled")
    return <StatusGlyph name="error" size={14} />;
  return null;
}

export function DeviceSignInCard(props: DeviceSignInCardProps) {
  const { family, view, look = "inline" } = props;
  const strings = useSignInStrings();
  const titleId = useId();
  const [code, setCode] = useState("");
  const title = strings.t(TITLE_KEY[family]);
  const line = statusLine(strings, family, view);
  const shown = view.state === "waiting" && view.way.kind === "code" ? view.way.code : null;
  const pasting = view.state === "waiting" && view.way.kind === "paste";
  const submit = () => {
    const pasted = code.trim();
    if (!pasted) return;
    setCode("");
    props.onSubmitCode?.(pasted);
  };
  const actions = (
    <ActionButtons view={view} strings={strings} props={props} canSubmit={code.trim() !== ""} submit={submit} />
  );
  const paste = pasting && (
    <PasteField
      strings={strings}
      code={code}
      setCode={setCode}
      onSubmit={submit}
      busy={view.state === "waiting" && view.busy === true}
    />
  );

  if (look === "strip") {
    return (
      <section className="signin" data-look="strip" data-state={view.state} aria-labelledby={titleId}>
        <ProviderMark family={family} size={14} />
        <span className="signin-strip-title" id={titleId}>
          {view.state === "starting" || view.state === "waiting"
            ? strings.format("signIn.strip", FAMILY_BRAND[family])
            : title}
        </span>
        <span className="signin-dot" aria-hidden="true">
          ·
        </span>
        {shown ? (
          <Code code={shown} strings={strings} size="small" />
        ) : (
          <output className="signin-line" aria-live="polite">
            {line}
          </output>
        )}
        {paste}
        {actions}
      </section>
    );
  }

  const body = (
    <>
      <header className="signin-head">
        <ProviderMark family={family} size={look === "sheet" ? 28 : 16} />
        <span className="signin-title" id={titleId}>
          {title}
        </span>
      </header>
      {shown && <Code code={shown} strings={strings} size="large" />}
      {look === "sheet" && view.state === "waiting" && view.way.kind === "code" ? (
        <ol className="signin-steps">
          <li>{strings.t("signIn.step.open")}</li>
          <li>{strings.t("signIn.step.paste")}</li>
          <li>{strings.t("signIn.step.wait")}</li>
        </ol>
      ) : null}
      <output className="signin-line" aria-live="polite">
        <StateGlyph view={view} />
        <span>
          {look === "sheet" && view.state === "waiting" && view.way.kind === "code"
            ? strings.t("signIn.waiting")
            : line}
        </span>
      </output>
      {paste}
      {actions}
    </>
  );

  if (look === "sheet") {
    return (
      <Dialog
        open
        label={title}
        onOpenChange={(open) => {
          if (open) return;
          if (view.state === "starting" || view.state === "waiting") props.onCancel?.();
          else props.onDone?.();
        }}
        className="ui-glass ui-glass-floats signin-sheet"
      >
        <section className="signin" data-look="sheet" data-state={view.state} aria-labelledby={titleId}>
          {body}
        </section>
      </Dialog>
    );
  }

  return (
    <section className="signin" data-look="inline" data-state={view.state} aria-labelledby={titleId}>
      {body}
    </section>
  );
}
