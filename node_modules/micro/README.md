<img src="https://raw.githubusercontent.com/zeit/art/6451bc300e00312d970527274f316f9b2c07a27e/micro/logo.png" width="50"/>

_**Micro** — Asynchronous HTTP microservices_

[![CircleCI](https://circleci.com/gh/zeit/micro/tree/master.svg?style=shield)](https://circleci.com/gh/zeit/micro/tree/master)
[![Install Size](https://packagephobia.now.sh/badge?p=micro)](https://packagephobia.now.sh/result?p=micro)
[![Join the community on Spectrum](https://withspectrum.github.io/badge/badge.svg)](https://spectrum.chat/zeit)

## Features

* **Easy**: Designed for usage with `async` and `await` ([more](https://zeit.co/blog/async-and-await))
* **Fast**: Ultra-high performance (even JSON parsing is opt-in)
* **Micro**: The whole project is ~260 lines of code
* **Agile**: Super easy deployment and containerization
* **Simple**: Oriented for single purpose modules (function)
* **Standard**: Just HTTP!
* **Explicit**: No middleware - modules declare all [dependencies](https://github.com/amio/awesome-micro)
* **Lightweight**: With all dependencies, the package weighs less than a megabyte

## Installation

**Important:** Micro is only meant to be used in production. In development, you should use [micro-dev](https://github.com/zeit/micro-dev), which provides you with a tool belt specifically tailored for developing microservices.

To prepare your microservice for running in the production environment, firstly install `micro`:

```bash
npm install --save micro
```

## Usage

Create an `index.js` file and export a function that accepts the standard [http.IncomingMessage](https://nodejs.org/api/http.html#http_class_http_incomingmessage) and [http.ServerResponse](https://nodejs.org/api/http.html#http_class_http_serverresponse) objects:

```js
module.exports = (req, res) => {
  res.end('Welcome to Micro')
}
```

Micro provides [useful helpers](https://github.com/zeit/micro#body-parsing) but also handles return values – so you can write it even shorter!

```js
module.exports = () => 'Welcome to Micro'
```

Next, ensure that the `main` property inside `package.json` points to your microservice (which is inside `index.js` in this example case) and add a `start` script:

```json
{
  "main": "index.js",
  "scripts": {
    "start": "micro"
  }
}
```

Once all of that is done, the server can be started like this:

```bash
npm start
```

And go to this URL: `http://localhost:3000` - 🎉

### Command line

```
  micro - Asynchronous HTTP microservices

  USAGE

      $ micro --help
      $ micro --version
      $ micro [-l listen_uri [-l ...]] [entry_point.js]

      By default micro will listen on 0.0.0.0:3000 and will look first
      for the "main" property in package.json and subsequently for index.js
      as the default entry_point.

      Specifying a single --listen argument will overwrite the default, not supplement it.

  OPTIONS

      --help                              shows this help message

      -v, --version                       displays the current version of micro

      -l, --listen listen_uri             specify a URI endpoint on which to listen (see below) -
                                          more than one may be specified to listen in multiple places

  ENDPOINTS

      Listen endpoints (specified by the --listen or -l options above) instruct micro
      to listen on one or more interfaces/ports, UNIX domain sockets, or Windows named pipes.

      For TCP (traditional host/port) endpoints:

          $ micro -l tcp://hostname:1234

      For UNIX domain socket endpoints:

          $ micro -l unix:/path/to/socket.sock

      For Windows named pipe endpoints:

          $ micro -l pipe:\\.\pipe\PipeName
```

### `async` & `await`

<p><details>
  <summary><b>Examples</b></summary>
  <ul><li><a href="./examples/external-api-call">Fetch external api</a></li></ul>
</details></p>

Micro is built for usage with async/await. You can read more about async / await [here](https://zeit.co/blog/async-and-await)

```js
const sleep = require('then-sleep')

module.exports = async (req, res) => {
  await sleep(500)
  return 'Ready!'
}
```

### Port Based on Environment Variable

When you want to set the port using an environment variable you can use:

```
micro -l tcp://0.0.0.0:$PORT
```

Optionally you can add a default if it suits your use case:

```
micro -l tcp://0.0.0.0:${PORT-3000}
```

`${PORT-3000}` will allow a fallback to port `3000` when `$PORT` is not defined.

Note that this only works in Bash.

### Body parsing

<p id="body-parsing-examples"><details>
  <summary><b>Examples</b></summary>
  <ul>
    <li><a href="./examples/json-body-parsing">Parse JSON</a></li>
    <li><a href="./examples/urlencoded-body-parsing">Parse urlencoded form (html `form` tag)</a></li>
  </ul>
</details></p>

For parsing the incoming request body we included an async functions `buffer`, `text` and `json`

```js
const {buffer, text, json} = require('micro')

module.exports = async (req, res) => {
  const buf = await buffer(req)
  console.log(buf)
  // <Buffer 7b 22 70 72 69 63 65 22 3a 20 39 2e 39 39 7d>
  const txt = await text(req)
  console.log(txt)
  // '{"price": 9.99}'
  const js = await json(req)
  console.log(js.price)
  // 9.99
  return ''
}
```

### API

##### `buffer(req, { limit = '1mb', encoding = 'utf8' })`
##### `text(req, { limit = '1mb', encoding = 'utf8' })`
##### `json(req, { limit = '1mb', encoding = 'utf8' })`

- Buffers and parses the incoming body and returns it.
- Exposes an `async` function that can be run with  `await`.
- Can be called multiple times, as it caches the raw request body the first time.
- `limit` is how much data is aggregated before parsing at max. Otherwise, an `Error` is thrown with `statusCode` set to `413` (see [Error Handling](#error-handling)). It can be a `Number` of bytes or [a string](https://www.npmjs.com/package/bytes) like `'1mb'`.
- If JSON parsing fails, an `Error` is thrown with `statusCode` set to `400` (see [Error Handling](#error-handling))

For other types of data check the [examples](#body-parsing-examples)

### Sending a different status code

So far we have used `return` to send data to the client. `return 'Hello World'` is the equivalent of `send(res, 200, 'Hello World')`.

```js
const {send} = require('micro')

module.exports = async (req, res) => {
  const statusCode = 400
  const data = { error: 'Custom error message' }

  send(res, statusCode, data)
}
```

##### `send(res, statusCode, data = null)`

- Use `require('micro').send`.
- `statusCode` is a `Number` with the HTTP status code, and must always be supplied.
- If `data` is supplied it is sent in the response. Different input types are processed appropriately, and `Content-Type` and `Content-Length` are automatically set.
  - `Stream`: `data` is piped as an `octet-stream`. Note: it is _your_ responsibility to handle the `error` event in this case (usually, simply logging the error and aborting the response is enough).
  - `Buffer`: `data` is written as an `octet-stream`.
  - `object`: `data` is serialized as JSON.
  - `string`: `data` is written as-is.
- If JSON serialization fails (for example, if a cyclical reference is found), a `400` error is thrown. See [Error Handling](#error-handling).

### Programmatic use

You can use Micro programmatically by requiring Micro directly:

```js
const http = require('http')
const micro = require('micro')
const sleep = require('then-sleep')

const server = new http.Server(micro(async (req, res) => {
  await sleep(500)
  return 'Hello world'
}))

server.listen(3000)
```

##### micro(fn)

- This function is exposed as the `default` export.
- Use `require('micro')`.
- Returns a function with the `(req, res) => void` signature. That uses the provided `function` as the request handler.
- The supplied function is run with `await`. So it can be `async`

##### sendError(req, res, error)

- Use `require('micro').sendError`.
- Used as the default handler for errors thrown.
- Automatically sets the status code of the response based on `error.statusCode`.
- Sends the `error.message` as the body.
- Stacks are printed out with `console.error` and during development (when `NODE_ENV` is set to `'development'`) also sent in responses.
- Usually, you don't need to invoke this method yourself, as you can use the [built-in error handling](#error-handling) flow with `throw`.

##### createError(code, msg, orig)

- Use `require('micro').createError`.
- Creates an error object with a `statusCode`.
- Useful for easily throwing errors with HTTP status codes, which are interpreted by the [built-in error handling](#error-handling).
- `orig` sets `error.originalError` which identifies the original error (if any).

## Error Handling

Micro allows you to write robust microservices. This is accomplished primarily by bringing sanity back to error handling and avoiding callback soup.

If an error is thrown and not caught by you, the response will automatically be `500`. **Important:** Error stacks will be printed as `console.error` and during development mode (if the env variable `NODE_ENV` is `'development'`), they will also be included in the responses.

If the `Error` object that's thrown contains a `statusCode` property, that's used as the HTTP code to be sent. Let's say you want to write a rate limiting module:

```js
const rateLimit = require('my-rate-limit')

module.exports = async (req, res) => {
  await rateLimit(req)
  // ... your code
}
```

If the API endpoint is abused, it can throw an error with ``createError`` like so:

```js
if (tooMany) {
  throw createError(429, 'Rate limit exceeded')
}
```

Alternatively you can create the `Error` object yourself

```js
if (tooMany) {
  const err = new Error('Rate limit exceeded')
  err.statusCode = 429
  throw err
}
```

The nice thing about this model is that the `statusCode` is merely a suggestion. The user can override it:

```js
try {
  await rateLimit(req)
} catch (err) {
  if (429 == err.statusCode) {
    // perhaps send 500 instead?
    send(res, 500)
  }
}
```

If the error is based on another error that **Micro** caught, like a `JSON.parse` exception, then `originalError` will point to it. If a generic error is caught, the status will be set to `500`.

In order to set up your own error handling mechanism, you can use composition in your handler:

```js
const {send} = require('micro')

const handleErrors = fn => async (req, res) => {
  try {
    return await fn(req, res)
  } catch (err) {
    console.log(err.stack)
    send(res, 500, 'My custom error!')
  }
}

module.exports = handleErrors(async (req, res) => {
  throw new Error('What happened here?')
})
```

## Testing

Micro makes tests compact and a pleasure to read and write.
We recommend [ava](https://github.com/sindresorhus/ava), a highly parallel Micro test framework with built-in support for async tests:

```js
const http = require('http')
const micro = require('micro')
const test = require('ava')
const listen = require('test-listen')
const request = require('request-promise')

test('my endpoint', async t => {
  const service = new http.Server(micro(async (req, res) => {
    micro.send(res, 200, {
      test: 'woot'
    })
  }))

  const url = await listen(service)
  const body = await request(url)

  t.deepEqual(JSON.parse(body).test, 'woot')
  service.close()
})
```

Look at [test-listen](https://github.com/zeit/test-listen) for a
function that returns a URL with an ephemeral port every time it's called.

## Contributing

1. [Fork](https://help.github.com/articles/fork-a-repo/) this repository to your own GitHub account and then [clone](https://help.github.com/articles/cloning-a-repository/) it to your local device
2. Link the package to the global module directory: `npm link`
3. Within the module you want to test your local development instance of Micro, just link it to the dependencies: `npm link micro`. Instead of the default one from npm, node will now use your clone of Micro!

As always, you can run the [AVA](https://github.com/sindresorhus/ava) and [ESLint](http://eslint.org) tests using: `npm test`

## Credits

Thanks to Tom Yandell and Richard Hodgson for donating the name "micro" on [npm](https://www.npmjs.com)!

## Authors

- Guillermo Rauch ([@rauchg](https://twitter.com/rauchg)) - [ZEIT](https://zeit.co)
- Leo Lamprecht ([@notquiteleo](https://twitter.com/notquiteleo)) - [ZEIT](https://zeit.co)
- Tim Neutkens ([@timneutkens](https://twitter.com/timneutkens)) - [ZEIT](https://zeit.co)
