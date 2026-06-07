import { and, desc, eq } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import { typefullyDrafts } from "../../db/schema";
import { TypefullyDatabaseError } from "./errors";

export type TypefullyDraftRow = typeof typefullyDrafts.$inferSelect;
export type TypefullyDraftStatus = TypefullyDraftRow["status"];

export type TypefullyDraftInput = {
  readonly title: string;
  readonly thread: readonly string[];
};

export type TypefullyDraftRepositoryShape = {
  readonly listDrafts: (userId: string) => Effect.Effect<TypefullyDraftRow[], TypefullyDatabaseError>;
  readonly createDraft: (input: {
    readonly userId: string;
    readonly userEmail: string;
    readonly title: string;
    readonly thread: readonly string[];
  }) => Effect.Effect<TypefullyDraftRow, TypefullyDatabaseError>;
  readonly updateDraft: (input: {
    readonly id: string;
    readonly userId: string;
    readonly title: string;
    readonly thread: readonly string[];
  }) => Effect.Effect<TypefullyDraftRow | null, TypefullyDatabaseError>;
  readonly archiveDraft: (input: {
    readonly id: string;
    readonly userId: string;
  }) => Effect.Effect<boolean, TypefullyDatabaseError>;
};

export class TypefullyDraftRepository extends Context.Tag("cmux/TypefullyDraftRepository")<
  TypefullyDraftRepository,
  TypefullyDraftRepositoryShape
>() {}

function dbEffect<A>(
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, TypefullyDatabaseError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new TypefullyDatabaseError({ operation, cause }),
  });
}

export const TypefullyDraftRepositoryLive = Layer.succeed(TypefullyDraftRepository, {
  listDrafts: (userId) =>
    dbEffect("listDrafts", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(typefullyDrafts)
        .where(and(eq(typefullyDrafts.userId, userId), eq(typefullyDrafts.status, "draft")))
        .orderBy(desc(typefullyDrafts.updatedAt));
    }),

  createDraft: (input) =>
    dbEffect("createDraft", async () => {
      const db = cloudDb();
      const [draft] = await db
        .insert(typefullyDrafts)
        .values({
          userId: input.userId,
          userEmail: input.userEmail,
          title: input.title,
          thread: [...input.thread],
        })
        .returning();
      if (!draft) {
        throw new Error("insert did not return a draft row");
      }
      return draft;
    }),

  updateDraft: (input) =>
    dbEffect("updateDraft", async () => {
      const db = cloudDb();
      const [draft] = await db
        .update(typefullyDrafts)
        .set({
          title: input.title,
          thread: [...input.thread],
          updatedAt: new Date(),
        })
        .where(and(eq(typefullyDrafts.id, input.id), eq(typefullyDrafts.userId, input.userId)))
        .returning();
      return draft ?? null;
    }),

  archiveDraft: (input) =>
    dbEffect("archiveDraft", async () => {
      const db = cloudDb();
      const [draft] = await db
        .update(typefullyDrafts)
        .set({
          status: "archived",
          updatedAt: new Date(),
        })
        .where(and(eq(typefullyDrafts.id, input.id), eq(typefullyDrafts.userId, input.userId)))
        .returning({ id: typefullyDrafts.id });
      return Boolean(draft);
    }),
});
