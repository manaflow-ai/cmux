"use client";

import { useMemo, useState } from "react";
import type React from "react";
import Link from "next/link";
import type { TypefullyDraft } from "../../services/typefully/workflows";

type EditableDraft = {
  readonly id: string | null;
  readonly title: string;
  readonly thread: readonly string[];
  readonly createdAt: string | null;
  readonly updatedAt: string | null;
};

type SaveState =
  | { readonly kind: "idle"; readonly message: string }
  | { readonly kind: "saving"; readonly message: string }
  | { readonly kind: "error"; readonly message: string };

const emptyDraft: EditableDraft = {
  id: null,
  title: "Untitled draft",
  thread: [""],
  createdAt: null,
  updatedAt: null,
};

export function TypefullyApp({
  initialDrafts,
  userEmail,
  signOutHref,
}: {
  initialDrafts: readonly TypefullyDraft[];
  userEmail: string;
  signOutHref: string;
}) {
  const [drafts, setDrafts] = useState<readonly TypefullyDraft[]>(initialDrafts);
  const [activeId, setActiveId] = useState<string | null>(initialDrafts[0]?.id ?? null);
  const [draft, setDraft] = useState<EditableDraft>(
    initialDrafts[0] ? editableFromDraft(initialDrafts[0]) : emptyDraft,
  );
  const [saveState, setSaveState] = useState<SaveState>({
    kind: "idle",
    message: initialDrafts[0] ? "Ready" : "New draft",
  });

  const totalCharacters = useMemo(
    () => draft.thread.reduce((total, part) => total + characterCount(part), 0),
    [draft.thread],
  );
  const hasExistingDraft = draft.id !== null;

  function selectDraft(next: TypefullyDraft) {
    setActiveId(next.id);
    setDraft(editableFromDraft(next));
    setSaveState({ kind: "idle", message: "Ready" });
  }

  function newDraft() {
    setActiveId(null);
    setDraft(emptyDraft);
    setSaveState({ kind: "idle", message: "New draft" });
  }

  function updateTitle(title: string) {
    updateDraft({ title });
  }

  function updateThreadPart(index: number, value: string) {
    const thread = draft.thread.map((part, partIndex) =>
      partIndex === index ? value : part
    );
    updateDraft({ thread });
  }

  function addThreadPart() {
    updateDraft({ thread: [...draft.thread, ""] });
  }

  function removeThreadPart(index: number) {
    if (draft.thread.length <= 1) return;
    updateDraft({ thread: draft.thread.filter((_, partIndex) => partIndex !== index) });
  }

  function splitFirstPost() {
    const split = draft.thread
      .join("\n\n")
      .split(/\n{2,}/)
      .map((part) => part.trim())
      .filter(Boolean);
    updateDraft({ thread: split.length > 0 ? split : [""] });
  }

  function updateDraft(patch: Partial<EditableDraft>) {
    const next = { ...draft, ...patch };
    setDraft(next);
    if (next.id) {
      setDrafts((currentDrafts) =>
        currentDrafts.map((candidate) =>
          candidate.id === next.id
            ? {
                ...candidate,
                title: next.title,
                thread: next.thread,
                updatedAt: new Date().toISOString(),
              }
            : candidate
        )
      );
    }
    setSaveState({ kind: "idle", message: "Unsaved" });
  }

  async function saveDraft() {
    setSaveState({ kind: "saving", message: "Saving" });
    const payload = {
      title: draft.title,
      thread: draft.thread,
    };
    const path = draft.id
      ? `/api/typefully/drafts/${encodeURIComponent(draft.id)}`
      : "/api/typefully/drafts";
    const method = draft.id ? "PATCH" : "POST";

    try {
      const response = await fetch(path, {
        method,
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      const body = await response.json() as { draft?: TypefullyDraft; message?: string };
      if (!response.ok || !body.draft) {
        throw new Error(body.message ?? "Draft save failed");
      }
      const savedDraft = body.draft;
      setDraft(editableFromDraft(savedDraft));
      setActiveId(savedDraft.id);
      setDrafts((currentDrafts) => upsertDraft(currentDrafts, savedDraft));
      setSaveState({ kind: "idle", message: "Saved" });
    } catch (err) {
      setSaveState({
        kind: "error",
        message: err instanceof Error ? err.message : "Draft save failed",
      });
    }
  }

  async function deleteDraft() {
    if (!draft.id) {
      newDraft();
      return;
    }

    setSaveState({ kind: "saving", message: "Deleting" });
    try {
      const response = await fetch(`/api/typefully/drafts/${encodeURIComponent(draft.id)}`, {
        method: "DELETE",
      });
      if (!response.ok) {
        const body = await response.json() as { message?: string };
        throw new Error(body.message ?? "Delete failed");
      }
      const remaining = drafts.filter((candidate) => candidate.id !== draft.id);
      setDrafts(remaining);
      const next = remaining[0] ? editableFromDraft(remaining[0]) : emptyDraft;
      setActiveId(next.id);
      setDraft(next);
      setSaveState({ kind: "idle", message: remaining[0] ? "Deleted" : "New draft" });
    } catch (err) {
      setSaveState({
        kind: "error",
        message: err instanceof Error ? err.message : "Delete failed",
      });
    }
  }

  function handleKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
      event.preventDefault();
      void saveDraft();
    }
  }

  return (
    <main
      className="flex min-h-screen flex-col bg-[#f6f7f8] text-[#191a1d]"
      onKeyDown={handleKeyDown}
    >
      <header className="flex min-h-14 flex-wrap items-center justify-between gap-3 border-b border-[#d9dde3] bg-white px-4 py-3">
        <div className="flex min-w-0 items-center gap-3">
          <div className="flex h-8 w-8 shrink-0 items-center justify-center border border-[#191a1d] bg-[#191a1d] text-sm font-semibold text-white">
            M
          </div>
          <div className="min-w-0">
            <h1 className="truncate text-sm font-semibold">Manaflow Drafts</h1>
            <p className="truncate text-xs text-[#69707d]">{userEmail}</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <span className={statusClass(saveState.kind)}>{saveState.message}</span>
          <button
            type="button"
            onClick={newDraft}
            className="h-9 border border-[#c8ced8] bg-white px-3 text-sm font-medium hover:bg-[#eef1f5]"
          >
            New
          </button>
          <button
            type="button"
            onClick={() => void saveDraft()}
            disabled={saveState.kind === "saving"}
            className="h-9 border border-[#1f6f5b] bg-[#1f6f5b] px-3 text-sm font-medium text-white hover:bg-[#185a49] disabled:cursor-not-allowed disabled:opacity-60"
          >
            Save
          </button>
          <Link
            href={signOutHref}
            className="inline-flex h-9 items-center border border-[#c8ced8] bg-white px-3 text-sm font-medium hover:bg-[#eef1f5]"
          >
            Sign out
          </Link>
        </div>
      </header>

      <div className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[280px_minmax(0,1fr)_320px]">
        <aside className="min-h-0 border-b border-[#d9dde3] bg-white lg:border-b-0 lg:border-r">
          <div className="flex h-12 items-center justify-between border-b border-[#e3e6eb] px-4">
            <p className="text-xs font-medium uppercase text-[#69707d]">Drafts</p>
            <p className="text-xs tabular-nums text-[#69707d]">{drafts.length}</p>
          </div>
          <div className="max-h-72 overflow-y-auto lg:max-h-[calc(100vh-6.5rem)]">
            {drafts.length === 0 ? (
              <div className="px-4 py-6 text-sm text-[#69707d]">No saved drafts</div>
            ) : (
              drafts.map((candidate) => (
                <button
                  key={candidate.id}
                  type="button"
                  onClick={() => selectDraft(candidate)}
                  className={`block w-full border-b border-[#edf0f3] px-4 py-3 text-left hover:bg-[#f2f4f7] ${
                    activeId === candidate.id ? "bg-[#edf7f3]" : "bg-white"
                  }`}
                >
                  <span className="block truncate text-sm font-medium">
                    {candidate.title}
                  </span>
                  <span className="mt-1 block truncate text-xs text-[#69707d]">
                    {candidate.thread[0] || "Empty draft"}
                  </span>
                  <span className="mt-2 block text-[11px] text-[#8a919d]">
                    {formatDate(candidate.updatedAt)}
                  </span>
                </button>
              ))
            )}
          </div>
        </aside>

        <section className="min-h-0 overflow-y-auto bg-[#f6f7f8] px-4 py-4 lg:max-h-[calc(100vh-3.5rem)]">
          <div className="mx-auto flex w-full max-w-3xl flex-col gap-3">
            <input
              value={draft.title}
              onChange={(event) => updateTitle(event.target.value)}
              className="h-12 w-full border border-[#c8ced8] bg-white px-3 text-lg font-semibold outline-none focus:border-[#1f6f5b] focus:ring-2 focus:ring-[#1f6f5b]/20"
              placeholder="Draft title"
            />

            <div className="flex flex-wrap items-center justify-between gap-2 border border-[#d9dde3] bg-white px-3 py-2">
              <div className="flex items-center gap-3 text-xs text-[#69707d]">
                <span>{draft.thread.length} posts</span>
                <span>{totalCharacters} chars</span>
                {draft.updatedAt ? <span>{formatDate(draft.updatedAt)}</span> : null}
              </div>
              <div className="flex gap-2">
                <button
                  type="button"
                  onClick={splitFirstPost}
                  className="h-8 border border-[#c8ced8] bg-white px-2 text-xs font-medium hover:bg-[#eef1f5]"
                >
                  Split
                </button>
                <button
                  type="button"
                  onClick={addThreadPart}
                  className="h-8 border border-[#c8ced8] bg-white px-2 text-xs font-medium hover:bg-[#eef1f5]"
                >
                  Add post
                </button>
              </div>
            </div>

            {draft.thread.map((part, index) => {
              const count = characterCount(part);
              return (
                <div
                  key={`${draft.id ?? "new"}-${index}`}
                  className="border border-[#d9dde3] bg-white"
                >
                  <div className="flex min-h-10 items-center justify-between border-b border-[#edf0f3] px-3">
                    <div className="flex items-center gap-2 text-xs text-[#69707d]">
                      <span className="font-mono tabular-nums">{index + 1}</span>
                      <span className={count > 280 ? "text-[#b42318]" : ""}>
                        {count}/280
                      </span>
                    </div>
                    <button
                      type="button"
                      onClick={() => removeThreadPart(index)}
                      disabled={draft.thread.length <= 1}
                      className="h-7 border border-transparent px-2 text-xs text-[#69707d] hover:border-[#d9dde3] hover:text-[#191a1d] disabled:cursor-not-allowed disabled:opacity-40"
                    >
                      Remove
                    </button>
                  </div>
                  <textarea
                    value={part}
                    onChange={(event) => updateThreadPart(index, event.target.value)}
                    className="min-h-44 w-full resize-y bg-white px-3 py-3 text-[15px] leading-7 outline-none"
                    placeholder="Write a post"
                  />
                </div>
              );
            })}

            <div className="flex flex-wrap justify-between gap-2 pb-8">
              <button
                type="button"
                onClick={() => void deleteDraft()}
                className="h-9 border border-[#d92d20] bg-white px-3 text-sm font-medium text-[#b42318] hover:bg-[#fff1f0]"
              >
                {hasExistingDraft ? "Delete" : "Clear"}
              </button>
              <button
                type="button"
                onClick={() => void saveDraft()}
                disabled={saveState.kind === "saving"}
                className="h-9 border border-[#1f6f5b] bg-[#1f6f5b] px-4 text-sm font-medium text-white hover:bg-[#185a49] disabled:cursor-not-allowed disabled:opacity-60"
              >
                Save draft
              </button>
            </div>
          </div>
        </section>

        <aside className="min-h-0 border-t border-[#d9dde3] bg-white lg:max-h-[calc(100vh-3.5rem)] lg:overflow-y-auto lg:border-l lg:border-t-0">
          <div className="flex h-12 items-center justify-between border-b border-[#e3e6eb] px-4">
            <p className="text-xs font-medium uppercase text-[#69707d]">Preview</p>
            <p className="text-xs tabular-nums text-[#69707d]">{totalCharacters}</p>
          </div>
          <div className="space-y-3 p-4">
            {draft.thread.map((part, index) => (
              <article
                key={`preview-${index}`}
                className="border border-[#d9dde3] bg-[#fbfcfd] p-3"
              >
                <div className="mb-2 flex items-center justify-between gap-2 text-xs text-[#69707d]">
                  <span>Post {index + 1}</span>
                  <span className={characterCount(part) > 280 ? "text-[#b42318]" : ""}>
                    {characterCount(part)}
                  </span>
                </div>
                <p className="whitespace-pre-wrap break-words text-sm leading-6">
                  {part || "Empty post"}
                </p>
              </article>
            ))}
          </div>
        </aside>
      </div>
    </main>
  );
}

