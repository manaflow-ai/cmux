import type { ReactNode } from "react";
import type { ClientInfo, CmuxClient, Id } from "cmux/browser";
import { t } from "../i18n";
import type { TerminalSize } from "../lib/fit";
import { ExtraKeysBar } from "./ExtraKeysBar";

interface TerminalFrameProps {
  children: ReactNode;
  client: CmuxClient | null;
  clients: ClientInfo[];
  surface: Id;
  focused: boolean;
  foreignSize: TerminalSize | null;
  error: string | null;
  onKey?(key: string): void;
  onSend(text: string): void;
}

export function TerminalFrame({
  children,
  client,
  clients,
  surface,
  focused,
  foreignSize,
  error,
  onKey,
  onSend,
}: TerminalFrameProps) {
  const matchingClients = foreignSize === null
    ? []
    : clients.filter((candidate) => (
      !candidate.self
      && candidate.sizes.some((size) => (
        size.surface === surface
        && size.cols === foreignSize.cols
        && size.rows === foreignSize.rows
      ))
    ));
  const foreignSizeHint = foreignSize === null
    ? null
    : matchingClients.length === 1
      ? t("foreignSizeNamed", {
          name: matchingClients[0]!.name || t("unnamed"),
          cols: foreignSize.cols,
          rows: foreignSize.rows,
        })
      : t("foreignSizeGeneric", { cols: foreignSize.cols, rows: foreignSize.rows });

  return (
    <>
      <div className={`terminal-stage${focused ? " terminal-focused" : ""}`}>
        {children}
        {foreignSizeHint !== null && <div className="foreign-size-hint">{foreignSizeHint}</div>}
        {error && <div className="terminal-error" role="alert">{error}</div>}
      </div>
      <ExtraKeysBar visible={focused && client !== null} onKey={onKey} onSend={onSend} />
    </>
  );
}
