# Dashboard SPA

Every `/dashboard/*` URL renders `app/[locale]/dashboard/[[...path]]/page.tsx`,
which mounts `DashboardApp`. TanStack Router owns routing and TanStack Query
owns data. Next only serves the shell, the API routes, and
`/dashboard/billing/success` (a server page that retrieves the Stripe session).

## Layout

- `app.tsx` mounts the router client-side; `router.tsx` registers the router
  type, so every `Link`, `navigate`, `params`, and `search` is checked.
- `routes/root.tsx`: `rootRoute` and `shellRoute`. The shell's `beforeLoad`
  loads the session through `orpc.dashboard.session`; `UNAUTHORIZED` goes to
  sign-in with a return URL, `UNAVAILABLE` renders recovery. Child routes read
  it with `shellRoute.useRouteContext()`.
- `routes/<section>.tsx`: one file per section, exporting a route array that
  `route-tree.tsx` spreads under the shell.
- `screens/<section>/`: screen components, loaded with `lazyRouteComponent`.
- `queries/<section>.ts`: thin wrappers over `orpc.<section>.*.queryOptions`
  and `mutationOptions` (query keys, invalidation, optimistic updates).
- `lib/`: flat string search params, basepath, locale hrefs,
  `useDashboardUrl`.
- Server side: `web/orpc/server/<section>/` holds the procedures; they call the
  same `web/services/*` functions as the REST routes.

## Rules

- Paths keep their public form: routes use `/dashboard/...` and the router
  basepath is only the locale prefix (`""` for English, `/ja` for Japanese).
- Search params are flat strings (`?team=`, `?billing=error`). Declare them
  with `validateSearch: z.object({...})` on the route; `team` is inherited from
  the shell.
- Data is end-to-end typed through oRPC. Every dashboard read and write is a
  procedure in `web/orpc/server/router.ts`; the client uses the
  `@orpc/tanstack-query` utils from `web/orpc/query.ts`, so input, output,
  and error types come from the server. No `fetch()`, no response casts, and
  no hand-written response schemas in `dashboard-app/` (enforced by ESLint).
- Every procedure declares `.input()` and `.output()` zod schemas and its
  known refusals with `.errors()` (`UNAUTHORIZED`, `FORBIDDEN`, `NOT_FOUND`,
  `SEAT_LIMIT`, ...). Screens branch on typed error codes.
- Auth: `requireAuth` for every dashboard procedure; team procedures add the
  `teamAccess` middleware, which reads `teamId` from input, runs
  `requireTeamAccess`, and puts role and permissions in context. Any
  `UNAUTHORIZED` from any query sends the visitor to sign-in. The Next page
  that mounts the SPA also checks the session before it sends HTML.
- Account settings (profile, emails, password, sessions, API keys) are oRPC
  procedures too, so they prefetch like other routes. Browser ceremonies the
  SDK must run client-side (passkey/WebAuthn, OAuth connect, OTP setup) stay on
  the Hexclave client SDK and invalidate the oRPC queries when they finish.
- Native clients (macOS, iOS, CLI) keep their REST routes as thin adapters
  over the same services; do not break their paths or shapes.
- Loading: the Next page prefetches the first route's queries on the server
  and dehydrates them, so a full load shows real data. Navigation preloads on
  hover (`defaultPreload: "intent"`). Each route has a `pendingComponent` that
  matches its final layout, shown after `pendingMs`. Paging and filters keep
  previous data; team edits, invites, and revokes update optimistically.
- Mutations use `mutationOptions` and invalidate the affected query keys.
  There is no `router.refresh()`.
- Links inside the SPA use `Link` from `@tanstack/react-router` with a typed
  `to`. Links that leave the SPA (`/api/billing/checkout`, `/pricing`,
  `/handler/...`) are plain `<a href>` with `localeHref` when locale matters.
- Server-only values (Stripe, S3, ASC, tokens, feature flags) stay behind API
  routes, which return only what the screen shows.
- Strings use `next-intl` `useTranslations`; the global provider already
  carries every dashboard namespace.
