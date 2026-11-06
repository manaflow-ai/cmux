// The Add Device card (design/server-cards.md, plans/cmux-next/add-device-DESIGN.md 2.3): the title,
// the ways (the pair code first, ssh behind Advanced), the chosen way's body and the footer. Every
// way, button and phase comes from the model (model.ts); the card only draws it and sends each
// click or key as one action.
import { useEffect, useRef, type CSSProperties } from "react";
import { DialogButton } from "../../../ui/DialogButton";
import { Tabs, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { VirtualList } from "../../../ui/VirtualList";
import { cx } from "../../../ui/cx";
import type { Strings } from "../../shared/i18n";
import {
  ADD_DEVICE_PLATFORMS,
  clockText,
  setupLine,
  type AddDeviceAction,
  type AddDeviceButton,
  type AddDeviceModel,
  type AddDeviceState,
  type AddDeviceWay,
  type AvailableComputer,
  type JoinCheck,
} from "./model";

/** The "Any machine" way's look (design/server-cards.md, Variants). */
export type JoinLineLayout = "card" | "steps" | "compact";

export interface AddDeviceCardProps {
  model: AddDeviceModel;
  /** The model's snapshot (the host re-renders on each change). */
  state: AddDeviceState;
  strings: Strings;
  layout?: JoinLineLayout;
  /** Runs one action; the host closes the card when it returns true. */
  onAction(action: AddDeviceAction): void;
}

/** The ssh-first card's width, and the wider one when the pair code is offered (the line and
 * every way read whole). */
export const CARD_WIDTH = 440;
export const WIDE_WIDTH = 540;
const ROW_HEIGHT = 36;
const ROW_GAP = 4;
const LIST_MAX_HEIGHT = 228;

export function AddDeviceCard({ model, state, strings, layout = "card", onAction }: AddDeviceCardProps) {
  const { t } = strings;
  const wide = model.advancedWays.length > 0;
  const buttons = model.buttons;
  const main = buttons.find((button) => button.key === "return");
  const onReturn = useRef<(() => void) | null>(null);
  onReturn.current = main ? () => onAction({ kind: main.action }) : null;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Enter" || event.isComposing || event.defaultPrevented || !onReturn.current) return;
      // A focused button answers its own Return.
      if (event.target instanceof HTMLButtonElement) return;
      event.preventDefault();
      onReturn.current();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
  const selected = model.ways.includes(state.way) ? state.way : null;
  return (
    <section
      className={cx("server-card add-device", `add-device--${layout}`)}
      style={{ width: wide ? WIDE_WIDTH : CARD_WIDTH } as CSSProperties}
      data-card="add-device"
      data-way={state.way}
      data-join={state.join.phase}
      aria-label={t("addDevice.title")}
    >
      <header className="add-device-header">
        <h1 className="server-card-title">{t("addDevice.title")}</h1>
        <p className="server-card-text">{t("addDevice.subtitle")}</p>
      </header>
      <Tabs
        variant="segmented"
        value={selected}
        onValueChange={(value) => model.chooseWay(value as AddDeviceWay)}
        className="add-device-ways"
      >
        <TabsList className={cx("add-device-switch", wide && "is-fit")} aria-label={t("addDevice.title")}>
          {model.ways.map((way) => (
            <TabsTrigger key={way} value={way} data-way={way}>
              {t(`addDevice.way.${way}`)}
            </TabsTrigger>
          ))}
        </TabsList>
      </Tabs>
      {!model.showsAdvanced && (
        <WayBody model={model} state={state} strings={strings} layout={layout} onAction={onAction} />
      )}
      {wide && (
        <div className="add-device-advanced">
          <button
            type="button"
            className="ui-button add-device-advanced-toggle"
            aria-expanded={model.showsAdvanced}
            data-action="toggleAdvanced"
            onClick={() => onAction({ kind: "toggleAdvanced" })}
          >
            <span className={cx("add-device-chevron", model.showsAdvanced && "is-open")} aria-hidden="true" />
            {t("addDevice.advanced")}
          </button>
          {model.showsAdvanced && (
            <WayBody model={model} state={state} strings={strings} layout={layout} onAction={onAction} />
          )}
        </div>
      )}
      {/* A joined machine was let in by the person's line, not by an approval: that way says its own note. */}
      {state.way !== "joinLine" && <p className="server-card-caption">{t("addDevice.approvalNote")}</p>}
      <footer className="server-card-footer">
        <span className="server-card-footer-gap" />
        {buttons.map((button) => (
          <FooterButton key={button.action} button={button} state={state} strings={strings} onAction={onAction} />
        ))}
      </footer>
    </section>
  );
}

function FooterButton({
  button,
  state,
  strings,
  onAction,
}: {
  button: AddDeviceButton;
  state: AddDeviceState;
  strings: Strings;
  onAction(action: AddDeviceAction): void;
}) {
  return (
    <DialogButton
      dialogKey={button.key}
      className={cx("server-card-button", button.key === "return" && "is-default")}
      data-action={button.action}
      onClick={() => onAction({ kind: button.action })}
    >
      {buttonTitle(button.action, state, strings)}
    </DialogButton>
  );
}

export function buttonTitle(action: AddDeviceAction["kind"], state: AddDeviceState, { t }: Strings): string {
  switch (action) {
    case "pick":
      return t("addDevice.add");
    case "otherComputer":
      return t("addDevice.otherComputer");
    case "newCloudMachine":
      return t("addDevice.newCloudMachine");
    case "enterCode":
      return t("addDevice.enterCode");
    case "installTailscale":
      return t("addDevice.installTailscale");
    case "copyLine":
      return state.copied ? t("addDevice.copied") : t("addDevice.copyLine");
    case "copyJoinLine":
      return state.joinCopied ? t("addDevice.copied") : t("addDevice.copyLine");
    case "makeJoinLine":
      return t("addDevice.joinLine.makeLine");
    case "newJoinLine":
      return t("addDevice.joinLine.newLine");
    case "signIn":
      return t("signIn.button");
    case "showMachines":
      return t("addDevice.joinLine.showMachines");
    case "pairAnotherMachine":
      return t("addDevice.joinLine.pairAnotherMachine");
    case "toggleAdvanced":
      return t("addDevice.advanced");
    case "done":
      return t("addDevice.done");
    case "cancel":
      return t("addDevice.cancel");
  }
}

interface WayProps {
  model: AddDeviceModel;
  state: AddDeviceState;
  strings: Strings;
  layout: JoinLineLayout;
  onAction(action: AddDeviceAction): void;
}

function WayBody(props: WayProps) {
  const { t } = props.strings;
  switch (props.state.way) {
    case "network":
      return <Network {...props} />;
    case "code":
      return <p className="server-card-text is-primary">{t("addDevice.code.help")}</p>;
    case "newDevice":
      return <NewDevice {...props} />;
    case "joinLine":
      return <JoinLineBody {...props} />;
  }
}

function Network({ model, state, strings, onAction }: WayProps) {
  const { t } = strings;
  const candidates = state.candidates;
  const list = model.available.length > 0 && (
    <ComputerList computers={model.available} strings={strings} onAction={onAction} />
  );
  return (
    <>
      <p className="server-card-text">{t("addDevice.network.help")}</p>
      <p className="server-card-caption">{t("addDevice.network.sshKeyHint")}</p>
      {candidates.state === "loading" && <Waiting text={t("addDevice.network.loading")} />}
      {candidates.state === "unavailable" && (
        <p className="server-card-text is-primary">{t("addDevice.network.unavailable")}</p>
      )}
      {candidates.state === "loaded" &&
        (model.networkProblem !== null ? (
          <>
            <p className="server-card-text is-danger">{model.networkProblem}</p>
            {model.canInstallTailscale && (
              <div>
                <DialogButton
                  dialogKey={null}
                  className="server-card-button"
                  data-action="installTailscale"
                  onClick={() => onAction({ kind: "installTailscale" })}
                >
                  {t("addDevice.installTailscale")}
                </DialogButton>
              </div>
            )}
            {/* The ssh config's computers do not need the network. */}
            {list}
          </>
        ) : model.available.length === 0 ? (
          <p className="server-card-text is-primary">{t("addDevice.network.empty")}</p>
        ) : (
          list
        ))}
    </>
  );
}

/** The network's computers: only the rows in view are in the DOM, so a long tailnet costs no more
 * than a short one. */
function ComputerList({
  computers,
  strings,
  onAction,
}: {
  computers: AvailableComputer[];
  strings: Strings;
  onAction(action: AddDeviceAction): void;
}) {
  const height = Math.min(computers.length * (ROW_HEIGHT + ROW_GAP), LIST_MAX_HEIGHT);
  return (
    <div className="add-device-list" style={{ height }} data-testid="add-device-list">
      <VirtualList
        count={computers.length}
        estimateSize={() => ROW_HEIGHT + ROW_GAP}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- VirtualList's role prop, its scroller is a div
        role="list"
        label={strings.t("addDevice.way.network")}
        className="add-device-list-scroll"
        renderRow={(index, style) => (
          <ComputerRow
            key={computers[index]!.address}
            computer={computers[index]!}
            strings={strings}
            style={style}
            onAction={onAction}
          />
        )}
      />
    </div>
  );
}

export function computerDetail(computer: AvailableComputer, { t }: Strings): string {
  const parts = computer.fromSSHConfig
    ? [t("addDevice.network.sshConfig")]
    : [computer.os, computer.mine ? t("addDevice.network.yours") : ""];
  return parts.filter((part) => part !== "").join(" · ");
}

function ComputerRow({
  computer,
  strings,
  style,
  onAction,
}: {
  computer: AvailableComputer;
  strings: Strings;
  style: CSSProperties;
  onAction(action: AddDeviceAction): void;
}) {
  const detail = computerDetail(computer, strings);
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtual row is absolutely placed in a div scroller
    <div className="add-device-row" role="listitem" style={style} data-computer={computer.name}>
      <span className="add-device-row-name">{computer.name}</span>
      <span className="add-device-row-detail">{detail}</span>
      <span className="server-card-footer-gap" />
      <DialogButton
        dialogKey={null}
        className="server-card-button"
        data-action="pick"
        aria-label={`${strings.t("addDevice.add")} ${computer.name}`}
        onClick={() => onAction({ kind: "pick", computer })}
      >
        {strings.t("addDevice.add")}
      </DialogButton>
    </div>
  );
}

