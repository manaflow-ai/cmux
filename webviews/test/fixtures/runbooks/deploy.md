# Deploy the web app

Before you start, install the dependencies.

```bash
npm ci
```

## Build

Build the bundle. It should print `built in`.

```sh
npm run build
```

## Log in

```bash
wrangler login
```

## Ship

If the build printed warnings, fix them first; otherwise deploy.

```bash
wrangler deploy --env production
```

## Clean up

```bash
rm -rf dist .wrangler
```

```json
{ "not": "a step" }
```
