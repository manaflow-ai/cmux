import * as React from "react";
import { createRoot } from "react-dom/client";
import { createIssueInboxLabelResolver } from "../issue-inbox/labels";
import {
  openConfig,
  openExternal,
  refreshIssues,
  spawnWorkspace,
  startIssueInboxStore,
  useIssueInboxStore,
} from "../issue-inbox/bridge";
import type {
  IssueInboxItem,
  IssueInboxSnapshot,
  IssueProvider,
  IssueSpawnAgent,
  IssueStatus,
} from "../issue-inbox/types";
import { installWebviewStyles } from "./installWebviewStyles";
import issueInboxStyles from "../issue-inbox/styles.css?inline";

type StatusFilter = IssueStatus | "all";
type ProviderFilter = IssueProvider | "all";

const rowLimit = 500;
const agentStorageKey = "cmux.issueInbox.agent";
const agents: IssueSpawnAgent[] = ["claude", "codex", "none"];

export function mountIssueInboxSurface(rootElement: HTMLElement): void {
  installWebviewStyles("issue-inbox", issueInboxStyles);
  document.documentElement.dataset.cmuxWebviewKind = "issue-inbox";
  document.body.dataset.cmuxWebviewKind = "issue-inbox";
  startIssueInboxStore();
  createRoot(rootElement).render(<IssueInboxApp />);
}

function IssueInboxApp() {
  const { snapshot, loading, refreshing, error } = useIssueInboxStore();
  const labels = createIssueInboxLabelResolver(snapshot?.labels);
  const [query, setQuery] = useStateText("");
  const [status, setStatus] = useStateText<StatusFilter>("open");
  const [provider, setProvider] = useStateText<ProviderFilter>("all");
  const [agent, setAgent] = useAgentChoice();

  if (loading && !snapshot) {
    return (
      <main className="issue-shell">
        <div className="issue-loading">{labels("loading")}</div>
      </main>
    );
  }

  const filtered = filterItems(snapshot, query, status, provider);
  const visible = filtered.slice(0, rowLimit);
  const hasConfig = Boolean(snapshot?.config.file_exists && snapshot.config.sources.length > 0);

  return (
    <main className="issue-shell">
      <header className="issue-header">
        <div className="issue-title-group">
          <h1>{labels("title")}</h1>
          {refreshing ? <span className="issue-refreshing">{labels("refreshing")}</span> : null}
        </div>
        <button className="issue-button" type="button" onClick={() => void refreshIssues()}>
          {labels("refresh")}
        </button>
      </header>

      <section className="issue-toolbar" aria-label={labels("title")}>
        <input
          className="issue-search"
          value={query}
          placeholder={labels("searchPlaceholder")}
          aria-label={labels("searchPlaceholder")}
          onChange={(event) => setQuery(event.currentTarget.value)}
        />
        <SegmentedFilter
          value={status}
          options={[
            ["open", labels("statusOpen")],
            ["closed", labels("statusClosed")],
            ["all", labels("statusAll")],
          ]}
          onChange={setStatus}
        />
        <SegmentedFilter
          value={provider}
          options={[
            ["all", labels("providerAll")],
            ["github", labels("providerGithub")],
            ["linear", labels("providerLinear")],
          ]}
          onChange={setProvider}
        />
      </section>

      {error ? <div className="issue-error-banner">{error}</div> : null}
      <SourceErrorBanners snapshot={snapshot} />

      {!hasConfig ? (
        <ConfigEmptyState snapshot={snapshot} />
      ) : visible.length === 0 ? (
        <div className="issue-empty-results">{labels("emptyResults")}</div>
      ) : (
        <section className="issue-list" aria-label={labels("title")}>
          {visible.map((item) => (
            <IssueRow
              key={item.id}
              item={item}
              snapshot={snapshot}
              agent={agent}
              onAgentChange={setAgent}
            />
          ))}
          <footer className="issue-footer">
            {labels("showing")
              .replace("{shown}", String(visible.length))
              .replace("{total}", String(filtered.length))}
          </footer>
        </section>
      )}
    </main>
  );
}

