// "Try a starter workspace" on Home, under Set Up cmux (idea from the Strawberry "Your first week" page):
// a first run should not open on an empty Home. Two kinds of starters, both marked as examples and
// removable in one click:
// - Built-in demos: a sample repo cmux clones into a scratch folder, with a terminal, an agent and a
//   browser already laid out (a planted failing test; two agents racing on one task; a PR review).
// - Personal starters: after the person picks a repo, Chief proposes real first tasks on it
//   (fix a failing test, explain the codebase, a morning CI report).
// Opening one makes a real workspace tagged "Example" in the sidebar; Remove deletes it and its folder.
import { Button } from "../../ui/Button";
import "./styles.css";

export type StarterKind = "demo" | "personal";

export interface Starter {
  id: string;
  kind: StarterKind;
  title: string;
  detail: string;
  /** What the workspace opens with, as short chips: "Terminal", "Claude Code", "Browser". */
  panes: string[];
  /** Minutes it usually takes, shown as "~3 min". */
  minutes?: number;
  /** Already opened: the row offers Open and Remove instead of Try. */
  opened?: boolean;
}

export interface StarterWorkspacesProps {
  starters: Starter[];
  /** The repo personal starters are about; absent: only the demos, with a pick-a-repo row. */
  repo?: string;
  onTry(id: string): void;
  onRemove(id: string): void;
  onPickRepo(): void;
  onHide(): void;
}

export function StarterWorkspaces({ starters, repo, onTry, onRemove, onPickRepo, onHide }: StarterWorkspacesProps) {
  const demos = starters.filter((s) => s.kind === "demo");
  const personal = starters.filter((s) => s.kind === "personal");
  return (
    <section className="sw" aria-label="Starter workspaces">
      <div className="sw__head">
        <span className="sw__title">Try a starter workspace</span>
        <span className="sw__sub">Real workspaces you can poke at, marked Example. Remove any in one click.</span>
        <button type="button" className="sw__hide" onClick={onHide}>
          Hide
        </button>
      </div>
      {personal.length > 0 && (
        <Group label={`For ${repo ?? "your repo"}`} starters={personal} onTry={onTry} onRemove={onRemove} />
      )}
      {personal.length === 0 && (
        <div className="sw__pick">
          <span className="sw__row-text">
            <span className="sw__row-title">Starters from your own repo</span>
            <span className="sw__row-detail">Pick a repo and Chief suggests first tasks on your real code.</span>
          </span>
          <Button variant="subtle" size="sm" onClick={onPickRepo}>
            Pick a Repo…
          </Button>
        </div>
      )}
      <Group label="Demos" starters={demos} onTry={onTry} onRemove={onRemove} />
    </section>
  );
}

function Group({
  label,
  starters,
  onTry,
  onRemove,
}: {
  label: string;
  starters: Starter[];
  onTry(id: string): void;
  onRemove(id: string): void;
}) {
  return (
    <div className="sw__group">
      <span className="sw__label">{label}</span>
      <ul className="sw__grid">
        {starters.map((s) => (
          <li key={s.id} className="sw__card" data-opened={s.opened ? "" : undefined}>
            <span className="sw__row-title">
              {s.title}
              {s.opened && <span className="sw__tag">Example</span>}
            </span>
            <span className="sw__row-detail">{s.detail}</span>
            <span className="sw__chips">
              {s.panes.map((p) => (
                <span key={p} className="sw__chip">
                  {p}
                </span>
              ))}
              {s.minutes && <span className="sw__time">~{s.minutes} min</span>}
            </span>
            <span className="sw__actions">
              {s.opened ? (
                <>
                  <Button variant="ghost" size="sm" onClick={() => onRemove(s.id)}>
                    Remove
                  </Button>
                  <Button variant="subtle" size="sm" onClick={() => onTry(s.id)}>
                    Open
                  </Button>
                </>
              ) : (
                <Button variant="subtle" size="sm" onClick={() => onTry(s.id)}>
                  Try It
                </Button>
              )}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
