import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CloudEnvironment } from "../../pages/cloud/environmentModel";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../ui/Menu";
import { ChevronIcon } from "./ComposerPickers";
import { ServerIcon } from "./EnvironmentPicker";
import { translate as t } from "./i18n";
import { useLocationOpener, useLocationPopover } from "./locationPopover";
import { postNative } from "./native";
import { openCloudEnvironment } from "./cloudEnvironment";
import {
  AUTO_ENVIRONMENT,
  autoEnvironment,
  cloudStartEnvironment,
  defaultPick,
  projectDefaultFrom,
  recentEnvironments,
  rememberEnvironment,
  cloudEnvironmentRows,
  cloudEnvironmentValue,
  type CloudEnvironmentControl,
  type CloudEnvironmentPick,
  type CloudEnvironmentRow,
} from "./cloudEnvironmentChoice";
import "./cloudEnvironmentChip.css";

/// The chip's live control for a new chat's strip: the account's environments
/// (`cloud.environment.list`), this folder's recent picks, and the chat's pick, which its Cloud send
/// names (App.tsx `sendToCloud`). The pick is the chat's own (`held`, kept with its run mode in
/// App.tsx); a composer given none keeps its own, which goes with it. Undefined while `enabled` is
/// off (CLOUD_ENVIRONMENTS_ENABLED, or no new chat): nothing is read then.
/// What this page last read, so a new chat's chip draws the account's environments and the project's
/// default at once and refreshes them in place (no empty list while a read runs). One list, and one
/// default per repository, at most 50 kept; the oldest goes first.
let cachedEnvironments: readonly CloudEnvironment[] = [];
const cachedDefaults = new Map<string, string | undefined>();
function rememberDefault(repo: string, id: string | undefined) {
  cachedDefaults.delete(repo);
  cachedDefaults.set(repo, id);
  while (cachedDefaults.size > 50) cachedDefaults.delete(cachedDefaults.keys().next().value!);
}

export function useCloudEnvironmentControl(
  enabled: boolean,
  folder: string | undefined,
  repo: string | undefined,
  held?: CloudEnvironmentPick,
): CloudEnvironmentControl | undefined {
  const [environments, setEnvironmentList] = useState<readonly CloudEnvironment[]>(() => cachedEnvironments);
  const setEnvironments = useCallback(
    (next: readonly CloudEnvironment[] | ((list: readonly CloudEnvironment[]) => readonly CloudEnvironment[])) =>
      setEnvironmentList((list) => {
        cachedEnvironments = typeof next === "function" ? next(list) : next;
        return cachedEnvironments;
      }),
    [],
  );
  const [own, setOwn] = useState(AUTO_ENVIRONMENT);
  const current = held?.current ?? own;
  const setPick = held?.onPick ?? setOwn;
  const load = useCallback(() => {
    postNative<unknown>("cloud.environment.list").then(
      (list) => {
        if (Array.isArray(list)) setEnvironments(list as CloudEnvironment[]);
      },
      // Signed out, Cloud off or offline: Auto and the actions still show; the list stays as it was.
      () => undefined,
    );
  }, [setEnvironments]);
  // The project's default, from the service (`cloud.environment.default`), for the repository it was read for;
  // undefined while unread or when the service keeps no per-project default (the local recents stand in).
  const [defaults, setDefaultState] = useState<{ repo: string; id: string } | undefined>(() => {
    const id = repo ? cachedDefaults.get(repo) : undefined;
    return repo && id !== undefined ? { repo, id } : undefined;
  });
  const setDefaults = useCallback((next: { repo: string; id: string } | undefined, forRepo: string) => {
    rememberDefault(forRepo, next?.id);
    setDefaultState(next);
  }, []);
  const loadDefault = useCallback(() => {
    if (!repo) return;
    postNative<unknown>("cloud.environment.default", { repo }).then(
      (reply) => {
        const id = projectDefaultFrom(reply);
        setDefaults(id === undefined ? undefined : { repo, id }, repo);
      },
      // Offline or refused: what was read before stands; a service with no such route answers that way too,
      // and never had one cached.
      () => undefined,
    );
  }, [repo, setDefaults]);
  useEffect(() => {
    if (!enabled) return;
    load();
    loadDefault();
  }, [enabled, load, loadDefault]);
  // Another repository than the one last read (the folder changed): its cached default until the read lands.
  const projectDefault = repo ? (defaults?.repo === repo ? defaults.id : cachedDefaults.get(repo)) : undefined;
  // A new chat starts on the project's default, once per chat and never over a pick made there.
  const chat = held?.chat ?? "";
  const pickedIn = useRef<string>(undefined);
  useEffect(() => {
    const next = enabled ? defaultPick(current, projectDefault, pickedIn.current === chat) : undefined;
    if (next) setPick(next);
  }, [enabled, current, projectDefault, chat, setPick]);
  if (!enabled) return undefined;
  const recent = recentEnvironments(folder, environments, undefined, projectDefault);
  const named = environments.find((environment) => environment.id === current);
  const auto = autoEnvironment(environments);
  // Remembered first, so the render the new pick causes reads this folder's new order.
  const pick = (id: string) => {
    pickedIn.current = chat;
    rememberEnvironment(folder, id);
    setPick(id);
  };
  const makeDefault = (id: string | undefined) => {
    if (!repo) return;
    const before = defaults;
    setDefaults({ repo, id: id ?? AUTO_ENVIRONMENT }, repo);
    // Refused or offline: the mark goes back to what the service has.
    postNative("cloud.environment.setDefault", { repo, environment: id ?? null }).catch(() =>
      setDefaults(before, repo),
    );
  };
  return {
    recent,
    current,
    ...(named ? { currentName: named.name } : {}),
    ...(auto ? { auto } : {}),
    onPick: pick,
    onNew: () =>
      openCloudEnvironment({
        create: { name: folderName(folder) ?? t("composer.envNewName") },
        section: "script",
        ...(repo ? { repo } : {}),
        onCreated: (environment) => {
          setEnvironments((list) => [...list.filter((kept) => kept.id !== environment.id), environment]);
          pick(environment.id);
        },
      }),
    onEdit: (id) =>
      openCloudEnvironment({
        ...(id ? { environmentId: id } : {}),
        section: id ? "overview" : "script",
        ...(repo ? { repo } : {}),
      }),
    onNewMachine: (environment) => {
      void postNative("action.run", { id: "newCloudMachine", ...(environment ? { environment } : {}) }).catch(
        () => undefined,
      );
    },
    onOpen: () => {
      load();
      loadDefault();
    },
    ...(projectDefault !== undefined ? { projectDefault, onMakeDefault: makeDefault } : {}),
  };
}

