"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "@/i18n/navigation";
import type { GitHubStatus, LinkRepo, LinkRepoPage, LinkResult } from "@/app/extensions/_lib/link";

export type LinkReposLabels = {
  loading: string;
  connectTitle: string;
  connectBody: string;
  connect: string;
  connectUnavailable: string;
  connectedAs: string;
  search: string;
  empty: string;
  hiddenPrivate: string;
  more: string;
  link: string;
  linking: string;
  refresh: string;
  view: string;
  unlink: string;
  unlinking: string;
  reviewedBadge: string;
  communityBadge: string;
  done: string;
  alreadyReviewed: string;
  problem: string;
  problemHint: string;
  unlinked: string;
  errorNoMarker: string;
  errorNotOwner: string;
  errorUnavailable: string;
  retry: string;
};

const STATUS_URL = "/api/extensions/link";
const REPOS_URL = "/api/extensions/link/repos";

type Outcome =
  | { kind: "result"; repo: string; result: LinkResult }
  | { kind: "unlinked"; repo: string }
  | { kind: "error"; repo: string; message: string };

type ApiError = { code?: string; message?: string; signInUrl?: string };

/** {repo} and {login} in a label: the server formats the rest, so only these fill in here. */
function fill(label: string, values: Record<string, string | number>): string {
  return label.replace(/\{(\w+)\}/g, (match, key: string) => (key in values ? String(values[key]) : match));
}

/** A JSON answer, or the error it carries; a 401 goes to sign-in and comes back. */
async function api<T>(input: string, init?: RequestInit): Promise<{ ok: true; value: T } | { ok: false; error: ApiError }> {
  let response: Response;
  try {
    response = await fetch(input, { ...init, credentials: "same-origin", cache: "no-store" });
  } catch {
    return { ok: false, error: {} };
  }
  const body = (await response.json().catch(() => ({}))) as T & ApiError;
  if (response.status === 401 && typeof body.signInUrl === "string") {
    window.location.assign(body.signInUrl);
    return { ok: false, error: body };
  }
  return response.ok ? { ok: true, value: body } : { ok: false, error: body };
}

const BUTTON_PRIMARY =
  "inline-flex items-center rounded-full bg-foreground px-4 py-1.5 text-[13px] font-medium transition-opacity hover:opacity-85 disabled:opacity-50";
const BUTTON_SECONDARY =
  "inline-flex items-center rounded-full border border-border px-4 py-1.5 text-[13px] font-medium transition-colors hover:bg-code-bg disabled:opacity-50";

export function LinkRepos({ labels }: { labels: LinkReposLabels }) {
  const [status, setStatus] = useState<GitHubStatus | "loading" | "error">("loading");

  const [attempt, setAttempt] = useState(0);
  const loadStatus = () => {
    setStatus("loading");
    setAttempt((value) => value + 1);
  };

  useEffect(() => {
    let live = true;
    void api<GitHubStatus>(STATUS_URL).then((answer) => {
      if (live) setStatus(answer.ok ? answer.value : "error");
    });
    return () => {
      live = false;
    };
  }, [attempt]);

  if (status === "loading") return <p className="text-[14px] text-muted">{labels.loading}</p>;
  if (status === "error") {
    return (
      <div className="rounded-2xl border border-dashed border-border px-6 py-8 text-center">
        <p className="text-[14px] text-muted">{labels.errorUnavailable}</p>
        <button type="button" onClick={loadStatus} className={`mt-3 ${BUTTON_SECONDARY}`}>
          {labels.retry}
        </button>
      </div>
    );
  }
  if (!status.connected) {
    return (
      <section className="rounded-2xl border border-border p-6">
        <h2 className="text-lg font-semibold tracking-tight">{labels.connectTitle}</h2>
        <p className="mt-2 max-w-2xl text-[14px] leading-6 text-muted">{labels.connectBody}</p>
        {status.installUrl ? (
          <a
            href={status.installUrl}
            className="mt-4 inline-flex items-center rounded-full bg-foreground px-5 py-2 text-[14px] font-medium transition-opacity hover:opacity-85"
            style={{ color: "var(--background)", textDecoration: "none" }}
          >
            {labels.connect}
          </a>
        ) : (
          <p className="mt-4 text-[14px] text-muted">{labels.connectUnavailable}</p>
        )}
      </section>
    );
  }
  return <RepoList login={status.login} avatarUrl={status.avatarUrl} labels={labels} />;
}

