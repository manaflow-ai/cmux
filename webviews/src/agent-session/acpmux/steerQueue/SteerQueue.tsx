import { type KeyboardEvent, useEffect, useRef, useState } from "react";
import { KeyboardScope } from "../../../ui/KeyboardScope";
import { Listbox } from "../../../ui/Listbox";
import { useT } from "../i18n";
import { shortAge } from "../sessionList";
import type { SteerActKind } from "./log";
import { nextFocus, type SteerItem } from "./model";
import "./steerQueue.css";

/// What a step into a chat does. Each settles once acpmux took it, and rejects when it was refused.
export type SteerActions = {
  /// A typed line: into the running turn (a steer), or as the next prompt of a finished chat.
  steer(item: SteerItem, text: string): Promise<unknown>;
  /// Stops the running turn and sends the typed line as the next prompt.
  redirect(item: SteerItem, text: string): Promise<unknown>;
  stop(item: SteerItem): Promise<unknown>;
  /// Forks the chat as it is now, its own turn going on.
  fork(item: SteerItem): Promise<unknown>;
  /// Opens the chat and then closes the queue; a typed line goes on in its composer.
  open(item: SteerItem, draft?: string): Promise<unknown>;
};

/// How a row draws: two lines with the live step under the title (`rows`, the default), one line
/// each (`compact`), or rows beside the focused chat's whole line and its last step (`split`).
export type SteerQueueLook = "rows" | "compact" | "split";

/// An open never reads as done: the queue closes when it lands.
type Step = { sessionId: string; act: SteerActKind | "open"; state: "sending" | "done" | "failed" };

/// How long a row says what was done before it reads as the chat again.
const DONE_MS = 2_400;

