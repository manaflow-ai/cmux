"use client";

import { useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import type {
  AwesomeCmuxProject,
  AwesomeCmuxProjectKind,
} from "./awesome-cmux-projects";

type CategorySummary = {
  category: string;
  count: number;
};

type FilterKind = "all" | AwesomeCmuxProjectKind;
type SortMode = "recommended" | "stars" | "name";

const kindRank: Record<AwesomeCmuxProjectKind, number> = {
  native: 0,
  port: 1,
  adjacent: 2,
};

const categoryLabelKeys: Record<string, string> = {
  "Sidebar & Status Pills": "sidebarStatusPills",
  "Progress Bars & Estimation": "progressBarsEstimation",
  "Sidebar Logs & Activity Feed": "sidebarLogsActivityFeed",
  "Desktop Notifications": "desktopNotifications",
  "Multi-Agent Orchestration": "multiAgentOrchestration",
  "Browser Automation": "browserAutomation",
  "Worktrees & Workspace Management": "worktreesWorkspaceManagement",
  "Monitoring & Session Restore": "monitoringSessionRestore",
  "Remote & Mobile Access": "remoteMobileAccess",
  "Themes, Layouts & Config": "themesLayoutsConfig",
  "Claude Code": "claudeCode",
  Pi: "pi",
  OpenCode: "openCode",
  "Copilot & Amp": "copilotAmp",
  "Multi-Agent / Agent-Agnostic": "multiAgentAgentAgnostic",
  "Cross-Platform Ports": "crossPlatformPorts",
  "Alternatives: tmux-Based": "alternativesTmuxBased",
  "Alternatives: Other Terminals & Workspaces":
    "alternativesOtherTerminalsWorkspaces",
  "Alternatives: Forks": "alternativesForks",
  "Build & Distribution": "buildDistribution",
  "Upstream Dependencies": "upstreamDependencies",
  Archived: "archived",
};

function isPresent(value: string | undefined): value is string {
  return Boolean(value);
}

function compareProjectNames(
  collator: Intl.Collator,
  left: AwesomeCmuxProject,
  right: AwesomeCmuxProject,
) {
  return collator.compare(left.name, right.name);
}

function compareProjectStars(
  collator: Intl.Collator,
  left: AwesomeCmuxProject,
  right: AwesomeCmuxProject,
) {
  const starDelta = (right.stars ?? -1) - (left.stars ?? -1);
  if (starDelta !== 0) {
    return starDelta;
  }

  return compareProjectNames(collator, left, right);
}

function projectMatchesQuery(
  project: AwesomeCmuxProject,
  query: string,
  categoryLabels: ReadonlyMap<string, string>,
) {
  if (!query) {
    return true;
  }

  const searchableText = [
    project.name,
    project.description,
    project.agent,
    project.language,
    ...project.categories.map(
      (category) => categoryLabels.get(category) ?? category,
    ),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  return searchableText.includes(query);
}

function ProjectCard({
  project,
  kindLabel,
  categoryLabels,
  numberFormatter,
}: {
  project: AwesomeCmuxProject;
  kindLabel: string;
  categoryLabels: ReadonlyMap<string, string>;
  numberFormatter: Intl.NumberFormat;
}) {
  const t = useTranslations("community");
  const visibleCategories = project.categories.slice(0, 4);
  const hiddenCategoryCount =
    project.categories.length - visibleCategories.length;

  return (
    <a
      href={project.url}
      target="_blank"
      rel="noopener noreferrer"
      data-project-card=""
      data-project-kind={project.kind}
      className="group flex h-full flex-col rounded-lg border border-border p-4 transition-colors hover:bg-code-bg"
    >
      <div className="flex min-w-0 items-start justify-between gap-3">
        <h3 className="break-words text-[15px] font-medium leading-6">
          {project.name}
        </h3>
        <span className="shrink-0 text-xs font-medium text-muted transition-colors group-hover:text-foreground">
          {t("projectAction")} &rarr;
        </span>
      </div>

      <div className="mt-2 flex flex-wrap gap-1.5 text-xs text-muted">
        <span className="rounded-md bg-code-bg px-2 py-1">{kindLabel}</span>
        {project.agent && (
          <span className="rounded-md bg-code-bg px-2 py-1">
            {project.agent}
          </span>
        )}
        {project.language && (
          <span className="rounded-md bg-code-bg px-2 py-1">
            {project.language}
          </span>
        )}
        {typeof project.stars === "number" && (
          <span className="rounded-md bg-code-bg px-2 py-1">
            {numberFormatter.format(project.stars)} {t("starsLabel")}
          </span>
        )}
      </div>

      <p className="mt-3 flex-1 text-sm leading-6 text-muted">
        {project.description}
      </p>

      <div className="mt-4 flex flex-wrap gap-1.5">
        {visibleCategories.map((category) => (
          <span
            key={category}
            className="rounded-md border border-border px-2 py-1 text-[11px] text-muted"
          >
            {categoryLabels.get(category) ?? category}
          </span>
        ))}
        {hiddenCategoryCount > 0 && (
          <span className="rounded-md border border-border px-2 py-1 text-[11px] text-muted">
            {t("moreCategoriesLabel", {
              count: numberFormatter.format(hiddenCategoryCount),
            })}
          </span>
        )}
      </div>
    </a>
  );
}

export function CommunityProjectBrowser({
  projects,
  categorySummaries,
}: {
  projects: readonly AwesomeCmuxProject[];
  categorySummaries: readonly CategorySummary[];
}) {
  const t = useTranslations("community");
  const locale = useLocale();
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<FilterKind>("all");
  const [category, setCategory] = useState("all");
  const [agent, setAgent] = useState("all");
  const [language, setLanguage] = useState("all");
  const [sortMode, setSortMode] = useState<SortMode>("recommended");

  const numberFormatter = useMemo(() => new Intl.NumberFormat(locale), [locale]);
  const collator = useMemo(
    () => new Intl.Collator(locale, { numeric: true, sensitivity: "base" }),
    [locale],
  );

  const agentOptions = useMemo(
    () =>
      Array.from(
        new Set(projects.map((project) => project.agent).filter(isPresent)),
      ).sort((left, right) => collator.compare(left, right)),
    [collator, projects],
  );

  const languageOptions = useMemo(
    () =>
      Array.from(
        new Set(projects.map((project) => project.language).filter(isPresent)),
      ).sort((left, right) => collator.compare(left, right)),
    [collator, projects],
  );

  const categoryLabels = useMemo(() => {
    const labels = new Map<string, string>();

    for (const { category } of categorySummaries) {
      const labelKey = categoryLabelKeys[category];
      labels.set(
        category,
        labelKey ? t(`categoryLabels.${labelKey}`) : category,
      );
    }

    return labels;
  }, [categorySummaries, t]);

  const normalizedQuery = query.trim().toLowerCase();
  const filteredProjects = useMemo(
    () =>
      projects.filter((project) => {
        if (kind !== "all" && project.kind !== kind) {
          return false;
        }

        if (category !== "all" && !project.categories.includes(category)) {
          return false;
        }

        if (agent !== "all" && project.agent !== agent) {
          return false;
        }

        if (language !== "all" && project.language !== language) {
          return false;
        }

        return projectMatchesQuery(project, normalizedQuery, categoryLabels);
      }),
    [agent, category, categoryLabels, kind, language, normalizedQuery, projects],
  );

  const sortedProjects = useMemo(() => {
    return [...filteredProjects].sort((left, right) => {
      if (sortMode === "name") {
        return compareProjectNames(collator, left, right);
      }

      if (sortMode === "stars") {
        return compareProjectStars(collator, left, right);
      }

      const kindDelta = kindRank[left.kind] - kindRank[right.kind];
      if (kindDelta !== 0) {
        return kindDelta;
      }

      return compareProjectStars(collator, left, right);
    });
  }, [collator, filteredProjects, sortMode]);

  const kindLabels: Record<AwesomeCmuxProjectKind, string> = {
    native: t("nativeKindLabel"),
    port: t("portKindLabel"),
    adjacent: t("adjacentKindLabel"),
  };

  const activeFilterCount = [
    normalizedQuery,
    kind !== "all",
    category !== "all",
    agent !== "all",
    language !== "all",
    sortMode !== "recommended",
  ].filter(Boolean).length;

  function resetFilters() {
    setQuery("");
    setKind("all");
    setCategory("all");
    setAgent("all");
    setLanguage("all");
    setSortMode("recommended");
  }

  return (
    <section className="mb-12">
      <div className="mb-4 flex items-end justify-between gap-4">
        <h2 className="text-xs font-medium tracking-tight text-muted">
          {t("projectsTitle")}
        </h2>
        <span className="text-xs text-muted">
          {t("showingCount", {
            count: numberFormatter.format(sortedProjects.length),
            total: numberFormatter.format(projects.length),
          })}
        </span>
      </div>

      <div className="mb-5 rounded-lg border border-border p-4">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
          <h3 className="text-sm font-medium">{t("filtersTitle")}</h3>
          <button
            type="button"
            onClick={resetFilters}
            disabled={activeFilterCount === 0}
            className="rounded-md border border-border px-3 py-1.5 text-xs font-medium text-muted transition-colors hover:text-foreground disabled:cursor-not-allowed disabled:opacity-40"
          >
            {t("resetFilters")}
          </button>
        </div>

        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-12">
          <label className="grid min-w-0 gap-1.5 xl:col-span-5">
            <span className="text-xs text-muted">{t("searchLabel")}</span>
            <input
              type="search"
              aria-label={t("searchLabel")}
              value={query}
              placeholder={t("searchPlaceholder")}
              onChange={(event) => setQuery(event.target.value)}
              className="h-10 w-full min-w-0 rounded-md border border-border bg-background px-3 text-sm outline-none transition-colors placeholder:text-muted focus:border-foreground"
            />
          </label>

          <div className="grid min-w-0 gap-1.5 xl:col-span-4">
            <span className="text-xs text-muted">{t("kindLabel")}</span>
            <div className="grid h-10 min-w-0 grid-cols-4 gap-1 rounded-md border border-border p-1">
              {[
                ["all", t("kindAll")],
                ["native", t("kindNative")],
                ["port", t("kindPort")],
                ["adjacent", t("kindAdjacent")],
              ].map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  aria-pressed={kind === value}
                  onClick={() => setKind(value as FilterKind)}
                  className={`min-w-0 rounded-[5px] px-2 text-xs font-medium transition-colors ${
                    kind === value
                      ? "bg-foreground text-background"
                      : "text-muted hover:bg-code-bg hover:text-foreground"
                  }`}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>

          <label className="grid min-w-0 gap-1.5 xl:col-span-3">
            <span className="text-xs text-muted">{t("sortLabel")}</span>
            <select
              value={sortMode}
              onChange={(event) => setSortMode(event.target.value as SortMode)}
              className="h-10 w-full min-w-0 rounded-md border border-border bg-background px-3 text-sm outline-none transition-colors focus:border-foreground"
            >
              <option value="recommended">{t("sortRecommended")}</option>
              <option value="stars">{t("sortStars")}</option>
              <option value="name">{t("sortName")}</option>
            </select>
          </label>

          <label className="grid min-w-0 gap-1.5 xl:col-span-4">
            <span className="text-xs text-muted">{t("areaLabel")}</span>
            <select
              value={category}
              onChange={(event) => setCategory(event.target.value)}
              className="h-10 w-full min-w-0 rounded-md border border-border bg-background px-3 text-sm outline-none transition-colors focus:border-foreground"
            >
              <option value="all">{t("allAreas")}</option>
              {categorySummaries.map(({ category: categoryName, count }) => (
                <option key={categoryName} value={categoryName}>
                  {`${categoryLabels.get(categoryName) ?? categoryName} (${numberFormatter.format(count)})`}
                </option>
              ))}
            </select>
          </label>

          <label className="grid min-w-0 gap-1.5 xl:col-span-4">
            <span className="text-xs text-muted">{t("agentLabel")}</span>
            <select
              value={agent}
              onChange={(event) => setAgent(event.target.value)}
              className="h-10 w-full min-w-0 rounded-md border border-border bg-background px-3 text-sm outline-none transition-colors focus:border-foreground"
            >
              <option value="all">{t("allAgents")}</option>
              {agentOptions.map((agentName) => (
                <option key={agentName} value={agentName}>
                  {agentName}
                </option>
              ))}
            </select>
          </label>

          <label className="grid min-w-0 gap-1.5 xl:col-span-4">
            <span className="text-xs text-muted">{t("languageLabel")}</span>
            <select
              value={language}
              onChange={(event) => setLanguage(event.target.value)}
              className="h-10 w-full min-w-0 rounded-md border border-border bg-background px-3 text-sm outline-none transition-colors focus:border-foreground"
            >
              <option value="all">{t("allLanguages")}</option>
              {languageOptions.map((languageName) => (
                <option key={languageName} value={languageName}>
                  {languageName}
                </option>
              ))}
            </select>
          </label>
        </div>
      </div>

      {sortedProjects.length > 0 ? (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {sortedProjects.map((project) => (
            <ProjectCard
              key={project.url}
              project={project}
              kindLabel={kindLabels[project.kind]}
              categoryLabels={categoryLabels}
              numberFormatter={numberFormatter}
            />
          ))}
        </div>
      ) : (
        <div className="rounded-lg border border-border px-4 py-10 text-center">
          <div className="text-sm font-medium">{t("noProjectsTitle")}</div>
          <p className="mt-2 text-sm text-muted">{t("noProjectsDescription")}</p>
        </div>
      )}
    </section>
  );
}
