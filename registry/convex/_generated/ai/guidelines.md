# Convex guidelines

These guidelines target Convex `^1.44.0`.

## Function guidelines

### Http endpoint syntax

- HTTP endpoints are defined in `convex/http.ts` and require an `httpAction` decorator. For example:

```typescript
import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
const http = httpRouter();
http.route({
  path: "/echo",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const body = await req.bytes();
    return new Response(body, { status: 200 });
  }),
});
```

- Treat the result of `await req.json()` as `unknown` - narrow each field (e.g. `typeof` checks) before use, and return a 400 response for bodies that fail validation.
- HTTP endpoints are always registered at the exact path you specify in the `path` field. For example, if you specify `/api/someRoute`, the endpoint will be registered at `/api/someRoute`.

### Validators

- Below is an example of an array validator:

```typescript
import { mutation } from "./_generated/server";
import { v } from "convex/values";

export default mutation({
  args: {
    simpleArray: v.array(v.union(v.string(), v.number())),
  },
  handler: async (ctx, args) => {
    //...
  },
});
```

- `v.object(...)` validators compose: `.pick("a", "b")`, `.omit("c")`, `.partial()`, and `.extend({ d: v.string() })` derive new object validators from an existing one - define a shape once and derive variants instead of duplicating fields. Use an object validator's `.fields` to supply function `args`.
- `schema.doc("tableName")` (import `schema` from `./schema`) returns the validator for a whole stored document: the table's validator with `_id` and `_creationTime` added, to every member for union tables. Use it when an `args` or `returns` validator needs a complete document instead of re-declaring the fields or the system fields; `docValidator("tableName", tableDefinition)` from `convex/server` builds the same from a bare table definition.
- Below is an example of a schema with validators that codify a discriminated union type:

```typescript
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  results: defineTable(
    v.union(
      v.object({
        kind: v.literal("error"),
        errorMessage: v.string(),
      }),
      v.object({
        kind: v.literal("success"),
        value: v.number(),
      }),
    ),
  ),
});
```

- Here are the valid Convex types along with their respective validators:
  | Convex Type | TS/JS type | Example Usage | Validator for argument validation and schemas | Notes |
  | ----------- | ----------- | -------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
  | Id | string | `doc._id` | `v.id(tableName)` | |
  | Null | null | `null` | `v.null()` | JavaScript's `undefined` is not a valid Convex value. Functions the return `undefined` or do not return will return `null` when called from a client. Use `null` instead. |
  | Int64 | bigint | `3n` | `v.int64()` | Int64s only support BigInts between -2^63 and 2^63-1. Convex supports `bigint`s in most modern browsers. |
  | Float64 | number | `3.1` | `v.number()` | Convex supports all IEEE-754 double-precision floating point numbers (such as NaNs). Inf and NaN are JSON serialized as strings. |
  | Boolean | boolean | `true` | `v.boolean()` |
  | String | string | `"abc"` | `v.string()` | Strings are stored as UTF-8 and must be valid Unicode sequences. Strings must be smaller than the 1MB total size limit when encoded as UTF-8. |
  | Bytes | ArrayBuffer | `new ArrayBuffer(8)` | `v.bytes()` | Convex supports first class bytestrings, passed in as `ArrayBuffer`s. Bytestrings must be smaller than the 1MB total size limit for Convex types. |
  | Array | Array | `[1, 3.2, "abc"]` | `v.array(values)` | Arrays can have at most 8192 values. |
  | Object | Object | `{a: "abc"}` | `v.object({property: value})` | Convex only supports "plain old JavaScript objects" (objects that do not have a custom prototype). Objects can have at most 1024 entries. Field names must be nonempty and not start with "$" or "\_". |

| Record | Record | `{"a": "1", "b": "2"}` | `v.record(keys, values)` | Records are objects at runtime, but can have dynamic keys. Keys must be only ASCII characters, nonempty, and not start with "$" or "\_". |

### Function registration

- Use `internalQuery`, `internalMutation`, and `internalAction` to register internal functions. These functions are private and aren't part of an app's API. They can only be called by other Convex functions. These functions are always imported from `./_generated/server`.
- Use `query`, `mutation`, and `action` to register public functions. These functions are part of the public API and are exposed to the public Internet. Do NOT use `query`, `mutation`, or `action` to register sensitive internal functions that should be kept private. A function invoked only by your own code - e.g. the mutation an HTTP action calls to commit its effects - is internal, not public.
- You CANNOT register a function through the `api` or `internal` objects.
- ALWAYS include argument validators for all Convex functions. This includes all of `query`, `internalQuery`, `mutation`, `internalMutation`, `action`, and `internalAction`.

