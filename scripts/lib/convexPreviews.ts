export const DEFAULT_BASE_URL = "https://api.convex.dev";

type TeamTokenDetails = {
  readonly type: "teamToken";
  readonly name: string;
  readonly createTime: number;
  readonly teamId: number;
};

type ProjectTokenDetails = {
  readonly type: "projectToken";
  readonly name: string;
  readonly createTime: number;
  readonly projectId: number;
};

type TokenDetails = TeamTokenDetails | ProjectTokenDetails;

type ProjectDetails = {
  readonly id: number;
  readonly name: string;
  readonly slug: string;
  readonly teamId: number;
  readonly createTime: number;
};

type DeploymentType = "dev" | "prod" | "preview";

type Deployment = {
  readonly name: string;
  readonly createTime: number;
  readonly deploymentType: DeploymentType;
  readonly projectId: number;
  readonly previewIdentifier: string | null;
};

export type GitHubPullRequestState = "open" | "closed" | "merged";

export type GitHubBranchStatus = {
  readonly branchName: string;
  readonly branchExists: boolean;
  readonly branchSha?: string;
  readonly checkedAt: string;
  readonly pullRequest?: {
    readonly number: number;
    readonly title: string;
    readonly state: GitHubPullRequestState;
    readonly htmlUrl: string;
    readonly mergedAt: string | null;
    readonly closedAt: string | null;
  };
};

export type PreviewDeploymentRecord = {
  readonly projectId: number;
  readonly projectSlug?: string;
  readonly projectName?: string;
  readonly deploymentName: string;
  readonly previewIdentifier: string | null;
  readonly createdAt: string;
  readonly github?: GitHubBranchStatus | null;
};

export type GitHubConfig = {
  readonly owner: string;
  readonly repo: string;
  readonly token: string | null;
  readonly branchPrefix: string;
  readonly onError?: (identifier: string, error: unknown) => void;
};

export type FetchPreviewOptions = {
  readonly token: string;
  readonly baseUrl?: string;
  readonly teamId?: number | null;
  readonly projectId?: number | null;
  readonly projectSlug?: string | null;
  readonly github?: GitHubConfig | null;
};

type TokenClassification =
  | { kind: "missing" }
  | { kind: "management"; token: string }
  | {
      kind: "previewProjectKey";
      teamSlug: string;
      projectSlug: string;
    }
  | { kind: "previewDeploymentKey"; deploymentName: string }
  | { kind: "deploymentKey" }
  | { kind: "projectKey" };

export class TokenError extends Error {}

export function parseGitHubRepo(input: string): { owner: string; repo: string } {
  const trimmed = input.trim();
  if (trimmed.length === 0) {
    throw new Error("Expected repository to be non-empty.");
  }
  const parts = trimmed.split("/");
  if (parts.length !== 2) {
    throw new Error(
      `Expected repository in the form owner/repo, received "${input}".`,
    );
  }
  const [owner, repo] = parts;
  if (owner.length === 0 || repo.length === 0) {
    throw new Error(
      `GitHub repository must include both owner and repo components, received "${input}".`,
    );
  }
  return { owner, repo };
}

export function normalizeBaseUrl(url: string): string {
  return url.endsWith("/") ? url.slice(0, -1) : url;
}

export function ensureManagementToken(rawToken: string): string {
  const classification = classifyToken(rawToken);
  switch (classification.kind) {
    case "missing":
      throw new TokenError(
        "A management API token is required. Pass --token or set CONVEX_MANAGEMENT_TOKEN.",
      );
    case "previewProjectKey":
      throw new TokenError(
        [
          "Preview deploy keys are limited to creating or deploying individual preview instances.",
          "They cannot call the management endpoints that enumerate preview deployments.",
          "Generate a team OAuth token or project token from the Convex dashboard instead.",
        ].join(" "),
      );
    case "previewDeploymentKey":
      throw new TokenError(
        [
          "Preview deployment keys target a single preview instance.",
          "Convex does not expose an API to list or manage other preview deployments with this credential.",
          "Use an OAuth team token or project token instead.",
        ].join(" "),
      );
    case "deploymentKey":
      throw new TokenError(
        [
          "Deployment admin keys (prod/dev) are scoped to a single deployment.",
          "Listing or deleting preview deployments requires a management-scoped credential.",
          "Provide an OAuth team token or project token instead.",
        ].join(" "),
      );
    case "projectKey":
      throw new TokenError(
        [
          "Project deploy keys cannot access the management endpoints used to manage preview deployments.",
          "Supply a team OAuth token or project-scoped OAuth token from the Convex dashboard.",
        ].join(" "),
      );
    case "management":
      return classification.token;
    default:
      classification satisfies never;
      throw new TokenError("Unsupported token type.");
  }
}

