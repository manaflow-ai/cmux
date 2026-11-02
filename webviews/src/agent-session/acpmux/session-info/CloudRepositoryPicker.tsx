import { useEffect, useRef, useState, type RefObject } from "react";
import { Popover, type UiAnchor } from "../../../ui/Popover";
import { postNative } from "../native";
import { NativeError } from "../nativeError";
import { useT, type Translate } from "../i18n";

export type CloudRepo = {
  fullName: string;
  private?: boolean;
  source?: "local" | "recent" | "installation";
};

export type AttachedCloudRepo = { repo: string; folder?: string; head?: string };
export type PendingCloudRepo = {
  repo: string;
  state?: string;
  phase?: string;
  progress?: { received_bytes?: number; objects?: number; total_objects?: number };
  notes?: string[];
};

type ListReply = { repos?: CloudRepo[]; connect?: { install_url?: string } };
type AddReply = { state?: string; repo?: string; folder?: string; head?: string };
type LocalReply = {
  repos?: CloudRepo[];
  recent?: CloudRepo[];
  complete?: boolean;
  connect?: { install_url?: string };
};

async function syncRepoCatalog(_session: string): Promise<string | undefined> {
  try {
    const local = await postNative<LocalReply>("cloud.repo.local", {});
    const installUrl = local?.connect?.install_url;
    await postNative("cloud.repo.sync", {
      repos: local?.repos ?? [],
      recent: local?.recent ?? [],
      complete: local?.complete === true,
      ...(installUrl ? { install_url: installUrl } : {}),
    });
    return installUrl;
  } catch {
    // Older hosts do not expose the local catalog. The machine's persisted catalog remains usable.
    return undefined;
  }
}

function reposOf(value: unknown): CloudRepo[] {
  const rows = (value as ListReply | undefined)?.repos;
  return Array.isArray(rows)
    ? rows.filter((row): row is CloudRepo => Boolean(row) && typeof row.fullName === "string")
    : [];
}

function sourceLabel(source: CloudRepo["source"], t: Translate): string {
  return source === "local"
    ? t("cloudRepository.source.local")
    : source === "recent"
      ? t("cloudRepository.source.recent")
      : source === "installation"
        ? t("cloudRepository.source.github")
        : "";
}

