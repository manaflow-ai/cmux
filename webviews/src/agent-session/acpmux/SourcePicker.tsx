import { useId, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode, type RefObject } from "react";
import { UI_ANCHOR_GAP } from "../../ui/anchor";
import { Button } from "../../ui/Button";
import { Combobox } from "../../ui/Combobox";
import { focusRoute } from "../../ui/focusRoute";
import { Input } from "../../ui/Input";
import { Popover } from "../../ui/Popover";
import { MenuFolderIcon, PlusIcon, SearchIcon } from "./ComposerPickers";
import { GitHubGlyph, LockIcon } from "./GitHubIcons";
import { githubFolder, githubFolderRepo, githubFullName, matchingRepos, type GitHubPicker } from "./githubRepos";
import { useT, type StringKey } from "./i18n";
import { useProjectPaletteHost, type SourceIcon, type SourcePage } from "./projectPaletteHost";
import { githubSource, matchesSourceQuery, type CloudFolder } from "./sourcePickerModel";
import "./sourcePicker.css";

export type SourcePickerOptions = {
  github?: GitHubPicker;
  cloudFolders?: readonly CloudFolder[];
  onCloudFolder?(folder: CloudFolder): void;
  onClone?(url: string): Promise<string>;
  onEmpty?(): void;
};

/// The panel's top edge, from the top of the page: near the top like the command palette, clear of the composer
/// and its chips wherever the composer sits.
const PALETTE_TOP = 40;

const paletteAnchor = {
  getBoundingClientRect: () => new window.DOMRect(window.innerWidth / 2, PALETTE_TOP - UI_ANCHOR_GAP, 0, 0),
};

