'use strict';

class StreamError extends Error {
  constructor(err, source) {
    const message = err && err.message || err;
    super(message);
    this.source = source;
    this.originalError = err;
  }
}

const events = ['error', 'end', 'close', 'finish'];

function cleanupEventHandlers(stream, listener) {
  events.map(e => stream.removeListener(e, listener));
}

function streamPromise(stream, state) {
  if (stream === process.stdout || stream === process.stderr) {
    return Promise.resolve(stream);
  }

  // see https://github.com/epeli/node-promisepipe/issues/2
  // and https://github.com/epeli/node-promisepipe/issues/15
  const isReadable = stream.readable || typeof stream._read === 'function';

  function on(evt) {
    function executor(resolve, reject) {
      const fn = evt === 'error' ?
        err => reject(new StreamError(err, stream)) :
        () => {
          // For readable streams, we ignore the "finish" event. However, if there
          // already was an error on another stream, the "end" event may never come,
          // so in that case we accept "finish" too.
          if (isReadable && evt === 'finish' && !state.error) {
            return;
          }

          cleanupEventHandlers(stream, fn);
          resolve(stream);
        };
      stream.on(evt, fn);
    }

    return new Promise(executor);
  }

  return Promise.race(events.map(on));
}

/**
 * @param {...Stream} stream
 */
function promisePipe(stream) {
  let i = arguments.length;
  const streams = [];
  while ( i-- ) streams[i] = arguments[i];

  const allStreams = streams
    .reduce((current, next) => current.concat(next), []);

  allStreams.reduce((current, next) => current.pipe(next));
  return allStreamsDone(streams);
}

function allStreamsDone(allStreams) {
  let state = {};
  let firstRejection;

  return Promise.all(allStreams.map(stream => streamPromise(stream, state).catch((e) => {
    if (!firstRejection) {
      firstRejection = e;
      state.error = true;

      // Close all streams as they are not closed automatically on error.
      allStreams.forEach(stream => {
        if (stream !== process.stdout && stream !== process.stderr) {
          stream.destroy();
        }
      });
    }
  }))).then((allResults) => {
		if (firstRejection) {
			throw firstRejection;
		}

		return allResults;
	});
}

module.exports = Object.assign(promisePipe, {
  __esModule: true,
  default: promisePipe,
  justPromise: streams => allStreamsDone(streams),
  StreamError,
});
