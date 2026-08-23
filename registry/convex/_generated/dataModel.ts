// Hand-written stand-in for `convex codegen` output: loose document types.
import type { GenericId } from "convex/values";

export type Id<TableName extends string> = GenericId<TableName>;
export type Doc<_TableName extends string> = any;
