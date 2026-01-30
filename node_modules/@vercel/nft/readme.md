# Node File Trace

[![CI Status](https://github.com/vercel/nft/actions/workflows/ci.yml/badge.svg)](https://github.com/vercel/nft/actions/workflows/ci.yml)

Used to determine exactly which files (including `node_modules`) are necessary for the application runtime.

This is similar to [@vercel/ncc](https://npmjs.com/package/@vercel/ncc) except there is no bundling performed and therefore no reliance on webpack. This achieves the same tree-shaking benefits without moving any assets or binaries.

## Usage

### Installation

```bash
npm i @vercel/nft
```

### Usage

Provide the list of source files as input:

```js
const { nodeFileTrace } = require('@vercel/nft');
const files = ['./src/main.js', './src/second.js'];
const { fileList } = await nodeFileTrace(files);
```

The list of files will include all `node_modules` modules and assets that may be needed by the application code.

### Options

#### Base

The base path for the file list - all files will be provided as relative to this base.

By default the `process.cwd()` is used:

```js
const { fileList } = await nodeFileTrace(files, {
  base: process.cwd(),
});
```

Any files/folders above the `base` are ignored in the listing and analysis.

#### Process Cwd

When applying analysis certain functions rely on the `process.cwd()` value, such as `path.resolve('./relative')` or even a direct `process.cwd()`
invocation.

Setting the `processCwd` option allows this analysis to be guided to the right path to ensure that assets are correctly detected.

```js
const { fileList } = await nodeFileTrace(files, {
  processCwd: path.resolve(__dirname),
});
```

By default `processCwd` is the same as `base`.

#### Exports & Imports

By default tracing of the [Node.js "exports" and "imports" fields](https://nodejs.org/dist/latest-v14.x/docs/api/esm.html#esm_package_entry_points) is supported, with the `"node"`, `"require"`, `"import"` and `"default"` conditions traced as defined.

Alternatively the explicit list of conditions can be provided:

```js
const { fileList } = await nodeFileTrace(files, {
  conditions: ['node', 'production'],
});
```

Only the `"node"` export should be explicitly included (if needed) when specifying the exact export condition list. The `"require"`, `"import"` and `"default"` conditions will always be traced as defined, no matter what custom conditions are set.

#### Exports Only

When tracing exports the `"main"` / index field will still be traced for Node.js versions without `"exports"` support.

This can be disabled with the `exportsOnly` option:

```js
const { fileList } = await nodeFileTrace(files, {
  exportsOnly: true,
});
```

Any package with `"exports"` will then only have its exports traced, and the main will not be included at all. This can reduce the output size when targeting [Node.js 12.17.0](https://github.com/nodejs/node/blob/master/doc/changelogs/CHANGELOG_V12.md#12.17.0) or newer.

#### Paths

> Status: Experimental. May change at any time.

Custom resolution path definitions to use.

```js
const { fileList } = await nodeFileTrace(files, {
  paths: {
    'utils/': '/path/to/utils/',
  },
});
```

Trailing slashes map directories, exact paths map exact only.

#### Hooks

The following FS functions can be hooked by passing them as options:

- `readFile(path): Promise<string>`
- `stat(path): Promise<FS.Stats>`
- `readlink(path): Promise<string>`
- `resolve(id: string, parent: string): Promise<string | string[]>`

##### Advanced Resolving

When providing a custom resolve hook you are responsible for returning one or more absolute paths to resolved files based on the `id` input. However it may be the case that you only want to augment or override the resolve behavior in certain cases. You can use `nft`'s underlying resolver by importing it. The builtin `resolve` function expects additional arguments that need to be forwarded from the hook

- `resolve(id: string, parent: string, job: Job, isCjs: boolean): Promise<string | string[]>`

Here is an example showing one id being resolved to a bespoke path while all other paths being resolved by the built-in resolver

```js
const { nodeFileTrace, resolve } = require('@vercel/nft');
const files = ['./src/main.js', './src/second.js'];
const { fileList } = await nodeFileTrace(files, {
  resolve: async (id, parent, job, isCjs) => {
    if (id === './src/main.js') {
      return '/path/to/some/resolved/main/file.js';
    } else {
      return resolve(id, parent, job, isCjs);
    }
  },
});
```

#### TypeScript

The internal resolution supports resolving `.ts` files in traces by default.

By its nature of integrating into existing build systems, the TypeScript
compiler is not included in this project - rather the TypeScript transform
layer requires separate integration into the `readFile` hook.

#### File IO Concurrency

In some large projects, the file tracing logic may process many files at the same time. In this case, if you do not limit the number of concurrent files IO, OOM problems are likely to occur.

We use a default of 1024 concurrency to balance performance and memory usage for fs operations. You can increase this value to a higher number for faster speed, but be aware of the memory issues if the concurrency is too high.

```js
const { fileList } = await nodeFileTrace(files, {
  fileIOConcurrency: 2048,
});
```

#### Analysis

Analysis options allow customizing how much analysis should be performed to exactly work out the dependency list.

By default as much analysis as possible is done to ensure no possibly needed files are left out of the trace.

To disable all analysis, set `analysis: false`. Alternatively, individual analysis options can be customized via:

```js
const { fileList } = await nodeFileTrace(files, {
  // default
  analysis: {
    // whether to glob any analysis like __dirname + '/dir/' or require('x/' + y)
    // that might output any file in a directory
    emitGlobs: true,
    // whether __filename and __dirname style
    // expressions should be analyzed as file references
    computeFileReferences: true,
    // evaluate known bindings to assist with glob and file reference analysis
    evaluatePureExpressions: true,
  },
});
```

#### Ignore

Custom ignores can be provided to skip file inclusion (and consequently analysis of the file for references in turn as well).

```js
const { fileList } = await nodeFileTrace(files, {
  ignore: ['./node_modules/pkg/file.js'],
});
```

Ignore will also accept a function or globs.

Note that the path provided to ignore is relative to `base`.

#### Cache

To persist the file cache between builds, pass an empty `cache` object:

```js
const cache = Object.create(null);
const { fileList } = await nodeFileTrace(['index.ts'], { cache });
// later:
{
  const { fileList } = await nodeFileTrace(['index.ts'], { cache });
}
```

Note that cache invalidations are not supported so the assumption is that the file system is not changed between runs.

#### Reasons

To get the underlying reasons for individual files being included, a `reasons` object is also provided by the output:

```js
const { fileList, reasons } = await nodeFileTrace(files);
```

The `reasons` output will then be an object of the following form:

```js
{
  [file: string]: {
    type: 'dependency' | 'asset' | 'sharedlib',
    ignored: true | false,
    parents: string[]
  }
}
```

`reasons` also includes files that were ignored as `ignored: true`, with their `ignoreReason`.

Every file is included because it is referenced by another file. The `parents` list will contain the list of all files that caused this file to be included.
