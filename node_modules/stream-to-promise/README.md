stream-to-promise [![Build Status](https://travis-ci.org/bendrucker/stream-to-promise.svg)](https://travis-ci.org/bendrucker/stream-to-promise)
=================

> Convert streams (readable or writable) to promises

## Installing

```sh
$ npm install --save[-dev] stream-to-promise
```

## Examples

### Readable Streams

```js
streamToPromise(readableStream).then(function (buffer) {
  // buffer.length === 3
})
readableStream.emit('data', new Buffer())
readableStream.emit('data', new Buffer())
readableStream.emit('data', new Buffer())
readableStream.emit('end') // promise is resolved here
```

### Writable Streams

```js
streamToPromise(writableStream).then(function () {
  // resolves undefined
})
writableStream.write('data')
writableStream.end() // promise is resolved here
```

### Error Handling

```js
var err = new Error()
streamToPromise(stream).catch(function (error) {
  // error === err
})
stream.emit('error', err) // promise is rejected here
```
