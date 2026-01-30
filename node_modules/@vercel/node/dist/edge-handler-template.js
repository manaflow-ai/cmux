// provided by the edge runtime:
/* global addEventListener */

function getUrl(url, headers) {
  const urlObj = new URL(url);
  const protocol = headers.get('x-forwarded-proto');
  if (protocol) urlObj.protocol = protocol.split(/\b/).shift();
  urlObj.host = headers.get('x-forwarded-host');
  urlObj.port = headers.get('x-forwarded-port');
  return urlObj.toString();
}

async function respond(handler, event, options, dependencies) {
  const { Request, Response } = dependencies;
  const { isMiddleware } = options;
  event.request.headers.set(
    'host',
    event.request.headers.get('x-forwarded-host')
  );
  let response = await handler(
    new Request(
      getUrl(event.request.url, event.request.headers),
      event.request
    ),
    event
  );

  if (!response) {
    if (isMiddleware) {
      // allow empty responses to pass through
      response = new Response(null, {
        headers: {
          'x-middleware-next': '1',
        },
      });
    } else {
      throw new Error(`Edge Function did not return a response.`);
    }
  }
  return response;
}

function toResponseError(error, Response) {
  // we can't easily show a meaningful stack trace
  // so, stick to just the error message for now
  const msg = error.cause
    ? error.message + ': ' + (error.cause.message || error.cause)
    : error.message;
  return new Response(msg, {
    status: 500,
    headers: {
      'x-vercel-failed': 'edge-wrapper',
    },
  });
}

async function parseRequestEvent(event) {
  const serializedRequest = await event.request.text();
  const requestDetails = JSON.parse(serializedRequest);
  return requestDetails;
}

// This will be invoked by logic using this template
// eslint-disable-next-line @typescript-eslint/no-unused-vars
function registerFetchListener(module, options, dependencies) {
  let handler;

  addEventListener('fetch', async event => {
    try {
      if (typeof module.default === 'function') {
        handler = module.default;
      } else {
        if (
          ['GET', 'HEAD', 'OPTIONS', 'POST', 'PUT', 'DELETE', 'PATCH'].some(
            method => typeof module[method] === 'function'
          )
        ) {
          const method = event.request.method ?? 'GET';
          handler =
            typeof module[method] === 'function'
              ? module[method]
              : () => new dependencies.Response(null, { status: 405 });
        }
      }
      if (!handler) {
        const url = getUrl(event.request.url, event.request.headers);
        throw new Error(
          `No default or HTTP-named export was found at ${url}. Add one to handle requests. Learn more: https://vercel.link/creating-edge-middleware`
        );
      }
      const response = await respond(
        (req, ctx) => handler(req, { waitUntil: ctx.waitUntil.bind(ctx) }),
        event,
        options,
        dependencies
      );
      event.respondWith(response);
    } catch (error) {
      event.respondWith(toResponseError(error, dependencies.Response));
    }
  });
}

module.exports = {
  getUrl,
  parseRequestEvent,
  registerFetchListener,
  respond,
  toResponseError,
};