### Function calling

- Use `ctx.runQuery` to call a query from a query, mutation, or action.
- Use `ctx.runMutation` to call a mutation from a mutation or action.
- Use `ctx.runAction` to call an action from an action.
- ONLY call an action from another action if you need to cross runtimes (e.g. from V8 to Node). Otherwise, pull out the shared code into a helper async function and call that directly instead.
- Try to use as few calls from actions to queries and mutations as possible. Queries and mutations are transactions, so splitting logic up into multiple calls introduces the risk of race conditions.
- All of these calls take in a `FunctionReference`. Do NOT try to pass the callee function directly into one of these calls.
- Nested `ctx.runQuery` and `ctx.runMutation` calls from a mutation execute as subtransactions. If a nested call throws, its writes roll back independently, so the caller can catch the error and continue with its own writes intact.
- In Convex 1.41+, `ctx.runQuery` and `ctx.runMutation` accept an optional third argument with `transactionLimits`. These limits cap how much the nested call may additionally consume on top of what the caller has already used - they can only tighten the global transaction limits, never raise them. If the nested call exceeds its cap and rolls back, the caller keeps its own remaining budget, which is useful for preserving caller headroom. For example:

```ts
try {
  await ctx.runMutation(internal.example.writeBatch, args, {
    transactionLimits: { documentsWritten: 100, bytesWritten: 1024 * 1024 },
  });
} catch (e) {
  // The nested mutation's writes rolled back; this mutation can still write.
}
```

The supported `transactionLimits` fields are `bytesRead`, `bytesWritten`, `databaseQueries`, `documentsRead`, `documentsWritten`, `functionsScheduled`, and `scheduledFunctionArgsBytes`.

- When using `ctx.runQuery`, `ctx.runMutation`, or `ctx.runAction` to call a function in the same file, specify a type annotation on the return value to work around TypeScript circularity limitations. For example,

```
export const f = query({
  args: { name: v.string() },
  handler: async (ctx, args) => {
    return "Hello " + args.name;
  },
});

export const g = query({
  args: {},
  handler: async (ctx, args) => {
    const result: string = await ctx.runQuery(api.example.f, { name: "Bob" });
    return null;
  },
});
```

### Function references

- Use the `api` object defined by the framework in `convex/_generated/api.ts` to call public functions registered with `query`, `mutation`, or `action`.
- Use the `internal` object defined by the framework in `convex/_generated/api.ts` to call internal (or private) functions registered with `internalQuery`, `internalMutation`, or `internalAction`.
- Convex uses file-based routing, so a public function defined in `convex/example.ts` named `f` has a function reference of `api.example.f`.
- A private function defined in `convex/example.ts` named `g` has a function reference of `internal.example.g`.
- Functions can also registered within directories nested within the `convex/` folder. For example, a public function `h` defined in `convex/messages/access.ts` has a function reference of `api.messages.access.h`.

### Pagination

- Define pagination using the following syntax:

```ts
import { v } from "convex/values";
import { query, mutation } from "./_generated/server";
import { paginationOptsValidator } from "convex/server";
export const listWithExtraArg = query({
  args: { paginationOpts: paginationOptsValidator, author: v.string() },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("messages")
      .withIndex("by_author", (q) => q.eq("author", args.author))
      .order("desc")
      .paginate(args.paginationOpts);
  },
});
```

Note: `paginationOpts` is an object with the following properties:

- `numItems`: the initial page-size target — not a guaranteed maximum under reactive pagination (the validator is `v.number()`)
- `cursor`: the cursor to use to fetch the next page of documents; required (the validator is `v.union(v.string(), v.null())`)
- `endCursor` (optional): bounds the page to end at a known cursor
- `maximumRowsRead` (optional): limits how many rows the query may scan before returning a partial page
- `maximumBytesRead` (optional): limits how many bytes the query may read before returning a partial page
- `id` (optional): client-managed pagination metadata accepted by `paginationOptsValidator`

Always validate pagination arguments with `paginationOptsValidator` and pass `args.paginationOpts` unchanged to `.paginate()` — do not reconstruct it field by field, or the optional fields lose their native behavior.