export function SourcePicker({
  open,
  options,
  current,
  currentPeer,
  onClose,
  onBrowse,
  onPick,
  onCloning,
  returnFocus,
  startPage,
}: {
  open: boolean;
  /// The page it opens on (the GitHub page, opened again after Connect to GitHub); none: the sources.
  startPage?: SourcePage;
  options: SourcePickerOptions;
  current?: string;
  currentPeer?: string;
  onClose(): void;
  onBrowse?(): void;
  onPick(folder: string): void;
  onCloning(name?: string): void;
  returnFocus: RefObject<HTMLButtonElement | null>;
}) {
  const t = useT();
  const { github, cloudFolders, onCloudFolder, onClone, onEmpty } = options;
  const [page, setPage] = useState<SourcePage>(startPage ?? "add");
  const [query, setQuery] = useState("");
  const [machine, setMachine] = useState<CloudFolder>();
  const clone = useGitURLClone(onClone, onCloning, pick);
  const typed = query.trim();
  const goTo = (next: SourcePage, text = "") => {
    if (page === "github" && github?.state.query) github.onSearch(null);
    if (page === "url") clone.reset();
    setQuery(text);
    if (next !== "folders") setMachine(undefined);
    setPage(next);
  };
  const close = () => {
    goTo("add");
    onClose();
  };
  const restoreFocus = () => {
    const trigger = returnFocus.current;
    queueMicrotask(() => {
      if (trigger?.isConnected && !trigger.closest("[inert]"))
        focusRoute(trigger, "person", "closed the project palette", { preventScroll: true });
    });
  };
  const dismiss = () => {
    close();
    restoreFocus();
  };
  const back = () => {
    if (page === "add") dismiss();
    else goTo(page === "folders" ? "machines" : "add");
  };
  function finish(run: () => void) {
    if (native.mode !== "web") {
      const closed = native.close();
      close();
      void closed.then(() => {
        restoreFocus();
        run();
      });
    } else {
      close();
      run();
    }
  }
  function pick(folder: string) {
    finish(() => onPick(folder));
  }
  const finalFocus = () => {
    const trigger = returnFocus.current;
    if (!trigger) return false;
    const { activeElement, body } = trigger.ownerDocument;
    // A pick can already have focused its destination.
    if (!activeElement || activeElement === body || activeElement.closest(".acpmux-add-project-palette"))
      return trigger;
    return false;
  };
  const edit = (next: string) => {
    setQuery(next);
    if (page === "url") clone.clearError();
    if (
      page === "github" &&
      github?.state.query &&
      !next.trim().toLowerCase().includes(github.state.query.toLowerCase())
    )
      github.onSearch(null);
  };

  const sources: ListRow[] = [];
  if (github)
    sources.push({
      id: "github",
      label: t("project.github"),
      // Its label alone; only a click the host refused says why (#46018).
      status: github.state.connectError ?? t(githubSource(github.state).status),
      icon: "github",
      onAction: () => goTo("github"),
    });
  if (cloudFolders)
    sources.push({
      id: "folders",
      label: t("source.cloudFolders"),
      status: cloudFolders[0]?.machine ?? t("source.cloudNone"),
      icon: "folder",
      onAction: () => goTo("machines"),
    });
  else {
    if (onBrowse)
      sources.push({
        id: "browse",
        label: t("source.folders"),
        status: t("source.choose"),
        icon: "folder",
        onAction: () => finish(onBrowse),
      });
    if (onClone)
      sources.push({
        id: "url",
        label: t("project.gitURL"),
        status: t("source.clone"),
        icon: "link",
        onAction: () => goTo("url"),
      });
  }
  if (onEmpty)
    sources.push({
      id: "empty",
      label: t("source.empty"),
      status: t("source.newFolder"),
      icon: "plus",
      onAction: () => finish(onEmpty),
    });
  const shownSources = sources.filter((row) => matchesSourceQuery(`${row.label} ${row.status ?? ""}`, query.trim()));

  const steps: Record<SourcePage, () => SourceStep> = {
    add: () => ({
      placeholder: t("source.search"),
      rows: shownSources,
      message: query && !shownSources.length ? t("source.noMatches") : undefined,
    }),
    github: () => ({
      placeholder: t("cloudRepository.search"),
      scope: { label: t("cloudRepository.github"), icon: "github" },
      ...(github ? githubRows(t, github, current, typed, pick) : { rows: [] }),
    }),
    machines: () => ({
      placeholder: t("source.searchMachines"),
      scope: { label: t("machineCard.label"), icon: "folder" },
      ...cloudRows(t, cloudFolders ?? [], undefined, current, currentPeer, typed, enterMachine, pickCloudFolder),
    }),
    folders: () => ({
      placeholder: t("source.searchFolders"),
      scope: { label: machine?.machine ?? t("machineCard.label"), icon: "folder" },
      ...cloudRows(t, cloudFolders ?? [], machine, current, currentPeer, typed, enterMachine, pickCloudFolder),
    }),
    url: () => ({
      placeholder: t("source.url.placeholder"),
      scope: { label: t("project.gitURL"), icon: "link" },
      rows: [],
      message: t(clone.error ?? (clone.cloning ? "source.url.cloning" : "source.url.destination")),
    }),
  };
  function enterMachine(folder: CloudFolder) {
    setMachine(folder);
    goTo("folders");
  }
  function pickCloudFolder(folder: CloudFolder) {
    finish(() => onCloudFolder?.(folder));
  }

  const step = steps[page]();
  const rows = step.action ? [...step.rows, step.action] : step.rows;
  // A native row's status: its own words or path, then a check on the current one ("main · ✓").
  const nativeStatus = (status: string | undefined, current: boolean | undefined) => {
    const parts = [status];
    if (current) parts.push("✓");
    const text = parts.filter(Boolean).join(" · ");
    return text === "" ? undefined : text;
  };
  const messageEnabled = page === "url" && Boolean(typed) && !clone.cloning;
  const native = useProjectPaletteHost(open, {
    model: {
      page,
      title: t("source.title"),
      placeholder: step.placeholder,
      scope: step.scope,
      query,
      rows: [
        ...rows.map(({ id, label, icon, status, path, current, disabled }) => ({
          id,
          label,
          icon,
          status: nativeStatus(status ?? path, current),
          enabled: !disabled,
        })),
        ...(step.message ? [{ id: "\0message", label: step.message, enabled: messageEnabled }] : []),
      ],
    },
    onEvent(event) {
      if (event.type === "closed") {
        dismiss();
        return;
      }
      if (event.type === "back") {
        goTo(event.page, event.text);
        return;
      }
      if (event.page !== page) return;
      switch (event.type) {
        case "query":
          edit(event.text);
          break;
        case "pick":
          rows.find((row) => row.id === event.id)?.onAction();
          break;
        case "submit":
          if (page === "url") clone.run(event.text);
          break;
      }
    },
  });

  if (native.mode !== "web") return null;
  const scope = step.scope && (
    <>
      {page === "folders" && <PaletteScope label={t("machineCard.label")} icon="folder" onBack={() => goTo("add")} />}
      <PaletteScope {...step.scope} onBack={back} />
    </>
  );

  return (
    <Popover
      open={open}
      onOpenChange={(next, details) => {
        if (next) return;
        if (details?.escape) back();
        else if (details?.outsidePress && page === "add" && !query) dismiss();
      }}
      anchor={open ? paletteAnchor : null}
      label={t("source.title")}
      align="center"
      flip={false}
      className="acpmux-add-project-palette ui-glass-material"
      hostGlass={false}
      initialFocus={false}
      finalFocus={finalFocus}
    >
      <div key={page}>
        {page === "url" ? (
          <GitURLField
            scope={scope}
            url={query}
            placeholder={step.placeholder}
            label={t("project.gitURL")}
            message={step.message}
            invalid={Boolean(clone.error)}
            cloning={clone.cloning}
            onQuery={edit}
            onSubmit={() => clone.run(query)}
            onBack={back}
          />
        ) : (
          <SourceList
            rows={step.rows}
            action={step.action}
            label={step.placeholder}
            scope={scope}
            message={step.message}
            onQuery={edit}
            onEscape={back}
          />
        )}
      </div>
    </Popover>
  );
}

