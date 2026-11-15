// The right sidebar's Machines section (design/machines-section.md): this Mac, then a header per kind
// (Cloud, SSH, Servers, Joined) over its machines, then Add Machine…, laid out as the
// `machines.section.style` tunable says. Every icon sits in one column and every name starts on one
// line. New Workspace (and a joined machine's "…") show on the row's hover, keyboard focus, or while
// its menu is open; the menus are the app's native registry menus. Rows past the viewport skip
// layout and paint (`content-visibility`), so the cost of a frame stays that of the visible rows.
import { DeviceGlyph } from "../../ui/DeviceGlyph";
import { deviceKindOfSymbol } from "../../ui/deviceKinds";
import { memo, useRef, useSyncExternalStore, type MouseEvent } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { TeamTag } from "../../agent-session/acpmux/TeamTag";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import type { Strings } from "../shared/i18n";
import {
  KIND_ICON,
  healthHelp,
  isLinked,
  joinedCaption,
  sectionItems,
  showsStateLine,
  stateText,
  asksFirst,
  dialStopped,
  dialText,
} from "./model";
import type { MachinesStore } from "./store";
import type { HostHealth, JoinedMachineChange, MachineRow, JoinedDialPhase } from "./types";

/** Where a joined row says how its New Workspace on another Mac stands (the gallery's variants; the
 * app ships `caption`): in the caption's place with Retry after it, at the trailing edge, or in the
 * caption's place in a tinted ink with Retry as the New Workspace button. */
export type DialLayout = "caption" | "trailing" | "tinted";

const ICON = 16;
const SMALL_ICON = 12;

export function MachinesSection({
  store,
  strings,
  dialLayout = "caption",
}: {
  store: MachinesStore;
  strings: Strings;
  dialLayout?: DialLayout;
}) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const snapshot = state.snapshot;
  // Nothing to show until the first snapshot: the section's frame stays empty, never a placeholder
  // that the rows replace.
  if (!snapshot) return <div className="machines" data-loading="" />;
  const stateLine = showsStateLine(snapshot.style);
  const busy = new Set(snapshot.busy);
  const asked = state.confirmRemove ? snapshot.rows.find((row) => row.id === state.confirmRemove) : undefined;
  return (
    <>
      <ul className="machines" data-style={snapshot.style} data-dial-layout={dialLayout}>
        {sectionItems(snapshot, strings, state.removed).map((item) => {
          switch (item.type) {
            case "header":
              return (
                <li key={item.key} className="machines-header" data-first={item.first ? "" : undefined}>
                  {item.title}
                  {item.team && <TeamTag team={item.team} />}
                </li>
              );
            case "add":
              return (
                <AddRow
                  key={item.key}
                  gap={item.gap}
                  label={strings.t("machines.addMachine")}
                  onAdd={() => store.addMachine()}
                />
              );
            case "row":
              return item.row.joined ? (
                <JoinedRow
                  key={item.key}
                  row={item.row}
                  strings={strings}
                  busy={busy.has(item.row.joined.id)}
                  failed={snapshot.failed[item.row.joined.id]}
                  menuOpen={state.menuOpen === item.row.id || snapshot.openMenu === item.row.joined.id}
                  store={store}
                  dial={state.dials[item.row.id]}
                  dialLayout={dialLayout}
                />
              ) : (
                <MachineRowView
                  key={item.key}
                  row={item.row}
                  strings={strings}
                  stateLine={stateLine}
                  menuOpen={state.menuOpen === item.row.id}
                  store={store}
                />
              );
          }
        })}
      </ul>
      {asked && <RemoveQuestion row={asked} strings={strings} store={store} />}
    </>
  );
}

/** Remove's question: what it does, Cancel (Escape) and Remove (Return), as the app's dialogs ask.
 * Remove takes the focus and is the form's submit, so Return removes and Escape cancels. */
function RemoveQuestion({ row, strings, store }: { row: MachineRow; strings: Strings; store: MachinesStore }) {
  const confirm = useRef<HTMLButtonElement | null>(null);
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) store.cancelRemove();
      }}
      label={strings.format("machines.joined.removeTitle", row.name)}
      className="ui-glass ui-glass-floats machines-dialog"
      initialFocus={confirm}
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void store.remove(row.id);
        }}
      >
        <h2 className="machines-dialog-title">{strings.format("machines.joined.removeTitle", row.name)}</h2>
        <p className="machines-dialog-body">{strings.t("machines.joined.removeBody")}</p>
        <div className="machines-dialog-actions">
          <DialogButton
            dialogKey="escape"
            type="button"
            className="machines-dialog-button"
            onClick={() => store.cancelRemove()}
          >
            {strings.t("machines.joined.cancel")}
          </DialogButton>
          <DialogButton
            dialogKey="return"
            type="submit"
            ref={confirm}
            className="machines-dialog-button"
            data-danger=""
          >
            {strings.t("machines.joined.removeButton")}
          </DialogButton>
        </div>
      </form>
    </Dialog>
  );
}

