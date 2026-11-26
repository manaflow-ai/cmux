import { useEffect, useState } from "react";
import type { Strings } from "../shared/i18n";
import type { TerminalHistoryStore } from "./store";

import type { RawChunk, RawSection } from "./types";

// A large record can span several reverse pages. Each section stays folded until requested,
// and replacing its visible chunk bounds the DOM even when a record holds an attachment.
export function RawRecord({
  store,
  strings,
  section,
  matchOffset,
}: {
  store: TerminalHistoryStore;
  strings: Strings;
  section: RawSection;
  matchOffset?: number;
}) {
  const [open, setOpen] = useState(matchOffset !== undefined);
  const [offset, setOffset] = useState(matchOffset ?? section.start);
  const [chunk, setChunk] = useState<RawChunk>();
  const [failed, setFailed] = useState(false);
  const [previous, setPrevious] = useState<number[]>([]);
  useEffect(() => {
    if (matchOffset === undefined) return;
    setPrevious([]);
    setOffset(matchOffset);
    setOpen(true);
  }, [matchOffset]);
  useEffect(() => {
    if (!open) return;
    let current = true;
    setChunk(undefined);
    setFailed(false);
    void store.readRaw(section, offset).then(
      (value) => {
        if (current) setChunk(value);
      },
      () => {
        if (current) setFailed(true);
      },
    );
    return () => {
      current = false;
    };
  }, [store, section, offset, open]);

  return (
    <details className="terminal-history-tools" open={open} onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary>{strings.t("history.rawRecord")}</summary>
      {open && (
        <>
          {failed ? <p role="alert">{strings.t("terminalHistory.unavailable")}</p> : <pre>{chunk?.text}</pre>}
          {offset > section.start && (
            <button
              type="button"
              onClick={() => {
                setOffset(previous.at(-1) ?? section.start);
                setPrevious(previous.slice(0, -1));
              }}
            >
              {strings.t("find.previous")}
            </button>
          )}
          {chunk?.nextOffset != null && (
            <button
              type="button"
              onClick={() => {
                setPrevious([...previous, offset]);
                setOffset(chunk.nextOffset!);
              }}
            >
              {strings.t("find.next")}
            </button>
          )}
        </>
      )}
    </details>
  );
}
