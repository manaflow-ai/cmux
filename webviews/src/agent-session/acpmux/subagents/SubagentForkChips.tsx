import { useState } from "react";
import {
  Menu,
  MenuButton,
  MenuGroup,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
} from "../../../ui/Menu";
import { ChevronIcon, ModeIcon } from "../ComposerPickers";
import { useT } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import { subagentForkChipsLook } from "./subagentForkChips.experiment";
import type { SubagentChipFacts } from "./subagentForkChipsModel";
import "./subagentForkChips.css";

/// What a fork of the subagent starts on: another model, or another permission mode.
export type SubagentForkTarget = { model?: string; mode?: string };

type Props = {
  facts: SubagentChipFacts;
  /// Forks the subagent's own context into a chat of the person's (App.tsx `forkSubagent`); unset
  /// when the daemon cannot fork a subagent, and the chips are then labels with no menu.
  onFork?(target: SubagentForkTarget): void;
  /// The look (subagentForkChips.experiment.ts); unset, the experiment's arm.
  look?: keyof typeof subagentForkChipsLook.arms;
};

/// A subagent composer's model and mode, read-only (Leo 2026-11-22: "are their permissions/model
/// locked right then and there? does it make sense to be able to reveal the fork or whatever
/// switching model behaviour for it?"). They are greyed, never a picker: the model is fixed at the
/// subagent's start and its mode follows its chat (Claude) or was copied at its start (Codex), so a
/// pick here could only change the chat, which is not the subagent (the 10-20 bug). Each chip's
/// hover says why; its click opens Fork with <model>… or Fork with <mode>…, which forks the
/// subagent's own context into a new chat the person controls (Leo 08:23Z: "why not a greyed out
/// permission situation and then the HOVER shows that?").
export function SubagentForkChips({ facts, onFork, look: pinned }: Props) {
  const [arm] = useState(() => pinned ?? experimentArm(subagentForkChipsLook));
  if (arm === "off") return null;
  if (arm === "takeover") return <TakeOver facts={facts} onFork={onFork} />;
  return (
    <div
      className={`acpmux-chips acpmux-subagent-chips${arm === "hover" ? " acpmux-subagent-chips--hover" : ""}`}
      data-subagent-chips={arm}
    >
      <ReadOnlyChip
        kind="model"
        label={facts.model}
        tip={facts.modelTip}
        items={facts.forkModels}
        onPick={onFork && ((id) => onFork({ model: id }))}
      />
      {facts.mode && (
        <ReadOnlyChip
          kind="mode"
          label={facts.mode.name}
          modeId={facts.mode.id}
          tip={facts.modeTip}
          items={facts.forkModes}
          onPick={onFork && ((id) => onFork({ mode: id }))}
        />
      )}
    </div>
  );
}

function ReadOnlyChip({
  kind,
  label,
  modeId,
  tip,
  items,
  onPick,
}: {
  kind: "model" | "mode";
  label: string;
  modeId?: string;
  tip: string;
  items: readonly { id: string; name: string }[];
  onPick?: ((id: string) => void) | undefined;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const className = `acpmux-picker acpmux-${kind === "model" ? "model" : "mode acpmux-access"} acpmux-chip-readonly`;
  const face = (
    <>
      {kind === "mode" && <ModeIcon modeId={modeId} />}
      <span className={kind === "model" ? "acpmux-model-name" : "acpmux-mode-text"}>{label}</span>
    </>
  );
  const name = t(kind === "model" ? "subagents.fork.modelLabel" : "subagents.fork.modeLabel", { value: label });
  // The chat's mode trigger class: without it the bar's icon-only 30 px mode button clipped the
  // label to "ss per" for "Bypass permissions" (composerLocation.css, the same bug New Tab had).
  const button = kind === "mode" ? "acpmux-picker-button acpmux-access-trigger" : "acpmux-picker-button";
  if (!onPick || items.length === 0)
    return (
      <span className={className} data-subagent-chip={kind}>
        {/* tooltip-allow: a read-only chip's hover says why it cannot change here */}
        <span className={button} title={tip}>
          {face}
          <span className="visually-hidden">{`${name}. ${tip}`}</span>
        </span>
      </span>
    );
  return (
    <span className={className} data-subagent-chip={kind}>
      <Menu open={open} onOpenChange={setOpen}>
        {/* tooltip-allow: the hover says why the chip is fixed and that a click forks */}
        <MenuButton className={button} label={name} title={tip} aria-haspopup="menu">
          {face}
          <ChevronIcon />
        </MenuButton>
        <MenuPopup side="top" align="start" className="acpmux-subagent-fork-menu">
          <div className="acpmux-subagent-fork-note">{tip}</div>
          <MenuSeparator />
          {items.map((item) => (
            <MenuItem key={item.id} data-value={item.id} onSelect={() => onPick(item.id)}>
              <span className="acpmux-menu-label">
                {t(kind === "model" ? "subagents.fork.withModel" : "subagents.fork.withMode", { value: item.name })}
              </span>
            </MenuItem>
          ))}
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// The `takeover` look: one button, a model and mode picker in its menu, and Fork.
function TakeOver({ facts, onFork }: { facts: SubagentChipFacts; onFork?: Props["onFork"] }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [model, setModel] = useState<string>();
  const [mode, setMode] = useState<string>();
  if (!onFork || (facts.forkModels.length === 0 && facts.forkModes.length === 0)) return null;
  return (
    <div className="acpmux-chips acpmux-subagent-chips" data-subagent-chips="takeover">
      <span className="acpmux-picker acpmux-model acpmux-chip-readonly">
        <Menu open={open} onOpenChange={setOpen}>
          {/* tooltip-allow: what the subagent runs on now, which the fork can change */}
          <MenuButton
            className="acpmux-picker-button"
            title={[facts.modelTip, facts.modeTip].join("\n")}
            aria-haspopup="menu"
          >
            <span className="acpmux-model-name">{t("subagents.fork.takeOver")}</span>
            <ChevronIcon />
          </MenuButton>
          <MenuPopup side="top" align="start" className="acpmux-subagent-fork-menu">
            {facts.forkModels.length > 0 && (
              <MenuGroup label={t("picker.model")}>
                <MenuRadioGroup value={model ?? ""} onValueChange={(value) => setModel(String(value))}>
                  {facts.forkModels.map((item) => (
                    <MenuRadioItem key={item.id} value={item.id}>
                      <span className="acpmux-menu-label">{item.name}</span>
                    </MenuRadioItem>
                  ))}
                </MenuRadioGroup>
              </MenuGroup>
            )}
            {facts.forkModes.length > 0 && (
              <MenuGroup label={t("subagents.fork.modeHeading")}>
                <MenuRadioGroup value={mode ?? ""} onValueChange={(value) => setMode(String(value))}>
                  {facts.forkModes.map((item) => (
                    <MenuRadioItem key={item.id} value={item.id}>
                      <span className="acpmux-menu-label">{item.name}</span>
                    </MenuRadioItem>
                  ))}
                </MenuRadioGroup>
              </MenuGroup>
            )}
            <MenuSeparator />
            <MenuItem onSelect={() => onFork({ ...(model ? { model } : {}), ...(mode ? { mode } : {}) })}>
              <span className="acpmux-menu-label">{t("subagents.fork.start")}</span>
            </MenuItem>
          </MenuPopup>
        </Menu>
      </span>
    </div>
  );
}
