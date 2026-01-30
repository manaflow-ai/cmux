import { tsc, esbuild } from '../../utils/build.mjs';

await Promise.all([tsc(), esbuild().then(() => esbuild({ bundle: true }))]);
