import { useCallback, useEffect, useMemo, useState } from "react";
import type { PageClient } from "../shared/pageClient";
import {
  SkillsOps,
  type DirectoryEntry,
  type DirectoryResult,
  type Harness,
  type SkillKind,
} from "./types";

const harnesses: Harness[] = ["claude", "codex", "pi", "opencode"];
const labels: Record<Harness, string> = {
  claude: "Claude",
  codex: "Codex",
  pi: "Pi",
  opencode: "OpenCode",
};

export function SkillsPage({
  client,
  initialEntries,
}: {
  client: PageClient | null;
  initialEntries?: DirectoryEntry[];
}) {
  const [entries, setEntries] = useState<DirectoryEntry[]>(
    initialEntries ?? [],
  );
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<SkillKind | "all">("all");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!client) return;
    try {
      const result = await client.call<DirectoryResult>(SkillsOps.list, {
        query,
        ...(kind === "all" ? {} : { kind }),
      });
      setEntries(result.entries);
      setError(null);
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "The directory is unavailable.",
      );
    }
  }, [client, kind, query]);
  useEffect(() => {
    void refresh();
  }, [refresh]);

  const visible = useMemo(
    () =>
      entries.filter(
        (entry) =>
          !query ||
          `${entry.name} ${entry.description}`
            .toLowerCase()
            .includes(query.toLowerCase()),
      ),
    [entries, query],
  );
  const install = async (
    entry: DirectoryEntry,
    action: "install" | "remove",
  ) => {
    if (!client) return;
    setBusy(entry.id);
    try {
      await client.call(SkillsOps[action], {
        id: entry.id,
        targets: entry.targets,
      });
      await refresh();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The change failed.");
    } finally {
      setBusy(null);
    }
  };

  return (
    <main className="skills-page">
      <header className="skills-header">
        <div>
          <p className="skills-eyebrow">DIRECTORY</p>
          <h1>Skills, MCP servers and plugins</h1>
          <p className="skills-subtitle">
            Install once and keep every harness in sync.
          </p>
        </div>
        <div className="skills-count">{visible.length} available</div>
      </header>
      <section className="skills-toolbar" aria-label="Directory filters">
        <input
          className="skills-search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search the directory"
          aria-label="Search the directory"
        />
        <div className="skills-filters">
          {(["all", "skill", "mcp", "plugin"] as const).map((value) => (
            <button
              key={value}
              className={kind === value ? "is-active" : ""}
              onClick={() => setKind(value)}
            >
              {value === "all"
                ? "Everything"
                : value === "mcp"
                  ? "MCP servers"
                  : `${value[0].toUpperCase()}${value.slice(1)}s`}
            </button>
          ))}
        </div>
      </section>
      {error && (
        <p className="skills-error" role="alert">
          {error}
        </p>
      )}
      <section className="skills-grid" aria-label="Directory entries">
        {visible.map((entry) => (
          <EntryCard
            key={entry.id}
            entry={entry}
            busy={busy === entry.id}
            onAction={(action) => void install(entry, action)}
          />
        ))}
      </section>
      {!visible.length && (
        <div className="skills-empty">
          <strong>No matches</strong>
          <span>Try a different search or filter.</span>
        </div>
      )}
    </main>
  );
}

function EntryCard({
  entry,
  busy,
  onAction,
}: {
  entry: DirectoryEntry;
  busy: boolean;
  onAction: (action: "install" | "remove") => void;
}) {
  const installed = harnesses.filter((harness) => entry.installed[harness]);
  return (
    <article className="skills-card">
      <div className="skills-card-top">
        <span className={`skills-kind skills-kind-${entry.kind}`}>
          {entry.kind === "mcp" ? "MCP" : entry.kind}
        </span>
        <span className="skills-version">v{entry.version}</span>
      </div>
      <h2>{entry.name}</h2>
      <p>{entry.description}</p>
      <footer>
        <div className="skills-harnesses" aria-label="Supported harnesses">
          {entry.targets.map((harness) => (
            <span
              key={harness}
              className={entry.installed[harness] ? "is-installed" : ""}
              title={labels[harness]}
            >
              {labels[harness][0]}
            </span>
          ))}
        </div>
        <button
          className="skills-action"
          disabled={busy}
          onClick={() =>
            onAction(
              installed.length === entry.targets.length ? "remove" : "install",
            )
          }
        >
          {busy
            ? "Working…"
            : installed.length === entry.targets.length
              ? "Remove"
              : installed.length
                ? "Sync"
                : "Install"}
        </button>
      </footer>
    </article>
  );
}
