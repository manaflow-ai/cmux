// Settings > Machines > Hands (cx-om025): the owner's Chief hands from the host's
// `cmux.settings.hands.state` (HandsService+Page), live through cmux.settings.hands.changed. Each
// hand shows its permission level as a segmented choice; the defaults for new sandbox and Mac hands
// sit below. The page only sends the chosen level: the host lowers at once and raises only through
// the presence key (Touch ID or the password), so a raise here can never skip that prompt.
import { useCallback, useId } from "react";
import { useQuery } from "@tanstack/react-query";
import { useStore } from "../context";
import type { HandLevel, HandRow, HandsState } from "../ops";
import { settingsKeys } from "../queries";
import { t } from "../strings";

const LEVEL_KEYS: Record<HandLevel, string> = {
  "read-only": "settingsWindow.hands.level.readOnly",
  ask: "settingsWindow.hands.level.ask",
  auto: "settingsWindow.hands.level.auto",
  full: "settingsWindow.hands.level.full",
};

function LevelChoice({
  name,
  label,
  levels,
  current,
  disabled,
  onChoose,
}: {
  name: string;
  label: string;
  levels: HandLevel[];
  current: HandLevel | null | undefined;
  disabled: boolean;
  onChoose: (level: HandLevel) => void;
}) {
  return (
    <fieldset className="segmented" aria-label={label} disabled={disabled}>
      {levels.map((level) => (
        <label key={level} className="segment" data-checked={current === level ? "" : undefined}>
          <input
            type="radio"
            name={name}
            data-hand-level={level}
            aria-label={t(LEVEL_KEYS[level])}
            checked={current === level}
            onChange={() => onChoose(level)}
          />
          {t(LEVEL_KEYS[level])}
        </label>
      ))}
    </fieldset>
  );
}

function Row({ row, state }: { row: HandRow; state: HandsState }) {
  const store = useStore();
  const name = useId();
  const facts = [
    row.profile ? t(`settingsWindow.hands.profile.${row.profile}`) : null,
    t(row.online ? "settingsWindow.hands.online" : "settingsWindow.hands.offline"),
    row.pending > 0 ? t("settingsWindow.hands.waiting", row.pending) : null,
  ].filter((fact) => fact !== null);
  return (
    <div className="row" data-hand={row.hand} data-hand-level-current={row.level ?? ""}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{row.name}</div>
          <div className="row-help">{facts.join(" · ")}</div>
        </div>
        <div className="row-control">
          <LevelChoice
            name={`hand-level-${name}`}
            label={t("settingsWindow.hands.levelLabel", row.name)}
            levels={state.levels}
            current={row.level}
            disabled={state.busy !== null}
            onChoose={(level) => void store.runHands({ action: "level", hand: row.hand, level })}
          />
        </div>
      </div>
    </div>
  );
}

function DefaultRow({ profile, state }: { profile: "mac" | "sandbox"; state: HandsState }) {
  const store = useStore();
  const title = t(`settingsWindow.hands.defaults.${profile}`);
  return (
    <div className="row" data-hand-default={profile}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{title}</div>
        </div>
        <div className="row-control">
          <LevelChoice
            name={`hand-default-${profile}`}
            label={title}
            levels={state.levels}
            current={state.defaults[profile]}
            disabled={state.busy !== null}
            onChoose={(level) => void store.runHands({ action: "default", profile, level })}
          />
        </div>
      </div>
    </div>
  );
}

export function HandsGroup() {
  const store = useStore();
  const { data: state } = useQuery<HandsState>({ queryKey: settingsKeys.hands, enabled: false });
  // Read again when the group mounts (a stable callback ref runs once per mount), like Harnesses.
  const mounted = useCallback(
    (node: HTMLElement | null) => {
      if (node) void store.runHands({ action: "refresh" });
    },
    [store],
  );
  return (
    <section className="group" data-card="hands" ref={mounted}>
      <h3 className="group-title">{t("settingsWindow.hands.title")}</h3>
      {!state || !state.signed_in ? (
        <div className="rows">
          <div className="row">
            <div className="empty" data-hands-signed-out="">
              {t("settingsWindow.hands.signedOut")}
            </div>
          </div>
        </div>
      ) : (
        <>
          <div className="row-help">{t("settingsWindow.hands.help")}</div>
          {state.prompt && (
            <output className="row-help" data-hands-prompt="">
              {t("settingsWindow.hands.prompt")}
            </output>
          )}
          {state.error && (
            <div className="row-error" data-hands-error="" role="alert">
              {state.error}
            </div>
          )}
          <div className="rows">
            {state.hands.length === 0 ? (
              <div className="row">
                <div className="empty">{t("settingsWindow.hands.empty")}</div>
              </div>
            ) : (
              state.hands.map((row) => <Row key={row.hand} row={row} state={state} />)
            )}
          </div>
          <h4 className="group-title">{t("settingsWindow.hands.defaults")}</h4>
          <div className="row-help">{t("settingsWindow.hands.defaults.help")}</div>
          <div className="rows">
            <DefaultRow profile="sandbox" state={state} />
            <DefaultRow profile="mac" state={state} />
          </div>
        </>
      )}
    </section>
  );
}
