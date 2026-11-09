import { useCallback, useEffect, useRef, useState } from "react";
import { devicePushCount, subscribeDeviceChats } from "./deviceChats";
import { chatsChangedSinceSettled, rememberChats, settledChats } from "./settledCache";
import { useT } from "../i18n";
import { errorMessage } from "../transportErrors";

export type AllChatsRow = { key: string; harness: string; title?: string; cwd?: string; updatedAt: number };
export type AllChatsDesign = "quiet" | "age" | "project";
export type AllChatsPage = {
  chats: AllChatsRow[];
  nextCursor?: string;
  ready?: boolean;
  enabled?: boolean;
  design?: string;
};

/// The host's `chats.page`; rejects or resolves undefined when the daemon cannot answer.
export type LoadChatsPage = (params: {
  query?: string;
  cursor?: string;
  limit: number;
}) => Promise<AllChatsPage | undefined>;

const PAGE = 100;
/// How long a first read may go unanswered before the list says it couldn't load and offers Try
/// again: a read that never answers (a stuck daemon) otherwise keeps the skeleton up for good.
export const CHATS_READ_CEILING_MS = 15_000;
type State = {
  query: string;
  rows: AllChatsRow[];
  nextCursor?: string;
  loading: boolean;
  loaded: boolean;
  /// The daemon's index has finished its first scan (`ready`); before that an empty page is not "No chats".
  ready: boolean;
  /// The last first-page read failed (the daemon did not answer): the list says so and offers Try again.
  failed: boolean;
  /// The cursor page that last failed. The loader stays in place, so it must expose its own retry.
  failedCursor?: string;
  /// The query `rows` answer; a failed read for another query drops them rather than show them under it.
  rowsQuery: string;
  design: AllChatsDesign;
};

const initial: State = {
  query: "",
  rows: [],
  loading: false,
  loaded: false,
  ready: false,
  failed: false,
  rowsQuery: "",
  design: "age",
};

/// The list a page starts with: the first page the last page read (settledCache.ts), drawn on the
/// first frame, else empty until its read lands.
function initialState(): State {
  const settled = settledChats();
  if (!settled) return initial;
  return {
    ...initial,
    rows: settled.rows,
    ...(settled.nextCursor ? { nextCursor: settled.nextCursor } : {}),
    loaded: true,
    ready: settled.ready,
    design: settled.design ?? initial.design,
  };
}

export function design(value: unknown): AllChatsDesign | undefined {
  return value === "quiet" || value === "age" || value === "project" ? value : undefined;
}

function rowsOf(page: AllChatsPage | undefined): AllChatsRow[] {
  if (!page || !Array.isArray(page.chats)) return [];
  return page.chats.filter((row) => row && typeof row.key === "string" && typeof row.harness === "string");
}

/// A first page read again (a push from the chat index) over the loaded rows: its rows lead, and
/// the loaded rows it does not name keep their order below (they are older than all of it).
export function mergeFirstPage(fresh: AllChatsRow[], rows: AllChatsRow[]): AllChatsRow[] {
  const named = new Set(fresh.map((row) => row.key));
  return [...fresh, ...rows.filter((row) => !named.has(row.key))];
}

/// A project of the Projects view: the chats of one folder (`cwd` unset: chats in no project).
export type ChatProject = { key: string; cwd?: string; label?: string; rows: AllChatsRow[] };

/// The loaded chats by folder, each project where its newest chat stands (the rows come newest
/// first), its chats in their own order.
export function projectGroups(rows: AllChatsRow[]): ChatProject[] {
  const groups = new Map<string, ChatProject>();
  for (const row of rows) {
    const key = row.cwd ?? "";
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        rows: [],
        ...(row.cwd ? { cwd: row.cwd, label: row.cwd.split("/").filter(Boolean).pop() || row.cwd } : {}),
      };
      groups.set(key, group);
    }
    group.rows.push(row);
  }
  return [...groups.values()];
}

