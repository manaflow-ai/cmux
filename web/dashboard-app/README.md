# Dashboard SPA

Every `/dashboard/*` URL renders `app/[locale]/dashboard/[[...path]]/page.tsx`,
which mounts `DashboardApp`. TanStack Router owns routing and TanStack Query
owns data. Next only serves the shell, the API routes, and
`/dashboard/billing/success` (a server page that retrieves the Stripe session).

## Layout

- `app.tsx` mounts the router client-side; `router.tsx` registers the router
  type, so every `Link`, `navigate`, `params`, and `search` is checked.
- `routes/root.tsx`: `rootRoute` and `shellRoute`. The shell's `beforeLoad`
  loads `GET /api/dashboard/session`; 401 goes to sign-in, 503 renders
  recovery. Child routes read it with `shellRoute.useRouteContext()`.
- `routes/<section>.tsx`: one file per section, exporting a route array that
  `route-tree.tsx` spreads under the shell.
- `screens/<section>/`: screen components, loaded with `lazyRouteComponent`.
- `queries/<section>.ts`: `queryOptions` factories and zod response schemas.
- `lib/`: `dashboardFetch` (zod-validated JSON, typed `DashboardApiError`),
  flat string search params, basepath, locale hrefs, `useDashboardUrl`.

## Rules

- Paths keep their public form: routes use `/dashboard/...` and the router
  basepath is only the locale prefix (`""` for English, `/ja` for Japanese).
- Search params are flat strings (`?team=`, `?billing=error`). Declare them
  with `validateSearch: z.object({...})` on the route; `team` is inherited from
  the shell.
- Data: define `queryOptions` in `queries/`, prefetch in the route `loader`
  with `context.queryClient.ensureQueryData(...)`, read with
  `useSuspenseQuery` in the screen. Never fetch in `useEffect`.
- Mutations: `useMutation`, then `queryClient.invalidateQueries` for what
  changed. There is no `router.refresh()`.
- Links inside the SPA use `Link` from `@tanstack/react-router` with a typed
  `to`. Links that leave the SPA (`/api/billing/checkout`, `/pricing`,
  `/handler/...`) are plain `<a href>` with `localeHref` when locale matters.
- Server-only values (Stripe, S3, ASC, tokens, feature flags) stay behind API
  routes, which return only what the screen shows.
- Strings use `next-intl` `useTranslations`; the global provider already
  carries every dashboard namespace.
