import React, { useEffect, useId, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { ChevronIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import { Popover } from "../../ui/Popover";
import { ProjectBadge } from "./ProjectBadge";
import { usePopoverTrigger } from "./popoverTrigger";

export type Project = { cwd: string; label: string };

/// The project pill on the composer's tray: it opens a menu above the tray with a search field over the
/// projects the user has chats in, newest first. Picking one other than the current
/// project starts a new chat there. The search field keeps focus; arrows move the
/// highlight, Enter picks and Escape closes back to the pill.
export function ProjectChooser({
  projects,
  current,
  currentLabel,
  icon,
  onPick,
  onBrowse,
}: {
  projects: Project[];
  current?: string;
  currentLabel?: string;
  icon: React.ReactNode;
  onPick(cwd: string): void;
  onBrowse?(): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  // The highlighted project, by folder: the list re-sorts as chats update while the menu is open.
  const [active, setActive] = useState<string | undefined>(undefined);
  const [addStep, setAddStep] = useState<AddProjectStep | undefined>(undefined);
  const addInput = useRef<HTMLInputElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const menuId = useId();

  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return projects.filter((project) => {
      const text = `${project.label} ${project.cwd}`.toLowerCase();
      return words.every((word) => text.includes(word));
    });
  }, [projects, query]);
  const typedPath = useMemo(() => {
    const value = query.trim();
    return value.startsWith("/") || value.startsWith("~/") ? value : undefined;
  }, [query]);
  const selected = Math.max(
    0,
    shown.findIndex((project) => project.cwd === active),
  );

  const show = () => {
    setQuery("");
    setActive(current);
    setAddStep(undefined);
    setOpen(true);
  };
  const close = (refocus: boolean) => {
    setOpen(false);
    setAddStep(undefined);
    if (refocus) trigger.current?.focus();
  };
  const press = usePopoverTrigger(open, (next) => (next ? show() : close(true)), show);
  const pick = (project: Project | undefined) => {
    const cwd = project?.cwd ?? typedPath;
    if (!cwd) return;
    // A new chat takes the focus to its prompt (Composer); the current project returns to the pill.
    const starts = cwd !== current;
    close(!starts);
    if (starts) onPick(cwd);
  };

  useEffect(() => {
    if (!open) return;
    if (addStep) addInput.current?.focus();
    else search.current?.focus();
    const blur = () => setOpen(false);
    window.addEventListener("blur", blur);
    return () => window.removeEventListener("blur", blur);
  }, [open, addStep]);

  const keyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close(true);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (shown.length > 0)
        setActive(shown[(selected + (event.key === "ArrowDown" ? 1 : -1) + shown.length) % shown.length]!.cwd);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(shown[selected]);
    }
  };

  return (
    <span className="acpmux-picker acpmux-project">
      <button
        ref={trigger}
        type="button"
        className="acpmux-context-chip acpmux-project-button"
        aria-label={t("project.label")}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        title={current ? `${t("project.label")}: ${current}` : undefined}
        {...press}
      >
        {icon}
        <span>{currentLabel ?? t("project.choose")}</span>
        <ChevronIcon />
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => (next ? show() : close(true))}
        anchor={open ? trigger.current : null}
        label={t("project.label")}
        className="acpmux-menu acpmux-project-menu"
        side="top"
        initialFocus={search}
        finalFocus={false}
      >
        {addStep ? (
          <AddProjectPanel
            ref={addInput}
            projects={projects}
            step={addStep}
            onStep={setAddStep}
            onPick={(cwd) => {
              close(false);
              onPick(cwd);
            }}
            onBrowse={() => {
              close(false);
              onBrowse?.();
            }}
            onCancel={() => {
              if (addStep === "environment") close(true);
              else if (addStep === "source") setAddStep("environment");
              else setAddStep("source");
            }}
          />
        ) : <div>
          <div className="acpmux-project-search">
            <SearchIcon />
            <input
              ref={search}
              type="text"
              // A combobox that owns the project list: the role carries aria-expanded and aria-controls.
              // oxlint-disable-next-line jsx-a11y/no-redundant-roles
              role="combobox"
              aria-label={t("project.search")}
              aria-expanded="true"
              aria-controls={menuId}
              aria-autocomplete="list"
              aria-activedescendant={shown.length > 0 ? `${menuId}-${selected}` : undefined}
              placeholder={t("project.search")}
              value={query}
              spellCheck={false}
              autoComplete="off"
              onChange={(event) => {
                setQuery(event.target.value);
                setActive(undefined);
              }}
              onKeyDown={keyDown}
            />
          </div>
          <div
            id={menuId}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="listbox"
            aria-label={t("project.label")}
          >
            {shown.map((project, index) => (
              <div
                key={project.cwd}
                id={`${menuId}-${index}`}
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                role="option"
                tabIndex={-1}
                aria-selected={index === selected}
                aria-checked={project.cwd === current}
                aria-label={`${project.label}, ${project.cwd}`}
                className={`acpmux-menu-item${index === selected ? " acpmux-menu-active" : ""}`}
                title={project.cwd}
                onPointerMove={() => setActive(project.cwd)}
                onMouseDown={(event) => {
                  event.preventDefault();
                  pick(project);
                }}
              >
                <ProjectBadge project={project} />
                <span className="acpmux-menu-text">
                  <span className="acpmux-menu-label">{project.label}</span>
                  <span className="acpmux-menu-description" data-path={project.cwd} />
                </span>
                <span className="acpmux-project-check" aria-hidden="true">
                  {project.cwd === current ? "✓" : ""}
                </span>
              </div>
            ))}
            {shown.length === 0 &&
              (typedPath ? (
                <button
                  type="button"
                  className="acpmux-menu-item acpmux-menu-active"
                  onMouseDown={(event) => {
                    event.preventDefault();
                    pick(undefined);
                  }}
                >
                  {icon}
                  <span className="acpmux-menu-label">{t("project.usePath", { path: typedPath })}</span>
                </button>
              ) : (
                <div className="acpmux-project-empty">{t("project.none")}</div>
              ))}
          </div>
          {onBrowse && (
            <button
              type="button"
              className="acpmux-project-browse"
              onMouseDown={(event) => {
                event.preventDefault();
                setQuery("");
                setAddStep("environment");
              }}
            >
              Add project
            </button>
          )}
        </div>
        }
      </Popover>
    </span>
  );
}

