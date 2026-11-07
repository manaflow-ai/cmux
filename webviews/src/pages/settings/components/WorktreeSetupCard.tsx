// Settings > Agents > Worktree Setup (design/worktree-setup.md): a project's worktree recipe, the
// setup, run and teardown scripts and the files a new worktree copies from the main checkout. The
// repository's own files (`.worktreeinclude`, `.cmux/worktree.toml`) say one recipe; this card
// edits the project's saved one over it (`project.update` field `worktree`): a saved script wins,
// a saved empty script turns the repository's off, saved file lines come after the repository's.
// Each field shows what the repository says under it. The card reads when it mounts and when the
// project changes; it does not poll.
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { savedRecipe, type ResolvedWorktreeRecipe, type WorktreeRecipe } from "../../../worktreeRecipe";
import { useStore } from "../context";
import { Select } from "../editors/Select";
import type { WorktreeProject } from "../store";
import { t } from "../strings";

type Command = "setup" | "run" | "teardown";
const COMMANDS: { key: Command; label: string; help: string; placeholder: string }[] = [
  {
    key: "setup",
    label: "settingsPage.worktreeSetup.setup",
    help: "settingsPage.worktreeSetup.setupHelp",
    placeholder: "bun install",
  },
  {
    key: "run",
    label: "settingsPage.worktreeSetup.run",
    help: "settingsPage.worktreeSetup.runHelp",
    placeholder: "bun run dev --port $CMUX_PORT",
  },
  {
    key: "teardown",
    label: "settingsPage.worktreeSetup.teardown",
    help: "settingsPage.worktreeSetup.teardownHelp",
    placeholder: "",
  },
];

/** The first line of a script, for the one-line note under its field. */
function firstLine(script: string): string {
  const lines = script.trim().split(/\r?\n/);
  return lines.length > 1 ? `${lines[0]} …` : (lines[0] ?? "");
}

const same = (left: WorktreeRecipe | null, right: WorktreeRecipe | null) =>
  JSON.stringify(left) === JSON.stringify(right);