/// The pages of one query: a new query starts over at the first page (its old cursor is dropped
/// at once, so no page of the old query is asked for again); a reply for an older query is
/// dropped (latest wins). `load` may change identity on every parent render: the list keeps the
/// latest one in a ref, so a parent render never restarts the list.
export function useChatPages(load: LoadChatsPage) {
  const [state, setState] = useState<State>(initialState);
  // Rows from the settled first page: the mount reads only a change pushed since (see below).
  const [seeded] = useState(() => state.loaded);
  // A list drawn from a saved first page that mounts to a changed index takes that first read
  // whole: a chat deleted or archived since must not stay listed (merging keeps every row the
  // fresh page does not name). Pages read past the saved one meanwhile stay; only saved rows go.
  const replaceSaved = useRef(false);
  const [savedKeys] = useState(() => new Set(state.rows.map((row) => row.key)));
  const pagedPastSaved = useRef(false);
  const latestLoad = useRef(load);
  latestLoad.current = load;
  const generation = useRef(0);
  const inFlight = useRef<string | undefined>(undefined);
  const fetchPage = useCallback((query: string, cursor: string | undefined) => {
    const ticket = cursor ? generation.current : ++generation.current;
    const marker = `${ticket}:${cursor ?? ""}`;
    if (inFlight.current === marker) return;
    inFlight.current = marker;
    const atPush = devicePushCount();
    setState((s) =>
      cursor
        ? { ...s, loading: true, failedCursor: undefined }
        : { ...s, query, nextCursor: undefined, loading: true, failedCursor: undefined },
    );
    void latestLoad
      .current({ ...(query ? { query } : {}), ...(cursor ? { cursor } : {}), limit: PAGE })
      .catch(() => undefined)
      .then((page) => {
        if (ticket !== generation.current) return;
        if (inFlight.current === marker) inFlight.current = undefined;
        setState((s) => {
          // A failed page keeps the cursor. The loader may still be in view, so the row exposes Retry.
          if (!page)
            return {
              ...s,
              loading: false,
              loaded: true,
              ...(cursor
                ? { nextCursor: cursor, failedCursor: cursor }
                : { failed: true, rows: s.rowsQuery === query ? s.rows : [], nextCursor: undefined }),
            };
          const fresh = rowsOf(page);
          const nextCursor = page.nextCursor && fresh.length > 0 ? page.nextCursor : undefined;
          if (!cursor && !query)
            rememberChats(
              {
                rows: fresh,
                ready: page.ready !== false,
                ...(nextCursor ? { nextCursor } : {}),
                ...(design(page.design) ? { design: design(page.design) } : {}),
              },
              atPush,
            );
          if (cursor) pagedPastSaved.current = true;
          else replaceSaved.current = false;
          const known = new Set(s.rows.map((row) => row.key));
          const rows = cursor ? [...s.rows, ...fresh.filter((row) => !known.has(row.key))] : fresh;
          return {
            ...s,
            rows,
            nextCursor,
            loading: false,
            loaded: true,
            ready: page.ready !== false,
            failed: false,
            failedCursor: undefined,
            rowsQuery: query,
            design: design(page.design) ?? s.design,
          };
        });
      });
  }, []);
  // A loaded list reads its first page again when the index pushes a change and puts it on top of
  // its rows, keeping the later pages and the cursor (cx-heu). One read at a time: a push during
  // one reads once more after it. A query's list, or a new query meanwhile, is left alone.
  const refreshing = useRef<"idle" | "busy" | "again">("idle");
  const refreshFirstPage = useCallback(() => {
    if (refreshing.current !== "idle") {
      refreshing.current = "again";
      return;
    }
    refreshing.current = "busy";
    const ticket = generation.current;
    const atPush = devicePushCount();
    void latestLoad
      .current({ limit: PAGE })
      .catch(() => undefined)
      .then((page) => {
        if (page) {
          const fresh = rowsOf(page);
          const nextCursor = page.nextCursor && fresh.length > 0 ? page.nextCursor : undefined;
          rememberChats(
            {
              rows: fresh,
              ready: page.ready !== false,
              ...(nextCursor ? { nextCursor } : {}),
              ...(design(page.design) ? { design: design(page.design) } : {}),
            },
            atPush,
          );
        }
        if (page && ticket === generation.current) {
          const replace = replaceSaved.current;
          replaceSaved.current = false;
          setState((s) => {
            if (s.query) return s;
            const fresh = rowsOf(page);
            if (replace && !pagedPastSaved.current) {
              const nextCursor = page.nextCursor && fresh.length > 0 ? page.nextCursor : undefined;
              return { ...s, rows: fresh, nextCursor, ready: page.ready !== false };
            }
            // An index-ready first page without a cursor is the whole list: rows omitted from it
            // were deleted or archived. A paged first page cannot distinguish those from rows
            // that merely moved to a later page, so retain older fetched rows in that case.
            const complete = page.ready !== false && !page.nextCursor;
            const named = new Set(fresh.map((row) => row.key));
            const rows = complete
              ? fresh
              : mergeFirstPage(
                  fresh,
                  replace ? s.rows.filter((row) => !savedKeys.has(row.key) || named.has(row.key)) : s.rows,
                );
            // Most pushes change nothing on the first page: the list keeps its rows (no re-render).
            const same =
              rows.length === s.rows.length &&
              rows.every(
                (row, i) =>
                  row === s.rows[i] ||
                  (row.key === s.rows[i]?.key &&
                    row.updatedAt === s.rows[i]?.updatedAt &&
                    row.title === s.rows[i]?.title &&
                    row.cwd === s.rows[i]?.cwd),
              ) &&
              (!complete || (s.nextCursor === undefined && s.ready));
            return same ? s : { ...s, rows, ...(complete ? { nextCursor: undefined, ready: true } : {}) };
          });
        }
        const again = refreshing.current === "again";
        refreshing.current = "idle";
        if (again) refreshFirstPage();
      });
  }, [savedKeys]);
  // The first page when the list mounts. A list that drew the settled first page (a workspace
  // closed or opened and its page mounted again) reads it only for a change the chat index pushed
  // since; a later push reads it as on any loaded list (Leo 2026-10-18: the list emptied and refilled).
  useEffect(() => {
    if (!seeded) fetchPage("", undefined);
    else if (chatsChangedSinceSettled()) {
      replaceSaved.current = true;
      refreshFirstPage();
    }
  }, [seeded, fetchPage, refreshFirstPage]);
  // A page opened before the chat index finished its first scan (`ready: false`, or no rows yet)
  // reads its first page from the start when the host pushes the index's chats (cx-ztlw: the first
  // Cmd-T page stayed empty for good); a loaded one refreshes it. A search is left alone.
  const latest = useRef(state);
  latest.current = state;
  useEffect(
    () =>
      subscribeDeviceChats(() => {
        const current = latest.current;
        if (current.query) return;
        if (!current.ready || current.rows.length === 0) fetchPage("", undefined);
        else refreshFirstPage();
      }),
    [fetchPage, refreshFirstPage],
  );
  return { state, fetchPage };
}