/** A machine's last check after its name: a check in the success color, a dot otherwise. */
function HealthMark({ health }: { health?: HostHealth }) {
  if (!health) return null;
  return health === "ok" ? (
    <span className="machines-health" data-health="ok" aria-hidden="true">
      <Icon name="status.complete" size={SMALL_ICON} />
    </span>
  ) : (
    <span className="machines-health machines-health-dot" data-health={health} aria-hidden="true" />
  );
}

type RowProps = { row: MachineRow; strings: Strings; menuOpen: boolean; store: MachinesStore };

/** Opens the native menu at the pointer (right-click) or under `button`. */
function openMenuAt(
  store: MachinesStore,
  row: string,
  kind: "row" | "joined",
  event: MouseEvent<HTMLElement>,
  below = false,
) {
  event.preventDefault();
  if (below) {
    const rect = event.currentTarget.getBoundingClientRect();
    void store.openMenu(row, kind, rect.left, rect.bottom + 4);
  } else {
    void store.openMenu(row, kind, event.clientX, event.clientY);
  }
}

const MachineRowView = memo(function MachineRowView({
  row,
  strings,
  stateLine,
  menuOpen,
  store,
}: RowProps & { stateLine: boolean }) {
  const state = stateText(row, strings);
  const help = healthHelp(row, strings);
  // The state shows on its own line, or at the trailing edge only when the link is down.
  const trailingState = !stateLine && !row.isConnected && !row.isConnecting;
  const label = [row.name, state, help ?? ""].filter(Boolean).join(", ");
  const newWorkspace = strings.t("machines.newWorkspace");
  return (
    <li
      className="machines-row"
      aria-label={label}
      data-connected={row.isConnected ? "" : undefined}
      data-menu-open={menuOpen ? "" : undefined}
      // tooltip-allow: the last check's step appears nowhere else on the row.
      title={help}
      onContextMenu={(event) => openMenuAt(store, row.id, "row", event)}
    >
      <MachineIcon row={row} />
      <span className="machines-text">
        <span className="machines-name-line">
          <span className="machines-name">{row.name}</span>
          <HealthMark health={row.health} />
        </span>
        {stateLine && <span className="machines-state">{state}</span>}
      </span>
      {trailingState && <span className="machines-state machines-state-trailing">{state}</span>}
      {row.isConnecting && <Spinner size={SMALL_ICON} className="machines-spinner" loading />}
      <button
        type="button"
        className="machines-action"
        aria-label={newWorkspace}
        // tooltip-allow: an icon-only button names its action.
        title={newWorkspace}
        disabled={!row.isConnected}
        onClick={() => row.isConnected && store.newWorkspace(row.id)}
      >
        <Icon name="action.add" size={SMALL_ICON} />
      </button>
    </li>
  );
});