/// A new chat's Cloud environment, held per chat (App.tsx, with its run mode): Auto until picked, and
/// Auto again when `chat` changes (a chat starts here, or another new chat shows) and once a Cloud
/// send takes it, so a pick never rides into a later chat's send. `forSend` is what that send names
/// (`cloudStartEnvironment`: the start's own, else the pick; none on Auto or with the flag off).
export function useChatCloudEnvironment(chat: string): {
  pick: CloudEnvironmentPick;
  forSend(explicit: string | undefined): string | undefined;
} {
  const [held, setHeld] = useState({ chat, current: AUTO_ENVIRONMENT });
  // Another chat: back to Auto in this render, before anything reads the old chat's pick.
  const current = held.chat === chat ? held.current : AUTO_ENVIRONMENT;
  if (held.chat !== chat) setHeld({ chat, current: AUTO_ENVIRONMENT });
  // The same pick object while the chat and its pick stay: the composer takes it in its run mode
  // rows, and a new object each render drew the composer again on every pane event.
  const pick = useMemo<CloudEnvironmentPick>(
    () => ({ current, chat, onPick: (id) => setHeld({ chat, current: id }) }),
    [chat, current],
  );
  return {
    pick,
    forSend: (explicit) => {
      const environment = cloudStartEnvironment(explicit, current);
      setHeld({ chat, current: AUTO_ENVIRONMENT });
      return environment;
    },
  };
}

/// A new environment's name: the project's folder name.
function folderName(folder: string | undefined): string | undefined {
  const name = folder?.replace(/\/+$/, "").split("/").pop();
  return name || undefined;
}

/// Stable hooks for GUI automation (the start matrix's flag-on row): the chip is
/// `cloud-environment-chip` (its button: `data-menu="Environment"`), Auto `cloud-environment-auto`,
/// each environment `cloud-environment-option` with `data-environment-name`, and the actions below.
const ACTION_TEST_IDS: Partial<Record<CloudEnvironmentRow["kind"], string>> = {
  new: "cloud-environment-new",
  edit: "cloud-environment-edit",
  makeDefault: "cloud-environment-make-default",
  newMachine: "cloud-environment-new-machine",
};

