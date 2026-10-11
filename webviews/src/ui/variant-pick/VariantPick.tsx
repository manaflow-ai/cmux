import { useRef, useState, type ReactNode } from "react";
import { Tooltip, TooltipProvider } from "../Tooltip";
import { useUiDirection } from "../UiProvider";
import { moveVariant } from "./model";
import { variantPickStrings } from "./strings";
import type { Strings } from "../../pages/shared/i18n";
import "./variant-pick.css";

export interface VariantOption {
  id: string;
  label: string;
  preview?: ReactNode;
}
export interface VariantPickProps {
  options: readonly VariantOption[];
  recommendedId?: string;
  currentPick: string | null;
  onPick(id: string): void | Promise<void>;
  strings?: Strings;
}

/** Controlled choice, independent from focus. Preview controls keep their own keyboard events. */
export function VariantPick({
  options,
  recommendedId,
  currentPick,
  onPick,
  strings = variantPickStrings(),
}: VariantPickProps) {
  const dir = useUiDirection();
  const [focused, setFocused] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  const busy = useRef(false);
  const buttons = useRef(new Map<string, HTMLButtonElement>());
  const ids = options.map((option) => option.id);
  const active = [focused, currentPick, ids[0]].find((id) => id != null && ids.includes(id));
  const pick = async (id: string) => {
    if (busy.current || currentPick === id) return;
    busy.current = true;
    setPending(true);
    setFailed(false);
    try {
      await onPick(id);
    } catch {
      setFailed(true);
    } finally {
      busy.current = false;
      setPending(false);
    }
  };
  return (
    <TooltipProvider>
      <fieldset className="variant-pick" aria-label={strings.t("group")} aria-busy={pending} dir={dir}>
        <div className="variant-pick-options">
          {options.map((option) => {
            const recommended = option.id === recommendedId;
            const selected = option.id === currentPick;
            const label = `${strings.format("pickLabel", option.label)}${recommended ? ` · ${strings.t("recommended")}` : ""}`;
            return (
              <div className="variant-pick-option" key={option.id} data-picked={selected || undefined}>
                <div className="variant-pick-heading">
                  <strong>{option.label}</strong>
                  {recommended && <span>{strings.t("recommended")}</span>}
                </div>
                {option.preview}
                <Tooltip label={label}>
                  <button
                    type="button"
                    className="ui-button variant-pick-button"
                    aria-label={label}
                    aria-pressed={selected}
                    aria-disabled={pending || selected}
                    tabIndex={option.id === active ? 0 : -1}
                    ref={(node) => {
                      if (node) buttons.current.set(option.id, node);
                      else buttons.current.delete(option.id);
                    }}
                    onFocus={() => setFocused(option.id)}
                    onClick={() => {
                      void pick(option.id);
                    }}
                    onKeyDown={(event) => {
                      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
                      if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
                        event.preventDefault();
                        const next = moveVariant(ids, option.id, event.key, dir);
                        if (next) buttons.current.get(next)?.focus();
                      } else if (event.key === "Enter") {
                        event.preventDefault();
                        if (!event.repeat) void pick(option.id);
                      }
                    }}
                  >
                    {strings.t(selected ? "picked" : "pick")}
                  </button>
                </Tooltip>
              </div>
            );
          })}
        </div>
        <output aria-live="polite">{pending ? strings.t("pending") : failed ? strings.t("error") : ""}</output>
      </fieldset>
    </TooltipProvider>
  );
}