/// The Steer queue (model.ts): a floating list over the chat, the field always focused, so the
/// person moves with the arrows and acts with one key: Return steers (or opens a chat that waits on
/// them), ⌘Return redirects, ⌘. stops, ⌘⇧Return forks, a digit with nothing typed jumps to a row
/// (⌘1-9 are the app's workspace keys), Escape closes.
export function SteerQueue({
  items,
  now,
  actions,
  onClose,
  onAct,
  look = "rows",
  initialFocus,
}: {
  items: readonly SteerItem[];
  now: number;
  actions: SteerActions;
  onClose(): void;
  /// The person stepped into a chat: the App records it (log.ts).
  onAct?(item: SteerItem, act: SteerActKind, text?: string): void;
  look?: SteerQueueLook;
  /// The chat focused when the queue opens; the first row when absent or not listed.
  initialFocus?: string;
}) {
  const t = useT();
  const field = useRef<HTMLInputElement>(null);
  // Focus follows a chat, not a row: the list re-ranks as acpmux reports, and the person's place
  // stays on the chat they were looking at.
  const [focusId, setFocusId] = useState(initialFocus);
  const [text, setText] = useState("");
  const [step, setStep] = useState<Step>();
  const found = items.findIndex((item) => item.sessionId === focusId);
  const index = Math.max(0, found);
  // A typed line never moves to another chat: when the chat it was for leaves the list, nothing is
  // focused until the person picks one, so Return cannot steer an agent they did not choose.
  const focused = found >= 0 || focusId === undefined || !text ? items[index] : undefined;

  const frame = useRef<HTMLDivElement>(null);
  useEffect(() => field.current?.focus(), []);
  useEffect(() => {
    const panel = frame.current;
    if (!panel) return;
    const keepField = (event: MouseEvent) => {
      if (event.target !== field.current) event.preventDefault();
    };
    panel.addEventListener("mousedown", keepField);
    return () => panel.removeEventListener("mousedown", keepField);
  }, []);
  useEffect(() => {
    if (step?.state !== "done") return;
    const timer = window.setTimeout(() => setStep(undefined), DONE_MS);
    return () => window.clearTimeout(timer);
  }, [step]);

  const move = (to: number) => {
    const item = items[Math.min(Math.max(to, 0), items.length - 1)];
    if (item) setFocusId(item.sessionId);
  };

  const run = (item: SteerItem, act: SteerActKind, work: () => Promise<unknown>, typed?: string) => {
    if (step?.state === "sending") return;
    // The field as it was when the step went (the person may type on meanwhile).
    const sent = text;
    setStep({ sessionId: item.sessionId, act, state: "sending" });
    work().then(
      () => {
        onAct?.(item, act, typed);
        setStep({ sessionId: item.sessionId, act, state: "done" });
        // Only the line that went leaves the field: words typed while it was on its way stay.
        if (typed !== undefined)
          setText((current) => (current.startsWith(sent) ? current.slice(sent.length).trimStart() : current));
        // On down the list: the next chat that may need the person.
        const next = items[nextFocus(items.length, items.indexOf(item))];
        if (next && act !== "fork") setFocusId(next.sessionId);
      },
      () => setStep({ sessionId: item.sessionId, act, state: "failed" }),
    );
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    // The Enter or Escape that ends an input method's composition is the input method's.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    const command = event.metaKey || event.ctrlKey;
    const typed = text.trim();
    let used = true;
    if (event.key === "Escape") {
      if (text) setText("");
      else onClose();
    } else if (event.key === "ArrowDown" || (event.ctrlKey && event.key === "n")) move(index + 1);
    else if (event.key === "ArrowUp" || (event.ctrlKey && event.key === "p")) move(index - 1);
    else if (!text && !command && !event.altKey && /^[1-9]$/.test(event.key)) move(Number(event.key) - 1);
    else if (!focused) used = false;
    else if (command && event.key === ".") {
      if (focused.running) run(focused, "stop", () => actions.stop(focused));
    } else if (event.key === "Enter" && command && event.shiftKey) run(focused, "fork", () => actions.fork(focused));
    else if (event.key === "Enter" && command) {
      if (focused.running && typed) run(focused, "redirect", () => actions.redirect(focused, typed), typed);
    } else if (event.key === "Enter" && !event.shiftKey) {
      // A chat that waits on the person is answered in it: its ask has its own card there.
      if (!typed || focused.reason === "ask") {
        if (step?.state === "sending") return;
        const item = focused;
        setStep({ sessionId: item.sessionId, act: "open", state: "sending" });
        actions
          .open(item, typed || undefined)
          .catch(() => setStep({ sessionId: item.sessionId, act: "open", state: "failed" }));
      } else run(focused, focused.running ? "steer" : "reply", () => actions.steer(focused, typed), typed);
    } else used = false;
    if (used) event.preventDefault();
  };

  const placeholder = !focused
    ? t("steerQueue.placeholder.empty")
    : focused.reason === "ask"
      ? t("steerQueue.placeholder.ask", { name: focused.title })
      : focused.running
        ? t("steerQueue.placeholder.steer", { name: focused.title })
        : t("steerQueue.placeholder.reply", { name: focused.title });

  return (
    <KeyboardScope className="acpmux-steer-queue ui-popup ui-glass" handleKeyDown={handleKeyDown}>
      {/* A press anywhere on the panel keeps the keyboard in the field: with focus on the page, keys
          would reach the chat under the queue (its composer, a permission card's digits, Esc Esc). */}
      <div ref={frame} className="acpmux-steer-frame">
        <div className="acpmux-steer-head">
          <span>{t("steerQueue.title")}</span>
          <span className="acpmux-steer-count">{items.length || ""}</span>
        </div>
        <div className="acpmux-steer-body" data-look={look}>
          <Listbox
            items={items}
            getKey={(item) => item.sessionId}
            textValue={(item) => item.title}
            label={t("steerQueue.title")}
            className="acpmux-steer-list"
            rowClassName="acpmux-steer-row"
            // The field keeps the keyboard; the list follows its focus (aria-activedescendant).
            autoFocus={false}
            activeIndex={index}
            onActiveIndexChange={move}
            itemAttributes={(item) => ({
              "data-reason": item.reason,
              "data-step": step?.sessionId === item.sessionId ? step.state : undefined,
            })}
            onOpen={(item) => {
              setFocusId(item.sessionId);
              field.current?.focus();
            }}
            renderItem={(item, at) => (
              <SteerRow
                item={item}
                index={at}
                now={now}
                step={step?.sessionId === item.sessionId ? step : undefined}
                look={look}
              />
            )}
            empty={<div className="acpmux-steer-empty">{t("steerQueue.empty")}</div>}
          />
          {look === "split" && focused ? <SteerDetail item={focused} now={now} /> : null}
        </div>
        <input
          ref={field}
          className="acpmux-steer-field"
          value={text}
          placeholder={placeholder}
          aria-label={placeholder}
          spellCheck={false}
          onChange={(event) => {
            // The first key typed pins the line to the chat it was typed for: a re-rank that moves
            // another chat to the top does not take the line with it.
            if (!text && focusId === undefined && items[index]) setFocusId(items[index].sessionId);
            setText(event.target.value);
          }}
        />
        <div className="acpmux-steer-hints" aria-hidden>
          {focused?.reason === "ask" ? (
            <Hint keys="↩" label={t("steerQueue.hint.open")} />
          ) : (
            <Hint keys="↩" label={t(focused?.running ? "steerQueue.hint.steer" : "steerQueue.hint.reply")} />
          )}
          {focused?.running ? <Hint keys="⌘↩" label={t("steerQueue.hint.redirect")} /> : null}
          {focused?.running ? <Hint keys="⌘." label={t("steerQueue.hint.stop")} /> : null}
          {focused ? <Hint keys="⌘⇧↩" label={t("steerQueue.hint.fork")} /> : null}
          <Hint keys="⎋" label={t("steerQueue.hint.close")} />
        </div>
      </div>
    </KeyboardScope>
  );
}

