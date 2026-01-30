# 🍪 cookie-es

<!-- automd:badges bundlejs packagephobia codecov -->

[![npm version](https://img.shields.io/npm/v/cookie-es)](https://npmjs.com/package/cookie-es)
[![npm downloads](https://img.shields.io/npm/dm/cookie-es)](https://npm.chart.dev/cookie-es)
[![bundle size](https://img.shields.io/bundlejs/size/cookie-es)](https://bundlejs.com/?q=cookie-es)
[![install size](https://badgen.net/packagephobia/install/cookie-es)](https://packagephobia.com/result?p=cookie-es)
[![codecov](https://img.shields.io/codecov/c/gh/unjs/cookie-es)](https://codecov.io/gh/unjs/cookie-es)

<!-- /automd -->

ESM ready [`Cookie`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cookie) and [`Set-Cookie`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie) parser and serializer based on [cookie](https://github.com/jshttp/cookie) and [set-cookie-parser](https://github.com/nfriedly/set-cookie-parser) with built-in types.

## Usage

Install:

```sh
# ✨ Auto-detect (npm, yarn, pnpm, bun, deno)
npx nypm install cookie-es
```

Import:

**ESM** (Node.js, Bun, Deno)

```js
import {
  parse,
  serialize,
  parseSetCookie,
  splitSetCookieString,
} from "cookie-es";
```

**CDN** (Deno, Bun and Browsers)

```js
import {
  parse,
  serialize,
  parseSetCookie,
  splitSetCookieString,
} from "https://esm.sh/cookie-es";
```

## License

[MIT](./LICENSE)

Based on [jshttp/cookie](https://github.com/jshttp/cookie) (Roman Shtylman and hristopher Wilson) and [nfriedly/set-cookie-parser](https://github.com/nfriedly/set-cookie-parser) (Nathan Friedly).
