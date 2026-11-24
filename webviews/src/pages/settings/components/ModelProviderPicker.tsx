// oxlint-disable jsx-a11y/prefer-tag-over-role -- A search input drives an ARIA combobox with grouped options.
import { useCallback, useId, useRef, useState, type RefObject } from "react";
import { Button } from "../../../ui/Button";
import { DrivenList, DrivenRow } from "../../../ui/DrivenList";
import { cx } from "../../../ui/cx";
import { Input } from "../../../ui/Input";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { useScrollEdges } from "../../../ui/scrollEdges";
import { Icon } from "../icons";
import {
  canAddProvider,
  providerDisabledReason,
  providerGroupName,
  providerName,
  searchProviders,
} from "../providerCatalog";
import { t } from "../strings";
import { ModelProviderMark } from "./ModelProviderMark";

const custom = "endpoint";
const isArrow = (key: string) =>
  key === "ArrowDown" || key === "ArrowUp" || key === "ArrowLeft" || key === "ArrowRight";
/// The API keys most people come for, first in the API keys grid.
const LEADING_KEYS = ["anthropic", "openai", "google", "xai", "openrouter", "deepseek"];

export function ModelProviderPicker({
  open,
  setOpen,
  trigger,
  cloud,
  claudeCodeAvailable,
  claudeError,
  disabled,
  handingOff,
  onPick,
}: {
  open: boolean;
  setOpen(open: boolean): void;
  trigger: RefObject<HTMLButtonElement | null>;
  cloud: boolean;
  claudeCodeAvailable?: boolean | null;
  claudeError?: string | null;
  disabled: boolean;
  handingOff: boolean;
  onPick(id: string): void;
}) {
  const triggerProps = usePopoverTrigger(open, setOpen);
  const search = useRef<HTMLInputElement>(null);
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  const attach = useCallback(
    (node: HTMLButtonElement | null) => {
      trigger.current = node;
      setAnchor(node);
    },
    [trigger],
  );
  return (
    <>
      <Button
        {...triggerProps}
        ref={attach}
        variant="ghost"
        className="row models-add"
        disabled={disabled}
        focusableWhenDisabled
        data-models-add=""
        data-popup-open={open ? "" : undefined}
      >
        <span className="row-main">
          <span className="models-add-mark" aria-hidden="true">
            <Icon name="plus" />
          </span>
          <span className="row-title">{t("settingsWindow.models.connect")}</span>
        </span>
      </Button>
      <Popover
        id={triggerProps["aria-controls"]}
        className="models-picker"
        anchor={anchor}
        align="start"
        open={open && anchor !== null}
        onOpenChange={setOpen}
        label={t("settingsWindow.models.connect")}
        initialFocus={search}
        finalFocus={handingOff ? false : trigger}
      >
        {open && (
          <ProviderOptions
            search={search}
            cloud={cloud}
            claudeCodeAvailable={claudeCodeAvailable}
            claudeError={claudeError}
            onPick={onPick}
          />
        )}
      </Popover>
    </>
  );
}

