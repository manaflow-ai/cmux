// The empty Chief conversation's first-run panel, the Chief's front page (Swift `HomeFirstRunView`,
// `HomeFirstRunHero`, `HomeFirstRunIntro`, `HomeStarterChips`, `HomeFirstRunSwitchCard`): the
// Chief's first-open message, its face and what it does, starter prompts, then things to do now
// (each a row with its shortcut), the person's agents at a glance, most urgent first, then the
// Switching card. Hidden once the conversation has a message (the transcript's call). A short pane
// drops agent rows first, then the starters, the hero, the intro and the card (`fitFirstRun`):
// every part is measured where it would sit, so a part that leaves takes no room and nothing jumps.
import { useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import { StatusGlyph } from "../../../../ui/StatusGlyph";
import { graphemePrefix, initials } from "../../../../ui/initials";
import type { Strings } from "../strings";
import {
  agentShortlist,
  fitFirstRun,
  switchKeyLines,
  type AgentGlance,
  type AgentGlanceStatus,
  type FirstRunAction,
  type FirstRunFit,
  type SwitchKeys,
} from "./firstRunModel";
import "../cards.css";

/** The Chief's face: its picture, else its emoji, else the monogram of its letters or its name. */
export interface ChiefFace {
  picture?: string;
  text?: string;
  name: string;
}

export type StarterLook = "wrapped" | "stacked" | "plain";

export interface FirstRunPanelProps {
  strings: Strings;
  face: ChiefFace;
  /** The Chief's first-open message (`chiefIntroText`); absent: none. */
  intro?: string;
  starters?: readonly string[];
  starterLook?: StarterLook;
  /** The rows' shortcuts as the live binding table has them; absent hides one. */
  shortcuts?: { terminal?: string; agent?: string };
  /** "Bring your memory from Claude Code": the row shows only while the host offers it. */
  memoryOffer?: string;
  petShown?: boolean;
  agents?: readonly AgentGlance[];
  /** Absent (or no lines): no Switching card. */
  switchKeys?: SwitchKeys;
  onAction(action: FirstRunAction): void;
  onAgent(id: string): void;
  onStarter(prompt: string): void;
  onHideSwitchKeys(): void;
  onOpenKeyboardSettings(): void;
}

const STATUS_GLYPH: Record<AgentGlanceStatus, "waiting" | "error" | "done" | "idle" | "working"> = {
  needsYou: "waiting",
  failed: "error",
  done: "done",
  idle: "idle",
  working: "working",
};

export function FirstRunPanel(props: FirstRunPanelProps) {
  const {
    strings,
    intro,
    starters = [],
    starterLook = "wrapped",
    shortcuts = {},
    memoryOffer,
    petShown,
    onAction,
  } = props;
  const { t } = strings;
  const agents = agentShortlist(props.agents ?? []);
  const lines = props.switchKeys ? switchKeyLines(props.switchKeys, strings) : [];
  const actions: { id: FirstRunAction; title: string; icon: string; shortcut?: string }[] = [
    { id: "startAgent", title: t("home.firstRun.startAgent"), icon: "agent.chat", shortcut: shortcuts.agent },
    { id: "openTerminal", title: t("home.firstRun.openTerminal"), icon: "terminal.new", shortcut: shortcuts.terminal },
    ...(memoryOffer ? [{ id: "importMemories" as const, title: memoryOffer, icon: "action.download" }] : []),
    { id: "togglePet", title: t(petShown ? "home.firstRun.hidePet" : "home.firstRun.showPet"), icon: "agent.chief" },
  ];
  const fit = useFit(actions.length, agents.length, intro !== undefined, starters.length > 0, lines.length > 0);
  return (
    <div className="hm-first-run" ref={fit.root}>
      <div className="hm-first-run__column" data-fit-actions={fit.shown.actions ? undefined : "out"}>
        {/* The intro rises in once, when it first shows (its mount); new text changes nothing. */}
        {intro !== undefined && (
          <div ref={fit.parts.intro} className="hm-first-run__intro" data-fit={fit.shown.intro ? undefined : "out"}>
            {intro}
          </div>
        )}
        <div ref={fit.parts.hero} className="hm-first-run__hero" data-fit={fit.shown.hero ? undefined : "out"}>
          <Face face={props.face} />
          <span className="hm-first-run__hero-title">{t("home.firstRun.hero.title")}</span>
          <span className="hm-first-run__hero-body">{t("home.firstRun.hero.body")}</span>
        </div>
        {starters.length > 0 && (
          <div
            ref={fit.parts.starters}
            className="hm-first-run__starters"
            data-look={starterLook}
            data-fit={fit.shown.starters ? undefined : "out"}
          >
            {starters.map((prompt) => (
              <button
                key={prompt}
                type="button"
                className="hm-first-run__starter"
                onClick={() => props.onStarter(prompt)}
              >
                {prompt}
              </button>
            ))}
          </div>
        )}
        <div
          className="hm-first-run__rows"
          role="toolbar"
          aria-orientation="vertical"
          tabIndex={-1}
          onKeyDown={moveBetweenRows}
        >
          {actions.map((action) => (
            <Row
              key={action.id}
              icon={<Icon name={action.icon} size={16} />}
              title={action.title}
              trailing={action.shortcut}
              onClick={() => onAction(action.id)}
            />
          ))}
        </div>
        {agents.length > 0 && (
          <div
            className="hm-first-run__agents"
            role="toolbar"
            tabIndex={-1}
            aria-orientation="vertical"
            data-fit={fit.shown.agents ? undefined : "out"}
            onKeyDown={moveBetweenRows}
          >
            <span ref={fit.parts.header} className="hm-first-run__agents-header">
              {t("home.firstRun.agents")}
            </span>
            {agents.map((agent, index) => {
              const word = t(`home.firstRun.agent.${agent.status}`);
              return (
                <Row
                  key={agent.id}
                  hidden={index >= fit.shown.agents}
                  icon={<Icon name={agent.icon} size={16} />}
                  title={agent.title}
                  status={agent.status}
                  trailing={word}
                  glyph={<StatusGlyph name={STATUS_GLYPH[agent.status]} size={12} />}
                  onClick={() => props.onAgent(agent.id)}
                />
              );
            })}
          </div>
        )}
        {lines.length > 0 && (
          <section
            ref={fit.parts.card}
            className="hm-first-run__switch"
            aria-label={t("home.firstRun.switchKeys.header")}
            data-fit={fit.shown.card ? undefined : "out"}
          >
            <div className="hm-first-run__switch-head">
              <span>{t("home.firstRun.switchKeys.header")}</span>
              <button type="button" className="hm-first-run__switch-hide" onClick={props.onHideSwitchKeys}>
                {t("home.firstRun.switchKeys.hide")}
              </button>
            </div>
            {lines.map((line) => (
              <div key={line.label} className="hm-first-run__switch-line">
                <span>{line.label}</span>
                <span className="hm-first-run__keys">{line.keys}</span>
              </div>
            ))}
            {props.switchKeys?.desktopConflict && (
              <>
                <p className="hm-first-run__switch-note">{t("home.firstRun.switchKeys.desktopConflict")}</p>
                <button type="button" className="hm-first-run__switch-settings" onClick={props.onOpenKeyboardSettings}>
                  {t("home.firstRun.switchKeys.openSettings")}
                </button>
              </>
            )}
          </section>
        )}
      </div>
    </div>
  );
}

/** One row: a glyph, a label and the action's shortcut (or an agent's status word) on a raised
 * small-radius rect with a hairline, never a capsule. Return presses it; Up and Down move between rows. */
function Row({
  icon,
  title,
  trailing,
  glyph,
  status,
  hidden,
  onClick,
}: {
  icon: ReactNode;
  title: string;
  trailing?: string;
  glyph?: ReactNode;
  status?: AgentGlanceStatus;
  hidden?: boolean;
  onClick(): void;
}) {
  return (
    <button
      type="button"
      className="hm-first-run__row"
      data-status={status}
      data-fit={hidden ? "out" : undefined}
      onClick={onClick}
    >
      <span className="hm-first-run__row-icon">{icon}</span>
      <span className="hm-first-run__row-title">{title}</span>
      {glyph}
      {trailing && <span className="hm-first-run__row-trailing">{trailing}</span>}
    </button>
  );
}

function moveBetweenRows(event: KeyboardEvent<HTMLElement>) {
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
  const panel = event.currentTarget.closest(".hm-first-run");
  const rows = [...(panel?.querySelectorAll<HTMLButtonElement>(".hm-first-run__row:not([data-fit='out'])") ?? [])];
  const index = rows.indexOf(event.target as HTMLButtonElement);
  const next = rows[index + (event.key === "ArrowDown" ? 1 : -1)];
  if (index < 0 || !next) return;
  event.preventDefault();
  next.focus();
}

/** The face: the profile's picture, else its emoji, else a monogram (a new Chief's "CH"). */
function Face({ face }: { face: ChiefFace }) {
  if (face.picture) return <img className="hm-first-run__face" src={face.picture} alt="" draggable={false} />;
  const letters = face.text === undefined || /^\p{L}{1,3}$/u.test(face.text);
  if (!letters) return <span className="hm-first-run__face hm-first-run__face--glyph">{face.text}</span>;
  const monogram = face.text ?? (face.name ? graphemePrefix(initials(face.name), 2) : "CH");
  return (
    <span className="hm-first-run__face hm-first-run__face--monogram" aria-hidden="true">
      {monogram.toUpperCase()}
    </span>
  );
}

/** Measures the panel and its parts where they sit (a part that does not fit stays measurable but
 * takes no room) and fits them to the panel's height. */
function useFit(actionCount: number, agentCount: number, hasIntro: boolean, hasStarters: boolean, hasCard: boolean) {
  const root = useRef<HTMLDivElement>(null);
  const parts = {
    intro: useRef<HTMLDivElement>(null),
    hero: useRef<HTMLDivElement>(null),
    starters: useRef<HTMLDivElement>(null),
    header: useRef<HTMLSpanElement>(null),
    card: useRef<HTMLElement>(null),
  };
  const [shown, setShown] = useState<FirstRunFit>({
    actions: true,
    card: hasCard,
    intro: hasIntro,
    hero: true,
    starters: hasStarters,
    agents: agentCount,
  });
  useLayoutEffect(() => {
    const element = root.current;
    if (!element) return;
    const height = (ref: { current: HTMLElement | null }) => ref.current?.getBoundingClientRect().height ?? 0;
    const measure = () => {
      const next = fitFirstRun({
        available: element.getBoundingClientRect().height,
        actionCount,
        card: hasCard ? height(parts.card) : 0,
        intro: hasIntro ? height(parts.intro) : undefined,
        hero: height(parts.hero),
        starters: hasStarters ? height(parts.starters) : 0,
        header: height(parts.header),
        agentCount,
      });
      setShown((old) => (JSON.stringify(old) === JSON.stringify(next) ? old : next));
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    for (const part of Object.values(parts)) if (part.current) observer.observe(part.current);
    return () => observer.disconnect();
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the refs are stable; the counts decide the fit.
  }, [actionCount, agentCount, hasIntro, hasStarters, hasCard]);
  return { root, parts, shown };
}
