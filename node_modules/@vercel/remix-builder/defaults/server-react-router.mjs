import { createRequestHandler } from 'react-router';
import * as build_ from 'virtual:react-router/server-build';
const build = build_.default || build_;
export default typeof build === 'function'
  ? // A custom server entrypoint is expected to export
    // a Web API-compatible handler function
    build
  : // Otherwise, assume the default export is
    // the React Router app manifest
    createRequestHandler(build);