function editableFromDraft(draft: TypefullyDraft): EditableDraft {
  return {
    id: draft.id,
    title: draft.title,
    thread: draft.thread.length > 0 ? draft.thread : [""],
    createdAt: draft.createdAt,
    updatedAt: draft.updatedAt,
  };
}

function upsertDraft(
  drafts: readonly TypefullyDraft[],
  draft: TypefullyDraft,
): readonly TypefullyDraft[] {
  const existingIndex = drafts.findIndex((candidate) => candidate.id === draft.id);
  if (existingIndex === -1) {
    return [draft, ...drafts];
  }
  return drafts.map((candidate) => candidate.id === draft.id ? draft : candidate);
}

function characterCount(value: string): number {
  return Array.from(value).length;
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat("en", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(value));
}

function statusClass(kind: SaveState["kind"]): string {
  const base = "hidden h-7 items-center border px-2 text-xs sm:inline-flex";
  switch (kind) {
    case "saving":
      return `${base} border-[#c8ced8] bg-[#eef1f5] text-[#4f5663]`;
    case "error":
      return `${base} border-[#fecdca] bg-[#fff1f0] text-[#b42318]`;
    case "idle":
      return `${base} border-[#c8eadf] bg-[#edf7f3] text-[#1f6f5b]`;
  }
}
