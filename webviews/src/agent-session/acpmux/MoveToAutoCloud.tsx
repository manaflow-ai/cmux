// l10n-allow-file: gallery design for "Move this to AutoCloud" (candidate looks), not shipped UI.
//
// Move this to AutoCloud: the card that shows `cmux migrate plan --json` (cmux-tui/crates/cmux-migrate,
// plan.rs) and moves it. Leo, 2026-11-24: "we ought to be able to have good migration capabilities all
// around for people of all stages any and all levels of technical sophistication and teams and
// organizations of any size and demand to move to autocloud".
//
// Picked look: `summary` (MOVE_LOOK). It fits one import card per source, and its Review list is the
// checklist, so the plan is still every row checkable (RFD 0173, "its sheet is the plan"). The other two
// stay in the gallery for comparison. Nothing renders this outside MoveToAutoCloud.gallery.tsx yet. The types below mirror the
// plan's JSON (serde's snake_case field names) and the ledger's stages (ledger.rs `Stage`), so the
// look picked here can take the CLI's output as it is. Three looks:
//   - `checklist`: one list by what moves (projects, settings, secrets, SSH hosts, imports).
//   - `sources`: one block per place the work is now (this Mac, a box over SSH, Codespaces).
//   - `summary`: one line of counts and Move; the list opens under "Review" (a small laptop, a pane).
// Each draws the same run: ready, moving (per project), moved (with undo) and failed (with Retry,
// which goes on where the ledger stopped). Headless (no app signed in) puts the CLI line where Move is.
import { useState, type ReactNode } from "react";
import { Button } from "../../ui/Button";
import { StatusGlyph } from "../../ui/StatusGlyph";
import { Switch } from "../../ui/Switch";
import { Spinner } from "./conversation/icons";
import { Icon } from "./icons/Icon";

/// plan.rs `SourceKind`.
export type MoveSourceKind =
  | "laptop"
  | "devcontainer"
  | "compose"
  | "nix"
  | "ssh-host"
  | "codespaces"
  | "gitpod"
  | "coder"
  | "daytona"
  | "other-cloud"
  | "ci"
  | "team";

/// plan.rs `CarryKind`.
export type MoveCarryKind =
  | "shell"
  | "shell-history"
  | "git-config"
  | "editor"
  | "agent-settings"
  | "agent-history"
  | "agent-login"
  | "ssh-config"
  | "dotfiles-repo";

export type MoveAgent = "claude" | "codex" | "cursor";

/// plan.rs `Plan`, as `cmux migrate plan SOURCE --json` prints it.
export type MovePlan = {
  version: number;
  source: { kind: MoveSourceKind; label: string; id: string };
  projects: MoveProject[];
  carry?: MoveCarry[];
  warnings?: string[];
  unsupported?: { what: string; why: string }[];
};

export type MoveProject = {
  key: string;
  name: string;
  repo?: {
    url?: string;
    branch?: string;
    commit?: string;
    path?: string;
    dirty_files?: number;
    unpushed_commits?: number;
  };
  machine: { env?: Record<string, string>; secret_names?: string[]; setup?: string[]; check?: string[] };
  image?: string;
  ports?: number[];
  services?: string[];
  chats?: { agent: MoveAgent; path: string }[];
  checked?: boolean;
  notes?: string[];
};

export type MoveCarry = { kind: MoveCarryKind; path: string; bytes?: number; agent?: MoveAgent; checked?: boolean };

/// ledger.rs `Stage` per project, plus `ready` (nothing started) and `moving` (this project's step now).
export type MoveStage = "ready" | "pending" | "moving" | "done" | "failed" | "undone";

export type MoveRun = {
  state: "ready" | "moving" | "moved" | "failed";
  /// Per project key: its ledger stage, and the step it is on or failed at.
  projects?: Record<string, { stage: MoveStage; step?: string; error?: string; first_chat_ms?: number }>;
  /// The ledger's namespace for undo (`cmux migrate undo SOURCE_ID --yes`).
  undoId?: string;
};