function SteerRow({
  item,
  index,
  now,
  step,
  look,
}: {
  item: SteerItem;
  index: number;
  now: number;
  step?: Step;
  look: SteerQueueLook;
}) {
  const t = useT();
  // The last thing the person did shows until the chat moves on from it: then its ask, error or
  // step under way is what the row is for.
  const answered = item.line !== undefined && item.at !== undefined && item.last && item.at > item.last.at;
  const said = step
    ? stepLabel(step, t)
    : item.last && !answered
      ? `${t(`steerQueue.act.${item.last.act}`)} · ${shortAge(item.last.at, now, t)}`
      : undefined;
  return (
    <>
      <span className="acpmux-steer-mark" aria-hidden />
      <span className="acpmux-steer-main">
        <span className="acpmux-steer-top">
          <span className="acpmux-steer-name">{item.title}</span>
          <span className="acpmux-steer-reason">{t(`steerQueue.reason.${item.reason}`)}</span>
          {item.host ? <span className="acpmux-steer-host">{item.host}</span> : null}
          <span className="acpmux-steer-age">{shortAge(item.at, now, t)}</span>
        </span>
        {look !== "compact" ? <span className="acpmux-steer-line">{item.line ?? ""}</span> : null}
        {said ? <span className="acpmux-steer-said">{said}</span> : null}
      </span>
      <kbd className="acpmux-steer-key">{index + 1}</kbd>
    </>
  );
}

function SteerDetail({ item, now }: { item: SteerItem; now: number }) {
  const t = useT();
  return (
    <aside className="acpmux-steer-detail">
      <div className="acpmux-steer-detail-name">{item.title}</div>
      <div className="acpmux-steer-detail-meta">
        {[t(`steerQueue.reason.${item.reason}`), item.harness, item.host, shortAge(item.at, now, t)]
          .filter(Boolean)
          .join(" · ")}
      </div>
      {item.line ? <p className="acpmux-steer-detail-line">{item.line}</p> : null}
      {item.last ? (
        <div className="acpmux-steer-detail-last">
          {t(`steerQueue.act.${item.last.act}`)} · {shortAge(item.last.at, now, t)}
          {item.last.text ? <q>{item.last.text}</q> : null}
        </div>
      ) : null}
    </aside>
  );
}

function stepLabel(step: Step, t: ReturnType<typeof useT>): string {
  if (step.state === "sending") return t("steerQueue.state.sending");
  if (step.state === "failed") return t("steerQueue.state.failed");
  return step.act === "open" ? t("steerQueue.state.sending") : t(`steerQueue.act.${step.act}`);
}

function Hint({ keys, label }: { keys: string; label: string }) {
  return (
    <span className="acpmux-steer-hint">
      <kbd>{keys}</kbd>
      {label}
    </span>
  );
}