/** A chat-open request keeps its originating row through host acceptance or refusal.
 * One click creates one request; a late refusal cannot overwrite a newer row's status.
 * A bulk History open reports failure without offering an unsafe all-rows replay.
 */
export function useChatOpenFeedback(onOpen: (key: string) => unknown, onBring?: (keys: string[]) => unknown) {
  const t = useT();
  const [opening, setOpening] = useState<string>();
  const [failure, setFailure] = useState<{ key?: string; message: string }>();
  const pending = useRef(new Set<string>());
  const newest = useRef(0);
  const message = (error: unknown) => errorMessage(error) || t("transport.refused");
  const open = (key: string) => {
    if (pending.current.has(key)) return;
    pending.current.add(key);
    const ticket = ++newest.current;
    setOpening(key);
    setFailure(undefined);
    // The call begins on this person gesture; the host requires that for some actions.
    let request: unknown;
    try {
      request = onOpen(key);
    } catch (error) {
      request = Promise.reject(error);
    }
    void Promise.resolve(request).then(
      () => {
        pending.current.delete(key);
        if (ticket === newest.current) setOpening(undefined);
      },
      (error: unknown) => {
        pending.current.delete(key);
        if (ticket !== newest.current) return;
        setOpening(undefined);
        setFailure({ key, message: message(error) });
      },
    );
  };
  const bring = (keys: string[]) => {
    if (!onBring) return;
    const ticket = ++newest.current;
    setOpening(undefined);
    setFailure(undefined);
    let request: unknown;
    try {
      request = onBring(keys);
    } catch (error) {
      request = Promise.reject(error);
    }
    // Some rows in a multi-open may have succeeded. Report the refusal without replaying them.
    void Promise.resolve(request).catch((error: unknown) => {
      if (ticket === newest.current) setFailure({ message: message(error) });
    });
  };
  return { opening, failure, open, bring };
}

/// A chat acpmux can show without running it: Claude Code and Codex (acpmux `hub/watch.rs`).
export const watchable = (key: string) => /^(claude-code|codex):./.test(key);