export type MoveLook = "checklist" | "sources" | "summary";

/// The look the import card uses (RFD 0173). The others are gallery comparisons only.
export const MOVE_LOOK: MoveLook = "summary";

export type MoveToAutoCloudProps = {
  look?: MoveLook;
  plans: MovePlan[];
  run?: MoveRun;
  /// No signed-in app: the CLI line replaces Move.
  headless?: boolean;
  /// The summary look starts with its list open.
  reviewOpen?: boolean;
  onMove?: () => void;
  onRetry?: () => void;
  onNotNow?: () => void;
};

const SOURCE_NAMES: Record<MoveSourceKind, string> = {
  laptop: "This computer",
  devcontainer: "Dev container",
  compose: "Docker Compose",
  nix: "Nix",
  "ssh-host": "SSH host",
  codespaces: "GitHub Codespaces",
  gitpod: "Gitpod",
  coder: "Coder",
  daytona: "Daytona",
  "other-cloud": "Cloud dev box",
  ci: "CI config",
  team: "Team",
};

const CARRY_NAMES: Record<MoveCarryKind, string> = {
  shell: "Shell",
  "shell-history": "Shell history",
  "git-config": "Git",
  editor: "Editor",
  "agent-settings": "Agent settings",
  "agent-history": "Agent chats",
  "agent-login": "Agent sign-in",
  "ssh-config": "SSH config",
  "dotfiles-repo": "Dotfiles repo",
};

const AGENT_NAMES: Record<MoveAgent, string> = { claude: "Claude Code", codex: "Codex", cursor: "Cursor" };

const IMPORTS = new Set<MoveSourceKind>(["codespaces", "gitpod", "coder", "daytona", "other-cloud"]);

function bytes(n = 0): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/// The environment a project's machine is set up from: what the source read, then the project's own
/// image, services and ports.
function envFacts(plan: MovePlan, project: MoveProject): string[] {
  const facts: string[] = [];
  if (plan.source.kind === "devcontainer" || plan.source.kind === "compose" || plan.source.kind === "nix")
    facts.push(SOURCE_NAMES[plan.source.kind]);
  if (project.image) facts.push(project.image);
  if (project.services?.length) facts.push(project.services.join(", "));
  if (project.ports?.length) facts.push(`ports ${project.ports.join(", ")}`);
  const setup = project.machine.setup?.length ?? 0;
  if (setup) facts.push(plural(setup, "setup step"));
  return facts;
}

/// What rides along besides a clone: local work a clone would miss, and chats.
function carryFacts(project: MoveProject): string[] {
  const facts: string[] = [];
  const repo = project.repo;
  if (repo && !repo.url) facts.push("no remote: the folder goes as a bundle");
  if (repo?.dirty_files) facts.push(plural(repo.dirty_files, "changed file"));
  if (repo?.unpushed_commits) facts.push(plural(repo.unpushed_commits, "unpushed commit"));
  if (project.chats?.length) {
    const agents = [...new Set(project.chats.map((c) => AGENT_NAMES[c.agent]))].join(", ");
    facts.push(`${plural(project.chats.length, "chat")} (${agents})`);
  }
  return facts;
}