function IssueRow({
  item,
  snapshot,
  agent,
  onAgentChange,
}: {
  item: IssueInboxItem;
  snapshot: IssueInboxSnapshot | null;
  agent: IssueSpawnAgent | null;
  onAgentChange: (agent: IssueSpawnAgent) => void;
}) {
  const labels = createIssueInboxLabelResolver(snapshot?.labels);
  const [busy, setBusy] = useStateText(false);
  const source = snapshot?.config.sources.find((entry) => entry.id === sourceID(item));
  const selectedAgent = agent ?? source?.spawn?.default_agent ?? "none";

  async function spawn(event: React.MouseEvent<HTMLButtonElement>) {
    event.stopPropagation();
    setBusy(true);
    try {
      await spawnWorkspace(item.id, selectedAgent);
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className="issue-row">
      <button
        className="issue-row-open"
        type="button"
        onClick={() => void openExternal(item.source_url)}
        aria-label={`${labels("openInBrowser")}: ${item.number} ${item.title}`}
      >
        <div className={`issue-provider issue-provider-${item.provider}`} aria-hidden="true">
          {item.provider === "github" ? "G" : "L"}
        </div>
        <div className="issue-main">
          <div className="issue-row-heading">
            <span className="issue-number">{item.number}</span>
            <span className="issue-row-title">{item.title}</span>
          </div>
          <div className="issue-meta">
            <span>{source?.display_name ?? item.repo_or_project}</span>
            <span>{labels("updated")} {relativeTime(item.updated_at)}</span>
            {item.assignees.map((assignee) => (
              <span key={assignee}>@{assignee}</span>
            ))}
          </div>
          {item.labels.length > 0 ? (
            <div className="issue-labels">
              {item.labels.map((label) => (
                <span className="issue-label" key={label}>
                  {label}
                </span>
              ))}
            </div>
          ) : null}
        </div>
      </button>
      <div className="issue-actions">
        <select
          className="issue-agent-select"
          value={selectedAgent}
          onChange={(event) => onAgentChange(event.currentTarget.value as IssueSpawnAgent)}
          onClick={(event) => event.stopPropagation()}
          onKeyDown={(event) => event.stopPropagation()}
          aria-label={labels("spawn")}
        >
          {agents.map((entry) => (
            <option key={entry} value={entry}>
              {agentLabel(labels, entry)}
            </option>
          ))}
        </select>
        <button
          className="issue-button issue-spawn-button"
          type="button"
          disabled={busy}
          onClick={spawn}
          onKeyDown={(event) => event.stopPropagation()}
        >
          {labels("spawn")}
        </button>
      </div>
    </article>
  );
}

function SourceErrorBanners({ snapshot }: { snapshot: IssueInboxSnapshot | null }) {
  const labels = createIssueInboxLabelResolver(snapshot?.labels);
  const errors = Object.entries(snapshot?.source_errors ?? {});
  if (errors.length === 0) {
    return null;
  }
  return (
    <section className="issue-source-errors">
      {errors.map(([source, detail]) => {
        const displayName =
          snapshot?.config.sources.find((entry) => entry.id === source)?.display_name ?? source;
        return (
          <div className="issue-source-error" key={source}>
            <div>
              <strong>{displayName}</strong>
              <span>{labels("sourceFailed")} {labels("staleRows")}</span>
            </div>
            <details>
              <summary>{labels("details")}</summary>
              <pre>{detail}</pre>
            </details>
          </div>
        );
      })}
    </section>
  );
}

function ConfigEmptyState({ snapshot }: { snapshot: IssueInboxSnapshot | null }) {
  const labels = createIssueInboxLabelResolver(snapshot?.labels);
  const path = snapshot?.config.path ?? "~/.config/cmux/issue-inbox.json";
  return (
    <section className="issue-empty-config">
      <h2>{labels("emptyTitle")}</h2>
      <p>{labels("emptyBody")}</p>
      <code>{path}</code>
      <div className="issue-example">
        <span>{labels("emptyExample")}</span>
        <pre>{`{
  "sources": [
    {
      "type": "github",
      "repo": "manaflow-ai/cmux",
      "projectRoot": "~/fun/cmuxterm-hq/repo",
      "spawn": {
        "devServerCommand": "cd web && bun dev",
        "webURL": "http://localhost:3000",
        "defaultAgent": "claude"
      }
    }
  ],
  "autoRefreshSeconds": 0
}`}</pre>
      </div>
      <button className="issue-button" type="button" onClick={() => void openConfig()}>
        {labels("openConfig")}
      </button>
    </section>
  );
}

function SegmentedFilter<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: Array<[T, string]>;
  onChange: (value: T) => void;
}) {
  return (
    <div className="issue-segmented">
      {options.map(([option, label]) => (
        <button
          className={option === value ? "selected" : ""}
          type="button"
          key={option}
          onClick={() => onChange(option)}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

function filterItems(
  snapshot: IssueInboxSnapshot | null,
  query: string,
  status: StatusFilter,
  provider: ProviderFilter,
): IssueInboxItem[] {
  const normalizedQuery = query.trim().toLowerCase();
  return (snapshot?.items ?? []).filter((item) => {
    if (status !== "all" && item.status !== status) {
      return false;
    }
    if (provider !== "all" && item.provider !== provider) {
      return false;
    }
    if (!normalizedQuery) {
      return true;
    }
    const searchable = [
      item.title,
      item.number,
      item.repo_or_project,
      ...item.labels,
      ...item.assignees,
    ].join(" ").toLowerCase();
    return searchable.includes(normalizedQuery);
  });
}

function useStateText<T>(initialValue: T): [T, (value: T) => void] {
  return React.useState(initialValue);
}

function useAgentChoice(): [IssueSpawnAgent | null, (agent: IssueSpawnAgent) => void] {
  const [agent, setAgentState] = React.useState<IssueSpawnAgent | null>(() => {
    const saved = window.localStorage.getItem(agentStorageKey);
    return agents.includes(saved as IssueSpawnAgent) ? (saved as IssueSpawnAgent) : null;
  });
  return [
    agent,
    (next) => {
      setAgentState(next);
      window.localStorage.setItem(agentStorageKey, next);
    },
  ];
}

function agentLabel(labels: ReturnType<typeof createIssueInboxLabelResolver>, agent: IssueSpawnAgent): string {
  switch (agent) {
    case "claude":
      return labels("agentClaude");
    case "codex":
      return labels("agentCodex");
    case "none":
      return labels("agentShell");
  }
}

function sourceID(item: IssueInboxItem): string {
  return `${item.provider}:${item.repo_or_project}`;
}

function relativeTime(value: string): string {
  const date = Date.parse(value);
  if (Number.isNaN(date)) {
    return value;
  }
  const deltaSeconds = Math.round((date - Date.now()) / 1000);
  const divisions: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["year", 31_536_000],
    ["month", 2_592_000],
    ["week", 604_800],
    ["day", 86_400],
    ["hour", 3_600],
    ["minute", 60],
  ];
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  for (const [unit, seconds] of divisions) {
    if (Math.abs(deltaSeconds) >= seconds) {
      return formatter.format(Math.round(deltaSeconds / seconds), unit);
    }
  }
  return formatter.format(deltaSeconds, "second");
}