const JoinedRow = memo(function JoinedRow({
  row,
  strings,
  busy,
  failed,
  menuOpen,
  store,
  dial,
  dialLayout,
}: RowProps & { busy: boolean; failed?: JoinedMachineChange; dial?: JoinedDialPhase; dialLayout: DialLayout }) {
  const machine = row.joined!;
  const caption = joinedCaption(machine, failed, strings);
  const help = healthHelp(row, strings);
  const linked = isLinked(row);
  const asks = asksFirst(row);
  const canOpen = (linked && row.isConnected) || asks;
  const newWorkspace = strings.t("machines.newWorkspace");
  // New Workspace on a Mac reached through the hub alone: the row says where the ask stands, in its
  // caption's place (the pick) or at its trailing edge, never in a dialog; Retry once it stopped.
  const asking = dial === "connecting" || dial === "waiting";
  const stopped = dialStopped(dial);
  const dialWords = dial ? dialText(dial, row.name, strings) : undefined;
  const inCaption = dialWords !== undefined && dialLayout !== "trailing";
  const retry = strings.t("machines.dial.retry");
  const open = () => {
    if (asks) store.openJoined(row.id);
    else if (canOpen) store.newWorkspace(row.id);
  };
  return (
    <li
      className="machines-row machines-joined"
      aria-label={[row.name, dialWords ?? caption, help ?? ""].filter(Boolean).join(", ")}
      data-menu-open={menuOpen ? "" : undefined}
      data-busy={busy ? "" : undefined}
      data-dial={dial}
      onContextMenu={(event) => openMenuAt(store, row.id, "joined", event)}
    >
      <MachineIcon row={row} />
      {/* tooltip-allow: the last check's step appears nowhere else on the row. */}
      <span className="machines-text" title={help}>
        <span className="machines-name-line">
          <span className="machines-name machines-name-truncate">{row.name}</span>
          <HealthMark health={row.health} />
        </span>
        <span className="machines-state-line">
          {inCaption ? (
            // An <output> is a status: a screen reader reads each new word of the ask as it lands.
            <output className="machines-state" data-dial={dial}>
              {dialWords}
            </output>
          ) : (
            <span className="machines-state" data-failed={failed ? "" : undefined}>
              {caption}
            </span>
          )}
          {stopped && dialLayout === "caption" && (
            <button type="button" className="machines-retry" onClick={open}>
              {retry}
            </button>
          )}
        </span>
      </span>
      {dialWords !== undefined && dialLayout === "trailing" && (
        <output className="machines-state machines-state-trailing" data-dial={dial}>
          {dialWords}
        </output>
      )}
      {busy ? (
        <Spinner size={SMALL_ICON} className="machines-spinner machines-joined-spinner" loading />
      ) : (
        <button
          type="button"
          className="machines-action machines-more"
          data-machine={machine.id}
          aria-label={strings.format("machines.joined.more", row.name)}
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          data-popup-open={menuOpen ? "" : undefined}
          onMouseDown={(event) => event.button === 0 && openMenuAt(store, row.id, "joined", event, true)}
          onKeyDown={(event) => {
            if (event.key !== "Enter" && event.key !== " ") return;
            event.preventDefault();
            const rect = event.currentTarget.getBoundingClientRect();
            void store.openMenu(row.id, "joined", rect.left, rect.bottom + 4);
          }}
        >
          <Icon name="overflow.more" size={SMALL_ICON} />
        </button>
      )}
      {!busy && (
        <button
          type="button"
          className="machines-action machines-remove"
          aria-label={strings.format("machines.joined.remove", row.name)}
          onClick={() => store.askRemove(row.id)}
        >
          <Icon name="action.remove" size={SMALL_ICON} />
        </button>
      )}
      {asking ? (
        <Spinner size={SMALL_ICON} className="machines-spinner machines-joined-spinner machines-dial-spinner" loading />
      ) : (
        <button
          type="button"
          className="machines-action machines-new"
          aria-label={stopped && dialLayout !== "caption" ? retry : newWorkspace}
          // tooltip-allow: why a workspace cannot open on a mesh-only machine.
          title={
            canOpen
              ? stopped && dialLayout !== "caption"
                ? retry
                : newWorkspace
              : strings.t("machines.joined.noWorkspace")
          }
          disabled={!canOpen}
          onClick={open}
        >
          <Icon name={stopped && dialLayout !== "caption" ? "action.retry" : "action.add"} size={SMALL_ICON} />
        </button>
      )}
    </li>
  );
});

/** A machine's icon: its device glyph when the app says what device it is (`device`, the kind
 * acpmux reported; Leo 2026-11-14), in the same icon box; else its kind's pack icon. */
function MachineIcon({ row }: { row: MachineRow }) {
  const device = deviceKindOfSymbol(row.symbol);
  if (!device) return <Icon name={KIND_ICON[row.kind]} size={ICON} row fit className="machines-icon" />;
  return <DeviceGlyph kind={device} width={ICON} height={ICON} className="machines-icon" />;
}

/** Add Machine… as the section's last row: its icon in the machines' icon column. The pointer
 * brightens it from the secondary ink to the primary one; only its icon and text take the click. */
function AddRow({ gap, label, onAdd }: { gap: boolean; label: string; onAdd: () => void }) {
  return (
    <li className="machines-add-line" data-gap={gap ? "" : undefined}>
      <button type="button" className="machines-add" onClick={onAdd}>
        <Icon name="action.add" size={ICON} row fit className="machines-icon" />
        <span>{label}</span>
      </button>
    </li>
  );
}