function repoLine(project: MoveProject): string {
  const repo = project.repo;
  if (!repo) return "no repository";
  const where = repo.url?.replace(/^https?:\/\//, "").replace(/\.git$/, "") ?? repo.path ?? "";
  return repo.branch ? `${where} · ${repo.branch}` : where;
}

type Totals = {
  projects: MoveProject[];
  carry: MoveCarry[];
  secrets: string[];
  hosts: MovePlan[];
  imports: MovePlan[];
  warnings: string[];
  unsupported: { what: string; why: string }[];
};

function totals(plans: MovePlan[]): Totals {
  const secrets = new Set<string>();
  for (const plan of plans)
    for (const project of plan.projects) for (const name of project.machine.secret_names ?? []) secrets.add(name);
  return {
    projects: plans.flatMap((p) => p.projects),
    carry: plans.flatMap((p) => p.carry ?? []),
    secrets: [...secrets].sort(),
    hosts: plans.filter((p) => p.source.kind === "ssh-host"),
    imports: plans.filter((p) => IMPORTS.has(p.source.kind)),
    warnings: plans.flatMap((p) => p.warnings ?? []),
    unsupported: plans.flatMap((p) => p.unsupported ?? []),
  };
}

/// The checked state the person edits: projects and carry items by key, defaulting to the plan's own.
function useChecks(plans: MovePlan[]) {
  const [off, setOff] = useState<ReadonlySet<string>>(() => {
    const start = new Set<string>();
    for (const plan of plans) {
      for (const p of plan.projects) if (p.checked === false) start.add(`p:${plan.source.id}:${p.key}`);
      for (const c of plan.carry ?? []) if (c.checked === false) start.add(`c:${plan.source.id}:${c.path}`);
    }
    return start;
  });
  const on = (key: string) => !off.has(key);
  const set = (key: string, value: boolean) =>
    setOff((prev) => {
      const next = new Set(prev);
      if (value) next.delete(key);
      else next.add(key);
      return next;
    });
  return { on, set };
}

type Checks = ReturnType<typeof useChecks>;

function StageMark({ stage }: { stage: MoveStage }) {
  if (stage === "moving") return <Spinner loading size={12} className="move-ac__mark" />;
  if (stage === "pending") return <StatusGlyph name="waiting" size={12} className="move-ac__mark" label="Waiting" />;
  if (stage === "done") return <StatusGlyph name="done" size={12} className="move-ac__mark" label="Moved" />;
  if (stage === "failed") return <StatusGlyph name="error" size={12} className="move-ac__mark" label="Failed" />;
  if (stage === "undone") return <StatusGlyph name="idle" size={12} className="move-ac__mark" label="Undone" />;
  return null;
}

function stageLine(stage: MoveStage | undefined, step?: string, error?: string, ms?: number): string | null {
  if (stage === "moving") return step ?? "Moving";
  if (stage === "pending") return "Waiting";
  if (stage === "done") return ms ? `Moved · first reply in ${Math.round(ms / 1000)} s` : "Moved";
  if (stage === "failed") return error ?? `Stopped at ${step ?? "a step"}`;
  if (stage === "undone") return "Undone: its machine was deleted";
  return null;
}

function ProjectRow({
  plan,
  project,
  checks,
  run,
}: {
  plan: MovePlan;
  project: MoveProject;
  checks: Checks;
  run?: MoveRun;
}) {
  const key = `p:${plan.source.id}:${project.key}`;
  const state = run?.projects?.[project.key];
  const locked = run !== undefined && run.state !== "ready";
  const env = envFacts(plan, project);
  const carried = carryFacts(project);
  const status = stageLine(state?.stage, state?.step, state?.error, state?.first_chat_ms);
  return (
    <li className="move-ac__row" data-stage={state?.stage ?? "ready"} data-off={checks.on(key) ? undefined : ""}>
      <span className="move-ac__lead">
        {locked && state ? (
          <StageMark stage={state.stage} />
        ) : (
          <Switch
            size="sm"
            checked={checks.on(key)}
            disabled={locked}
            onCheckedChange={(value) => checks.set(key, value)}
            aria-label={`Move ${project.name}`}
          />
        )}
      </span>
      <span className="move-ac__body">
        <span className="move-ac__name">{project.name}</span>
        <span className="move-ac__mono">{repoLine(project)}</span>
        {env.length > 0 && <span className="move-ac__facts">{env.join(" · ")}</span>}
        {carried.length > 0 && <span className="move-ac__facts">{carried.join(" · ")}</span>}
        {status && (
          <span className="move-ac__status" data-stage={state?.stage}>
            {status}
          </span>
        )}
      </span>
    </li>
  );
}

function CarryRow({
  plan,
  item,
  checks,
  locked,
}: {
  plan: MovePlan;
  item: MoveCarry;
  checks: Checks;
  locked: boolean;
}) {
  const key = `c:${plan.source.id}:${item.path}`;
  const secret = item.kind === "agent-login";
  return (
    <li className="move-ac__row move-ac__row--carry" data-off={checks.on(key) ? undefined : ""}>
      <span className="move-ac__lead">
        <Switch
          size="sm"
          checked={checks.on(key)}
          disabled={locked}
          onCheckedChange={(value) => checks.set(key, value)}
          aria-label={`Carry ${item.path}`}
        />
      </span>
      <span className="move-ac__body move-ac__body--inline">
        <span className="move-ac__name">
          {CARRY_NAMES[item.kind]}
          {item.agent ? ` · ${AGENT_NAMES[item.agent]}` : ""}
        </span>
        <span className="move-ac__mono">{item.path}</span>
        <span className="move-ac__facts">{secret ? "over the secret channel" : bytes(item.bytes)}</span>
      </span>
    </li>
  );
}

function Secrets({ names }: { names: string[] }) {
  return (
    <div className="move-ac__secrets">
      <ul className="move-ac__chips" aria-label="Secrets by name">
        {names.map((name) => (
          <li key={name} className="move-ac__chip">
            <Icon name="security.lock" size={12} />
            {name}
          </li>
        ))}
      </ul>
      <p className="move-ac__note">
        Names only. Values go from this computer's keychain, never through a file or a log.
      </p>
    </div>
  );
}

function Section({ title, count, children }: { title: string; count?: number; children: ReactNode }) {
  return (
    <section className="move-ac__section">
      <h4 className="move-ac__label">
        {title}
        {count !== undefined && <span className="move-ac__count">{count}</span>}
      </h4>
      {children}
    </section>
  );
}

function Unsupported({ items }: { items: { what: string; why: string }[] }) {
  if (!items.length) return null;
  return (
    <Section title="Stays behind for now" count={items.length}>
      <ul className="move-ac__list">
        {items.map((item) => (
          <li key={item.what} className="move-ac__left">
            <span className="move-ac__name">{item.what}</span>
            <span className="move-ac__facts">{item.why}</span>
          </li>
        ))}
      </ul>
    </Section>
  );
}

/// The list by what moves: projects, then settings, secrets, SSH hosts and imports.
function ByKind({ plans, checks, run }: { plans: MovePlan[]; checks: Checks; run?: MoveRun }) {
  const all = totals(plans);
  const locked = run !== undefined && run.state !== "ready";
  const fromHosts = all.hosts.concat(all.imports);
  const local = plans.filter((p) => !fromHosts.includes(p));
  const localCount = local.reduce((n, p) => n + p.projects.length, 0);
  return (
    <>
      {localCount > 0 && (
        <Section title="Projects" count={localCount}>
          <ul className="move-ac__list">
            {local.flatMap((plan) =>
              plan.projects.map((project) => (
                <ProjectRow
                  key={`${plan.source.id}:${project.key}`}
                  plan={plan}
                  project={project}
                  checks={checks}
                  run={run}
                />
              )),
            )}
          </ul>
        </Section>
      )}
      {all.hosts.length > 0 && (
        <Section title="SSH hosts" count={all.hosts.length}>
          {all.hosts.map((plan) => (
            <div key={plan.source.id} className="move-ac__group">
              <span className="move-ac__group-head">
                <Icon name="terminal" size={14} />
                <span className="move-ac__mono">{plan.source.label}</span>
              </span>
              <ul className="move-ac__list">
                {plan.projects.map((project) => (
                  <ProjectRow key={project.key} plan={plan} project={project} checks={checks} run={run} />
                ))}
              </ul>
            </div>
          ))}
        </Section>
      )}
      {all.imports.length > 0 && (
        <Section title="Imports" count={all.imports.length}>
          {all.imports.map((plan) => (
            <div key={plan.source.id} className="move-ac__group">
              <span className="move-ac__group-head">
                <Icon name="cloud.workspace" size={14} />
                {SOURCE_NAMES[plan.source.kind]}
                <span className="move-ac__facts">{plan.source.label}</span>
              </span>
              <ul className="move-ac__list">
                {plan.projects.map((project) => (
                  <ProjectRow key={project.key} plan={plan} project={project} checks={checks} run={run} />
                ))}
              </ul>
            </div>
          ))}
        </Section>
      )}
      {all.carry.length > 0 && (
        <Section title="Settings that follow you" count={all.carry.length}>
          <ul className="move-ac__list">
            {plans.flatMap((plan) =>
              (plan.carry ?? []).map((item) => (
                <CarryRow
                  key={`${plan.source.id}:${item.path}`}
                  plan={plan}
                  item={item}
                  checks={checks}
                  locked={locked}
                />
              )),
            )}
          </ul>
        </Section>
      )}
      {all.secrets.length > 0 && (
        <Section title="Secrets" count={all.secrets.length}>
          <Secrets names={all.secrets} />
        </Section>
      )}
      <Unsupported items={all.unsupported} />
    </>
  );
}

const SOURCE_ICONS: Partial<Record<MoveSourceKind, string>> = {
  laptop: "folder",
  devcontainer: "package",
  compose: "package",
  nix: "package",
  "ssh-host": "terminal",
  team: "team",
};

/// The list by where the work is now: one block per source, its projects, settings and secrets inside.
function BySource({ plans, checks, run }: { plans: MovePlan[]; checks: Checks; run?: MoveRun }) {
  const locked = run !== undefined && run.state !== "ready";
  return (
    <>
      {plans.map((plan) => {
        const secrets = [...new Set(plan.projects.flatMap((p) => p.machine.secret_names ?? []))].sort();
        return (
          <section key={plan.source.id} className="move-ac__source">
            <header className="move-ac__source-head">
              <Icon name={SOURCE_ICONS[plan.source.kind] ?? "cloud.workspace"} size={16} />
              <span className="move-ac__name">{plan.source.label}</span>
              <span className="move-ac__facts">{SOURCE_NAMES[plan.source.kind]}</span>
            </header>
            <ul className="move-ac__list">
              {plan.projects.map((project) => (
                <ProjectRow key={project.key} plan={plan} project={project} checks={checks} run={run} />
              ))}
              {(plan.carry ?? []).map((item) => (
                <CarryRow key={item.path} plan={plan} item={item} checks={checks} locked={locked} />
              ))}
            </ul>
            {secrets.length > 0 && <Secrets names={secrets} />}
            <Unsupported items={plan.unsupported ?? []} />
          </section>
        );
      })}
    </>
  );
}

function headline(all: Totals, run?: MoveRun): string {
  const n = all.projects.length;
  if (run?.state === "moving") return `Moving ${plural(n, "project")} to AutoCloud`;
  if (run?.state === "moved") return `Moved ${plural(n, "project")} to AutoCloud`;
  if (run?.state === "failed") return "The move stopped";
  return `Move ${n === 1 ? "this" : plural(n, "project")} to AutoCloud`;
}

function counts(all: Totals): string {
  const parts = [plural(all.projects.length, "project")];
  if (all.carry.length) parts.push(plural(all.carry.length, "setting"));
  if (all.secrets.length) parts.push(plural(all.secrets.length, "secret"));
  if (all.hosts.length) parts.push(plural(all.hosts.length, "SSH host"));
  if (all.imports.length) parts.push(plural(all.imports.length, "import"));
  return parts.join(" · ");
}

function cliLine(plans: MovePlan[]): string {
  const sources = plans.map((p) =>
    p.source.kind === "ssh-host"
      ? `ssh:${p.source.label}`
      : p.source.kind === "laptop"
        ? "this-computer"
        : p.source.kind,
  );
  return sources.map((s) => `cmux migrate apply ${s} --headless`).join("\n");
}

function Footer({ plans, run, headless, onMove, onRetry, onNotNow }: MoveToAutoCloudProps) {
  const state = run?.state ?? "ready";
  if (state === "moving")
    return (
      <p className="move-ac__note">Each finished step is saved. Closing this goes on where it stopped next time.</p>
    );
  if (state === "moved")
    return (
      <div className="move-ac__foot">
        <p className="move-ac__note">
          Nothing on the source changed. Undo deletes the machines:{" "}
          <code className="move-ac__code-inline">cmux migrate undo {run?.undoId ?? "SOURCE_ID"} --yes</code>
        </p>
      </div>
    );
  if (state === "failed")
    return (
      <div className="move-ac__foot">
        <div className="move-ac__actions">
          <Button variant="solid" onClick={onRetry}>
            Retry
          </Button>
          <Button variant="ghost" onClick={onNotNow}>
            Not now
          </Button>
        </div>
        <p className="move-ac__note">Retry goes on where it stopped and makes nothing twice.</p>
      </div>
    );
  if (headless)
    return (
      <div className="move-ac__foot">
        <p className="move-ac__note">No signed-in app here. Run this where the work is:</p>
        <pre className="move-ac__code">{cliLine(plans)}</pre>
      </div>
    );
  return (
    <div className="move-ac__foot">
      <div className="move-ac__actions">
        <Button variant="solid" onClick={onMove}>
          Move to AutoCloud
        </Button>
        <Button variant="ghost" onClick={onNotNow}>
          Not now
        </Button>
      </div>
      <p className="move-ac__note">One machine per project. Nothing here changes the source.</p>
    </div>
  );
}

export function MoveToAutoCloud(props: MoveToAutoCloudProps) {
  const { look = MOVE_LOOK, plans, run, reviewOpen = false } = props;
  const checks = useChecks(plans);
  const [open, setOpen] = useState(reviewOpen);
  const all = totals(plans);
  const list =
    look === "sources" ? (
      <BySource plans={plans} checks={checks} run={run} />
    ) : (
      <ByKind plans={plans} checks={checks} run={run} />
    );
  const done = run?.projects ? Object.values(run.projects).filter((p) => p.stage === "done").length : 0;
  return (
    <article className="move-ac" data-look={look} data-state={run?.state ?? "ready"}>
      <header className="move-ac__head">
        <Icon name="cloud" size={16} className="move-ac__head-icon" />
        <span className="move-ac__title">{headline(all, run)}</span>
        {run?.state === "moving" && (
          <span className="move-ac__facts">
            {done} of {all.projects.length}
          </span>
        )}
      </header>
      {look === "summary" ? (
        <>
          {!open && all.warnings.length > 0 && (
            <ul className="move-ac__warnings">
              {all.warnings.map((w) => (
                <li key={w}>{w}</li>
              ))}
            </ul>
          )}
          <div className="move-ac__summary">
            <span className="move-ac__facts">{counts(all)}</span>
            <Button variant="ghost" size="sm" aria-expanded={open} onClick={() => setOpen(!open)}>
              {open ? "Hide" : "Review"}
            </Button>
          </div>
          {open && <div className="move-ac__review">{list}</div>}
          {!open && run?.state === "failed" && (
            <p className="move-ac__status" data-stage="failed">
              {Object.entries(run.projects ?? {})
                .filter(([, p]) => p.stage === "failed")
                .map(([key, p]) => `${key}: ${p.error ?? p.step ?? "failed"}`)
                .join(" · ")}
            </p>
          )}
        </>
      ) : (
        <>
          <p className="move-ac__lede">{counts(all)}</p>
          {all.warnings.length > 0 && (
            <ul className="move-ac__warnings">
              {all.warnings.map((w) => (
                <li key={w}>{w}</li>
              ))}
            </ul>
          )}
          <div className="move-ac__lists">{list}</div>
        </>
      )}
      <Footer {...props} />
    </article>
  );
}
