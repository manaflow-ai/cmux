import handleRequest from '__RELATIVE__/src/App.server';
import indexTemplate from '__RELATIVE__/dist/client/index.html?raw';

// ReadableStream is bugged in Vercel Edge, overwrite with polyfill
import { ReadableStream } from 'web-streams-polyfill/ponyfill';
Object.assign(globalThis, { ReadableStream });

export default (request, event) =>
  handleRequest(request, {
    indexTemplate,
    context: event,
  });