A query that ends in `.paginate()` returns an object that has the following properties:

- `page`: an array of the documents fetched for this page
- `isDone`: a boolean representing whether this is the last page of documents
- `continueCursor`: a string cursor to fetch the next page of documents
- `splitCursor` (optional, string or null) and `pageStatus` (optional, `"SplitRecommended"`, `"SplitRequired"`, or null): present when the page was cut short and should be split

For the return validator of a paginated query, use `paginationResultValidator(itemValidator)` from `convex/server` rather than reproducing this shape by hand.

## Schema guidelines

- Always define your schema in `convex/schema.ts`.
- Always import the schema definition functions from `convex/server`.
- System fields are automatically added to all documents and are prefixed with an underscore. The two system fields that are automatically added to all documents are `_creationTime` which has the validator `v.number()` and `_id` which has the validator `v.id(tableName)`.
- Always include all index fields in the index name. For example, if an index is defined as `["field1", "field2"]`, the index name should be "by_field1_and_field2".
- Index fields must be queried in the same order they are defined. If you want to be able to query by "field1" then "field2" and by "field2" then "field1", you must create separate indexes.
- Do not store unbounded lists as an array field inside a document (e.g. `v.array(v.object({...}))`). As the array grows it will hit the 1MB document size limit, and every update rewrites the entire document. Instead, create a separate table for the child items with a foreign key back to the parent.
- Separate high-churn operational data (e.g. heartbeats, online status, typing indicators) from stable profile data. Storing frequently updated fields on a shared document forces every write to contend with reads of the entire document. Instead, create a dedicated table for the high-churn data with a foreign key back to the parent record.

- Adding an index to a large existing table blocks the deploy until backfill completes. Declare it staged - `.index("by_field", { fields: ["field"], staged: true })` - to backfill asynchronously without blocking; a staged index cannot be queried until a later deploy removes the flag.

## Authentication guidelines

- Convex supports JWT-based authentication through `convex/auth.config.ts`. ALWAYS create this file when using authentication. Without it, `ctx.auth.getUserIdentity()` will always return `null`.
- Example `convex/auth.config.ts`:

```typescript
export default {
  providers: [
    {
      domain: "https://your-auth-provider.com",
      applicationID: "convex",
    },
  ],
};
```

The `domain` must be the issuer URL of the JWT provider. Convex fetches `{domain}/.well-known/openid-configuration` to discover the JWKS endpoint. The `applicationID` is checked against the JWT `aud` (audience) claim.

- Use `ctx.auth.getUserIdentity()` to get the authenticated user's identity in any query, mutation, or action. This returns `null` if the user is not authenticated, or a `UserIdentity` object with fields like `subject`, `issuer`, `name`, `email`, etc. The `subject` field is the unique user identifier.
- In Convex `UserIdentity`, `tokenIdentifier` is guaranteed and is the canonical stable identifier for the authenticated identity. For any auth-linked database lookup or ownership check, prefer `identity.tokenIdentifier` over `identity.subject`. Do NOT use `identity.subject` alone as a global identity key.
- NEVER accept a `userId` or any user identifier as a function argument for authorization purposes. Always derive the user identity server-side via `ctx.auth.getUserIdentity()`.
- When using an external auth provider with Convex on the client, use `ConvexProviderWithAuth` instead of `ConvexProvider`:

```tsx
import { ConvexProviderWithAuth, ConvexReactClient } from "convex/react";

const convex = new ConvexReactClient(process.env.NEXT_PUBLIC_CONVEX_URL!);

function App({ children }: { children: React.ReactNode }) {
  return (
    <ConvexProviderWithAuth client={convex} useAuth={useYourAuthHook}>
      {children}
    </ConvexProviderWithAuth>
  );
}
```

The `useAuth` prop must return `{ isLoading, isAuthenticated, fetchAccessToken }`. Do NOT use plain `ConvexProvider` when authentication is needed — it will not send tokens with requests.

## Typescript guidelines

- You can use the helper typescript type `Id` imported from './\_generated/dataModel' to get the type of the id for a given table. For example if there is a table called 'users' you can use `Id<'users'>` to get the type of the id for that table.
- Use `Doc<"tableName">` from `./_generated/dataModel` to get the full document type for a table.
- Use `QueryCtx`, `MutationCtx`, `ActionCtx` from `./_generated/server` for typing function contexts. NEVER use `any` for ctx parameters — always use the proper context type.
- If you need to define a `Record` make sure that you correctly provide the type of the key and value in the type. For example a validator `v.record(v.id('users'), v.string())` would have the type `Record<Id<'users'>, string>`. Below is an example of using `Record` with an `Id` type in a query:

```ts
import { query } from "./_generated/server";
import { Doc, Id } from "./_generated/dataModel";

export const exampleQuery = query({
  args: { userIds: v.array(v.id("users")) },
  handler: async (ctx, args) => {
    const idToUsername: Record<Id<"users">, string> = {};
    for (const userId of args.userIds) {
      const user = await ctx.db.get("users", userId);
      if (user) {
        idToUsername[user._id] = user.username;
      }
    }

    return idToUsername;
  },
});
```

- Be strict with types, particularly around id's of documents. For example, if a function takes in an id for a document in the 'users' table, take in `Id<'users'>` rather than `string`.
- For typed app environment variables, declare them in `convex/convex.config.ts` with `defineApp({ env: { MY_KEY: v.optional(v.string()) } })` and read them with `env` from `./_generated/server` instead of `process.env`. The platform-provided `CONVEX_SITE_URL` and `CONVEX_CLOUD_URL` are already on `env` as strings; never declare them in `convex.config.ts` (redeclaring them fails the deploy or breaks the generated `env` type).

## Full text search guidelines

- A query for "10 messages in channel '#general' that best match the query 'hello hi' in their body" would look like:

const messages = await ctx.db
.query("messages")
.withSearchIndex("search_body", (q) =>
q.search("body", "hello hi").eq("channel", "#general"),
)
.take(10);

## Vector search guidelines

- Store embeddings in a field validated with `v.array(v.float64())` and declare a vector index on it in the schema:

```ts
documents: defineTable({
  title: v.string(),
  category: v.string(),
  embedding: v.array(v.float64()),
}).vectorIndex("by_embedding", {
  vectorField: "embedding",
  dimensions: 1536,
  filterFields: ["category"],
}),
```

- `dimensions` must exactly match the length of the vectors you store and search with.
- `ctx.vectorSearch` is ONLY available in actions - not in queries or mutations:

```ts
const results = await ctx.vectorSearch("documents", "by_embedding", {
  vector: args.embedding,
  limit: 10,
  filter: (q) => q.eq("category", args.category),
});
```

- The vector search `filter` supports only equality on declared `filterFields` and `q.or(...)` - there is no AND across different fields and no inequality. Push what you can into the vector filter and apply any remaining predicates after hydration.
- Vector search returns only `{ _id, _score }` pairs ordered by descending similarity score - not full documents. Because actions have no `ctx.db`, hydrate the hits through an internal query, preserve the vector search's order, and pair each score with its document by ID.

## Component guidelines

- Convex components are installable building blocks (e.g. `@convex-dev/aggregate`, `@convex-dev/rate-limiter`) with their own isolated tables and functions. Install the npm package, then mount the component in `convex/convex.config.ts`:

```ts
import { defineApp } from "convex/server";
import aggregate from "@convex-dev/aggregate/convex.config"; // no .js suffix

const app = defineApp();
app.use(aggregate);
export default app;
```

