// The Pair Another Machine card (design/server-cards.md): the code large with its QR, the
// `cmux pair` line and the install line with their Copy buttons and the countdown; then, once a
// machine used the code, Add Server's facts, four words and name, with Confirm. Every step derives
// from the host's status (model.ts); the card only draws it.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { DialogButton } from "../../../ui/DialogButton";
import { cx } from "../../../ui/cx";
import type { Strings } from "../../shared/i18n";
import {
  buttonsOf,
  clock,
  isClickOnly,
  isEnabled,
  isUrgent,
  phaseOf,
  secondsLeft,
  stepOf,
  type Action,
  type Step,
} from "./model";
import type { CopyTarget, PairInviteApprover, PairInviteShown, PairInviteStatus, PairingCandidate } from "./types";

/** How the invite step lays out its code, QR and lines (design/server-cards.md, Variants). */
export type PairInviteLayout = "side" | "stacked" | "line-first";

export interface PairInviteCardProps {
  status: PairInviteStatus | undefined;
  strings: Strings;
  /** Unix ms, as of the countdown's last tick. */
  now: number;
  copied: CopyTarget | null;
  layout?: PairInviteLayout;
  /** A footer or Copy button. */
  onAction(action: Action): void;
  onRunChief(on: boolean): void;
  /** The Name field changed (the native Confirm reads it). */
  onNameChange?(name: string): void;
  /** Draws Confirm and Try Again in the card's footer (the gallery); in the app the panel's native footer does. */
  controlStandIn?: boolean;
}

const MINTING: PairInviteStatus = {
  session: 0,
  mint: "minting",
  frames: [],
  approver: { step: "enterCode", canApprove: false, runChief: false },
};

export function PairInviteCard({
  status = MINTING,
  strings,
  now,
  copied,
  layout = "side",
  onAction,
  onRunChief,
  onNameChange,
  controlStandIn = false,
}: PairInviteCardProps) {
  const { t } = strings;
  const step = stepOf(phaseOf(status, now), status.approver);
  const candidate = "candidate" in step ? step.candidate : undefined;
  // The Name field keeps what the person typed for this machine; it is read only on Confirm.
  const [typed, setTyped] = useState<{ code: string; value: string } | null>(null);
  const name = candidate && typed?.code === candidate.code ? typed.value : (candidate?.name ?? "");
  // Sent once per change of the field or of the machine (a fresh status is a new object each read).
  const nameChange = useRef(onNameChange);
  nameChange.current = onNameChange;
  const candidateCode = candidate?.code;
  useEffect(() => {
    if (candidateCode) nameChange.current?.(name);
  }, [candidateCode, name]);
  const buttons = buttonsOf(step);
  const press = (action: Action) => onAction(action);
  // Return presses the default button, never Confirm or Try Again: only a click pairs a machine.
  const main = buttons.find((button) => button.key === "return");
  const onReturn = useRef<(() => void) | null>(null);
  onReturn.current =
    main && !isClickOnly(main.action) && isEnabled(main.action, step, status.approver)
      ? () => press(main.action)
      : null;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Enter" || event.isComposing || event.defaultPrevented || !onReturn.current) return;
      event.preventDefault();
      onReturn.current();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
  return (
    <section
      className={cx("server-card pair-invite", `pair-invite--${layout}`)}
      data-card="pair-invite"
      data-step={step.kind}
      aria-label={t("pairInvite.title")}
    >
      <Body
        step={step}
        approver={status.approver}
        strings={strings}
        now={now}
        copied={copied}
        layout={layout}
        name={name}
        onName={(value) => candidate && setTyped({ code: candidate.code, value })}
        onCopy={(action) => press(action)}
        onRunChief={onRunChief}
      />
      <footer className="server-card-footer">
        {step.kind === "approving" && <Spinner size={12} loading className="server-card-spinner" />}
        <span className="server-card-footer-gap" />
        {buttons
          // Confirm and Try Again are the panel's native footer, never the page's (the gallery
          // draws them in their place).
          .filter((button) => controlStandIn || !isClickOnly(button.action))
          .map((button) => (
            <DialogButton
              key={button.action}
              dialogKey={isClickOnly(button.action) ? null : button.key}
              className={cx("server-card-button", button.key === "return" && "is-default")}
              data-action={button.action}
              disabled={!isEnabled(button.action, step, status.approver)}
              onClick={isClickOnly(button.action) ? undefined : () => press(button.action)}
            >
              {buttonTitle(button.action, strings, copied)}
            </DialogButton>
          ))}
      </footer>
    </section>
  );
}

