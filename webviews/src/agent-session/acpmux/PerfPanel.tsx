// The Inspector's Perf tab: the live perf commentator (acpmux perf_watch.rs; Leo, 2026-11-18: "it's
// timing this, it's timing that. It's showing you in detail, like what's happening"). A switch turns
// the daemon's watch on or off (off by default); while it is on the tab shows the daemon's notes,
// each span as a waterfall of its parts against its budget, and the data meter's hot zones, and
// Copy diagnosis copies the last minute with the page's own marks as JSON.
//
// The tab reads only while it is open and the watch is on: one `read` at a time that waits for the
// next event (READ_WAIT_MS), stopped when the tab closes, the watch goes off or a read fails.
import { useEffect, useRef, useState } from "react";
import { Button } from "../../ui/Button";
import { Switch } from "../../ui/Switch";
import { copyTextResult } from "./conversation/clipboard";
import { translate, useT } from "./i18n";
import { clockTime } from "./inspectorModel";
import { acpmuxPerf } from "./perf";
import {
  appendEvents,
  byteText,
  EVENTS_KEPT,
  meterOf,
  msText,
  nextAfter,
  notesOf,
  perfStatus,
  READ_WAIT_MS,
  readEvents,
  spansOf,
  waterfall,
  type PerfEvent,
  type PerfSpanEvent,
} from "./perfPanelModel";
import { perfReporter, type PerfReporter, type PerfSend } from "./perfReporter";
import { acpWire } from "./wire";
import "./Inspector.css";