function githubInstallUrl(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "github.com" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function errorCode(error: unknown): string | undefined {
  if (error instanceof NativeError && error.code) return error.code;
  const code = (error as { code?: unknown } | null | undefined)?.code;
  return typeof code === "string" ? code : undefined;
}

export function CloudRepositoryPicker({
  session,
  anchor,
  open,
  onOpenChange,
  onAttached,
  request = postNative,
}: {
  session: string;
  anchor: RefObject<HTMLElement | null>;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onAttached: (repo: AttachedCloudRepo) => void;
  request?: <T = unknown>(method: string, params?: Record<string, unknown>) => Promise<T>;
}) {
  const t = useT();
  const [query, setQuery] = useState("");
  const [repos, setRepos] = useState<CloudRepo[]>([]);
  const [connectUrl, setConnectUrl] = useState<string>();
  const [loading, setLoading] = useState(false);
  const [attaching, setAttaching] = useState<string>();
  const [error, setError] = useState<string>();
  const generation = useRef(0);
  /// The search field takes focus when the popover opens (the Popover moves it, not autoFocus).
  const search = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) return;
    const id = ++generation.current;
    const timer = window.setTimeout(
      () => {
        setLoading(true);
        setError(undefined);
        void (request === postNative ? syncRepoCatalog(session) : Promise.resolve(undefined))
          .then((syncedInstallUrl) =>
            request<ListReply>("cloud.repo.list", query.trim() ? { query: query.trim() } : {}).then((reply) => ({
              reply,
              syncedInstallUrl,
            })),
          )
          .then(({ reply, syncedInstallUrl }) => {
            if (id !== generation.current) return;
            setRepos(reposOf(reply));
            setConnectUrl(githubInstallUrl(reply?.connect?.install_url) ?? githubInstallUrl(syncedInstallUrl));
          })
          .catch(() => {
            if (id === generation.current) setError(t("cloudRepository.loadFailed"));
          })
          .finally(() => {
            if (id === generation.current) setLoading(false);
          });
      },
      query.trim() ? 120 : 0,
    );
    return () => window.clearTimeout(timer);
  }, [open, query, request, session, t]);

  const attach = (repo: CloudRepo) => {
    if (attaching) return;
    setAttaching(repo.fullName);
    setError(undefined);
    void (request === postNative ? syncRepoCatalog(session) : Promise.resolve(undefined))
      .then(() => request<AddReply>("cloud.repo.add", { repo: repo.fullName }))
      .then((reply) => {
        if (reply?.state === "done" && !(reply as { code?: unknown }).code && reply.repo) {
          onAttached({ repo: reply.repo, folder: reply.folder, head: reply.head });
          onOpenChange(false);
          setQuery("");
        } else {
          const code = (reply as { code?: unknown }).code;
          setConnectUrl(githubInstallUrl((reply as { install_url?: unknown }).install_url));
          setError(typeof code === "string" ? code : t("cloudRepository.attachFailed"));
        }
      })
      .catch((reason: unknown) => {
        const code = errorCode(reason);
        setError(
          code === "repo.needs_github" ? t("cloudRepository.connectToAttach") : t("cloudRepository.attachFailed"),
        );
      })
      .finally(() => setAttaching(undefined));
  };

  return (
    <Popover
      open={open}
      onOpenChange={onOpenChange}
      anchor={anchor.current as UiAnchor}
      label={t("cloudRepository.add")}
      className="acpmux-cloud-repository-popover"
      initialFocus={search}
    >
      <div className="acpmux-cloud-repository-picker">
        <input
          ref={search}
          className="acpmux-cloud-repository-search"
          value={query}
          placeholder={t("cloudRepository.search")}
          aria-label={t("cloudRepository.search")}
          onChange={(event) => setQuery(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") onOpenChange(false);
            if (event.key === "Enter") {
              const first = repos[0];
              if (first) {
                event.preventDefault();
                attach(first);
              }
            }
          }}
        />
        {loading && <div className="acpmux-cloud-repository-progress">{t("cloudRepository.searching")}</div>}
        {!loading && repos.length > 0 && (
          <ul className="acpmux-cloud-repository-list">
            {repos.map((repo) => (
              <li key={repo.fullName}>
                <button
                  type="button"
                  className="acpmux-cloud-repository-option"
                  data-action="repository-option"
                  disabled={Boolean(attaching)}
                  onClick={() => attach(repo)}
                >
                  <span className="acpmux-cloud-repository-name">{repo.fullName}</span>
                  <span className="acpmux-cloud-repository-source">
                    {attaching === repo.fullName ? t("cloudRepository.attaching") : sourceLabel(repo.source, t)}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {!loading && repos.length === 0 && !error && (
          <div className="acpmux-cloud-repository-empty">{t("cloudRepository.empty")}</div>
        )}
        {error && (
          <div className="acpmux-cloud-repository-error" role="alert">
            {error}
          </div>
        )}
        {connectUrl && (
          <a className="acpmux-cloud-repository-connect" href={connectUrl} target="_blank" rel="noreferrer">
            {t("cloudRepository.connect")}
          </a>
        )}
      </div>
    </Popover>
  );
}

export function loadAttachedCloudRepos(
  _session: string,
): Promise<{ repos: AttachedCloudRepo[]; pending: PendingCloudRepo[] }> {
  return postNative<{ repos?: AttachedCloudRepo[]; pending?: PendingCloudRepo[] }>("cloud.repo.attached", {}).then(
    (reply) => ({
      repos: Array.isArray(reply?.repos)
        ? reply.repos.filter((repo): repo is AttachedCloudRepo => Boolean(repo) && typeof repo.repo === "string")
        : [],
      pending: Array.isArray(reply?.pending)
        ? reply.pending.filter((repo): repo is PendingCloudRepo => Boolean(repo) && typeof repo.repo === "string")
        : [],
    }),
  );
}