function RepoList({ login, avatarUrl, labels }: { login: string; avatarUrl?: string; labels: LinkReposLabels }) {
  const [query, setQuery] = useState("");
  const [repos, setRepos] = useState<LinkRepo[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [hiddenPrivate, setHiddenPrivate] = useState(0);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const request = useRef(0);

  const load = useCallback(async (search: string, after: string | null) => {
    const id = ++request.current;
    setLoading(true);
    setFailed(false);
    const params = new URLSearchParams();
    if (search.trim()) params.set("query", search.trim());
    if (after) params.set("cursor", after);
    const answer = await api<LinkRepoPage>(`${REPOS_URL}?${params.toString()}`);
    if (id !== request.current) return;
    setLoading(false);
    if (!answer.ok) {
      setFailed(true);
      return;
    }
    setRepos((current) => (after ? [...current, ...answer.value.repos] : answer.value.repos));
    setHiddenPrivate((current) => (after ? current : 0) + answer.value.hiddenPrivate);
    setCursor(answer.value.cursor);
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => void load(query, null), query ? 250 : 0);
    return () => clearTimeout(timer);
  }, [load, query]);

  // A new search drops the old one's cursor and any page in flight for it now, so Load more can't fetch them during
  // the debounce.
  const search = (value: string) => {
    request.current++;
    setCursor(null);
    setQuery(value);
  };

  const update = (fullName: string, change: Partial<LinkRepo> | null) =>
    setRepos((current) =>
      current.map((repo) => {
        if (repo.fullName !== fullName) return repo;
        if (change) return { ...repo, ...change };
        return { fullName: repo.fullName, owner: repo.owner, name: repo.name };
      }),
    );

  const linkRepo = async (repo: LinkRepo) => {
    setBusy(repo.fullName);
    setOutcome(null);
    const answer = await api<LinkResult>(STATUS_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ repo: repo.fullName }),
    });
    setBusy(null);
    if (!answer.ok) {
      setOutcome({ kind: "error", repo: repo.fullName, message: errorMessage(answer.error, repo.fullName, labels) });
      return;
    }
    setOutcome({ kind: "result", repo: repo.fullName, result: answer.value });
    // A problem keeps the page hidden, so the row offers Link again rather than a page that 404s.
    if (!answer.value.problem) update(repo.fullName, { page: answer.value.page, community: answer.value.status === "linked" });
  };

  const unlinkRepo = async (repo: LinkRepo) => {
    setBusy(repo.fullName);
    setOutcome(null);
    const answer = await api<{ status: "unlinked" }>(`${STATUS_URL}?${new URLSearchParams({ repo: repo.fullName })}`, {
      method: "DELETE",
    });
    setBusy(null);
    if (!answer.ok) {
      setOutcome({ kind: "error", repo: repo.fullName, message: errorMessage(answer.error, repo.fullName, labels) });
      return;
    }
    setOutcome({ kind: "unlinked", repo: repo.fullName });
    update(repo.fullName, null);
  };

  return (
    <section>
      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <p className="flex items-center gap-2 text-[14px] text-muted">
          {avatarUrl ? (
            // eslint-disable-next-line @next/next/no-img-element -- a GitHub avatar, at 20 px
            <img src={avatarUrl} alt="" width={20} height={20} className="rounded-full" />
          ) : null}
          {fill(labels.connectedAs, { login })}
        </p>
        <input
          type="search"
          value={query}
          onChange={(event) => search(event.target.value)}
          placeholder={labels.search}
          aria-label={labels.search}
          className="w-full rounded-full border border-border bg-transparent px-4 py-1.5 text-[14px] outline-none focus:border-foreground sm:w-72"
        />
      </div>
      {outcome ? <OutcomeNotice outcome={outcome} labels={labels} /> : null}
      <ul className="divide-y divide-border rounded-2xl border border-border">
        {repos.map((repo) => (
          <RepoRow key={repo.fullName} repo={repo} busy={busy} labels={labels} onLink={linkRepo} onUnlink={unlinkRepo} />
        ))}
        {!loading && !failed && repos.length === 0 ? <li className="px-5 py-6 text-[14px] text-muted">{labels.empty}</li> : null}
        {failed ? <li className="px-5 py-6 text-[14px] text-muted">{labels.errorUnavailable}</li> : null}
        {loading ? <li className="px-5 py-6 text-[14px] text-muted">{labels.loading}</li> : null}
      </ul>
      <div className="mt-4 flex flex-wrap items-center gap-3">
        {cursor && !loading ? (
          <button type="button" onClick={() => void load(query, cursor)} className={BUTTON_SECONDARY}>
            {labels.more}
          </button>
        ) : null}
        {hiddenPrivate > 0 ? <p className="text-[13px] text-muted">{fill(labels.hiddenPrivate, { count: hiddenPrivate })}</p> : null}
      </div>
    </section>
  );
}