- After mounting, the generated `components` object in `convex/_generated/api` references the component (e.g. `components.aggregate`), and is passed to the component's client class.
- Component functions are not exposed to clients; the app's own queries and mutations wrap them. Perform authentication and authorization in the app functions before calling into a component.
- Component reads and writes participate in the calling mutation's transaction. When a component mirrors state from one of your tables (like an aggregate over a table), update the component in the SAME mutation as every insert, patch, replace, or delete of that table - never from a separate function - so the two can never drift.
- To author a LOCAL component: a directory under `convex/` with its own `convex.config.ts` (`export default defineComponent("myName");` - the argument is the name string), its own `schema.ts`, and functions built from that directory's own `_generated/server`. Mount it from the root config (`app.use(myName)` - no options), and reference its functions through the generated `components` object INCLUDING the module segment: a function in `convex/myName/index.ts` is `components.myName.index.myFunction`, never `components.myName.myFunction`.
- For per-key quotas, cooldowns, or throttling (N operations per period, retry-after), use the `@convex-dev/rate-limiter` component - hand-rolled counter or window-scan implementations admit races under concurrency and lose quota when a mutation fails.
- For chat or assistant features where an LLM replies inside a durable conversation - per-user resumable histories, recorded tool-call steps, several assistants sharing one conversation - use the `@convex-dev/agent` component: mount it, create one component thread per conversation, and generate/read through it (`createThread(ctx, components.agent, ...)`, `new Agent(components.agent, { name, languageModel, tools }).generateText(ctx, { threadId }, { prompt })`, `listMessages`). Do not hand-roll a messages table or call an LLM SDK directly from your functions for these.
- For async Convex functions needing bounded parallelism, serialized mutation work, or completion callbacks, use `@convex-dev/workpool`; retry only idempotent actions.
- For ephemeral presence - who is online/viewing/typing in a room, tracked by client heartbeats with session tokens, multi-session aggregation (one entry per user across tabs), and timeout-to-offline - use the `@convex-dev/presence` component - hand-rolled lastSeen tables need wall-clock query filters that go stale, and per-session rows break the one-entry-per-user contract.
- Calling a component mutation is a subtransaction: if it throws and the caller catches the error, the component's writes roll back while the calling mutation continues and can still commit its own writes.
- To pass a function across a component boundary, mint a handle in the app: `const handle = await createFunctionHandle(internal.index.myCallback);` (from `convex/server`; async, takes only the function reference - `getFunctionHandle` and `getFunctionName` are not this API). Send it as a string; the receiver casts it back and invokes it: `await ctx.runMutation(args.handle as FunctionHandle<"mutation">, callbackArgs);`.

## Query guidelines

- Prefer `.withIndex()` and express every predicate supported by the index in its index range. A subsequent `.filter()` is acceptable for additional predicates that cannot be expressed by that index. Filtering happens after the index scan and does not reduce rows read, so it does not make an otherwise unbounded query scalable.
- Do not read the wall clock inside a query. Queries are not rerun merely because time advances, so results derived from `Date.now()` or a zero-argument `new Date()` can become stale, and wall-clock reads also reduce query-cache reuse. Instead, pass the current time in as an argument and let the client refresh it, or materialize time-based state with scheduled mutations that update a flag field. (`Date.now()` is fine in mutations and actions.)
- If the user does not explicitly tell you to return all results from a query you should ALWAYS return a bounded collection instead. So that is instead of using `.collect()` you should use `.take()` or paginate on database queries. This prevents future performance issues when tables grow in an unbounded way.
- Never use `.collect().length` to count rows. Convex has no built-in count operator. For a simple total, maintain a denormalized counter document updated in your mutations. When queries need aggregates over many rows - counts, sums, ranks/positions, or offset access, whole-table or within a key range - use the `@convex-dev/aggregate` component (O(log n) reads; keep it updated in the same mutation as every source-table write).
- Convex queries do NOT support `.delete()`. To delete all documents matching a query, read them (in `.take(n)` batches or via async iteration) and call `ctx.db.delete("tasks", row._id)` on each.
- Convex mutations are transactions with limits on the documents and bytes they read and write. If a mutation needs to process more documents than fit in a single transaction (e.g. bulk deletion on a large table), process one batch, then `await ctx.scheduler.runAfter(0, internal.myModule.myMutation, args)` to continue in a fresh transaction. A fixed `.take(n)` batch is the default when document sizes are uniform; when they vary, iterate with `for await (const row of query)` and after each write `await ctx.meta.getTransactionMetrics()`, scheduling the continuation and returning as soon as any needed `.remaining` metric (e.g. `metrics.bytesRead.remaining`) falls to a safety reserve.
- Use `.unique()` to get a single document from a query. This method will throw an error if there are multiple documents that match the query.
- When using async iteration, don't use `.collect()` or `.take(n)` on the result of a query. Instead, use the `for await (const row of query)` syntax.

### Ordering

- Queries default to ascending order over the selected index key. A plain table scan uses the built-in `by_creation_time` index, so it returns documents in ascending `_creationTime` order; a query using a custom index defaults to ascending order across that index's entire key.
- You can use `.order('asc')` or `.order('desc')` to pick whether a query is in ascending or descending order. If the order isn't specified, it defaults to ascending.
- Document queries that use indexes will be ordered based on the columns in the index and can avoid slow table scans.
- Convex appends `_creationTime` as the final column of every database index. An index on `["points"]` therefore orders by `points`, then `_creationTime`. `.order("desc")` reverses the entire index key, so rows with equal `points` come back newest first. Rely on this built-in tiebreak instead of re-sorting results in JavaScript.