type AddProjectStep = "environment" | "source" | "directory";
type AddProjectChoice = { id: string; label: string; description: string; disabled?: boolean };

const ADD_PROJECT_ENVIRONMENTS: AddProjectChoice[] = [
  { id: "local", label: "This device", description: "Use folders on this Mac" },
  { id: "big-red", label: "big-red", description: "Use the shared development machine" },
];
const ADD_PROJECT_SOURCES: AddProjectChoice[] = [
  { id: "new", label: "New project", description: "Create a project from a folder" },
  { id: "folder", label: "Local folder", description: "Choose a folder already on the device" },
  { id: "git", label: "Git URL", description: "Clone a repository from a URL" },
  { id: "github", label: "GitHub repo", description: "Setup Required", disabled: true },
  { id: "other", label: "Other sources", description: "Setup Required", disabled: true },
];

const AddProjectPanel = React.forwardRef<HTMLInputElement, {
  projects: Project[];
  step: AddProjectStep;
  onStep(step: AddProjectStep): void;
  onPick(cwd: string): void;
  onBrowse(): void;
  onCancel(): void;
}>(function AddProjectPanel({ projects, step, onStep, onPick, onBrowse, onCancel }, inputRef) {
  const [query, setQuery] = useState("");
  const choices: AddProjectChoice[] =
    step === "environment"
      ? ADD_PROJECT_ENVIRONMENTS
      : step === "source"
        ? ADD_PROJECT_SOURCES
        : projects.map((project) => ({ id: project.cwd, label: project.label, description: project.cwd }));
  const suggestions = choices
    .filter((choice) => !choice.disabled)
    .filter((choice) => `${choice.label} ${choice.description}`.toLowerCase().includes(query.trim().toLowerCase()))
    .map((choice) => choice.id);
  const title = step === "environment" ? "Environment" : step === "source" ? "Add project" : "Choose a folder";
  const placeholder = step === "directory" ? "Search folders" : `Search ${title.toLowerCase()}`;
  return (
    <div className="acpmux-add-project" data-add-project-step={step}>
      <div className="acpmux-add-project-title">{title}</div>
      <Combobox
        suggestions={suggestions}
        onQuery={setQuery}
        onSubmit={(id) => {
          const choice = choices.find((item) => item.id === id);
          if (!choice || choice.disabled) return;
          setQuery("");
          if (step === "environment") onStep("source");
          else if (step === "source") onStep("directory");
          else onPick(id);
        }}
        onCancel={onCancel}
        label={title}
        placeholder={placeholder}
        inputClassName="acpmux-add-project-input"
        listClassName="acpmux-add-project-list"
        itemClassName="acpmux-add-project-item"
        inputRef={inputRef}
        renderItem={(id) => {
          const choice = choices.find((item) => item.id === id)!;
          return (
            <span className="acpmux-add-project-row">
              <span className="acpmux-add-project-icon" aria-hidden="true">{step === "directory" ? "⌂" : "•"}</span>
              <span className="acpmux-menu-text">
                <span className="acpmux-menu-label">{choice.label}</span>
                <span className="acpmux-menu-description">{choice.description}</span>
              </span>
            </span>
          );
        }}
        inline
      />
      {step === "directory" && (
        <button type="button" className="acpmux-add-project-finder" onClick={onBrowse}>
          Open in Finder
        </button>
      )}
      <div className="acpmux-add-project-footer" aria-label="Keyboard shortcuts">
        <span>↑↓ Navigate</span><span>↵ Select</span><span>← Back</span><span>Esc Close</span>
      </div>
    </div>
  );
});

function SearchIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="7" cy="7" r="4.25" />
      <path d="m10.25 10.25 3 3" />
    </svg>
  );
}
