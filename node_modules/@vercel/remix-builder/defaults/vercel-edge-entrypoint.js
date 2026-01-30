/**
 * Edge runtime entrypoint for `@remix-run/vercel`.
 */
'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

var serverRuntime = require('@remix-run/server-runtime');

/**
 * Returns a request handler for the Vercel Edge runtime that serves
 * the Remix SSR response.
 */
function createRequestHandler({ build, mode }) {
  let handleRequest = serverRuntime.createRequestHandler(build, mode);
  return request => {
    return handleRequest(request);
  };
}

exports.createRequestHandler = createRequestHandler;