function ProviderOptions({
  search,
  cloud,
  claudeCodeAvailable,
  claudeError,
  onPick,
}: {
  search: RefObject<HTMLInputElement | null>;
  cloud: boolean;
  claudeCodeAvailable?: boolean | null;
  claudeError?: string | null;
  onPick(id: string): void;
}) {
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState<string | null>(null);
  // Each column scrolls on its own and fades at an edge with more rows past it.
  const plansEdges = useScrollEdges();
  const keysEdges = useScrollEdges();
  // A search lists its matches as full-width rows under their group captions, in one scroller.
  const resultsEdges = useScrollEdges();
  const searching = query.trim() !== "";
  const listId = useId();
  const optionId = (id: string) => `${listId}-${id}`;
  const matches = searchProviders(query).filter(
    (provider) => provider.group !== "local" && canAddProvider(provider, cloud),
  );
  // Two columns: Plans (a subscription or a coding plan: both a monthly plan the person signs in with) and API keys
  // (a vendor's key or a gateway's: both a key the person pastes), the common keys first. A search filters both.
  const keys = matches.filter((provider) => provider.group === "keys" || provider.group === "gateways");
  const leading = (id: string) => (LEADING_KEYS.includes(id) ? LEADING_KEYS.indexOf(id) : LEADING_KEYS.length);
  const groups = [
    {
      id: "plans",
      caption: t("settingsWindow.models.catalog.plans"),
      providers: matches.filter((provider) => provider.group === "subscriptions" || provider.group === "codingPlans"),
    },
    {
      id: "keys",
      caption: providerGroupName("keys"),
      providers: [...keys].sort((a, b) => leading(a.id) - leading(b.id)),
    },
  ] as const;
  const choices = [
    ...groups.flatMap(({ providers }) =>
      providers.filter((p) => !providerDisabledReason(p, claudeCodeAvailable, cloud, claudeError)).map((p) => p.id),
    ),
    custom,
  ];
  // The column view's arrows: Plans is one column, the keys grid two. Right and Left cross between them on the same
  // row; Down and Up move within a column (a grid row at a time) and past either end reach Add custom provider.
  const planIds = groups[0].providers.map((p) => p.id);
  const keyIds = groups[1].providers.map((p) => p.id);
  const enabled = new Set(choices);
  const gridStep = (from: string | undefined, key: string): string | undefined => {
    const first = choices[0];
    if (!from) return first;
    const step = (at: string): string | undefined => {
      const plan = planIds.indexOf(at);
      const keyAt = keyIds.indexOf(at);
      if (at === custom) {
        if (key === "ArrowDown") return planIds[0] ?? keyIds[0];
        if (key === "ArrowUp") return planIds.at(-1) ?? keyIds.at(-1);
        return undefined;
      }
      if (plan >= 0) {
        if (key === "ArrowDown") return planIds[plan + 1] ?? custom;
        if (key === "ArrowUp") return plan > 0 ? planIds[plan - 1] : custom;
        if (key === "ArrowRight") return keyIds.length ? keyIds[Math.min(plan * 2, keyIds.length - 1)] : undefined;
        return undefined;
      }
      if (keyAt >= 0) {
        if (key === "ArrowDown") return keyIds[keyAt + 2] ?? custom;
        if (key === "ArrowUp") return keyAt >= 2 ? keyIds[keyAt - 2] : custom;
        if (key === "ArrowRight") return keyAt % 2 === 0 ? keyIds[keyAt + 1] : undefined;
        if (keyAt % 2 === 1) return keyIds[keyAt - 1];
        return planIds.length ? planIds[Math.min(keyAt / 2, planIds.length - 1)] : undefined;
      }
      return first;
    };
    // A disabled row (Claude without Claude Code) is passed over in the same direction.
    let at: string | undefined = from;
    for (let guard = 0; guard < planIds.length + keyIds.length + 2; guard++) {
      at = at === undefined ? undefined : step(at);
      if (at === undefined) return from;
      if (at === custom || enabled.has(at)) return at;
    }
    return from;
  };
  const active =
    highlight && choices.includes(highlight) ? highlight : query.trim() && choices.length > 1 ? choices[0] : undefined;
  const searchLabel = t("settingsWindow.models.catalog.searchProviders");
  return (
    <>
      <div className="models-search">
        <Icon name="search" />
        <Input
          type="search"
          variant="plain"
          role="combobox"
          tabIndex={0}
          ref={search}
          value={query}
          placeholder={searchLabel}
          aria-label={searchLabel}
          aria-expanded="true"
          aria-autocomplete="list"
          aria-controls={listId}
          aria-activedescendant={active ? optionId(active) : undefined}
          onChange={(event) => {
            setQuery(event.target.value);
            setHighlight(null);
          }}
          onKeyDown={(event) => {
            if (event.nativeEvent.isComposing) return;
            if (event.key === "Enter" && active) {
              event.preventDefault();
              onPick(active);
            } else if (!searching && choices.length > 0 && isArrow(event.key)) {
              // The two columns move in two dimensions: across Plans and the keys grid, down a column.
              event.preventDefault();
              const id = gridStep(active, event.key);
              if (id) {
                setHighlight(id);
                document.getElementById(optionId(id))?.scrollIntoView?.({ block: "nearest" });
              }
            } else if (choices.length > 0 && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
              event.preventDefault();
              const current = active ? choices.indexOf(active) : -1;
              const next = event.key === "ArrowDown" ? current + 1 : current < 0 ? choices.length - 1 : current - 1;
              const id = choices[(next + choices.length) % choices.length]!;
              setHighlight(id);
              document.getElementById(optionId(id))?.scrollIntoView?.({ block: "nearest" });
            }
          }}
        />
      </div>
      <DrivenList kind="listbox" id={listId} className="models-picker-list" label={searchLabel} data-models-catalog="">
        <div
          ref={searching ? resultsEdges : undefined}
          className={cx(
            "models-picker-scroll",
            searching ? "models-picker-results ui-scroll-edge-fade" : "models-picker-columns",
          )}
          role="presentation"
        >
          {groups.map(({ id, caption, providers }) => {
            if (!providers.length) return null;
            return (
              <div key={id} role="group" aria-label={caption} data-models-group={id} className="models-picker-column">
                <div className="models-picker-caption" aria-hidden="true">
                  {caption}
                </div>
                <div
                  ref={searching ? undefined : id === "keys" ? keysEdges : plansEdges}
                  className={
                    searching
                      ? undefined
                      : cx("models-picker-column-scroll ui-scroll-edge-fade", id === "keys" && "models-picker-grid")
                  }
                  role="presentation"
                >
                  {providers.map((provider) => {
                    const reason = providerDisabledReason(provider, claudeCodeAvailable, cloud, claudeError);
                    return (
                      <DrivenRow
                        key={provider.id}
                        id={optionId(provider.id)}
                        kind="option"
                        className="ui-menu-item models-picker-option"
                        data-models-choice={provider.id}
                        data-highlighted={active === provider.id ? "" : undefined}
                        aria-selected={active === provider.id}
                        aria-disabled={reason ? true : undefined}
                        onPointerEnter={(event) => {
                          if (!reason && event.pointerType !== "touch") setHighlight(provider.id);
                        }}
                        onPick={() => {
                          if (!reason) onPick(provider.id);
                        }}
                      >
                        <ModelProviderMark mark={provider.mark} />
                        {reason ? (
                          <span className="models-picker-provider">
                            <span>
                              {providerName(provider)}{" "}
                              <span className="models-picker-disabled">
                                {t("settingsWindow.models.catalog.disabled")}
                              </span>
                            </span>
                            <small className="row-help">{reason}</small>
                          </span>
                        ) : (
                          <span>{providerName(provider)}</span>
                        )}
                      </DrivenRow>
                    );
                  })}
                </div>
              </div>
            );
          })}
          {!matches.length && (
            <div className="models-picker-caption" role="presentation">
              {t("settingsWindow.models.catalog.noProviders")}
            </div>
          )}
        </div>
        {
          <div className="models-picker-footer" role="presentation">
            <DrivenRow
              id={optionId(custom)}
              kind="option"
              className="ui-menu-item models-picker-option"
              data-models-choice={custom}
              data-highlighted={active === custom ? "" : undefined}
              aria-selected={active === custom}
              onPointerEnter={(event) => {
                if (event.pointerType !== "touch") setHighlight(custom);
              }}
              onPick={() => onPick(custom)}
            >
              <Icon name="plus" />
              {t("settingsWindow.models.addCustom")}
            </DrivenRow>
          </div>
        }
      </DrivenList>
    </>
  );
}
