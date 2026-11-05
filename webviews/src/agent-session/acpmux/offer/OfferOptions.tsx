// A suggested task's Options popover (offerChoice.ts): the rows of Claude desktop's
// suggested-session card, Environment, the folder, Worktree, Model, Effort and Permissions.
// Environment and the folder say where the new chat runs; the rest are picks that ride on Start,
// each at "Default" (the new chat's own) until the person picks. Model, Effort and Permissions
// show only when the task runs on this chat's agent, whose lists they are. Dismiss stays at the
// foot, as the menu before it had it.
import { useId, useState } from "react";
import { Popover } from "../../../ui/Popover";
import { Select } from "../../../ui/Select";
import { Switch } from "../../../ui/Switch";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import type { AcpmuxSessionOffer } from "../model";
import { folderParts, sameAgent, type OfferChoice, type OfferDefaults, type OfferPick } from "./offerChoice";

export function OfferOptions({
  offer,
  defaults,
  choice,
  disabled,
  onChoice,
  onPick,
  onDismiss,
}: {
  offer: AcpmuxSessionOffer;
  defaults: OfferDefaults | undefined;
  choice: OfferChoice;
  disabled?: boolean;
  onChoice(next: OfferChoice): void;
  onPick(pick: OfferPick): void;
  onDismiss(): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  // The button as state, not a ref: the popover's anchor is read during render.
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  return (
    <>
      <button
        ref={setButton}
        type="button"
        className="acpmux-task-action"
        aria-haspopup="dialog"
        aria-expanded={open}
        disabled={disabled}
        onClick={() => setOpen((was) => !was)}
      >
        {t("offer.options")}
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={open ? button : null}
        label={t("offer.options")}
        className="acpmux-task-options"
        side="bottom"
        align="start"
      >
        <OfferOptionRows
          offer={offer}
          defaults={defaults}
          choice={choice}
          onChoice={onChoice}
          onPick={onPick}
          onDismiss={() => {
            setOpen(false);
            onDismiss();
          }}
        />
      </Popover>
    </>
  );
}

/// The popover's rows (the gallery draws them in place too).
export function OfferOptionRows({
  offer,
  defaults,
  choice,
  onChoice,
  onPick,
  onDismiss,
}: {
  offer: AcpmuxSessionOffer;
  defaults: OfferDefaults | undefined;
  choice: OfferChoice;
  onChoice(next: OfferChoice): void;
  onPick(pick: OfferPick): void;
  onDismiss(): void;
}) {
  const t = useT();
  const ids = { env: useId(), folder: useId(), worktree: useId(), model: useId(), effort: useId(), mode: useId() };
  const folder = folderParts(offer.cwd);
  const same = sameAgent(offer, defaults);
  // A value the list does not hold (the agent's model id) still shows as picked.
  const withValue = (options: { value: string; name: string; disabled?: boolean }[], value: string | undefined) =>
    value && !options.some((option) => option.value === value) ? [{ value, name: value }, ...options] : options;
  const models = same ? withValue(defaults.models, choice.model) : [];
  const effort = same ? defaults.effort : undefined;
  const modes = same ? withValue(defaults.modes, choice.mode) : [];
  return (
    <div className="acpmux-task-options-body">
      <div className="acpmux-task-option">
        <span className="acpmux-task-option-label" id={ids.env}>
          {t("offer.options.environment")}
        </span>
        <span className="acpmux-task-option-value" aria-labelledby={ids.env}>
          <Icon name={defaults?.machine ? "machine.remote" : "machine.mac"} size={12} />
          {defaults?.machine ?? t("offer.options.thisComputer")}
        </span>
      </div>
      <div className="acpmux-task-option acpmux-task-option--folder">
        <Icon name="folder" size={14} />
        <span className="acpmux-task-folder" id={ids.folder} title={offer.cwd}>
          <span className="acpmux-task-folder-name">{folder.name}</span>
          {folder.parent && <span className="acpmux-task-folder-path">{folder.parent}</span>}
        </span>
      </div>
      <label className="acpmux-task-option" htmlFor={ids.worktree}>
        <span className="acpmux-task-option-label">{t("offer.options.worktree")}</span>
        <Switch
          id={ids.worktree}
          size="sm"
          checked={choice.worktree}
          onCheckedChange={(worktree) => onChoice({ ...choice, worktree })}
        />
      </label>
      {models.length > 0 && (
        <div className="acpmux-task-option">
          <span className="acpmux-task-option-label" id={ids.model}>
            {t("offer.options.model")}
          </span>
          <Select
            label={t("offer.options.model")}
            labelledBy={ids.model}
            value={choice.model ?? ""}
            placeholder={t("offer.options.default")}
            options={models.map((option) => ({
              value: option.value,
              label: option.name,
              ...(option.disabled ? { disabled: true } : {}),
            }))}
            onChange={(model) => onPick({ model })}
            buttonClassName="acpmux-task-option-select"
            popupClassName="acpmux-task-menu"
            closeOnPick
          />
        </div>
      )}
      {effort && effort.options.length > 0 && (
        <div className="acpmux-task-option">
          <span className="acpmux-task-option-label" id={ids.effort}>
            {t("offer.options.effort")}
          </span>
          <Select
            label={t("offer.options.effort")}
            labelledBy={ids.effort}
            value={choice.effort?.value ?? ""}
            placeholder={t("offer.options.default")}
            options={effort.options.map((option) => ({ value: option.value, label: option.name }))}
            onChange={(value) => onPick({ effort: { configId: effort.configId, value } })}
            buttonClassName="acpmux-task-option-select"
            popupClassName="acpmux-task-menu"
            closeOnPick
          />
        </div>
      )}
      {modes.length > 0 && (
        <div className="acpmux-task-option">
          <span className="acpmux-task-option-label" id={ids.mode}>
            {t("offer.options.permissions")}
          </span>
          <Select
            label={t("offer.options.permissions")}
            labelledBy={ids.mode}
            value={choice.mode ?? ""}
            placeholder={t("offer.options.default")}
            options={modes.map((option) => ({ value: option.value, label: option.name }))}
            onChange={(mode) => onPick({ mode })}
            buttonClassName="acpmux-task-option-select"
            popupClassName="acpmux-task-menu"
            closeOnPick
          />
        </div>
      )}
      <div className="acpmux-task-options-foot">
        <button type="button" className="acpmux-task-option-dismiss" onClick={onDismiss}>
          {t("offer.dismiss")}
        </button>
      </div>
    </div>
  );
}
