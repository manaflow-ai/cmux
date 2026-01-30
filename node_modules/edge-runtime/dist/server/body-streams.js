"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.pipeBodyStreamToResponse = exports.consumeUint8ArrayReadableStream = exports.getClonableBodyStream = void 0;
const stream_1 = require("stream");
/**
 * An interface that encapsulates body stream cloning
 * of an incoming request.
 */
function getClonableBodyStream(incomingMessage, KUint8Array, KTransformStream) {
    let bufferedBodyStream = null;
    return {
        /**
         * Replaces the original request body if necessary.
         * This is done because once we read the body from the original request,
         * we can't read it again.
         */
        finalize() {
            if (bufferedBodyStream) {
                replaceRequestBody(incomingMessage, bodyStreamToNodeStream(bufferedBodyStream));
            }
        },
        /**
         * Clones the body stream
         * to pass into a middleware
         */
        cloneBodyStream() {
            const originalStream = bufferedBodyStream !== null && bufferedBodyStream !== void 0 ? bufferedBodyStream : requestToBodyStream(incomingMessage, KUint8Array, KTransformStream);
            const [stream1, stream2] = originalStream.tee();
            bufferedBodyStream = stream1;
            return stream2;
        },
    };
}
exports.getClonableBodyStream = getClonableBodyStream;
/**
 * Creates a ReadableStream from a Node.js HTTP request
 */
function requestToBodyStream(request, KUint8Array, KTransformStream) {
    const transform = new KTransformStream({
        start(controller) {
            request.on('data', (chunk) => controller.enqueue(new KUint8Array([...new Uint8Array(chunk)])));
            request.on('end', () => controller.terminate());
            request.on('error', (err) => controller.error(err));
        },
    });
    return transform.readable;
}
function bodyStreamToNodeStream(bodyStream) {
    const reader = bodyStream.getReader();
    return stream_1.Readable.from((async function* () {
        while (true) {
            const { done, value } = await reader.read();
            if (done) {
                return;
            }
            yield value;
        }
    })());
}
function replaceRequestBody(base, stream) {
    for (const key in stream) {
        let v = stream[key];
        if (typeof v === 'function') {
            v = v.bind(stream);
        }
        base[key] = v;
    }
    return base;
}
function isUint8ArrayChunk(value) {
    var _a;
    return ((_a = value === null || value === void 0 ? void 0 : value.constructor) === null || _a === void 0 ? void 0 : _a.name) == 'Uint8Array';
}
/**
 * Creates an async iterator from a ReadableStream that ensures that every
 * emitted chunk is a `Uint8Array`. If there is some invalid chunk it will
 * throw.
 */
async function* consumeUint8ArrayReadableStream(body) {
    const reader = body === null || body === void 0 ? void 0 : body.getReader();
    if (reader) {
        let error;
        try {
            while (true) {
                const { done, value } = await reader.read();
                if (done) {
                    return;
                }
                if (!isUint8ArrayChunk(value)) {
                    error = new TypeError('This ReadableStream did not return bytes.');
                    break;
                }
                yield value;
            }
        }
        finally {
            if (error) {
                reader.cancel(error);
                throw error;
            }
            else {
                reader.cancel();
            }
        }
    }
}
exports.consumeUint8ArrayReadableStream = consumeUint8ArrayReadableStream;
/**
 * Pipes the chunks of a BodyStream into a Response. This optimizes for
 * laziness, pauses reading if we experience back-pressure, and handles early
 * disconnects by the client on the other end of the server response.
 */
async function pipeBodyStreamToResponse(body, res) {
    if (!body)
        return;
    // If the client has already disconnected, then we don't need to pipe anything.
    if (res.destroyed)
        return body.cancel();
    // When the server pushes more data than the client reads, then we need to
    // wait for the client to catch up before writing more data. We register this
    // generic handler once so that we don't incur constant register/unregister
    // calls.
    let drainResolve;
    res.on('drain', () => drainResolve === null || drainResolve === void 0 ? void 0 : drainResolve());
    // If the user aborts, then we'll receive a close event before the
    // body closes. In that case, we want to end the streaming.
    let open = true;
    res.on('close', () => {
        open = false;
        drainResolve === null || drainResolve === void 0 ? void 0 : drainResolve();
    });
    const reader = body.getReader();
    while (open) {
        const { done, value } = await reader.read();
        if (done)
            break;
        if (!isUint8ArrayChunk(value)) {
            const error = new TypeError('This ReadableStream did not return bytes.');
            reader.cancel(error);
            throw error;
        }
        if (open) {
            const bufferSpaceAvailable = res.write(value);
            // If there's no more space in the buffer, then we need to wait on the
            // client to read data before pushing again.
            if (!bufferSpaceAvailable) {
                await new Promise((res) => {
                    drainResolve = res;
                });
            }
        }
        // If the client disconnected early, then we need to cleanup the stream.
        // This cannot be joined with the above if-statement, because the client may
        // have disconnected while waiting for a drain signal.
        if (!open) {
            return reader.cancel();
        }
    }
}
exports.pipeBodyStreamToResponse = pipeBodyStreamToResponse;
//# sourceMappingURL=body-streams.js.map