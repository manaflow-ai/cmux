// A message this agent sent another one, as one tool row: "Sending message to tests" with the
// working spinner while it goes out, "Sent message to tests" with the envelope once it went, and
// "Couldn't send to tests" when it failed; then how it was delivered, when the call says ("· queued"),
// and the message's first line, muted. The row opens to the whole message as Markdown and, behind
// Raw, the call itself (its command and output, or its MCP request and response); a failed send
// opens to its output. Both ways of sending draw this one row: a cmux-subsessions `send_message`
// (SubsessionCallCard.tsx) and a shell `acpmux send` (acpmuxSends.ts, `AcpmuxSendLine` below).
// Whether a row is open lasts across the virtualized transcript (transcriptDisclosure.tsx).
import { type ReactNode, useId, useMemo, useState, useSyncExternalStore } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { AcpmuxSendCall, SendState } from "./acpmuxSends";
import { messagePreview } from "./AgentMessageRow";
import { messageDelivery } from "./agentMessages";
import { useFindReveal } from "./chatFind";
import { AlertCircle, ChevronRight, Envelope, Spinner } from "./icons";
import { Markdown } from "./Markdown";
import { ShellBlock } from "./ShellBlock";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import "./SubsessionCallCard.css";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// How the line reads. `sentence`, the default: "Sent message to tests", then the first line muted
/// (Leo 2026-10-24: "sending message or sent message to X or Y"). The others are gallery versions
/// kept beside it (SentMessageLine.gallery.ts): `arrow`, "→ tests: <first line>" (#24977's line),
/// and `quote`, "Sent message to tests: “<first line>”". The native host sends no value.
export type SentLook = "sentence" | "arrow" | "quote";

const LOOKS: readonly SentLook[] = ["sentence", "arrow", "quote"];
let look: SentLook = "sentence";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureSentLook(value: unknown): void {
  const next = LOOKS.find((one) => one === value) ?? "sentence";
  if (next === look) return;
  look = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => look;

export function SentMessageLine({
  tool,
  state,
  target,
  text,
  detail,
  disclosureKey,
  raw,
  rawOpen = false,
}: {
  /// The call: Find in Chat opens the row when its match is in it.
  tool: Tool;
  state: SendState;
  /// Who it went to, by name.
  target: string;
  /// The message, when the call holds it; without it the row names only the target.
  text?: string;
  /// How it was delivered, after the line ("queued", "read at its next step").
  detail?: string;
  disclosureKey: string;
  /// The call as it was made, behind the Raw toggle while open.
  raw: ReactNode;
  /// Raw starts open (a failed send: its output says why).
  rawOpen?: boolean;
}) {
  const t = useT();
  const shape = useSyncExternalStore(subscribe, snapshot, snapshot);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  useFindReveal(
    useMemo((): AcpmuxActivity[] => [{ kind: "tool", text: tool.title, tool }], [tool]),
    () => setOpen(true),
  );
  const id = useId();
  const preview = text ? messagePreview(text) : "";
  const label =
    shape === "arrow" && state !== "failed" && preview
      ? t(state === "sending" ? "subsession.sending" : "subsession.to", { name: target, text: preview })
      : t(state === "sending" ? "send.sending" : state === "failed" ? "send.failed" : "send.sent", { target });
  const icon =
    state === "sending" ? <Spinner size={16} loading /> : state === "failed" ? <AlertCircle /> : <Envelope />;
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle cv-subsession cv-sent${state === "sending" ? " is-live" : " is-strong"}`}
        data-send-state={state}
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        <span className={`cv-tool__icon${state === "failed" ? " cv-tool__failed" : ""}`}>{icon}</span>
        <span className="cv-tool__text">
          {label}
          {shape === "quote" && preview && state !== "failed" && (
            // l10n-allow: punctuation around the message's own words.
            <span className="cv-tool__detail">{`: “${preview}”`}</span>
          )}
          {detail && <span className="cv-tool__detail">{` · ${detail}`}</span>}
          {shape === "sentence" && preview && state !== "failed" && (
            <span className="cv-tool__detail cv-sent__preview">{preview}</span>
          )}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div id={id} className="cv-subsession__under">
          {text && (
            <div className="cv-subsession__markdown selectable">
              <Markdown commits="quiet">{text}</Markdown>
            </div>
          )}
          <RawToggle startOpen={rawOpen}>{raw}</RawToggle>
        </div>
      )}
    </>
  );
}

/// "Raw" and the call under it while open.
export function RawToggle({ children, startOpen = false }: { children: ReactNode; startOpen?: boolean }) {
  const t = useT();
  const [open, setOpen] = useState(startOpen);
  const id = useId();
  return (
    <div className="cv-subsession__raw">
      <button
        type="button"
        className="cv-subsession__toggle"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        {t("subsession.raw")}
        <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
      </button>
      {open && <div id={id}>{children}</div>}
    </div>
  );
}

/// A shell `acpmux send` (acpmuxSends.ts) as the sent-message row; Raw holds its Shell card.
export function AcpmuxSendLine({ tool, send }: { tool: Tool; send: AcpmuxSendCall }) {
  const t = useT();
  // `--no-wait` prints how the daemon took the message; a send that waits prints the reply.
  const delivery = send.noWait && send.state === "sent" ? messageDelivery(tool) : undefined;
  const detail =
    delivery === "queued"
      ? t("subsession.delivery.queuedBare")
      : delivery === "delivered"
        ? t("subsession.delivery.nextStep")
        : undefined;
  return (
    <SentMessageLine
      tool={tool}
      state={send.state}
      target={send.target}
      text={send.text}
      detail={detail}
      disclosureKey={`send:${tool.id}`}
      rawOpen={send.state === "failed"}
      raw={
        <ShellBlock
          command={tool.command}
          output={tool.output}
          exitCode={tool.exitCode}
          live={send.state === "sending"}
        />
      }
    />
  );
}