function NewDevice({ model, state, strings, onAction }: WayProps) {
  const { t } = strings;
  const line = setupLine(state.platform);
  return (
    <>
      <Tabs
        variant="segmented"
        value={state.platform}
        onValueChange={(value) => model.choosePlatform(value as AddDeviceState["platform"])}
      >
        <TabsList className="add-device-switch" aria-label={t("addDevice.way.newDevice")}>
          {ADD_DEVICE_PLATFORMS.map((platform) => (
            <TabsTrigger key={platform} value={platform} data-platform={platform}>
              {t(`addDevice.platform.${platform}`)}
            </TabsTrigger>
          ))}
        </TabsList>
      </Tabs>
      {line === null ? (
        <p className="server-card-text is-primary">{t("addDevice.newDevice.phone")}</p>
      ) : (
        <>
          <p className="server-card-text">{t("addDevice.newDevice.help")}</p>
          <div className="add-device-line">
            <code className="add-device-line-text" data-testid="add-device-setup-line">
              {line}
            </code>
          </div>
        </>
      )}
      {model.offersOtherComputer && (
        <div className="add-device-other">
          <p className="server-card-text">{t("addDevice.newDevice.otherComputerHint")}</p>
          <DialogButton
            dialogKey={null}
            className="server-card-button"
            data-action="otherComputer"
            onClick={() => onAction({ kind: "otherComputer" })}
          >
            {t("addDevice.otherComputer")}
          </DialogButton>
        </div>
      )}
    </>
  );
}