## Mutation guidelines

- Use `ctx.db.replace` to fully replace an existing document. This method will throw an error if the document does not exist. Syntax: `await ctx.db.replace("tasks", taskId, { name: "Buy milk", completed: false })`
- Use `ctx.db.patch` to shallow merge updates into an existing document. This method will throw an error if the document does not exist. Syntax: `await ctx.db.patch("tasks", taskId, { completed: true })`

## Action guidelines

- Always add `"use node";` to the top of files containing actions that use Node.js built-in modules.
- Never add `"use node";` to a file that also exports queries or mutations. Only actions can run in the Node.js runtime; queries and mutations must stay in the default Convex runtime. If you need Node.js built-ins alongside queries or mutations, put the action in a separate file.
- `fetch()` is available in the default Convex runtime. You do NOT need `"use node";` just to use `fetch()`.
- Never use `ctx.db` inside of an action. Actions don't have access to the database.
- Below is an example of the syntax for an action:

```ts
import { action } from "./_generated/server";

export const exampleAction = action({
  args: {},
  handler: async (ctx, args) => {
    console.log("This action does not return anything");
    return null;
  },
});
```

## Scheduling guidelines

### Cron guidelines

- Only use the `crons.interval` or `crons.cron` methods to schedule cron jobs. Do NOT use the `crons.hourly`, `crons.daily`, or `crons.weekly` helpers.
- Both cron methods take in a FunctionReference. Do NOT try to pass the function directly into one of these methods.
- Define crons by declaring the top-level `crons` object, calling some methods on it, and then exporting it as default. For example,

```ts
import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";

const empty = internalAction({
  args: {},
  handler: async (ctx, args) => {
    console.log("empty");
  },
});

const crons = cronJobs();

// Run `internal.crons.empty` every two hours.
crons.interval("delete inactive users", { hours: 2 }, internal.crons.empty, {});

export default crons;
```

- You can register Convex functions within `crons.ts` just like any other file.
- If a cron calls an internal function, always import the `internal` object from '\_generated/api', even if the internal function is registered in the same file.

## Testing guidelines

- Use `convex-test` with `vitest` and `@edge-runtime/vm` to test Convex functions. Always install the latest versions of these packages. Configure vitest with `environment: "edge-runtime"` in `vitest.config.ts`.

Test files go inside the `convex/` directory. You must pass a module map from `import.meta.glob` to `convexTest`:

```typescript
/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "./_generated/api";
import schema from "./schema";

const modules = import.meta.glob("./**/*.ts");

test("some behavior", async () => {
  const t = convexTest(schema, modules);
  await t.mutation(api.messages.send, { body: "Hi!", author: "Sarah" });
  const messages = await t.query(api.messages.list);
  expect(messages).toMatchObject([{ body: "Hi!", author: "Sarah" }]);
});
```

The `modules` argument is required so convex-test can discover and load function files. The `/// <reference types="vite/client" />` directive is needed for TypeScript to recognize `import.meta.glob`.

- Only add the `/// <reference types="vite/client" />` directive at the top of test files that call `import.meta.glob`; do NOT add it to non-test files.
- Do NOT add a `compilerOptions.types` allowlist to `tsconfig.json` for type packages you have not installed (e.g. `"node"` without `@types/node`, or `"vite/client"` without vite). Any unresolved entry in `types` fails typechecking with TS2688. Leave `types` unset unless a package genuinely requires it and is installed.

## File storage guidelines

- The `ctx.storage.getUrl()` method returns a signed URL for a given file. It returns `null` if the file doesn't exist.
- Do NOT use the deprecated `ctx.storage.getMetadata` call for loading a file's metadata.

Instead, query the `_storage` system table. For example, you can use `ctx.db.system.get` to get an `Id<"_storage">`.

```
import { query } from "./_generated/server";
import { Id } from "./_generated/dataModel";

type FileMetadata = {
    _id: Id<"_storage">;
    _creationTime: number;
    contentType?: string;
    sha256: string;
    size: number;
}

export const exampleQuery = query({
    args: { fileId: v.id("_storage") },
    handler: async (ctx, args) => {
        const metadata: FileMetadata | null = await ctx.db.system.get("_storage", args.fileId);
        console.log(metadata);
        return null;
    },
});
```

- Convex storage stores items as `Blob` objects. You must convert all items to/from a `Blob` when using Convex storage.