export async function fetchPreviewDeployments(
  options: FetchPreviewOptions,
): Promise<PreviewDeploymentRecord[]> {
  const managementToken = ensureManagementToken(options.token);
  const baseUrl = normalizeBaseUrl(options.baseUrl ?? DEFAULT_BASE_URL);
  const apiBase = `${baseUrl}/v1`;
  const headers: HeadersInit = {
    Authorization: `Bearer ${managementToken}`,
  };

  const tokenDetails = parseTokenDetails(
    await fetchJson(apiBase, "/token_details", headers),
  );

  const optionTeamId =
    options.teamId === undefined || options.teamId === null
      ? null
      : options.teamId;
  const optionProjectId =
    options.projectId === undefined || options.projectId === null
      ? null
      : options.projectId;
  const optionProjectSlug =
    options.projectSlug === undefined || options.projectSlug === null
      ? null
      : options.projectSlug;

  const projects = await resolveTeamProjectScope({
    apiBase,
    headers,
    tokenDetails,
    optionTeamId,
    optionProjectId,
    optionProjectSlug,
  });

  const previewRows: PreviewDeploymentRecord[] = [];
  for (const project of projects) {
    const deployments = parseDeployments(
      await fetchJson(
        apiBase,
        `/projects/${project.id}/list_deployments`,
        headers,
      ),
    );

    const previews = deployments.filter((deployment) => {
      return deployment.deploymentType === "preview";
    });

    for (const preview of previews) {
      previewRows.push({
        projectId: project.id,
        projectSlug: project.slug,
        projectName: project.name,
        deploymentName: preview.name,
        previewIdentifier: preview.previewIdentifier ?? null,
        createdAt: new Date(preview.createTime).toISOString(),
        github: null,
      });
    }
  }

  if (!options.github) {
    return previewRows;
  }

  const identifiers = new Set(
    previewRows
      .map((row) => row.previewIdentifier)
      .filter((identifier): identifier is string => identifier !== null),
  );
  const githubStatuses = new Map<string, GitHubBranchStatus | null>();
  for (const identifier of identifiers) {
    try {
      const status = await fetchGitHubBranchStatus(options.github, identifier);
      githubStatuses.set(identifier, status);
    } catch (error) {
      githubStatuses.set(identifier, null);
      options.github.onError?.(identifier, error);
    }
  }

  return previewRows.map((row) => ({
    ...row,
    github:
      row.previewIdentifier === null
        ? null
        : githubStatuses.get(row.previewIdentifier) ?? null,
  }));
}

export async function fetchGitHubBranchStatus(
  config: GitHubConfig,
  identifier: string,
): Promise<GitHubBranchStatus | null> {
  const branchName = deriveGitHubBranchName(identifier, config.branchPrefix);
  if (branchName === null) {
    return null;
  }

  const encodedBranch = encodeURIComponent(branchName);
  const branchResponse = await fetchGitHub(
    config,
    `/repos/${config.owner}/${config.repo}/branches/${encodedBranch}`,
  );

  let branchExists = false;
  let branchSha: string | undefined;

  if (branchResponse.status === 200) {
    const branchJson = (await branchResponse.json()) as unknown;
    if (!isObject(branchJson)) {
      throw new Error(
        `Unexpected branch payload when fetching ${branchName} from GitHub.`,
      );
    }
    const commit = branchJson.commit;
    if (!isObject(commit)) {
      throw new Error(
        `Branch payload for ${branchName} missing commit information.`,
      );
    }
    const commitSha = commit.sha;
    if (!isString(commitSha)) {
      throw new Error(
        `Branch payload for ${branchName} missing commit SHA.`,
      );
    }
    branchExists = true;
    branchSha = commitSha;
  } else if (branchResponse.status === 404) {
    branchExists = false;
  } else {
    const body = await branchResponse.text();
    throw new Error(
      `GitHub branch lookup for ${branchName} failed with ${branchResponse.status}: ${branchResponse.statusText}\n${body}`,
    );
  }

  const prQuery = new URLSearchParams({
    state: "all",
    head: `${config.owner}:${branchName}`,
    per_page: "1",
  });
  const prResponse = await fetchGitHub(
    config,
    `/repos/${config.owner}/${config.repo}/pulls?${prQuery.toString()}`,
  );

  let pullRequest:
    | {
        readonly number: number;
        readonly title: string;
        readonly state: GitHubPullRequestState;
        readonly htmlUrl: string;
        readonly mergedAt: string | null;
        readonly closedAt: string | null;
      }
    | undefined;

  if (prResponse.status === 200) {
    const prs = (await prResponse.json()) as unknown;
    if (Array.isArray(prs) && prs.length > 0) {
      const pr = prs[0];
      if (
        isObject(pr) &&
        typeof pr.number === "number" &&
        isString(pr.title) &&
        isString(pr.state) &&
        isString(pr.html_url)
      ) {
        const mergedAtValue =
          "merged_at" in pr && (pr.merged_at === null || isString(pr.merged_at))
            ? (pr.merged_at as string | null)
            : null;
        const closedAtValue =
          "closed_at" in pr && (pr.closed_at === null || isString(pr.closed_at))
            ? (pr.closed_at as string | null)
            : null;
        const state: GitHubPullRequestState =
          pr.state === "closed"
            ? mergedAtValue
              ? "merged"
              : "closed"
            : "open";
        pullRequest = {
          number: pr.number,
          title: pr.title,
          state,
          htmlUrl: pr.html_url,
          mergedAt: mergedAtValue,
          closedAt: closedAtValue,
        };
      }
    }
  } else if (prResponse.status !== 404) {
    const body = await prResponse.text();
    throw new Error(
      `GitHub PR lookup for branch ${branchName} failed with ${prResponse.status}: ${prResponse.statusText}\n${body}`,
    );
  }

  return {
    branchName,
    branchExists,
    branchSha,
    checkedAt: new Date().toISOString(),
    pullRequest,
  };
}

