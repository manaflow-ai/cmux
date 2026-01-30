# uid-promise

[![Build Status](https://travis-ci.org/zeit/uid-promise.svg?branch=master)](https://travis-ci.org/zeit/uid-promise)
[![XO code style](https://img.shields.io/badge/code_style-XO-5ed9c7.svg)](https://github.com/sindresorhus/xo)

Creates a cryptographically secure UID with a 62 character range that can be safely used in URLs.

## Usage

Firstly, install the package from [npm](https://www.npmjs.com):

```js
npm install --save uid-promise
```

Then load it:

```js
const uid = require('uid-promise')
```

Finally, call it:

```js
await uid(20)
```

## API

**`uid(Number len) => Promise`**

- Return a `Promise` that resolves with a string of random characters
of length `len`
- `len` must always be provided, else the promise is rejected
- Under the hood, `crypto.randomBytes` is used
- Character set: `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789`

## Authors

- Guillermo Rauch ([@rauchg](https://twitter.com/rauchg)) - [▲ZEIT](https://zeit.co)
- Leo Lamprecht ([@notquiteleo](https://twitter.com/notquiteleo)) - [▲ZEIT](https://zeit.co)
