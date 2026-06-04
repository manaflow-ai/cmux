"use client";

import { useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import type { AwesomeCmuxProject } from "./awesome-cmux-projects";

type CategorySummary = {
  category: string;
  count: number;
};

type SortMode = "recommended" | "stars" | "name";

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
  "Build & Distribution": "buildDistribution",
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
  description: string,
  query: string,
  categoryLabels: ReadonlyMap<string, string>,
) {
  if (!query) {
    return true;
  }

  const searchableText = [
    project.name,
    description,
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
  description,
  categoryLabels,
  numberFormatter,
}: {
  project: AwesomeCmuxProject;
  description: string;
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

      <p className="mt-3 flex-1 text-sm leading-6 text-muted">{description}</p>

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

  const projectOrder = useMemo(
    () => new Map(projects.map((project, index) => [project.url, index])),
    [projects],
  );
  const projectDescriptions = useMemo(
    () =>
      new Map(
        projects.map((project) => [
          project.url,
          t(`projectDescriptions.${project.descriptionKey}`),
        ]),
      ),
    [projects, t],
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
        if (category !== "all" && !project.categories.includes(category)) {
          return false;
        }

        if (agent !== "all" && project.agent !== agent) {
          return false;
        }

        if (language !== "all" && project.language !== language) {
          return false;
        }

        return projectMatchesQuery(
          project,
          projectDescriptions.get(project.url) ?? "",
          normalizedQuery,
          categoryLabels,
        );
      }),
    [
      agent,
      category,
      categoryLabels,
      language,
      normalizedQuery,
      projectDescriptions,
      projects,
    ],
  );

  const sortedProjects = useMemo(() => {
    return [...filteredProjects].sort((left, right) => {
      if (sortMode === "name") {
        return compareProjectNames(collator, left, right);
      }

      if (sortMode === "stars") {
        return compareProjectStars(collator, left, right);
      }

      return (projectOrder.get(left.url) ?? 0) - (projectOrder.get(right.url) ?? 0);
    });
  }, [collator, filteredProjects, projectOrder, sortMode]);

  const activeFilterCount = [
    normalizedQuery,
    category !== "all",
    agent !== "all",
    language !== "all",
    sortMode !== "recommended",
  ].filter(Boolean).length;

  function resetFilters() {
    setQuery("");
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
          <label className="grid min-w-0 gap-1.5 xl:col-span-6">
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

          <label className="grid min-w-0 gap-1.5 xl:col-span-6">
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
              description={projectDescriptions.get(project.url) ?? ""}
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