export type DeletePreviewAuth =
  | {
      readonly kind: "dashboard";
      readonly token: string;
    }
  | {
      readonly kind: "management";
      readonly token: string;
    };

export async function deletePreviewDeployment(options: {
  readonly auth: DeletePreviewAuth;
  readonly projectId: number;
  readonly identifier: string;
  readonly baseUrl?: string;
}): Promise<void> {
  const baseUrl = normalizeBaseUrl(options.baseUrl ?? DEFAULT_BASE_URL);
  const headers: HeadersInit = {
    "Content-Type": "application/json",
  };

  let url: string;
  if (options.auth.kind === "dashboard") {
    headers.Authorization = `Bearer ${options.auth.token}`;
    url = `${baseUrl}/api/dashboard/projects/${options.projectId}/delete_preview_deployment`;
  } else {
    const managementToken = ensureManagementToken(options.auth.token);
    headers.Authorization = `Bearer ${managementToken}`;
    url = `${baseUrl}/v1/projects/${options.projectId}/delete_preview_deployment`;
  }

  const resp = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify({ identifier: options.identifier }),
  });
  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(
      `Failed to delete preview deployment ${options.identifier}: ${resp.status} ${resp.statusText}${body ? `\n${body}` : ""}`,
    );
  }
}

function classifyToken(input: string): TokenClassification {
  const token = input.trim();
  if (token.length === 0) {
    return { kind: "missing" };
  }

  const pipeIndex = token.indexOf("|");
  if (pipeIndex !== -1) {
    const prefix = token.slice(0, pipeIndex);
    const segments = prefix.split(":");
    const [first, second, third] = segments;

    if (first === "preview") {
      if (segments.length === 3 && second && third) {
        return {
          kind: "previewProjectKey",
          teamSlug: second,
          projectSlug: third,
        };
      }
      if (segments.length === 2 && second) {
        return { kind: "previewDeploymentKey", deploymentName: second };
      }
    }

    if (first === "project" && segments.length >= 2) {
      return { kind: "projectKey" };
    }

    if ((first === "dev" || first === "prod") && segments.length >= 2) {
      return { kind: "deploymentKey" };
    }
  }

  return { kind: "management", token };
}

async function fetchJson(
  apiBase: string,
  path: string,
  headers: HeadersInit,
): Promise<unknown> {
  const response = await fetch(`${apiBase}${path}`, {
    headers,
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `Request to ${path} failed with ${response.status}: ${response.statusText}\n${body}`,
    );
  }

  if (response.status === 204) {
    return null;
  }

  return (await response.json()) as unknown;
}

function parseTokenDetails(data: unknown): TokenDetails {
  if (!isObject(data) || !isString(data.type)) {
    throw new Error("Unexpected token details response shape.");
  }

  if (data.type === "teamToken") {
    if (
      !isNumber(data.teamId) ||
      !isString(data.name) ||
      !isNumber(data.createTime)
    ) {
      throw new Error("Team token response missing required fields.");
    }
    return {
      type: "teamToken",
      teamId: data.teamId,
      name: data.name,
      createTime: data.createTime,
    };
  }

  if (data.type === "projectToken") {
    if (
      !isNumber(data.projectId) ||
      !isString(data.name) ||
      !isNumber(data.createTime)
    ) {
      throw new Error("Project token response missing required fields.");
    }
    return {
      type: "projectToken",
      projectId: data.projectId,
      name: data.name,
      createTime: data.createTime,
    };
  }

  throw new Error(`Unhandled token type: ${data.type}`);
}

