import * as Effect from "effect/Effect";
import {
  TypefullyDraftNotFoundError,
  typefullyWorkflowErrorCause,
  type TypefullyWorkflowError,
} from "./errors";
import {
  TypefullyDraftRepository,
  TypefullyDraftRepositoryLive,
  type TypefullyDraftInput,
  type TypefullyDraftRow,
} from "./repository";

export type TypefullyDraft = {
  readonly id: string;
  readonly title: string;
  readonly thread: readonly string[];
  readonly createdAt: string;
  readonly updatedAt: string;
};

export async function runTypefullyWorkflow<A>(
  program: Effect.Effect<A, TypefullyWorkflowError, TypefullyDraftRepository>,
): Promise<A> {
  try {
    return await Effect.runPromise(program.pipe(Effect.provide(TypefullyDraftRepositoryLive)));
  } catch (err) {
    throw typefullyWorkflowErrorCause(err) ?? err;
  }
}

export function listTypefullyDrafts(userId: string) {
  return Effect.gen(function* () {
    const repo = yield* TypefullyDraftRepository;
    const rows = yield* repo.listDrafts(userId);
    return rows.map(draftFromRow);
  });
}

export function createTypefullyDraft(input: {
  readonly userId: string;
  readonly userEmail: string;
  readonly draft: TypefullyDraftInput;
}) {
  return Effect.gen(function* () {
    const repo = yield* TypefullyDraftRepository;
    const normalized = normalizeDraftInput(input.draft);
    const row = yield* repo.createDraft({
      userId: input.userId,
      userEmail: input.userEmail,
      title: normalized.title,
      thread: normalized.thread,
    });
    return draftFromRow(row);
  });
}

export function updateTypefullyDraft(input: {
  readonly id: string;
  readonly userId: string;
  readonly draft: TypefullyDraftInput;
}) {
  return Effect.gen(function* () {
    const repo = yield* TypefullyDraftRepository;
    const normalized = normalizeDraftInput(input.draft);
    const row = yield* repo.updateDraft({
      id: input.id,
      userId: input.userId,
      title: normalized.title,
      thread: normalized.thread,
    });
    if (!row) {
      return yield* Effect.fail(new TypefullyDraftNotFoundError({ draftId: input.id }));
    }
    return draftFromRow(row);
  });
}

export function archiveTypefullyDraft(input: {
  readonly id: string;
  readonly userId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* TypefullyDraftRepository;
    const archived = yield* repo.archiveDraft(input);
    if (!archived) {
      return yield* Effect.fail(new TypefullyDraftNotFoundError({ draftId: input.id }));
    }
  });
}

export function normalizeDraftInput(input: TypefullyDraftInput): TypefullyDraftInput {
  const title = input.title.trim().slice(0, 180) || "Untitled draft";
  const thread = input.thread
    .map((part) => part.replace(/\r\n/g, "\n").trimEnd().slice(0, 8000))
    .filter((part, index) => index === 0 || part.trim().length > 0)
    .slice(0, 50);

  return {
    title,
    thread: thread.length > 0 ? thread : [""],
  };
}

function draftFromRow(row: TypefullyDraftRow): TypefullyDraft {
  return {
    id: row.id,
    title: row.title,
    thread: row.thread,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}