/** The "Any machine" way: signed in, the invite hand-off; signed out, the single-use line. */
function JoinLineBody({ model, state, strings, layout }: WayProps) {
  const { t, format } = strings;
  if (state.offer.invite) {
    return (
      <>
        <p className="server-card-text">{t("addDevice.joinLine.inviteHelp")}</p>
        <p className="server-card-caption">{t("addDevice.approvalNote")}</p>
      </>
    );
  }
  const join = state.join;
  const compact = layout === "compact";
  const steps = layout === "steps";
  // The help is for making and pasting the line; after the flip or the expiry it is noise.
  const helps = join.phase === "idle" || join.phase === "minting" || join.phase === "showing";
  return (
    <>
      {helps && layout === "card" && <p className="server-card-text">{t("addDevice.joinLine.help")}</p>}
      {join.phase === "idle" && (
        <>
          {steps && <Step n={1} text={t("addDevice.joinLine.name")} />}
          <NameField key={state.opening} model={model} strings={strings} labelled={!steps} />
        </>
      )}
      {join.phase === "minting" && <Waiting text={t("addDevice.joinLine.minting")} />}
      {join.phase === "showing" && (
        <>
          {steps && <Step n={1} text={t("addDevice.copyLine")} />}
          <div className={cx("add-device-line", compact && "is-compact")}>
            <code className="add-device-line-text" data-testid="add-device-join-line">
              {join.line.line}
            </code>
            {compact && <Countdown model={model} strings={strings} />}
          </div>
          {!compact && (
            <p className="add-device-meta">
              <Countdown model={model} strings={strings} />
              <span>{`· ${t("addDevice.joinLine.once")}`}</span>
            </p>
          )}
          {steps && <Step n={2} text={t("addDevice.joinLine.paste")} />}
          <Waiting text={t("addDevice.joinLine.waiting")} />
        </>
      )}
      {join.phase === "joined" && (
        <>
          <p className="server-card-text is-emphasized">{format("addDevice.joinLine.joined", join.machine.name)}</p>
          {state.checks.length === 0 ? (
            <Waiting text={t("addDevice.joinLine.checking")} />
          ) : (
            <ul className="add-device-checks">
              {state.checks.map((check, index) => (
                <CheckRow key={`${check.step}-${index}`} check={check} />
              ))}
            </ul>
          )}
        </>
      )}
      {join.phase === "expired" && <p className="server-card-text is-primary">{t("addDevice.joinLine.expired")}</p>}
      {join.phase === "failed" && (
        <p className="server-card-text is-danger">{t(`addDevice.joinLine.${join.failure}`)}</p>
      )}
      <p className="server-card-caption">{t("addDevice.joinLine.consent")}</p>
    </>
  );
}