function parseProjects(data: unknown): ProjectDetails[] {
  if (!Array.isArray(data)) {
    throw new Error("List projects response is not an array.");
  }

  return data.map((entry) => {
    if (!isObject(entry)) {
      throw new Error("Project entry is not an object.");
    }

    const { id, name, slug, teamId, createTime } = entry;
    if (
      !isNumber(id) ||
      !isString(name) ||
      !isString(slug) ||
      !isNumber(teamId) ||
      !isNumber(createTime)
    ) {
      throw new Error("Project entry missing required fields.");
    }

    return { id, name, slug, teamId, createTime };
  });
}

function parseDeployments(data: unknown): Deployment[] {
  if (!Array.isArray(data)) {
    throw new Error("List deployments response is not an array.");
  }

  return data.map((entry) => {
    if (!isObject(entry)) {
      throw new Error("Deployment entry is not an object.");
    }

    const { name, createTime, deploymentType, projectId, previewIdentifier } =
      entry;

    if (
      !isString(name) ||
      !isNumber(createTime) ||
      !isString(deploymentType) ||
      !isNumber(projectId)
    ) {
      throw new Error("Deployment entry missing required fields.");
    }

    if (
      deploymentType !== "dev" &&
      deploymentType !== "prod" &&
      deploymentType !== "preview"
    ) {
      throw new Error(`Unexpected deployment type: ${deploymentType}`);
    }

    if (
      previewIdentifier !== null &&
      previewIdentifier !== undefined &&
      !isString(previewIdentifier)
    ) {
      throw new Error("Preview identifier must be null or string.");
    }

    return {
      name,
      createTime,
      deploymentType,
      projectId,
      previewIdentifier:
        previewIdentifier === undefined ? null : previewIdentifier,
    };
  });
}

async function resolveTeamProjectScope(options: {
  readonly apiBase: string;
  readonly headers: HeadersInit;
  readonly tokenDetails: TokenDetails;
  readonly optionTeamId: number | null;
  readonly optionProjectId: number | null;
  readonly optionProjectSlug: string | null;
}): Promise<ProjectDetails[]> {
  if (options.tokenDetails.type === "teamToken") {
    const teamId = options.optionTeamId ?? options.tokenDetails.teamId;
    const projectsData = parseProjects(
      await fetchJson(options.apiBase, `/teams/${teamId}/list_projects`, options.headers),
    );

    if (options.optionProjectId !== null) {
      const project = projectsData.find(
        (item) => item.id === options.optionProjectId,
      );
      if (!project) {
        throw new Error(
          `Project ${options.optionProjectId} not found within team ${teamId}.`,
        );
      }
      return [project];
    }

    if (options.optionProjectSlug) {
      const project = projectsData.find(
        (item) => item.slug === options.optionProjectSlug,
      );
      if (!project) {
        throw new Error(
          `Project with slug "${options.optionProjectSlug}" not found within team ${teamId}.`,
        );
      }
      return [project];
    }

    return projectsData;
  }

  const effectiveProjectId =
    options.optionProjectId ?? options.tokenDetails.projectId;
  return [
    {
      id: effectiveProjectId,
      name: `Project ${effectiveProjectId}`,
      slug: `project-${effectiveProjectId}`,
      teamId: -1,
      createTime: 0,
    },
  ];
}

const GITHUB_API_BASE = "https://api.github.com";

function gitHubHeaders(config: GitHubConfig): Headers {
  const headers = new Headers({
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  });
  if (config.token) {
    headers.set("Authorization", `Bearer ${config.token}`);
  }
  return headers;
}

async function fetchGitHub(
  config: GitHubConfig,
  path: string,
  init?: RequestInit,
): Promise<Response> {
  const headers = gitHubHeaders(config);
  if (init?.headers) {
    const extra = new Headers(init.headers as HeadersInit);
    extra.forEach((value, key) => {
      headers.set(key, value);
    });
  }
  return await fetch(`${GITHUB_API_BASE}${path}`, {
    ...init,
    headers,
  });
}

function deriveGitHubBranchName(
  identifier: string,
  prefix: string,
): string | null {
  if (identifier.length === 0) {
    return null;
  }
  if (prefix.length === 0) {
    return identifier;
  }
  if (!identifier.startsWith(prefix)) {
    return identifier;
  }
  const trimmed = identifier.slice(prefix.length);
  return trimmed.length === 0 ? null : trimmed;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isString(value: unknown): value is string {
  return typeof value === "string";
}
