'use strict'

var toArray = require('stream-to-array')
var Promise = require('any-promise')
var onEnd = require('end-of-stream')

module.exports = streamToPromise

function streamToPromise (stream) {
  if (stream.readable) return fromReadable(stream)
  if (stream.writable) return fromWritable(stream)
  return Promise.resolve()
}

function fromReadable (stream) {
  var promise = toArray(stream)

  // Ensure stream is in flowing mode
  if (stream.resume) stream.resume()

  return promise
    .then(function concat (parts) {
      if (stream._readableState && stream._readableState.objectMode) {
        return parts
      }
      return Buffer.concat(parts.map(bufferize))
    })
}

function fromWritable (stream) {
  return new Promise(function (resolve, reject) {
    onEnd(stream, function (err) {
      (err ? reject : resolve)(err)
    })
  })
}

function bufferize (chunk) {
  return Buffer.isBuffer(chunk) ? chunk : new Buffer(chunk)
}
