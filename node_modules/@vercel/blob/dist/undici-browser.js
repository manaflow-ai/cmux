// this file gets copied to the dist folder
// it makes undici work in the browser by reusing the global fetch
// it's the simplest way I've found to make http requests work in Node.js, Serverles Functions, Edge Functions, and the browser
// this should work as long as this module is used via Next.js/Webpack
// moving forward we will have to solve this problem in a more robust way
// reusing https://github.com/inrupt/universal-fetch
// or seeing how/if cross-fetch solves https://github.com/lquixada/cross-fetch/issues/69
export const fetch = globalThis.fetch.bind(globalThis);