function Step({ n, text }: { n: number; text: string }) {
  return <p className="server-card-text is-emphasized">{`${n}. ${text}`}</p>;
}

function NameField({ model, strings, labelled }: { model: AddDeviceModel; strings: Strings; labelled: boolean }) {
  const { t } = strings;
  return (
    <label className="add-device-name">
      {labelled && <span>{t("addDevice.joinLine.name")}</span>}
      <input
        className="ui-field ui-input add-device-name-field"
        data-variant="filled"
        data-size="md"
        defaultValue={model.joinName}
        placeholder={t("addDevice.joinLine.namePlaceholder")}
        aria-label={t("addDevice.joinLine.name")}
        data-testid="add-device-join-name"
        // Not state: typing never redraws the card.
        onChange={(event) => (model.joinName = event.currentTarget.value)}
      />
    </label>
  );
}

/** "Expires in 9:41", the attention color under a minute. */
function Countdown({ model, strings }: { model: AddDeviceModel; strings: Strings }) {
  const left = model.secondsLeft ?? 0;
  return (
    <span className={cx("add-device-countdown", left < 60 && "is-urgent")} data-testid="add-device-countdown">
      {strings.format("addDevice.joinLine.expiresIn", clockText(left))}
    </span>
  );
}

function CheckRow({ check }: { check: JoinCheck }) {
  const mark =
    check.state === "ok" || check.state === "fixed"
      ? "✓"
      : check.state === "warn"
        ? "!"
        : check.state === "fail"
          ? "✕"
          : "–";
  const detail = check.state === "fail" ? (check.fix ?? check.detail) : check.detail;
  const text = [check.title ?? check.step, detail].filter((part) => part !== "").join(": ");
  return (
    <li className="add-device-check" data-state={check.state}>
      <span className="add-device-check-mark" aria-hidden="true">
        {mark}
      </span>
      <span>{text}</span>
    </li>
  );
}

function Waiting({ text }: { text: string }) {
  return (
    <p className="server-card-waiting">
      <span className="server-card-spinner" aria-hidden="true" />
      <span>{text}</span>
    </p>
  );
}
