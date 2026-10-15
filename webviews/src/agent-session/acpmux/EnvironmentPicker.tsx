import { useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { ComputerIcon, FolderIcon, LocationFace } from "./ComposerContext";
import { ENVIRONMENT_KINDS, type Environment, type EnvironmentKind } from "./environments";
import { type Translate, useT } from "./i18n";
import { useLocationOpener, useLocationPopover } from "./locationPopover";
import { projectLabel } from "./sessionList";
import "./environments.css";

/// The New Tab composer strip's environment control (cx-ncc.104, Labs `savedEnvironments`):
/// "Choose environment", or the picked one's name and machine glyph. It opens a popover like the
/// folder's (FolderPopover): a search field over the saved environments, Local, then SSH, then
/// Cloud, the picked one checked; then No environment and Edit environment while one is picked,
/// and New environment. A right-click on the control edits, removes or clears the picked one.
export function EnvironmentPicker({
  environments,
  selected,
  onSelect,
  onNew,
  onEdit,
  onRemove,
}: {
  environments: readonly Environment[];
  selected?: Environment;
  onSelect(id: string | undefined): void;
  onNew(): void;
  onEdit(environment: Environment): void;
  onRemove(environment: Environment): void;
}) {
  const t = useT();
  const [query, setQuery] = useState("");
  const trigger = useRef<HTMLButtonElement>(null);
  const escaped = useRef(false);
  const { control, anchor, open, setOpen, side } = useLocationPopover();
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) setQuery("");
  });
  useLocationOpener("Environment", () => setOpen(true));
  const grouped = useMemo(
    () => ENVIRONMENT_KINDS.flatMap((kind) => environments.filter((environment) => environment.kind === kind)),
    [environments],
  );
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return grouped.filter((environment) => {
      const text = [
        environment.name,
        groupLabel(t, environment.kind),
        environment.host ?? "",
        ...environment.folders.map((folder) => folder.path),
      ]
        .join(" ")
        .toLowerCase();
      return words.every((word) => text.includes(word));
    });
  }, [grouped, query, t]);
  const actions: { value: string; text: string; run(): void }[] = [
    ...(selected
      ? [
          { value: ACTION + "clear", text: t("environment.clear"), run: () => onSelect(undefined) },
          { value: ACTION + "edit", text: t("environment.edit"), run: () => onEdit(selected) },
        ]
      : []),
    { value: ACTION + "new", text: t("environment.new"), run: onNew },
  ];
  const close = () => {
    setOpen(false);
    setQuery("");
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  const submit = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    close();
    if (action) action.run();
    else if (shown.some((environment) => environment.id === value)) onSelect(value);
  };
  const row = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    if (action)
      return (
        <span className="acpmux-location-action" data-first={action === actions[0] ? "" : undefined}>
          <span className="acpmux-location-check" aria-hidden="true" />
          <span className="acpmux-menu-label">{action.text}</span>
        </span>
      );
    const index = shown.findIndex((candidate) => candidate.id === value);
    const environment = shown[index]!;
    const first = index === 0 || shown[index - 1]!.kind !== environment.kind;
    const detail = environmentDetail(environment);
    return (
      <span
        className="acpmux-location-row acpmux-env-row"
        data-env-id={environment.id}
        data-group={first ? groupLabel(t, environment.kind) : undefined}
        data-current={environment.id === selected?.id ? "" : undefined}
        title={environment.folders.map((folder) => folder.path).join("\n") || undefined}
      >
        <span className="acpmux-location-check" aria-hidden="true">
          {environment.id === selected?.id && <CheckIcon />}
        </span>
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{environment.name}</span>
          {detail && (
            <>
              {" "}
              <span className="acpmux-location-suffix-dot" aria-hidden="true">
                ·
              </span>{" "}
              <span className="acpmux-location-suffix">{detail}</span>
            </>
          )}
        </span>
      </span>
    );
  };
  const menu: ContextMenuItem[] = selected
    ? [
        { id: "edit", label: t("environment.edit"), onSelect: () => onEdit(selected) },
        { id: "clear", label: t("environment.clear"), onSelect: () => onSelect(undefined) },
        { id: "new", label: t("environment.new"), separatorBefore: true, onSelect: onNew },
        {
          id: "remove",
          label: t("environment.remove"),
          destructive: true,
          separatorBefore: true,
          onSelect: () => onRemove(selected),
        },
      ]
    : [{ id: "new", label: t("environment.new"), onSelect: onNew }];
  return (
    <ContextMenu items={menu} targets="own">
      <span ref={control} className="acpmux-location-picker acpmux-env-picker" data-env-kind={selected?.kind}>
        <button
          ref={trigger}
          type="button"
          className="acpmux-location-button ui-ghost ui-ghost-sm"
          aria-label={t("project.environment")}
          aria-haspopup="dialog"
          aria-expanded={open}
          title={
            selected
              ? selected.folders.map((folder) => folder.path).join("\n") || selected.name
              : t("environment.choose")
          }
          {...press}
        >
          <LocationFace
            icon={selected ? <EnvironmentGlyph kind={selected.kind} /> : <EnvironmentGlyph />}
            // Nothing picked: the glyph alone (its title names it), so Folder and Computer keep their room.
            value={selected ? selected.name : ""}
            chevron
          />
        </button>
        <Popover
          open={open}
          onOpenChange={(next) => {
            setOpen(next);
            if (!next) setQuery("");
          }}
          anchor={open ? anchor : null}
          label={t("project.environment")}
          className="acpmux-menu acpmux-location-menu acpmux-folder-popover acpmux-env-popover"
          side={side}
          flip={false}
          finalFocus={false}
        >
          <Combobox
            suggestions={[...shown.map((environment) => environment.id), ...actions.map((action) => action.value)]}
            onQuery={setQuery}
            onSubmit={submit}
            onCancel={close}
            onCommand={(event) => {
              if (event.key === "Escape") escaped.current = true;
              if (event.key === "Tab") event.preventDefault();
            }}
            label={t("environment.search")}
            placeholder={t("environment.search")}
            inputClassName="acpmux-location-search"
            listClassName="acpmux-location-folders"
            itemClassName="acpmux-menu-item"
            renderItem={row}
            autoHighlight
            inline
          />
          {shown.length === 0 && (
            <div className="acpmux-location-empty">
              {t(environments.length ? "environment.none" : "environment.noneYet")}
            </div>
          )}
        </Popover>
      </span>
    </ContextMenu>
  );
}

