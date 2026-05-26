# cmux web

Next.js app deployed as the existing Vercel `manaflow/cmux` project. The app serves the website,
Stack Auth handlers, feedback endpoint, and Cloud VM backend routes.

## Development

```bash
bun install
bun dev
```

`bun dev` sources provider secrets from `~/.secrets/cmux.env` when present, then sources
Stack/web secrets from `~/.secrets/cmuxterm-dev.env`. It derives local database URLs from `CMUX_PORT`,
starts this worktree's Docker Postgres, applies Drizzle migrations, then starts Next.js.
It listens on `CMUX_PORT` when it is set, otherwise `PORT`, otherwise `3777`.
When `bun dev` exits or is interrupted, it stops the matching Docker Postgres container and
network. The database volume is preserved so local state survives restarts.

The committed `.envrc` uses the same loader for direnv. Run `direnv allow` once in `web/` if you
want shells opened there to automatically get the same local dev environment.

`web/.env.local` is not used for local development. Keep Stack/web runtime secrets in
`~/.secrets/cmuxterm-dev.env` and Cloud VM provider secrets in `~/.secrets/cmux.env`.
`~/.secret/cmuxterm.env` and `~/.secrets/cmuxterm.env` are accepted as legacy fallbacks for the
Stack/web file.

To start Next without Docker Postgres, use:

```bash
CMUX_DEV_START_DB=0 bun dev
```

To keep the Docker Postgres container running after Next exits, use:

```bash
CMUX_DEV_STOP_DB_ON_EXIT=0 bun dev
```

## Local Postgres

Local Postgres is isolated per worktree by deriving its port and Docker names from `CMUX_PORT` and
the git branch. `bun dev` starts and migrates this database automatically; the commands below are
for manual control. `bun db:down` stops the container and network while preserving the volume.

```bash
CMUX_PORT=10180 bun db:up
CMUX_PORT=10180 bun db:migrate
CMUX_PORT=10180 bun db:status
```

With `CMUX_PORT=10180`, Postgres listens on `localhost:20180`. A second worktree with
`CMUX_PORT=10181` listens on `localhost:20181`, so multiple dev environments can run on one
machine.

Useful commands:

```bash
bun db:up       # start this worktree's Postgres
bun db:migrate  # apply Drizzle migrations
bun db:test     # start an isolated test DB on CMUX_PORT+11000 and run DB behavior tests
bun db:status   # print container, volume, port, and redacted DATABASE_URL
bun db:reset    # delete and recreate this worktree's DB volume
bun db:down     # stop this worktree's DB
```

The local default URL shape is:

```text
postgres://cmux:cmux@localhost:${CMUX_PORT + 10000}/cmux
```

## Database

Schema lives in `db/schema.ts`. SQL migrations live in `db/migrations`.

Generate a migration after schema edits:

```bash
bunx drizzle-kit generate --config drizzle.config.ts
```

Apply migrations:

```bash
bun db:migrate
```

CI applies migrations twice against a real Postgres service and runs the DB behavior tests to
verify the runtime behavior we rely on, including per-user create idempotency and internal
read-model access to the database.

The Cloud VM REST routes now run through Effect workflows backed by Postgres. The supporting
read model is `services/vms/dbReadModel.ts`; it is intentionally not exposed as an API route.