function RepoRow({
  repo,
  busy,
  labels,
  onLink,
  onUnlink,
}: {
  repo: LinkRepo;
  busy: string | null;
  labels: LinkReposLabels;
  onLink: (repo: LinkRepo) => void;
  onUnlink: (repo: LinkRepo) => void;
}) {
  const working = busy === repo.fullName;
  return (
    <li className="flex flex-wrap items-center justify-between gap-3 px-5 py-3">
      <div className="min-w-0">
        <span className="font-mono text-[14px]">{repo.fullName}</span>
        {repo.page ? (
          <span className="ml-2 rounded-full border border-border px-2 py-0.5 text-[11px] text-muted">
            {repo.community ? labels.communityBadge : labels.reviewedBadge}
          </span>
        ) : null}
      </div>
      <div className="flex gap-2">
        {repo.page ? (
          <Link href={repo.page} className={BUTTON_SECONDARY} style={{ textDecoration: "none" }}>
            {labels.view}
          </Link>
        ) : null}
        {repo.page && repo.community ? (
          <button type="button" disabled={busy !== null} onClick={() => onUnlink(repo)} className={BUTTON_SECONDARY}>
            {working ? labels.unlinking : labels.unlink}
          </button>
        ) : null}
        {!repo.page || repo.community ? (
          <button
            type="button"
            disabled={busy !== null}
            onClick={() => onLink(repo)}
            className={BUTTON_PRIMARY}
            style={{ color: "var(--background)" }}
          >
            {working ? labels.linking : repo.page ? labels.refresh : labels.link}
          </button>
        ) : null}
      </div>
    </li>
  );
}

function errorMessage(error: ApiError, repo: string, labels: LinkReposLabels): string {
  if (error.code === "extension.no_marker") return fill(labels.errorNoMarker, { repo });
  if (error.code === "extension.not_owner") return fill(labels.errorNotOwner, { repo });
  if (!error.code || error.code === "extension.unavailable") return labels.errorUnavailable;
  return error.message ?? labels.errorUnavailable;
}

function OutcomeNotice({ outcome, labels }: { outcome: Outcome; labels: LinkReposLabels }) {
  const repo = outcome.repo;
  if (outcome.kind === "error") {
    return (
      <div role="alert" className="mb-4 rounded-2xl border border-border bg-code-bg px-5 py-4 text-[14px] leading-6">
        {outcome.message}
      </div>
    );
  }
  if (outcome.kind === "unlinked") {
    return <div role="status" className="mb-4 rounded-2xl border border-border px-5 py-4 text-[14px]">{fill(labels.unlinked, { repo })}</div>;
  }
  const { result } = outcome;
  const pageLink = (
    <Link href={result.page} className="font-medium underline decoration-link-underline underline-offset-2">
      cmux.com{result.page}
    </Link>
  );
  if (result.problem) {
    return (
      <div role="status" className="mb-4 rounded-2xl border border-border bg-code-bg px-5 py-4 text-[14px] leading-6">
        <p>{fill(labels.problem, { repo })}</p>
        <p className="mt-1 font-medium">{result.problem}</p>
        <p className="mt-1 text-muted">{labels.problemHint}</p>
      </div>
    );
  }
  return (
    <div role="status" className="mb-4 rounded-2xl border border-border px-5 py-4 text-[14px] leading-6">
      {fill(result.status === "reviewed" ? labels.alreadyReviewed : labels.done, { repo })} {pageLink}
    </div>
  );
}