type SourceStep = {
  placeholder: string;
  scope?: { label: string; icon: SourceIcon };
  rows: ListRow[];
  action?: ListRow;
  message?: string;
};

const sourceIcons = { github: GitHubGlyph, folder: MenuFolderIcon, link: LinkGlyph, plus: PlusIcon };

function SourceGlyph({ icon }: { icon?: SourceIcon }) {
  if (!icon) return null;
  const Glyph = sourceIcons[icon];
  return <Glyph />;
}

function PaletteScope({ label, icon, onBack }: { label: string; icon: SourceIcon; onBack(): void }) {
  const t = useT();
  return (
    <Button
      variant="subtle"
      className="acpmux-add-project-scope"
      aria-label={t("source.leaveScope", { scope: label })}
      onClick={onBack}
    >
      <span aria-hidden="true">
        <SourceGlyph icon={icon} />
      </span>
      <span className="acpmux-add-project-scope-label">{label}</span>
    </Button>
  );
}

function focusPaletteField(field: HTMLInputElement | null) {
  if (field) focusRoute(field, "person", "opened a project palette page", { preventScroll: true });
}

function backOnEmptyField(event: KeyboardEvent<HTMLInputElement>, back?: () => void) {
  if (
    !back ||
    event.key !== "Backspace" ||
    event.currentTarget.value ||
    event.nativeEvent.isComposing ||
    event.altKey ||
    event.ctrlKey ||
    event.metaKey ||
    event.shiftKey
  )
    return;
  event.preventDefault();
  event.stopPropagation();
  back();
}

type ListRow = {
  id: string;
  label: string;
  status?: string;
  icon?: SourceIcon;
  trail?: ReactNode;
  path?: string;
  current?: boolean;
  /// Shown but not pickable (a folder on a Cloud machine that cannot take a chat now); its status says why.
  disabled?: boolean;
  onAction(): void;
};