export function WorktreeSetupCard() {
  const store = useStore();
  const projectLabel = useId();
  const [projects, setProjects] = useState<WorktreeProject[] | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const [path, setPath] = useState<string | null>(null);
  const [recipe, setRecipe] = useState<ResolvedWorktreeRecipe | null>(null);
  const [draft, setDraft] = useState<WorktreeRecipe>({});
  const [includeText, setIncludeText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The path whose recipe read has answered (or failed): until it is the selected one, the fields
  // show another project's draft, so nothing can be edited or saved.
  const [loaded, setLoaded] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    void store.worktreeProjects().then((result) => {
      if (!live) return;
      setProjects(result.projects);
      setUnavailable(result.unavailable);
      if (!result.unavailable) setError(result.error);
      setPath((current) => current ?? result.projects[0]?.path ?? null);
    });
    return () => {
      live = false;
    };
  }, [store]);

  const project = projects?.find((row) => row.path === path);
  // The project's saved recipe from the list: the fallback when the recipe read fails.
  const listed = useRef<WorktreeRecipe | undefined>(undefined);
  listed.current = project?.saved;
  // Only the latest read lands (a quick project switch answers out of order).
  const reads = useRef(0);
  const load = useCallback(
    async (folder: string) => {
      const read = ++reads.current;
      const result = await store.worktreeRecipe(folder);
      if (read !== reads.current) return;
      const saved = result.recipe?.saved ?? listed.current ?? {};
      setRecipe(result.recipe);
      setDraft(saved);
      setIncludeText((saved.include ?? []).join("\n"));
      setError(result.error);
      setLoaded(folder);
    },
    [store],
  );
  useEffect(() => {
    if (path) void load(path);
    return () => {
      reads.current += 1;
    };
  }, [path, load]);

  const edited = useMemo(() => savedRecipe({ ...draft, include: includeText.split(/\r?\n/) }), [draft, includeText]);
  const stored = savedRecipe(recipe?.saved ?? project?.saved ?? {});
  const dirty = !same(edited, stored);
  const locked = busy || !path || loaded !== path;

  const save = async (worktree: WorktreeRecipe | null) => {
    if (!path) return;
    setBusy(true);
    try {
      const failure = await store.saveWorktreeRecipe(path, worktree);
      if (failure) {
        setError(failure);
        return;
      }
      setProjects((rows) =>
        (rows ?? []).map((row) => {
          if (row.path !== path) return row;
          const { saved: _old, ...rest } = row;
          return worktree ? { ...rest, saved: worktree } : rest;
        }),
      );
      await load(path);
    } finally {
      setBusy(false);
    }
  };

  const repository = recipe?.repository ?? {};
  return (
    <section className="group" data-card="worktreeSetup">
      <h3 className="group-title">{t("settingsPage.worktreeSetup.title")}</h3>
      <p className="row-help">{t("settingsPage.worktreeSetup.help")}</p>
      {unavailable ? (
        <div className="row" data-worktree-unavailable="">
          <span className="row-help">{t("settingsPage.worktreeSetup.unavailable")}</span>
        </div>
      ) : projects && projects.length === 0 ? (
        <div className="row" data-worktree-empty="">
          <span className="row-help">{t("settingsPage.worktreeSetup.empty")}</span>
        </div>
      ) : (
        <>
          <div className="rows">
            <div className="row">
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title" id={projectLabel}>
                    {t("settingsPage.worktreeSetup.project")}
                  </div>
                  {project && <div className="row-help font-mono">{project.path}</div>}
                </div>
                <div className="row-control">
                  <Select
                    value={path ?? ""}
                    disabled={!projects || projects.length < 2 || busy}
                    labelId={projectLabel}
                    onChange={(value) => setPath(value)}
                  >
                    {(projects ?? []).map((row) => (
                      <option key={row.path} value={row.path}>
                        {row.name}
                      </option>
                    ))}
                  </Select>
                </div>
              </div>
            </div>
          </div>
          <div className="worktree-setup-form" data-worktree-form="">
            {COMMANDS.map((command) => (
              <CommandField
                key={command.key}
                id={command.key}
                label={t(command.label)}
                help={t(command.help)}
                placeholder={repository[command.key] ?? command.placeholder}
                repository={repository[command.key]}
                value={draft[command.key]}
                disabled={locked}
                onChange={(value) =>
                  setDraft((current) => {
                    const next = { ...current };
                    if (value === undefined) delete next[command.key];
                    else next[command.key] = value;
                    return next;
                  })
                }
              />
            ))}
            <label className="worktree-setup-field" data-worktree-field="include">
              <span className="row-title">{t("settingsPage.worktreeSetup.include")}</span>
              <span className="row-help">{t("settingsPage.worktreeSetup.includeHelp")}</span>
              <textarea
                className="field font-mono"
                aria-label={t("settingsPage.worktreeSetup.include")}
                rows={3}
                spellCheck={false}
                placeholder=".env"
                disabled={locked}
                value={includeText}
                onChange={(event) => setIncludeText(event.target.value)}
              />
              <span className="row-help" data-worktree-repository="include">
                {repository.include && repository.include.length > 0
                  ? t("settingsPage.worktreeSetup.repository", repository.include.join(", "))
                  : t("settingsPage.worktreeSetup.repositoryNone")}
              </span>
            </label>
          </div>
          <div className="host-footer worktree-setup-footer">
            <span className="row-help worktree-setup-files">
              {recipe && recipe.files.length > 0 ? t("settingsPage.worktreeSetup.files", recipe.files.join(", ")) : ""}
            </span>
            {stored && (
              <Button
                type="button"
                className="button"
                data-worktree="clear"
                disabled={locked}
                onClick={() => void save(null)}
              >
                {t("settingsPage.worktreeSetup.clear")}
              </Button>
            )}
            <Button
              type="button"
              className="button"
              data-worktree="revert"
              disabled={locked || !dirty}
              onClick={() => {
                const saved = recipe?.saved ?? project?.saved ?? {};
                setDraft(saved);
                setIncludeText((saved.include ?? []).join("\n"));
              }}
            >
              {t("settingsPage.worktreeSetup.revert")}
            </Button>
            <Button
              type="button"
              className="button"
              data-worktree="save"
              variant="solid"
              disabled={locked || !dirty}
              onClick={() => void save(edited)}
            >
              {t("settingsPage.worktreeSetup.save")}
            </Button>
          </div>
        </>
      )}
      {(error || recipe?.problems?.length) && (
        <div className="row-error" data-worktree-error="" role="alert">
          {[error, ...(recipe?.problems ?? [])].filter(Boolean).join(" ")}
        </div>
      )}
    </section>
  );
}

/** One script: the project's own (undefined: the repository's runs), with what the repository
 *  says under it and Use Repository's when the project's replaces it or turns it off. */
function CommandField({
  id,
  label,
  help,
  placeholder,
  repository,
  value,
  disabled,
  onChange,
}: {
  id: Command;
  label: string;
  help: string;
  placeholder: string;
  repository: string | undefined;
  value: string | undefined;
  disabled: boolean;
  onChange(value: string | undefined): void;
}) {
  const note = repository
    ? t("settingsPage.worktreeSetup.repository", firstLine(repository))
    : t("settingsPage.worktreeSetup.repositoryNone");
  const state = repository && value === "" ? "off" : repository && value !== undefined ? "replaced" : "repository";
  return (
    <label className="worktree-setup-field" data-worktree-field={id} data-source={state}>
      <span className="row-title">{label}</span>
      <span className="row-help">{help}</span>
      <textarea
        className="field font-mono"
        aria-label={label}
        rows={2}
        spellCheck={false}
        placeholder={placeholder}
        disabled={disabled}
        value={value ?? ""}
        onChange={(event) => onChange(event.target.value)}
      />
      <span className="row-help worktree-setup-source" data-worktree-repository={id}>
        <span>
          {note}
          {state === "off"
            ? ` ${t("settingsPage.worktreeSetup.off")}`
            : state === "replaced"
              ? ` ${t("settingsPage.worktreeSetup.replaces")}`
              : ""}
        </span>
        {state !== "repository" && (
          <Button
            type="button"
            className="button worktree-setup-use"
            size="sm"
            data-worktree-use={id}
            disabled={disabled}
            onClick={(event) => {
              // The button sits in the field's label: keep the click off the textarea.
              event.preventDefault();
              onChange(undefined);
            }}
          >
            {t("settingsPage.worktreeSetup.useRepository")}
          </Button>
        )}
      </span>
    </label>
  );
}