function buttonTitle(action: Action, { t }: Strings, copied: CopyTarget | null): string {
  switch (action) {
    case "copyCode":
      return copied === "code" ? t("pairInvite.copied") : t("pairInvite.copyCode");
    case "copyLine":
      return copied === "line" ? t("pairInvite.copied") : t("pairInvite.copyLine");
    case "copyInstallLine":
      return copied === "installLine" ? t("pairInvite.copied") : t("pairInvite.copyInstallLine");
    case "confirm":
      return t("pairInvite.confirm");
    case "retry":
      return t("approver.retry");
    case "newCode":
      return t("pairInvite.newCode");
    case "done":
      return t("approver.done");
    case "cancel":
      return t("approver.cancel");
  }
}

interface BodyProps {
  step: Step;
  approver: PairInviteApprover;
  strings: Strings;
  now: number;
  copied: CopyTarget | null;
  layout: PairInviteLayout;
  name: string;
  onName(value: string): void;
  onCopy(action: Action): void;
  onRunChief(on: boolean): void;
}

function Body({ step, approver, strings, now, copied, layout, name, onName, onCopy, onRunChief }: BodyProps) {
  const { t, format } = strings;
  switch (step.kind) {
    case "minting":
      return (
        <>
          <Header text={t("pairInvite.title")} />
          <Waiting text={t("pairInvite.minting")} />
        </>
      );
    case "showing":
      return (
        <>
          <Header text={t("pairInvite.title")} />
          <p className="server-card-text">{t("pairInvite.help")}</p>
          <Invite invite={step.invite} strings={strings} now={now} copied={copied} layout={layout} onCopy={onCopy} />
        </>
      );
    case "lookingUp":
      return (
        <>
          <Header text={t("pairInvite.arrived")} />
          <Waiting text={t("pairInvite.lookingUp")} />
        </>
      );
    case "review":
    case "approving":
    case "approveFailed":
      return (
        <>
          <Review
            candidate={step.candidate}
            approver={approver}
            strings={strings}
            name={name}
            onName={onName}
            onRunChief={onRunChief}
          />
          {step.kind === "approveFailed" && <p className="server-card-text is-danger">{step.reject}</p>}
        </>
      );
    case "paired":
      return (
        <>
          <Header text={format("pairInvite.paired", step.name)} />
          <p className="server-card-text">{t("pairInvite.pairedDetail")}</p>
        </>
      );
    case "voided":
      return <Ended title={t("pairInvite.title")} text={t("pairInvite.voided")} danger />;
    case "expired":
      return <Ended title={t("pairInvite.title")} text={t("pairInvite.expired")} />;
    case "lost":
      return <Ended title={t("pairInvite.title")} text={t("pairInvite.lost")} />;
    case "signedOut":
      return <Ended title={t("pairInvite.title")} text={t("pairInvite.signedOut")} />;
    case "failed":
      return <Ended title={t("pairInvite.title")} text={step.text} danger />;
  }
}

function Header({ text }: { text: string }) {
  return <h1 className="server-card-title">{text}</h1>;
}

function Waiting({ text }: { text: string }) {
  return (
    <p className="server-card-waiting">
      <Spinner size={12} loading className="server-card-spinner" />
      <span>{text}</span>
    </p>
  );
}

function Ended({ title, text, danger }: { title: string; text: string; danger?: boolean }) {
  return (
    <>
      <Header text={title} />
      <p className={cx("server-card-text is-primary", danger && "is-danger")}>{text}</p>
    </>
  );
}

interface InviteProps {
  invite: PairInviteShown;
  strings: Strings;
  now: number;
  copied: CopyTarget | null;
  layout: PairInviteLayout;
  onCopy(action: Action): void;
}