function SourceList({
  rows,
  label,
  onQuery,
  onEscape,
  scope,
  action,
  message,
}: {
  rows: readonly ListRow[];
  label: string;
  onQuery(query: string): void;
  onEscape(): void;
  scope?: ReactNode;
  action?: ListRow;
  message?: string;
}) {
  const byId = new Map([...rows, ...(action ? [action] : [])].map((row) => [row.id, row]));
  return (
    <>
      <Combobox
        label={label}
        placeholder={label}
        suggestions={[...byId.keys()]}
        pinnedSuggestions={action ? [action.id] : undefined}
        pinnedPlacement="bottom"
        rootClassName="acpmux-add-project-list"
        inputClassName="acpmux-location-search acpmux-add-project-input"
        inputRow={{
          className: "acpmux-add-project-search",
          start: scope ?? (
            <span className="acpmux-add-project-search-icon" aria-hidden="true">
              <SearchIcon />
            </span>
          ),
        }}
        inputRef={focusPaletteField}
        itemClassName="acpmux-add-project-option"
        inline
        autoHighlight="always"
        cancelOnBlur={false}
        completeOnTab={false}
        virtualRows={scope ? { estimate: 28 } : undefined}
        onQuery={onQuery}
        onCommand={(event) => backOnEmptyField(event, scope ? onEscape : undefined)}
        onCancel={onEscape}
        onSubmit={(value) => {
          const row = byId.get(value);
          if (row && !row.disabled) row.onAction();
        }}
        isItemDisabled={(id) => byId.get(id)?.disabled === true}
        isItemCurrent={(id) => byId.get(id)?.current === true}
        itemLabel={(id) => {
          const row = byId.get(id);
          return row ? [row.label, row.status].filter(Boolean).join(" · ") : id;
        }}
        renderItem={(id) => {
          const row = byId.get(id);
          if (!row) return null;
          return (
            <span
              className="acpmux-add-project-line"
              data-source={id}
              // tooltip-allow: the full path distinguishes folders with the same name.
              title={row.path}
            >
              <span className="acpmux-add-project-icon" aria-hidden="true">
                <SourceGlyph icon={row.icon} />
              </span>
              <span className="acpmux-menu-label">{row.label}</span>
              {row.status && <span className="acpmux-source-status">{row.status}</span>}
              {row.trail}
              {row.current && <span aria-hidden="true">✓</span>}
            </span>
          );
        }}
      />
      <ProjectMessage>{message}</ProjectMessage>
    </>
  );
}

