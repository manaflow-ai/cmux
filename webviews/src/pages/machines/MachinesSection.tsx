// The right sidebar's Machines section (design/machines-section.md): this Mac, then a header per kind
// (Cloud, SSH, Servers, Joined) over its machines, then Add Machine…, laid out as the
// `machines.section.style` tunable says. Every icon sits in one column and every name starts on one
// line. New Workspace (and a joined machine's "…") show on the row's hover, keyboard focus, or while
// its menu is open; the menus are the app's native registry menus. Rows past the viewport skip
// layout and paint (`content-visibility`), so the cost of a frame stays that of the visible rows.
import { memo, useRef, useSyncExternalStore, type MouseEvent } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import type { Strings } from "../shared/i18n";
import { KIND_ICON, healthHelp, isLinked, joinedCaption, sectionItems, showsStateLine, stateText } from "./model";
import type { MachinesStore } from "./store";
import type { HostHealth, JoinedMachineChange, MachineRow } from "./types";

const ICON = 16;
const SMALL_ICON = 12;

export function MachinesSection({ store, strings }: { store: MachinesStore; strings: Strings }) {
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
      <ul className="machines" data-style={snapshot.style}>
        {sectionItems(snapshot, strings, state.removed).map((item) => {
          switch (item.type) {
            case "header":
              return (
                <li key={item.key} className="machines-header" data-first={item.first ? "" : undefined}>
                  {item.title}
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
      <Icon name={KIND_ICON[row.kind]} size={ICON} row fit className="machines-icon" />
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
}: RowProps & { busy: boolean; failed?: JoinedMachineChange }) {
  const machine = row.joined!;
  const caption = joinedCaption(machine, failed, strings);
  const help = healthHelp(row, strings);
  const linked = isLinked(row);
  const canOpen = linked && row.isConnected;
  const newWorkspace = strings.t("machines.newWorkspace");
  return (
    <li
      className="machines-row machines-joined"
      aria-label={[row.name, caption, help ?? ""].filter(Boolean).join(", ")}
      data-menu-open={menuOpen ? "" : undefined}
      data-busy={busy ? "" : undefined}
      onContextMenu={(event) => openMenuAt(store, row.id, "joined", event)}
    >
      <Icon name={KIND_ICON[row.kind]} size={ICON} row fit className="machines-icon" />
      {/* tooltip-allow: the last check's step appears nowhere else on the row. */}
      <span className="machines-text" title={help}>
        <span className="machines-name-line">
          <span className="machines-name machines-name-truncate">{row.name}</span>
          <HealthMark health={row.health} />
        </span>
        <span className="machines-state" data-failed={failed ? "" : undefined}>
          {caption}
        </span>
      </span>
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
      <button
        type="button"
        className="machines-action"
        aria-label={newWorkspace}
        // tooltip-allow: why a workspace cannot open on a mesh-only machine.
        title={linked ? newWorkspace : strings.t("machines.joined.noWorkspace")}
        disabled={!canOpen}
        onClick={() => canOpen && store.newWorkspace(row.id)}
      >
        <Icon name="action.add" size={SMALL_ICON} />
      </button>
    </li>
  );
});

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