function Invite({ invite, strings, now, copied, layout, onCopy }: InviteProps) {
  const { t, format } = strings;
  const left = secondsLeft(invite, now);
  const copyButton = (action: Action) => (
    <DialogButton
      dialogKey={null}
      className="server-card-button is-small"
      data-action={action}
      onClick={() => onCopy(action)}
    >
      {buttonTitle(action, strings, copied)}
    </DialogButton>
  );
  const code = (
    <div className="pair-invite-code-column">
      <output className="pair-invite-code" data-testid="pair-invite-code">
        {invite.code}
      </output>
      {copyButton("copyCode")}
      <p className="pair-invite-meta">
        <span className={cx("pair-invite-countdown", isUrgent(left) && "is-urgent")} role="timer">
          {format("pairInvite.expiresIn", clock(left))}
        </span>
        <span> · {t("pairInvite.once")}</span>
      </p>
      <p className="pair-invite-meta">{t("pairInvite.scan")}</p>
    </div>
  );
  const qr = invite.qr ? (
    <img className="pair-invite-qr" src={invite.qr} alt={t("pairInvite.scan")} width={132} height={132} />
  ) : (
    <span className="pair-invite-qr" aria-hidden="true" />
  );
  const lines: ReactNode = (
    <>
      <Line text={invite.line} button={copyButton("copyLine")} />
      <p className="server-card-caption">{t("pairInvite.installHelp")}</p>
      <Line text={invite.installLine} button={copyButton("copyInstallLine")} />
    </>
  );
  const top = (
    <div className="pair-invite-top">
      {code}
      {qr}
    </div>
  );
  return (
    <>
      {layout === "line-first" ? (
        <>
          {lines}
          {top}
        </>
      ) : (
        <>
          {top}
          {lines}
        </>
      )}
      <Waiting text={t("pairInvite.waiting")} />
    </>
  );
}

function Line({ text, button }: { text: string; button: ReactNode }) {
  return (
    <div className="pair-invite-line">
      <code className="pair-invite-line-text">{text}</code>
      {button}
    </div>
  );
}

interface ReviewProps {
  candidate: PairingCandidate;
  approver: PairInviteApprover;
  strings: Strings;
  name: string;
  onName(value: string): void;
  onRunChief(on: boolean): void;
}

function Review({ candidate, approver, strings, name, onName, onRunChief }: ReviewProps) {
  const { t } = strings;
  const facts = [candidate.os, candidate.version, regionName(candidate.region, strings.language)].filter(Boolean);
  return (
    <>
      <Header text={t("pairInvite.arrived")} />
      <div className="pair-invite-facts" data-testid="pair-invite-facts">
        <strong>{candidate.name}</strong>
        <span>{facts.join(" · ")}</span>
      </div>
      <p className="server-card-text is-emphasized">{t("approver.wordsQuestion")}</p>
      <ol className="pair-invite-words" aria-label={candidate.words.join(", ")}>
        {candidate.words.map((word, index) => (
          <li key={`${index}-${word}`} className="pair-invite-word">
            <span className="pair-invite-word-index">{index + 1}</span>
            <span>{word}</span>
          </li>
        ))}
      </ol>
      <p className="server-card-caption">{t("approver.wordsWarning")}</p>
      <label className="pair-invite-name">
        <span>{t("approver.name")}</span>
        <input
          className="pair-invite-name-field"
          value={name}
          placeholder={candidate.name}
          aria-label={t("approver.name")}
          onChange={(event) => onName(event.target.value)}
        />
      </label>
      <label className="pair-invite-chief">
        <input
          type="checkbox"
          aria-label={t("approver.runChief")}
          checked={approver.runChief}
          onChange={(event) => onRunChief(event.target.checked)}
        />
        <span>{t("approver.runChief")}</span>
      </label>
      <p className="server-card-caption">{t("pairInvite.confirmNote")}</p>
    </>
  );
}

/** A region code's name in the card's language (`DE` → `Germany`), else the code. */
export function regionName(region: string | undefined, language: string): string {
  if (!region) return "";
  try {
    return new Intl.DisplayNames([language], { type: "region" }).of(region) ?? region;
  } catch {
    return region;
  }
}
