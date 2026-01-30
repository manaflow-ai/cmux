# 🍙 @vercel/blob

The Vercel Blob JavaScript API client.

---

<p align="center">
  👉 
  <a href="https://vercel.com/docs/vercel-blob">
    <b>Quickstart</b>
  </a> — 
  <a href="https://vercel.com/docs/vercel-blob/using-blob-sdk">
    <b>SDK Reference</b>
  </a>
   👈
  </b>
</p>

---

## Installation

```sh
npm install @vercel/blob
```

## Quickstart

We have examples on the vercel.com documentation, there are two ways to upload files to Vercel Blob:

1. [Server uploads](https://vercel.com/docs/vercel-blob/server-upload): This is the most common way to upload files. The file is first sent to your server and then to Vercel Blob. It's straightforward to implement, but you are limited to the request body your server can handle. Which in case of a Vercel-hosted website is 4.5 MB. **This means you can't upload files larger than 4.5 MB on Vercel when using this method.**
2. [Client uploads](https://vercel.com/docs/vercel-blob/client-upload): This is a more advanced solution for when you need to upload larger files. The file is securely sent directly from the client (a browser for example) to Vercel Blob. This requires a bit more work to implement, but it allows you to upload files up to 5 TB.

## Releasing

Make sure to include a changeset in your PR. You can do this by running:

```sh
pnpm changeset
git commit -am "changeset"
git push
```

Once such a commit gets merged in main, then GitHub will open a versioning PR you can merge. And the package will be automatically published to npm.

## A note for Vite users

`@vercel/blob` reads the token from the environment variables on `process.env`. In general, `process.env` is automatically populated from your `.env` file during development, which is created when you run `vc env pull`. However, Vite does not expose the `.env` variables on `process.env.`

You can fix this in **one** of following two ways:

1. You can populate `process.env` yourself using something like `dotenv-expand`:

```shell
pnpm install --save-dev dotenv dotenv-expand
```

```js
// vite.config.js
import dotenvExpand from 'dotenv-expand';
import { loadEnv, defineConfig } from 'vite';

export default defineConfig(({ mode }) => {
  // This check is important!
  if (mode === 'development') {
    const env = loadEnv(mode, process.cwd(), '');
    dotenvExpand.expand({ parsed: env });
  }

  return {
    ...
  };
});
```

2. You can provide the credentials explicitly, instead of relying on a zero-config setup. For example, this is how you could create a client in SvelteKit, which makes private environment variables available via `$env/static/private`:

```diff
import { put } from '@vercel/blob';
+ import { BLOB_TOKEN } from '$env/static/private';

const blob = await head("filepath", {
-  token: '<token>',
+  token: BLOB_TOKEN,
});
```
