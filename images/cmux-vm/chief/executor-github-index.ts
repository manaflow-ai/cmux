// cmux's first-party GitHub app for a Cloud Chief's Executor (RFD 0111). The person connects a GitHub token
// through Executor's connect form; `hosts` keeps the token a handle the app code never reads.
import {
  ProviderError,
  decodeJson,
  defineApp,
  defineProvider,
  mutation,
  number,
  object,
  query,
  router,
  secrets,
  string,
  type QueryContext,
} from "apps";

const API = "https://api.github.com";

const github = defineProvider({
  name: "GitHub",
  hosts: ["api.github.com"],
  auth: {
    apiKey: secrets({
      label: "GitHub token",
      fields: object({ token: string({ minLength: 1 }) }),
    }),
  },
  async health({ account, fetch, signal }) {
    const response = await fetch(`${API}/user`, { signal, headers: headers(account.fields.token) });
    if (response.status === 403) throw new ProviderError({ reason: "rejected", status: 403 });
    const user = await decodeJson(response, object({ id: number(), login: string() }));
    return { accountInfo: { externalId: String(user.id), username: user.login } };
  },
});

const requirements = { user: { accounts: { github } } };
type Context = QueryContext<typeof requirements>;

function headers(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "cmux-chief-executor",
  };
}

async function get(ctx: Context, path: string): Promise<unknown> {
  const response = await ctx.fetch(`${API}${path}`, { headers: headers(ctx.user.accounts.github.fields.token) });
  if (!response.ok) throw new Error(`GitHub ${response.status} on GET ${path}: ${(await response.text()).slice(0, 300)}`);
  return response.json();
}

const Repo = object({ owner: string({ minLength: 1 }), repo: string({ minLength: 1 }) });
const enc = encodeURIComponent;

const me = query(
  { description: "The GitHub account the connected token belongs to", input: object({}) },
  async (ctx: Context) => {
    const u = (await get(ctx, "/user")) as Record<string, unknown>;
    return { login: u.login, name: u.name, html_url: u.html_url };
  },
);

const listIssues = query(
  {
    description: "List open issues and pull requests in a repository, newest first (up to 30)",
    input: Repo,
  },
  async (ctx: Context, { owner, repo }) => {
    const items = (await get(ctx, `/repos/${enc(owner)}/${enc(repo)}/issues?state=open&per_page=30`)) as Array<Record<string, any>>;
    return items.map((i) => ({
      number: i.number,
      title: i.title,
      kind: i.pull_request ? "pull_request" : "issue",
      author: i.user?.login,
      updated_at: i.updated_at,
      html_url: i.html_url,
    }));
  },
);

const getIssue = query(
  {
    description: "Read one issue or pull request with its body and latest comments",
    input: object({ owner: string({ minLength: 1 }), repo: string({ minLength: 1 }), number: number() }),
  },
  async (ctx: Context, { owner, repo, number: n }) => {
    const base = `/repos/${enc(owner)}/${enc(repo)}/issues/${n}`;
    const i = (await get(ctx, base)) as Record<string, any>;
    const comments = (await get(ctx, `${base}/comments?per_page=20`)) as Array<Record<string, any>>;
    return {
      number: i.number,
      title: i.title,
      state: i.state,
      author: i.user?.login,
      body: i.body,
      html_url: i.html_url,
      comments: comments.map((c) => ({ author: c.user?.login, body: c.body, created_at: c.created_at })),
    };
  },
);

const searchIssues = query(
  {
    description: "Search issues and pull requests with GitHub search syntax, e.g. `repo:owner/name is:open label:bug`",
    input: object({ q: string({ minLength: 1 }) }),
  },
  async (ctx: Context, { q }) => {
    const r = (await get(ctx, `/search/issues?per_page=20&q=${enc(q)}`)) as { items: Array<Record<string, any>> };
    return r.items.map((i) => ({ title: i.title, number: i.number, state: i.state, html_url: i.html_url }));
  },
);

const commentOnIssue = mutation(
  {
    description: "Post a comment on an issue or pull request as the connected account",
    input: object({
      owner: string({ minLength: 1 }),
      repo: string({ minLength: 1 }),
      number: number(),
      body: string({ minLength: 1 }),
    }),
  },
  async (ctx: Context, { owner, repo, number: n, body }) => {
    const response = await ctx.fetch(`${API}/repos/${enc(owner)}/${enc(repo)}/issues/${n}/comments`, {
      method: "POST",
      headers: { ...headers(ctx.user.accounts.github.fields.token), "Content-Type": "application/json" },
      body: JSON.stringify({ body }),
    });
    if (!response.ok) throw new Error(`GitHub ${response.status}: ${(await response.text()).slice(0, 300)}`);
    const c = (await response.json()) as Record<string, any>;
    return { html_url: c.html_url };
  },
);

export default defineApp(requirements, { tools: router({ me, listIssues, getIssue, searchIssues, commentOnIssue }) });