function githubRows(
  t: ReturnType<typeof useT>,
  github: GitHubPicker,
  current: string | undefined,
  typed: string,
  onPick: (folder: string) => void,
) {
  const { state } = github;
  const { status, action, message: messageKey } = githubSource(state);
  const ready = state.status?.state === "ready";
  const repos: ListRow[] =
    ready && !state.error
      ? matchingRepos(state.repos ?? [], typed).map((repo) => ({
          id: repo.fullName,
          label: repo.fullName,
          icon: "github",
          status: repo.private ? t("composer.githubPrivate") : undefined,
          trail: repo.private && <LockIcon />,
          current: current === githubFolder(repo.fullName),
          onAction: () => onPick(githubFolder(repo.fullName)),
        }))
      : [];
  let message = messageKey ? t(messageKey) : undefined;
  if (state.error && action === "retry") {
    message = state.rateLimited
      ? state.retryAfter
        ? t("source.github.retryAfter", { seconds: state.retryAfter })
        : t("composer.githubRateLimited")
      : state.error;
  } else if (ready && !repos.length && typed && !state.loading) {
    // A typed owner/name the app can't see: say how to add it, not only that nothing matched.
    const name = githubFullName(typed);
    message = name ? t("source.github.notShared", { repo: name }) : t("composer.githubNoMatches");
  } else if (ready && state.missing && !state.loading) {
    message = t("source.github.notShared", { repo: state.missing });
  } else if (ready && state.status?.progress === "connected" && state.status.account && !typed) {
    // The app just finished the connect: whose repositories these are now.
    message = t("source.github.connectedAccount", { account: state.status.account });
  }
  // The repository the person is after rides along with Connect, so it is picked once GitHub hands back.
  const connectFor = () => github.onConnect(githubFullName(typed) ?? githubFolderRepo(current) ?? state.missing);

  if (ready && !state.error && typed && !repos.length && state.truncated)
    repos.push({ id: "\0search", label: t("composer.githubSearchOnReturn"), onAction: () => github.onSearch(typed) });
  const chooseMore =
    ready && !state.error && !state.connecting && !state.status?.connecting
      ? { id: "\0more", label: t("composer.githubChooseMore"), onAction: connectFor }
      : undefined;
  // One more organization: GitHub's account chooser, from the list it adds to.
  if (ready && !state.error && !typed && github.onAddAccount && !state.connecting && !state.status?.connecting)
    repos.push({
      id: "\0addAccount",
      label: t("source.github.addOrganization"),
      icon: "github",
      onAction: github.onAddAccount,
    });
  if (action) {
    const connect = action === "connect";
    repos.push({
      id: "\0connection",
      label: t(connect ? (status === "source.github.signIn" ? status : "composer.githubConnect") : "project.retry"),
      icon: "github",
      onAction: connect ? connectFor : action === "refresh" ? github.onOpen : github.onRetry,
    });
  }
  return { rows: repos, action: chooseMore, message: state.connectError ?? state.status?.message ?? message };
}

function cloudRows(
  t: ReturnType<typeof useT>,
  folders: readonly CloudFolder[],
  machine: CloudFolder | undefined,
  current: string | undefined,
  currentPeer: string | undefined,
  typed: string,
  onMachine: (folder: CloudFolder) => void,
  onPick: (folder: CloudFolder) => void,
) {
  const rows: ListRow[] = [];
  if (machine) {
    for (const folder of folders) {
      if (folder.peer !== machine.peer || !matchesSourceQuery(`${folder.label} ${folder.id}`, typed)) continue;
      rows.push({
        id: folder.id,
        label: folder.label,
        status: folder.id,
        icon: "folder",
        path: folder.id,
        current: current === folder.id && currentPeer === folder.peer,
        ...(folder.disabled ? { disabled: true, status: folder.stage ?? folder.id } : {}),
        onAction: () => onPick(folder),
      });
    }
  } else {
    const peers = new Set<string>();
    for (const folder of folders) {
      if (peers.has(folder.peer)) continue;
      peers.add(folder.peer);
      if (!matchesSourceQuery(folder.machine, typed)) continue;
      rows.push({
        id: folder.peer,
        label: folder.machine,
        status: folder.stage,
        icon: "folder",
        ...(folder.disabled ? { disabled: true } : {}),
        onAction: () => onMachine(folder),
      });
    }
  }
  return { rows, message: rows.length ? undefined : t(typed ? "source.noMatches" : "source.cloudEmpty") };
}

