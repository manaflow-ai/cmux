import {
  createRequestHandler as createRemixRequestHandler,
  createReadableStreamFromReadable,
  writeReadableStreamToWritable,
  installGlobals,
} from '@remix-run/node';
import * as build from '@remix-run/dev/server-build';

installGlobals({
  nativeFetch:
    // Explicit opt-in to native fetch via runtime env var
    (parseInt(process.versions.node, 10) >= 20 &&
      process.env.VERCEL_REMIX_NATIVE_FETCH === '1') ||
    // `unstable_singleFetch` future flag added in Remix v2.9.0
    build.future.unstable_singleFetch ||
    // `v3_singleFetch` future flag stabilized in Remix v2.13.0
    build.future.v3_singleFetch,
});

const handleRequest = createRemixRequestHandler(
  build.default || build,
  process.env.NODE_ENV
);

function toWebHeaders(nodeHeaders) {
  const headers = new Headers();

  for (const key in nodeHeaders) {
    const header = nodeHeaders[key];
    // set-cookie is an array (maybe others)
    if (Array.isArray(header)) {
      for (const value of header) {
        headers.append(key, value);
      }
    } else {
      headers.append(key, header);
    }
  }

  return headers;
}

function toNodeHeaders(webHeaders) {
  return webHeaders.raw?.() || [...webHeaders].flat();
}

function createRemixRequest(req, res) {
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  const protocol = req.headers['x-forwarded-proto'] || 'https';
  const url = new URL(req.url, `${protocol}://${host}`);

  // Abort action/loaders once we can no longer write a response
  const controller = new AbortController();
  res.on('close', () => controller.abort());

  const init = {
    method: req.method,
    headers: toWebHeaders(req.headers),
    signal: controller.signal,
  };

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    init.body = createReadableStreamFromReadable(req);
    init.duplex = 'half';
  }

  return new Request(url.href, init);
}

async function sendRemixResponse(res, nodeResponse) {
  res.statusMessage = nodeResponse.statusText;
  res.writeHead(
    nodeResponse.status,
    nodeResponse.statusText,
    toNodeHeaders(nodeResponse.headers)
  );

  if (nodeResponse.body) {
    await writeReadableStreamToWritable(nodeResponse.body, res);
  } else {
    res.end();
  }
}

export default async (req, res) => {
  const request = createRemixRequest(req, res);
  const response = await handleRequest(request);
  await sendRemixResponse(res, response);
};
