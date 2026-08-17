# Web pull request checks

`Web CI` runs for pull requests that change the web app, its root JavaScript
dependencies, or this workflow. It validates the managed relay catalog and
runs `bun run typecheck` in `web/` with Bun 1.3.14 on a GitHub-hosted Ubuntu
runner.

The check is limited to catalog and static type validation. A green result does
not prove Bun unit tests, Playwright browser behavior, API or database smoke
tests, or a Vercel deployment.

The equivalent local evidence is:

```sh
cd web
bun install --frozen-lockfile
bun tools/generate-managed-iroh-relay-catalog.ts --check
bun run typecheck
```

A successful Vercel preview proves that the Next.js production build completed
for that deployment. Vercel's build-time TypeScript phase is not the same as
`tsgo --noEmit`, and a preview does not prove Bun tests, Playwright tests, or
live API behavior.