function useGitURLClone(
  onClone: SourcePickerOptions["onClone"],
  onCloning: (name?: string) => void,
  onPick: (folder: string) => void,
) {
  const [error, setError] = useState<StringKey>();
  const pending = useRef(false);
  const turn = useRef(0);
  const [cloning, setCloning] = useState(false);
  const onPickRef = useRef(onPick);
  // The latest pick, for a clone that finishes after a render (written after the render, never during it).
  useLayoutEffect(() => {
    onPickRef.current = onPick;
  });
  useLayoutEffect(
    () => () => {
      turn.current += 1;
    },
    [],
  );

  const run = (url: string) => {
    const typed = url.trim();
    if (!typed || !onClone || pending.current) return;
    const validation = gitURLValidation(typed);
    if (validation) {
      setError(validation);
      return;
    }
    const attempt = ++turn.current;
    pending.current = true;
    setCloning(true);
    setError(undefined);
    onCloning(
      new URL(typed).pathname
        .split("/")
        .filter(Boolean)
        .at(-1)
        ?.replace(/\.git$/i, ""),
    );
    void Promise.resolve()
      .then(() => onClone(typed))
      .then(
        (cwd) => {
          if (attempt === turn.current) onPickRef.current(cwd);
        },
        (error: unknown) => {
          if (attempt !== turn.current) return;
          switch ((error as { code?: unknown } | null)?.code) {
            case "repo.credentials":
              setError("source.url.credentials");
              break;
            case "repo.invalid_url":
              setError("source.url.invalid");
              break;
            case "repo.destination_taken":
              setError("source.url.taken");
              break;
            default:
              setError("source.url.failed");
          }
        },
      )
      .finally(() => {
        if (attempt !== turn.current) return;
        pending.current = false;
        setCloning(false);
        onCloning();
      });
  };

  return {
    run,
    error,
    cloning,
    clearError: () => setError(undefined),
    reset() {
      turn.current += 1;
      pending.current = false;
      setCloning(false);
      setError(undefined);
      onCloning();
    },
  };
}

function GitURLField({
  scope,
  url,
  placeholder,
  label,
  message,
  invalid,
  cloning,
  onQuery,
  onSubmit,
  onBack,
}: {
  scope?: ReactNode;
  url: string;
  placeholder: string;
  label: string;
  message?: string;
  invalid: boolean;
  cloning: boolean;
  onQuery(text: string): void;
  onSubmit(): void;
  onBack(): void;
}) {
  const messageId = useId();
  return (
    <>
      <div className="acpmux-add-project-search">
        {scope}
        <Input
          ref={focusPaletteField}
          className="acpmux-add-project-input acpmux-location-search"
          variant="plain"
          value={url}
          placeholder={placeholder}
          aria-label={label}
          aria-describedby={messageId}
          aria-keyshortcuts="Enter"
          aria-invalid={invalid}
          inputMode="url"
          autoCapitalize="off"
          autoComplete="off"
          spellCheck={false}
          readOnly={cloning}
          onChange={(event) => onQuery(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.nativeEvent.isComposing || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey)
              return;
            if (event.key === "Enter") {
              event.preventDefault();
              event.stopPropagation();
              onSubmit();
            } else {
              backOnEmptyField(event, onBack);
            }
          }}
        />
      </div>
      <ProjectMessage id={messageId} error={invalid}>
        {message}
      </ProjectMessage>
    </>
  );
}

function ProjectMessage({ id, children, error }: { id?: string; children?: string; error?: boolean }) {
  return (
    <output
      id={id}
      data-error={error ? "" : undefined}
      className="acpmux-add-project-message"
      // tooltip-allow: a long service response can be truncated in a narrow pane.
      title={children}
    >
      {children}
    </output>
  );
}

function gitURLValidation(url: string): StringKey | undefined {
  if (!/^https:\/\//i.test(url) || /\s/.test(url)) return "source.url.invalid";
  try {
    const parsed = new URL(url);
    if (parsed.username || parsed.password || parsed.search || parsed.hash) return "source.url.credentials";
    return parsed.pathname.split("/").filter(Boolean).length < 2 ? "source.url.invalid" : undefined;
  } catch {
    return "source.url.invalid";
  }
}

function LinkGlyph() {
  return (
    <svg
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.4"
      strokeLinecap="round"
      aria-hidden="true"
    >
      <path d="m6 10 4-4M5 7l-2 2a2.8 2.8 0 0 0 4 4l2-2m2-2 2-2a2.8 2.8 0 0 0-4-4L7 5" />
    </svg>
  );
}