/** The page's own state for Copy diagnosis: its marks and render counts (perf.ts) and its wire stats. */
function pageState(): Record<string, unknown> {
  return {
    agentLatency: acpmuxPerf.agentLatency(),
    launchTimeline: acpmuxPerf.launchTimeline(),
    renders: Object.fromEntries(acpmuxPerf.renders),
    wire: acpWire.stats(),
  };
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function SpanRow({ span }: { span: PerfSpanEvent }) {
  const t = useT();
  const { bars, budgetAt, over } = waterfall(span);
  const parts = (span.parts ?? []).map((part) => `${part.name} ${msText(part.ms, t)}`).join(" · ");
  return (
    <li className="acpmux-inspector-perf-span" data-over={over ? "true" : undefined}>
      <div className="acpmux-inspector-perf-span-head">
        <time>{clockTime(span.at)}</time>
        <span className="acpmux-inspector-name">{span.name}</span>
        <span className="acpmux-inspector-perf-total">{msText(span.ms, t)}</span>
        {typeof span.budgetMs === "number" && span.budgetMs > 0 && (
          <span className="acpmux-inspector-num">
            {t("inspector.perfBudget", { value: Math.round(span.budgetMs) })}
          </span>
        )}
        {over && <span className="acpmux-inspector-perf-over">{t("inspector.perfOver")}</span>}
      </div>
      <div className="acpmux-inspector-perf-track" aria-hidden="true">
        {bars.map((bar, index) => (
          <span
            key={`${bar.name}-${index}`}
            className="acpmux-inspector-perf-bar"
            style={{ left: `${bar.left}%`, width: `${bar.width}%` }}
            title={bar.name ? `${bar.name} ${msText(bar.ms, t)}` : undefined}
          />
        ))}
        {budgetAt !== undefined && <span className="acpmux-inspector-perf-budget" style={{ left: `${budgetAt}%` }} />}
      </div>
      {parts && <p className="acpmux-inspector-perf-parts">{parts}</p>}
    </li>
  );
}

export function PerfPanel({
  send,
  reporter = perfReporter,
  page = pageState,
  copy = copyTextResult,
}: {
  /** `_acpmux/perf` through the page's client. */
  send: PerfSend;
  reporter?: PerfReporter;
  /** The page's own state for Copy diagnosis. */
  page?: () => Record<string, unknown>;
  copy?: (text: string) => Promise<boolean>;
}) {
  const t = useT();
  /** Undefined until the first status answer. */
  const [on, setOn] = useState<boolean>();
  const [events, setEvents] = useState<PerfEvent[]>([]);
  const [notice, setNotice] = useState<string>();
  const [busy, setBusy] = useState(false);
  /// Where the read loop starts: set with each status answer.
  const startAfter = useRef(0);

  /// The switch's answer: the tab and the page's reporter follow it, and a watch just turned on is
  /// read from its start (its count restarts).
  const apply = (answer: unknown) => {
    const status = perfStatus(answer);
    startAfter.current = 0;
    setEvents([]);
    setOn(status.on);
    reporter.setOn(status.on);
  };

  // The watch's state as the tab opens.
  useEffect(() => {
    let open = true;
    send({ op: "status" }).then(
      (answer) => {
        if (!open) return;
        const status = perfStatus(answer);
        startAfter.current = Math.max(0, status.seq - EVENTS_KEPT);
        setOn(status.on);
        reporter.setOn(status.on);
      },
      (error: unknown) => {
        if (!open) return;
        setOn(false);
        setNotice(translate("inspector.perfFailed", { message: errorText(error) }));
      },
    );
    return () => {
      open = false;
    };
  }, [send, reporter]);

  // The read loop: one long read at a time while the tab is open and the watch is on.
  useEffect(() => {
    if (!on) return;
    let stopped = false;
    void (async () => {
      let after = startAfter.current;
      while (!stopped) {
        let answer: unknown;
        try {
          answer = await send({ op: "read", after, limit: EVENTS_KEPT, waitMs: READ_WAIT_MS });
        } catch (error) {
          if (!stopped) setNotice(translate("inspector.perfFailed", { message: errorText(error) }));
          return;
        }
        if (stopped) return;
        if (!perfStatus(answer).on) {
          setOn(false);
          reporter.setOn(false);
          return;
        }
        const incoming = readEvents(answer);
        if (incoming.length) setEvents((kept) => appendEvents(kept, incoming));
        after = nextAfter(after, answer, incoming);
      }
    })();
    return () => {
      stopped = true;
    };
  }, [on, send, reporter]);

  const toggle = async (next: boolean) => {
    setBusy(true);
    setNotice(undefined);
    // No `finally`: the React Compiler cannot memoize a try with one (react-doctor react-hooks-js/todo).
    const answer = await send({ op: next ? "on" : "off" }).then(
      (value) => ({ value }),
      (error: unknown) => ({ error }),
    );
    setBusy(false);
    if ("error" in answer) setNotice(t("inspector.perfFailed", { message: errorText(answer.error) }));
    else apply(answer.value);
  };

  const copyDiagnosis = async () => {
    setNotice(undefined);
    let snapshot: unknown;
    try {
      snapshot = await send({ op: "snapshot" });
    } catch (error) {
      setNotice(t("inspector.perfFailed", { message: errorText(error) }));
      return;
    }
    const text = JSON.stringify(
      { type: "cmux-perf-diagnosis", copiedAt: new Date().toISOString(), snapshot, page: page() },
      null,
      2,
    );
    setNotice((await copy(text)) ? t("inspector.perfCopied") : t("inspector.copyFailed"));
  };

  const notes = notesOf(events);
  const spans = spansOf(events);
  const meter = meterOf(events);

  return (
    <div className="acpmux-inspector-perf">
      <div className="acpmux-inspector-perf-tools">
        <label className="acpmux-inspector-perf-switch">
          <Switch
            size="sm"
            checked={on === true}
            disabled={on === undefined || busy}
            onCheckedChange={(checked) => void toggle(checked)}
          />
          {t("inspector.perfWatch")}
        </label>
        {notice && <output className="acpmux-inspector-count">{notice}</output>}
        {on && (
          <Button size="sm" onClick={() => void copyDiagnosis()}>
            {t("inspector.perfCopy")}
          </Button>
        )}
      </div>
      {on === false && <p className="acpmux-inspector-perf-empty">{t("inspector.perfOffHint")}</p>}
      {on && (
        <div className="acpmux-inspector-perf-body">
          <section aria-label={t("inspector.perfNotes")}>
            <h3 className="acpmux-inspector-perf-heading">{t("inspector.perfNotes")}</h3>
            {notes.length ? (
              <ol className="acpmux-inspector-perf-notes">
                {notes.map((note) => (
                  <li key={note.seq}>
                    <time>{clockTime(note.at)}</time>
                    <span>{note.text}</span>
                    {note.quietedBefore ? (
                      <span className="acpmux-inspector-num">
                        {t("inspector.perfQuieted", { count: note.quietedBefore })}
                      </span>
                    ) : null}
                  </li>
                ))}
              </ol>
            ) : (
              <p className="acpmux-inspector-perf-empty">{t("inspector.perfNoNotes")}</p>
            )}
          </section>
          <section aria-label={t("inspector.perfTimings")}>
            <h3 className="acpmux-inspector-perf-heading">{t("inspector.perfTimings")}</h3>
            {spans.length ? (
              <ol className="acpmux-inspector-perf-spans">
                {spans.map((span) => (
                  <SpanRow key={span.seq} span={span} />
                ))}
              </ol>
            ) : (
              <p className="acpmux-inspector-perf-empty">{t("inspector.perfNoTimings")}</p>
            )}
          </section>
          <section aria-label={t("inspector.perfData")}>
            <h3 className="acpmux-inspector-perf-heading">{t("inspector.perfData")}</h3>
            {meter.length ? (
              <table className="acpmux-inspector-perf-meter">
                <thead>
                  <tr>
                    <th>{t("inspector.perfChannel")}</th>
                    <th>{t("inspector.perfWhat")}</th>
                    <th>{t("inspector.perfPerMinute")}</th>
                    <th>{t("inspector.perfTotal")}</th>
                    <th>{t("inspector.perfLargest")}</th>
                  </tr>
                </thead>
                <tbody>
                  {meter.map((zone) => (
                    <tr key={`${zone.channel} ${zone.label}`}>
                      <td>{zone.channel}</td>
                      <td className="acpmux-inspector-perf-label">{zone.label}</td>
                      <td>{byteText(zone.bytesPerMinute, t)}</td>
                      <td>{byteText(zone.bytes, t)}</td>
                      <td>{byteText(zone.largest, t)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="acpmux-inspector-perf-empty">{t("inspector.perfNoData")}</p>
            )}
          </section>
        </div>
      )}
    </div>
  );
}