/// How the drop-up draws its rows (gallery seam; `list` ships):
/// - `list`: one line per row, hairlines between the environments, their actions and New Cloud
///   machine…; no headers and no second lines (design/environment-picker.md rule 0).
/// - `gear`: the same rows, and each environment row carries its own edit gear at its end.
/// - `sections`: "Environment" and "Machine" group headers over the same rows.
export type CloudEnvironmentDropUp = "list" | "gear" | "sections";

/// The composer's Environment chip: beside the Where chip while Cloud is the pick, behind
/// CLOUD_ENVIRONMENTS_ENABLED. Leo, 2026-11-07: "you pick the cloud thing, and then you have another
/// thing, drop down, or, you know, drop up, that is, because you don't want to hide the composer. So
/// the drop up, it goes, like, it's auto by default, but then you can also say create environment."
/// Its menu always opens up, away from the box under it, whichever half of the window the composer
/// is in: the composer never sits under it (the location menus open away from the chat instead,
/// locationPopover.ts). It fits the room above, scrolling if it must, and never flips.
export function CloudEnvironmentChip({
  control,
  dropUp = "list",
  active = true,
}: {
  control: CloudEnvironmentControl;
  dropUp?: CloudEnvironmentDropUp;
  /// False while the strip keeps it closed (Cloud is not the pick): it never opens, by click or by
  /// automation (`openPicker("Environment")`).
  active?: boolean;
}) {
  const { control: box, anchor, open: popoverOpen, setOpen } = useLocationPopover();
  const open = popoverOpen && active;
  useLocationOpener(active ? "Environment" : undefined, () => setOpen(true));
  const auto = t("composer.envAuto");
  const value = cloudEnvironmentValue(control, auto);
  // The visible name ("Environment: Auto") and, for the tooltip and accessible name, one that never
  // repeats the Where chip's ("Environment: Cloud"): "Cloud environment: Auto".
  const label = t("composer.environment");
  const name = t("composer.envCloudLabel");
  const rows = cloudEnvironmentRows(control, auto);
  const environments = rows.filter((row) => row.kind === "auto" || row.kind === "environment");
  const actions = rows.filter((row) => row.kind !== "auto" && row.kind !== "environment");
  const pick = (id: string) => {
    if (id !== control.current) control.onPick(id);
  };
  const action = (row: CloudEnvironmentRow) => {
    if (row.kind === "new") control.onNew();
    else if (row.kind === "edit") control.onEdit(row.id);
    else if (row.kind === "makeDefault") control.onMakeDefault?.(row.id);
    else if (row.kind === "newMachine")
      control.onNewMachine(control.current === AUTO_ENVIRONMENT ? undefined : control.current);
  };
  const actionRow = (row: CloudEnvironmentRow, index: number) => {
    if (row.kind === "separator") return <MenuSeparator key={`separator-${index}`} />;
    const text =
      row.kind === "new"
        ? t("composer.envNew")
        : row.kind === "edit"
          ? t("composer.envEdit", { name: row.name })
          : row.kind === "makeDefault"
            ? t("composer.envMakeDefault")
            : t("composer.envNewMachine");
    return (
      <MenuItem key={row.kind} className="acpmux-menu-item" data-value={row.kind} onSelect={() => action(row)}>
        <span
          className="acpmux-location-row acpmux-cloud-env-row"
          data-action={row.kind}
          data-testid={ACTION_TEST_IDS[row.kind]}
        >
          {row.kind === "new" ? (
            <PlusIcon />
          ) : row.kind === "edit" ? (
            <GearIcon />
          ) : row.kind === "makeDefault" ? (
            <PinIcon />
          ) : (
            <ServerIcon />
          )}
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{text}</span>
          </span>
        </span>
      </MenuItem>
    );
  };
  const environmentRow = (row: CloudEnvironmentRow) => {
    if (row.kind !== "auto" && row.kind !== "environment") return null;
    const id = row.kind === "auto" ? AUTO_ENVIRONMENT : row.environment.id;
    const rowName = row.kind === "auto" ? auto : row.environment.name;
    return (
      <MenuRadioItem key={id} value={id} className="acpmux-menu-item" closeOnClick>
        <span
          className="acpmux-location-row acpmux-cloud-env-row"
          data-environment={id}
          data-environment-name={rowName}
          data-testid={row.kind === "auto" ? "cloud-environment-auto" : "cloud-environment-option"}
        >
          {row.kind === "auto" ? <SparkIcon /> : <BoxIcon />}
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{rowName}</span>
          </span>
          {row.kind === "environment" && id === control.projectDefault && (
            <span className="acpmux-cloud-env-default">{t("composer.envProjectDefault")}</span>
          )}
          {dropUp === "gear" && row.kind === "environment" && (
            <button
              type="button"
              className="acpmux-cloud-env-gear ui-ghost ui-ghost-sm"
              aria-label={t("composer.envEdit", { name: rowName })}
              onPointerDown={(event) => event.stopPropagation()}
              onClick={(event) => {
                event.stopPropagation();
                setOpen(false);
                control.onEdit(id);
              }}
            >
              <GearIcon />
            </button>
          )}
        </span>
      </MenuRadioItem>
    );
  };
  return (
    // tooltip-allow: a narrow strip shows the chip's value alone; the tooltip names it
    <span
      ref={box}
      className="acpmux-location-picker acpmux-cloud-env"
      data-kind="cloud-environment"
      data-testid="cloud-environment-chip"
      title={`${name}: ${value}`}
    >
      <Menu
        open={open}
        onOpenChange={(next) => {
          if (next && !active) return;
          setOpen(next);
          if (next) control.onOpen?.();
        }}
      >
        <MenuButton
          className="acpmux-location-button ui-ghost ui-ghost-sm"
          label={`${name}: ${value}`}
          data-menu="Environment"
        >
          <BoxIcon />
          <span className="acpmux-location-label acpmux-cloud-env-label">
            <span className="acpmux-cloud-env-prefix">{label}: </span>
            {value}
          </span>
          <span className="ui-ghost-icon" aria-hidden="true">
            <ChevronIcon />
          </span>
        </MenuButton>
        <MenuPopup
          // Always up: the composer is under the chip, so the drop-up never covers it.
          side="top"
          flip={false}
          anchor={anchor}
          align="start"
          label={name}
          className={`acpmux-menu acpmux-location-menu acpmux-cloud-env-menu acpmux-cloud-env-menu-${dropUp}`}
        >
          {dropUp === "sections" && <div className="acpmux-env-heading">{label}</div>}
          <MenuRadioGroup value={control.current} onValueChange={(next) => pick(String(next))}>
            {environments.map(environmentRow)}
          </MenuRadioGroup>
          {dropUp !== "sections" && <MenuSeparator />}
          {dropUp === "sections" && <div className="acpmux-env-heading">{t("composer.machine")}</div>}
          {actions.map((row, index) =>
            dropUp === "sections" && row.kind === "separator" ? null : actionRow(row, index),
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}

function Icon({ children }: { children: React.ReactNode }) {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon ui-ghost-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

/// An environment: a box (what the machine boots from).
function BoxIcon() {
  return (
    <Icon>
      <path d="M8 1.75 13.75 4.75v6.5L8 14.25 2.25 11.25v-6.5Z" />
      <path d="M2.25 4.75 8 7.75l5.75-3M8 7.75v6.5" />
    </Icon>
  );
}

/// Auto: a spark (made for the chat, with no questions).
function SparkIcon() {
  return (
    <Icon>
      <path d="M8 2v3M8 11v3M2 8h3M11 8h3M3.75 3.75l2 2M10.25 10.25l2 2M12.25 3.75l-2 2M5.75 10.25l-2 2" />
    </Icon>
  );
}

function PlusIcon() {
  return (
    <Icon>
      <path d="M8 3v10M3 8h10" />
    </Icon>
  );
}

/// Make default: a pin (this project keeps it).
function PinIcon() {
  return (
    <Icon>
      <path d="M6 2.25h4M7 2.25v4L4.75 9h6.5L9 6.25v-4M8 9v4.75" />
    </Icon>
  );
}

function GearIcon() {
  return (
    <Icon>
      <circle cx="8" cy="8" r="2" />
      <path d="M8 1.75v1.5M8 12.75v1.5M1.75 8h1.5M12.75 8h1.5M3.6 3.6l1.05 1.05M11.35 11.35l1.05 1.05M12.4 3.6l-1.05 1.05M4.65 11.35 3.6 12.4" />
    </Icon>
  );
}
