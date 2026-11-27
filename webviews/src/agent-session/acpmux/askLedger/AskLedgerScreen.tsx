import { useEffect, useRef, useState } from "react";
import { intl } from "../../../ui/intl";
import { useT } from "../i18n";
import "./askLedger.css";

type AskLedgerEntry = {
  id: string;
  text: string;
  createdAt: number;
  harness: string;
  sessionId: string;
  host: string;
  truncated: boolean;
};

function formatTime(createdAt: number): string {
  return intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(createdAt);
}

export function AskLedgerScreen({ load }: { load(): Promise<unknown> }) {
  const t = useT();
  const [entries, setEntries] = useState<AskLedgerEntry[]>();
  const [failed, setFailed] = useState(false);
  // The page loads once, on mount, with the loader it mounted with.
  const loadRef = useRef(load);
  useEffect(() => {
    let active = true;
    void loadRef.current().then(
      (reply) => {
        if (!active) return;
        const rows = (reply as { entries?: AskLedgerEntry[] } | null)?.entries;
        if (Array.isArray(rows)) setEntries(rows);
        else setFailed(true);
      },
      () => {
        if (active) setFailed(true);
      },
    );
    return () => {
      active = false;
    };
  }, []);
  return (
    <section className="acpmux-ask-ledger" aria-labelledby="acpmux-ask-ledger-title">
      <h2 id="acpmux-ask-ledger-title" className="acpmux-ask-ledger-title">
        {t("askLedger.title")}
      </h2>
      <p className="acpmux-ask-ledger-empty">{t("askLedger.scope")}</p>
      {failed ? (
        <p role="alert">{t("askLedger.failed")}</p>
      ) : !entries ? (
        <p>{t("ledger.loading")}</p>
      ) : entries.length === 0 ? (
        <p className="acpmux-ask-ledger-empty">{t("askLedger.empty")}</p>
      ) : (
        <ol className="acpmux-ask-ledger-list">
          {entries.map((entry) => (
            <li key={entry.id} className="acpmux-ask-ledger-row">
              <p className="acpmux-ask-ledger-text">
                {entry.text}
                {entry.truncated && "…"}
              </p>
              <p className="acpmux-ask-ledger-meta">
                <time dateTime={new Date(entry.createdAt).toISOString()}>{formatTime(entry.createdAt)}</time>
                {entry.harness && <span>{entry.harness}</span>}
                {entry.sessionId && <span>{entry.sessionId}</span>}
                <span>{entry.host}</span>
              </p>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