function groupLabel(t: Translate, kind: EnvironmentKind): string {
  return kind === "local" ? t("environment.local") : kind === "ssh" ? t("environment.ssh") : t("composer.cloud");
}

/// A row's muted second part: an SSH machine's name, else the first folder's.
function environmentDetail(environment: Environment): string | undefined {
  if (environment.kind === "ssh" && environment.host) return environment.host;
  const folder = environment.folders[0]?.path;
  return folder ? projectLabel(folder) : undefined;
}

/// The strip's glyph: the stack of an environment not yet chosen, a folder for a local one, the
/// machine for an SSH one and a cloud for a Cloud one.
export function EnvironmentGlyph({ kind }: { kind?: EnvironmentKind }) {
  if (kind === "local") return <FolderIcon />;
  if (kind === "ssh") return <ComputerIcon />;
  return (
    <svg
      className="acpmux-icon acpmux-location-icon ui-ghost-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinejoin="round"
      strokeLinecap="round"
      aria-hidden="true"
      focusable="false"
    >
      {kind === "cloud" ? (
        <path d="M4.6 12.5h7a2.6 2.6 0 0 0 .3-5.2 3.9 3.9 0 0 0-7.5-.8A3 3 0 0 0 4.6 12.5Z" />
      ) : (
        <>
          <path d="M8 2.5 13.5 5 8 7.5 2.5 5Z" />
          <path d="M2.5 8 8 10.5 13.5 8" />
          <path d="M2.5 11 8 13.5 13.5 11" />
        </>
      )}
    </svg>
  );
}

/// An action row's value: never an environment's id.
const ACTION = "\u0000action:";

function CheckIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m3.5 8.5 3 3 6-7" />
    </svg>
  );
}
