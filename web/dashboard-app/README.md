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

## Page states

Every page has four states, and each uses one shared component, so the same
outage or wait looks the same on every page.

- **Frame first.** The page header (title, description) and any tabs or
  subnav are static, so they render at once in every state. Only the data
  region below them loads, fails, or is empty. No route skeleton hides the
  header.
- **Loading.** The data region shows a skeleton with the shape of what will
  appear: a settings-row skeleton for settings forms, a table skeleton with
  the real column count for tables, a card skeleton only for card grids.
  It appears after `pendingMs` and stays at least `pendingMinMs`, as now.
  No plain "Loading…" text.
- **Error.** `SectionError` in the data region: a bordered panel titled
  "Couldn't load <section>", one sentence from the declared refusal (network:
  check your connection; 5xx: temporarily unavailable; 403: no access; 404:
  not found), and a "Try again" button that refetches only that data and shows
  "Retrying…" while it runs. Never "Go to homepage", never a centered page-wide
  message, and never the sign-in recovery screen unless the session itself
  failed. A declared 5xx or a network error is retried once, after about one
  second, before the error shows; a declared 4xx shows at once.
- **Empty.** `EmptyState`: a one-line title, one sentence on what fills it,
  and the primary action when the viewer can take one.
- **Writes.** Buttons show their pending label and are disabled while a
  write runs; failures show `InlineError` next to the control that failed.

Row actions in tables use `ActionMenu` (the "…" trigger), not inline selects.
An action the viewer cannot take stays in the menu, disabled, with its reason
(for example, "A team needs at least one admin").

## Navigation

The sidebar has four groups, all title case: **Cloud** (Mac access),
**Coderouter** (Overview), **Remote control** (Mobile devices, iOS
TestFlight), and **Account** (Settings). Page titles are title case too
("Dashboard", "Billing", "Coderouter"). Other locales capitalize the first
letter where their script has case.

**Settings is the single hub** for the account, billing, and teams. Its
subnav groups:

- **Account:** Profile, Emails & auth, Notifications, Sessions, API keys
  (when the project allows them), Account.
- **Billing:** Plan & billing.
- **Teams:** one entry per team, then Create team.

Team pages open inside Settings, with the team header and tabs (General,
Members, Billing, API keys). The public URLs do not change:
`/dashboard/billing`, `/dashboard/teams`, and `/dashboard/teams/$teamId/...`
still resolve, render inside the Settings layout, and highlight Settings in
the sidebar. Email, Stripe, and the native apps keep linking to them.

## Plans and billing

Plan & billing (personal) and a team's Billing tab use one plan picker.

- **Picker:** cards for Free, Pro, and Max (Team for a team), each with the
  price and three plain lines on what it includes. The current plan is
  marked; the others carry one action each.
- **Upgrade from Free:** opens Stripe Checkout, returning to Plan & billing
  (or to the page that sent the user, see below).
- **Switch between paid plans (Pro and Max):** in the app. A confirm dialog
  shows the new price, the prorated amount due today (from a Stripe invoice
  preview), and the next renewal date. An upgrade takes effect now and
  charges the prorated difference now; a downgrade takes effect now and the
  unused part is credited to later invoices.
- **Cancel:** a dialog that states the end date, lists in plain words what
  stops then (Cloud VM pool size, the iOS app, team seats for a team), and
  asks one optional question: why (too expensive, missing a feature, not using
  it, other with text). The answer goes to analytics and is never required.
  Access continues to the end date; Plan & billing shows "Ends on <date>"
  with Resume until then.
- **Payment method and invoices:** "Manage payment method" and "Invoices"
  open the Stripe portal. Plan changes never go through the portal.
- **Welcome:** after a successful checkout the user lands on Plan & billing
  with a welcome state: what just unlocked, and links to the first things to
  try (install the iOS app, open Cloud, create a team).

Upgrade prompts, for a Free user:

- The plan picker on Plan & billing.
- Pages that need a paid plan (Cloud, iOS TestFlight, Mobile devices) show a
  short "Requires Pro" panel with Upgrade; checkout returns to that page.
- The account menu shows the plan (Free, Pro, Max) and, for Free, an
  Upgrade link.
