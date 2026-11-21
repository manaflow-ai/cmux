// The composer hat's marks beside the composer instead of over it (hatSide.experiment.ts). Leo,
// 2026-11-21, on the Rolodex hat: "this is uncomfortably tight. didn't we say we wanted to move these
// to the side or smth?". The same marks as the hat's header (SubagentTray.tsx `stackMarks`), in a slim
// column at the composer's right or left, or inline on its bottom line: hovering or focusing one lifts
// it and names its line beside it (`peekOf`, the hat's own words), a click opens it (`openHatMark`, the
// hat's own open path), and the list control shows the hat's full list over the composer.
import { useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { BackgroundCommand } from "../session-info/processes";
import { AgentIdentity } from "./AgentIdentity";
import { SubagentHarnessContext } from "./subagentGroupModel";
import type { TrayItem } from "./runningTray";
import { longestRunningFirst } from "./trayHeadOrder";
import { markTarget, openHatMark, peekOf, stackMarks } from "./SubagentTray";
import "./hatRail.css";
import { focusRoute } from "../../../ui/focusRoute";
import type { HatSide } from "./hatSide.experiment";
import { useTraySeen } from "./traySeen";

const MARK = rowIconSize(12);
const NO_ITEMS: readonly TrayItem[] = [];

export function HatRail({
  side,
  items,
  finished = NO_ITEMS,
  waiting,
  listOpen,
  onOpen,
  onOpenSession,
  onOpenCommand,
  onList,
  onHold,
  onSeen,
}: {
  side: HatSide;
  /// What runs or waits on the person (runningTray.ts `trayItems`), as the hat takes it.
  items: readonly TrayItem[];
  /// What ended (runningTray.ts `finishedTrayItems`).
  finished?: readonly TrayItem[];
  waiting: ReadonlySet<string>;
  /// The hat's full list shows over the composer.
  listOpen: boolean;
  onOpen: (id: string) => void;
  onOpenSession?: (sessionId: string) => void;
  onOpenCommand?: (command: BackgroundCommand) => void;
  /// Shows or hides the full list (the hat, opened over the composer).
  onList: (open: boolean) => void;
  /// The rail is held, as the hat is (SubagentTray.tsx `onHold`): its list open, or the pointer or
  /// keyboard on it. Reported on a change only, and false when it unmounts.
  onHold?: (held: boolean) => void;
  /// The rail could be seen (traySeen.ts), as the hat reports it (SubagentTray.tsx `onSeen`).
  onSeen?: (seen: boolean) => void;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const chatHarness = useContext(SubagentHarnessContext);
  const leading = useMemo(() => longestRunningFirst(items), [items]);
  const marks = useMemo(() => stackMarks(leading, finished, chatHarness), [leading, finished, chatHarness]);
  const all = useMemo(() => [...items, ...finished], [items, finished]);
  const [peekKey, setPeekKey] = useState<string | undefined>(undefined);
  const [within, setWithin] = useState(false);
  const node = useRef<HTMLDivElement | null>(null);
  const drawn = marks.length > 0;
  useTraySeen(node, drawn, onSeen);
  useHeld(drawn && (listOpen || within || peekKey !== undefined), onHold);
  if (!drawn) return null;
  const peekDrawn = peekKey !== undefined && marks.some((mark) => mark.key === peekKey);
  const label = (key: string) => peekOf(t, language, key, all, waiting) ?? "";
  const inline = side === "bottom-line";
  // Arrows step between the marks and the list control: down and up in a rail, left and right inline.
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const next = inline ? "ArrowRight" : "ArrowDown";
    const previous = inline ? "ArrowLeft" : "ArrowUp";
    if (event.key !== next && event.key !== previous) return;
    const stops = [...event.currentTarget.querySelectorAll<HTMLButtonElement>("button")];
    const at = stops.indexOf(event.target as HTMLButtonElement);
    if (at < 0) return;
    event.preventDefault();
    focusRoute(
      stops[(at + (event.key === next ? 1 : -1) + stops.length) % stops.length],
      "person",
      "arrow along the hat rail",
    );
  };
  return (
    <div
      ref={node}
      className="acpmux-hat-rail"
      data-side={side}
      role="toolbar"
      // Focus lands on its marks, never on the rail itself; it takes focus only from script.
      tabIndex={-1}
      aria-label={t("summary.backgroundTasks")}
      aria-orientation={inline ? "horizontal" : "vertical"}
      onKeyDown={onKeyDown}
      onPointerEnter={() => setWithin(true)}
      onPointerLeave={() => {
        setWithin(false);
        setPeekKey(undefined);
      }}
    >
      {marks.map((mark) => (
        <button
          key={mark.key}
          type="button"
          className="acpmux-hat-rail__mark"
          data-rolodex-key={mark.key}
          data-peeked={(peekDrawn && peekKey === mark.key) || undefined}
          aria-label={label(mark.key)}
          onPointerEnter={() => setPeekKey(mark.key)}
          onFocus={() => setPeekKey(mark.key)}
          onBlur={() => setPeekKey((current) => (current === mark.key ? undefined : current))}
          onClick={() =>
            openHatMark(markTarget(mark.key, all), {
              onOpen,
              onOpenSession,
              onOpenCommand,
              onList: () => onList(true),
            })
          }
        >
          <AgentIdentity
            className="acpmux-hat-rail__glyph"
            harness={mark.harness}
            tone={mark.tone}
            size={MARK}
            fallback={mark.icon}
          />
          {peekDrawn && peekKey === mark.key && (
            <span className="acpmux-hat-rail__label" aria-hidden="true">
              {label(mark.key)}
            </span>
          )}
        </button>
      ))}
      <button
        type="button"
        className="acpmux-hat-rail__list"
        aria-label={t("summary.backgroundTasks")}
        aria-expanded={listOpen}
        onClick={() => onList(!listOpen)}
      >
        <Icon name="disclosure.expanded" size={MARK} row />
      </button>
    </div>
  );
}

/// Reports `held` through `onHold` on each change, and false when the rail unmounts.
function useHeld(held: boolean, onHold: ((held: boolean) => void) | undefined) {
  const report = useRef(onHold);
  useLayoutEffect(() => {
    report.current = onHold;
  });
  useEffect(() => {
    report.current?.(held);
  }, [held]);
  useEffect(() => () => report.current?.(false), []);
}
