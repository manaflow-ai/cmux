import { a as RollupLog, i as RollupError, n as LogLevelOption, o as RollupLogWithString, r as LogOrStringHandler, t as LogLevel } from "./logging-B4x9qar8.mjs";
import { A as BindingWatcherBundler, B as ParserOptions, F as JsxOptions, I as MinifyOptions$1, M as ExternalMemoryStatus, V as PreRenderedChunk, W as TransformOptions$1, a as BindingHookResolveIdExtraArgs, d as BindingTransformHookExtraArgs, j as BindingWatcherEvent, l as BindingRenderedChunk, s as BindingMagicString, t as BindingBuiltinPluginName } from "./binding-MAEzB4KA.mjs";
import { TopLevelFilterExpression } from "@rolldown/pluginutils";
import { Program } from "@oxc-project/types";

//#region src/types/misc.d.ts
type SourcemapPathTransformOption = (relativeSourcePath: string, sourcemapPath: string) => string;
type SourcemapIgnoreListOption = (relativeSourcePath: string, sourcemapPath: string) => boolean;
//#endregion
//#region src/types/module-info.d.ts
/** @category Plugin APIs */
interface ModuleInfo extends ModuleOptions {
  /**
  *  Unsupported at rolldown
  */
  ast: any;
  code: string | null;
  id: string;
  importers: string[];
  dynamicImporters: string[];
  importedIds: string[];
  dynamicallyImportedIds: string[];
  exports: string[];
  isEntry: boolean;
}
//#endregion
//#region src/utils/asset-source.d.ts
type AssetSource = string | Uint8Array;
//#endregion
//#region src/types/external-memory-handle.d.ts
declare const symbolForExternalMemoryHandle: "__rolldown_external_memory_handle__";
/**
* Interface for objects that hold external memory that can be explicitly freed.
*/
interface ExternalMemoryHandle {
  /**
  * Frees the external memory held by this object.
  * @param keepDataAlive - If true, evaluates all lazy fields before freeing memory.
  *   This will take time but prevents errors when accessing properties after freeing.
  * @returns Status object with `freed` boolean and optional `reason` string.
  * @internal
  */
  [symbolForExternalMemoryHandle]: (keepDataAlive?: boolean) => ExternalMemoryStatus;
}
/**
* Frees the external memory held by the given handle.
*
* This is useful when you want to manually release memory held by Rust objects
* (like `OutputChunk` or `OutputAsset`) before they are garbage collected.
*
* @param handle - The object with external memory to free
* @param keepDataAlive - If true, evaluates all lazy fields before freeing memory (default: false).
*   This will take time to copy data from Rust to JavaScript, but prevents errors
*   when accessing properties after the memory is freed.
* @returns Status object with `freed` boolean and optional `reason` string.
*   - `{ freed: true }` if memory was successfully freed
*   - `{ freed: false, reason: "..." }` if memory couldn't be freed (e.g., already freed or other references exist)
*
* @example
* ```typescript
* import { freeExternalMemory } from 'rolldown/experimental';
*
* const output = await bundle.generate();
* const chunk = output.output[0];
*
* // Use the chunk...
*
* // Manually free the memory (fast, but accessing properties after will throw)
* const status = freeExternalMemory(chunk); // { freed: true }
* const statusAgain = freeExternalMemory(chunk); // { freed: false, reason: "Memory has already been freed" }
*
* // Keep data alive before freeing (slower, but data remains accessible)
* freeExternalMemory(chunk, true); // Evaluates all lazy fields first
* console.log(chunk.code); // OK - data was copied to JavaScript before freeing
*
* // Without keepDataAlive, accessing chunk properties after freeing will throw an error
* ```
*/
declare function freeExternalMemory(handle: ExternalMemoryHandle, keepDataAlive?: boolean): ExternalMemoryStatus;
//#endregion
//#region src/types/rolldown-output.d.ts
/** @category Plugin APIs */
interface OutputAsset extends ExternalMemoryHandle {
  type: "asset";
  fileName: string;
  /** @deprecated Use "originalFileNames" instead. */
  originalFileName: string | null;
  originalFileNames: string[];
  source: AssetSource;
  /** @deprecated Use "names" instead. */
  name: string | undefined;
  names: string[];
}
/** @category Plugin APIs */
interface SourceMap {
  file: string;
  mappings: string;
  names: string[];
  sources: string[];
  sourcesContent: string[];
  version: number;
  debugId?: string;
  x_google_ignoreList?: number[];
  toString(): string;
  toUrl(): string;
}
/** @category Plugin APIs */
interface RenderedModule {
  readonly code: string | null;
  renderedLength: number;
  renderedExports: string[];
}
/** @category Plugin APIs */
interface RenderedChunk extends Omit<BindingRenderedChunk, "modules"> {
  type: "chunk";
  modules: {
    [id: string]: RenderedModule;
  };
  name: string;
  isEntry: boolean;
  isDynamicEntry: boolean;
  facadeModuleId: string | null;
  moduleIds: Array<string>;
  exports: Array<string>;
  fileName: string;
  imports: Array<string>;
  dynamicImports: Array<string>;
}
/** @category Plugin APIs */
interface OutputChunk extends ExternalMemoryHandle {
  type: "chunk";
  code: string;
  name: string;
  isEntry: boolean;
  exports: string[];
  fileName: string;
  modules: {
    [id: string]: RenderedModule;
  };
  imports: string[];
  dynamicImports: string[];
  facadeModuleId: string | null;
  isDynamicEntry: boolean;
  moduleIds: string[];
  map: SourceMap | null;
  sourcemapFileName: string | null;
  preliminaryFileName: string;
}
/** @category Programmatic APIs */
interface RolldownOutput extends ExternalMemoryHandle {
  output: [OutputChunk, ...(OutputChunk | OutputAsset)[]];
}
//#endregion
//#region src/types/utils.d.ts
type MaybePromise<T> = T | Promise<T>;
type NullValue<T = void> = T | undefined | null | void;
type PartialNull<T> = { [P in keyof T]: T[P] | null };
type MakeAsync<Function_> = Function_ extends ((this: infer This, ...parameters: infer Arguments) => infer Return) ? (this: This, ...parameters: Arguments) => Return | Promise<Return> : never;
type MaybeArray<T> = T | T[];
type StringOrRegExp = string | RegExp;
//#endregion
//#region src/options/output-options.d.ts
type GeneratedCodePreset = "es5" | "es2015";
interface GeneratedCodeOptions {
  /**
  * Whether to use Symbol.toStringTag for namespace objects.
  * @default false
  */
  symbols?: boolean;
  /**
  * Allows choosing one of the presets listed above while overriding some options.
  *
  * ```js
  * export default {
  *   output: {
  *     generatedCode: {
  *       preset: 'es2015',
  *       symbols: false
  *     }
  *   }
  * };
  * ```
  */
  preset?: GeneratedCodePreset;
  /**
  * Whether to add readable names to internal variables for profiling purposes.
  *
  * When enabled, generated code will use descriptive variable names that correspond
  * to the original module names, making it easier to profile and debug the bundled code.
  *
  * Note: Enabling this option makes the output more difficult to minify effectively.
  *
  * @default false
  */
  profilerNames?: boolean;
}
type ModuleFormat = "es" | "cjs" | "esm" | "module" | "commonjs" | "iife" | "umd";
type AddonFunction = (chunk: RenderedChunk) => string | Promise<string>;
type ChunkFileNamesFunction = (chunkInfo: PreRenderedChunk) => string;
type SanitizeFileNameFunction = (name: string) => string;
/** @category Plugin APIs */
interface PreRenderedAsset {
  type: "asset";
  name?: string;
  names: string[];
  originalFileName?: string;
  originalFileNames: string[];
  source: string | Uint8Array;
}
type AssetFileNamesFunction = (chunkInfo: PreRenderedAsset) => string;
type PathsFunction$1 = (id: string) => string;
type ManualChunksFunction = (moduleId: string, meta: {
  getModuleInfo: (moduleId: string) => ModuleInfo | null;
}) => string | NullValue;
type GlobalsFunction = (name: string) => string;
type AdvancedChunksNameFunction = (moduleId: string, ctx: ChunkingContext) => string | NullValue;
type AdvancedChunksTestFunction = (id: string) => boolean | undefined | void;
type MinifyOptions = Omit<MinifyOptions$1, "module" | "sourcemap">;
interface ChunkingContext {
  getModuleInfo(moduleId: string): ModuleInfo | null;
}
interface OutputOptions {
  dir?: string;
  file?: string;
  exports?: "auto" | "named" | "default" | "none";
  hashCharacters?: "base64" | "base36" | "hex";
  /**
  * Expected format of generated code.
  * - `'es'`, `'esm'` and `'module'` are the same format, all stand for ES module.
  * - `'cjs'` and `'commonjs'` are the same format, all stand for CommonJS module.
  * - `'iife'` stands for [Immediately Invoked Function Expression](https://developer.mozilla.org/en-US/docs/Glossary/IIFE).
  * - `'umd'` stands for [Universal Module Definition](https://github.com/umdjs/umd).
  *
  * @default 'esm'
  */
  format?: ModuleFormat;
  sourcemap?: boolean | "inline" | "hidden";
  sourcemapBaseUrl?: string;
  sourcemapDebugIds?: boolean;
  /**
  * Control which source files are included in the sourcemap ignore list.
  * Files in the ignore list are excluded from debugger stepping and error stack traces.
  *
  * - `false`: Include all source files in the ignore list
  * - `true`: Include no source files in the ignore list
  * - `string`: Files containing this string in their path will be included in the ignore list
  * - `RegExp`: Files matching this regular expression will be included in the ignore list
  * - `function`: Custom function `(source: string, sourcemapPath: string) => boolean` to determine if a source should be ignored
  *
  * :::tip Performance
  * Using static values (`boolean`, `string`, or `RegExp`) is significantly more performant than functions.
  * Calling JavaScript functions from Rust has extremely high overhead, so prefer static patterns when possible.
  * :::
  *
  * ## Examples
  * ```js
  * // ✅ Preferred: Use RegExp for better performance
  * sourcemapIgnoreList: /node_modules/
  *
  * // ✅ Preferred: Use string pattern for better performance
  * sourcemapIgnoreList: "vendor"
  *
  * // ! Use sparingly: Function calls have high overhead
  * sourcemapIgnoreList: (source, sourcemapPath) => {
  *   return source.includes('node_modules') || source.includes('.min.');
  * }
  * ```
  *
  * **default**: /node_modules/
  */
  sourcemapIgnoreList?: boolean | SourcemapIgnoreListOption | StringOrRegExp;
  sourcemapPathTransform?: SourcemapPathTransformOption;
  banner?: string | AddonFunction;
  footer?: string | AddonFunction;
  /**
  * Similar to `banner` option, but will run after the `renderChunk` hook and builtin minification.
  */
  postBanner?: string | AddonFunction;
  /**
  * Similar to `footer` option, but will run after the `renderChunk` hook and builtin minification.
  */
  postFooter?: string | AddonFunction;
  intro?: string | AddonFunction;
  outro?: string | AddonFunction;
  extend?: boolean;
  esModule?: boolean | "if-default-prop";
  assetFileNames?: string | AssetFileNamesFunction;
  entryFileNames?: string | ChunkFileNamesFunction;
  chunkFileNames?: string | ChunkFileNamesFunction;
  cssEntryFileNames?: string | ChunkFileNamesFunction;
  cssChunkFileNames?: string | ChunkFileNamesFunction;
  sanitizeFileName?: boolean | SanitizeFileNameFunction;
  /**
  * Control code minification.
  *
  * - `true`: Enable full minification including code compression and dead code elimination
  * - `false`: Disable minification (default)
  * - `'dce-only'`: Only perform dead code elimination without code compression
  * - `MinifyOptions`: Fine-grained control over minification settings
  *
  * @default false
  */
  minify?: boolean | "dce-only" | MinifyOptions;
  name?: string;
  globals?: Record<string, string> | GlobalsFunction;
  /**
  * Maps external module IDs to paths.
  *
  * Allows customizing the path used when importing external dependencies.
  * This is particularly useful for loading dependencies from CDNs or custom locations.
  *
  * - Object form: Maps module IDs to their replacement paths
  * - Function form: Takes a module ID and returns its replacement path
  *
  * @example
  * ```js
  * {
  *   paths: {
  *     'd3': 'https://cdn.jsdelivr.net/npm/d3@7'
  *   }
  * }
  * ```
  *
  * @example
  * ```js
  * {
  *   paths: (id) => {
  *     if (id.startsWith('lodash')) {
  *       return `https://cdn.jsdelivr.net/npm/${id}`
  *     }
  *     return id
  *   }
  * }
  * ```
  */
  paths?: Record<string, string> | PathsFunction$1;
  generatedCode?: Partial<GeneratedCodeOptions>;
  externalLiveBindings?: boolean;
  inlineDynamicImports?: boolean;
  dynamicImportInCjs?: boolean;
  /**
  * - Type: `((moduleId: string, meta: { getModuleInfo: (moduleId: string) => ModuleInfo | null }) => string | NullValue)`
  * - Object form is not supported.
  *
  * :::warning
  * - This option is deprecated. Please use `advancedChunks` instead.
  * - If `manualChunks` and `advancedChunks` are both specified, `manualChunks` option will be ignored.
  * :::
  *
  * You could use this option for migration purpose. Under the hood,
  *
  * ```js
  * {
  *   manualChunks: (moduleId, meta) => {
  *     if (moduleId.includes('node_modules')) {
  *       return 'vendor';
  *     }
  *     return null;
  *   }
  * }
  * ```
  *
  * will be transformed to
  *
  * ```js
  * {
  *   advancedChunks: {
  *     groups: [
  *       {
  *         name(moduleId) {
  *           if (moduleId.includes('node_modules')) {
  *             return 'vendor';
  *           }
  *           return null;
  *         },
  *       },
  *     ],
  *   }
  * }
  *
  * ```
  *
  * @deprecated Please use `advancedChunks` instead.
  */
  manualChunks?: ManualChunksFunction;
  /**
  * Allows you to do manual chunking. For deeper understanding, please refer to the in-depth [documentation](https://rolldown.rs/in-depth/advanced-chunks).
  */
  advancedChunks?: {
    /**
    * - Type: `boolean`
    * - Default: `true`
    *
    * By default, each group will also include captured modules' dependencies. This reduces the chance of generating circular chunks.
    *
    * If you want to disable this behavior, it's recommended to both set
    * - `preserveEntrySignatures: false | 'allow-extension'`
    * - `strictExecutionOrder: true`
    *
    * to avoid generating invalid chunks.
    */
    includeDependenciesRecursively?: boolean;
    /**
    * - Type: `number`
    *
    * Global fallback of [`{group}.minSize`](#advancedchunks-groups-minsize), if it's not specified in the group.
    */
    minSize?: number;
    /**
    * - Type: `number`
    *
    * Global fallback of [`{group}.maxSize`](#advancedchunks-groups-maxsize), if it's not specified in the group.
    */
    maxSize?: number;
    /**
    * - Type: `number`
    *
    * Global fallback of [`{group}.maxModuleSize`](#advancedchunks-groups-maxmodulesize), if it's not specified in the group.
    */
    maxModuleSize?: number;
    /**
    * - Type: `number`
    *
    * Global fallback of [`{group}.minModuleSize`](#advancedchunks-groups-minmodulesize), if it's not specified in the group.
    */
    minModuleSize?: number;
    /**
    * - Type: `number`
    *
    * Global fallback of [`{group}.minShareCount`](#advancedchunks-groups-minsharecount), if it's not specified in the group.
    */
    minShareCount?: number;
    /**
    * Groups to be used for advanced chunking.
    */
    groups?: {
      /**
      * - Type: `string | ((moduleId: string, ctx: { getModuleInfo: (moduleId: string) => ModuleInfo | null }) => string | NullValue)`
      *
      * Name of the group. It will be also used as the name of the chunk and replaced the `[name]` placeholder in the `chunkFileNames` option.
      *
      * For example,
      *
      * ```js
      * import { defineConfig } from 'rolldown';
      *
      * export default defineConfig({
      *   advancedChunks: {
      *     groups: [
      *       {
      *         name: 'libs',
      *         test: /node_modules/,
      *       },
      *     ],
      *   },
      * });
      * ```
      * will create a chunk named `libs-[hash].js` in the end.
      *
      * It's ok to have the same name for different groups. Rolldown will deduplicate the chunk names if necessary.
      *
      * # Dynamic `name()`
      *
      * If `name` is a function, it will be called with the module id as the argument. The function should return a string or `null`. If it returns `null`, the module will be ignored by this group.
      *
      * Notice, each returned new name will be treated as a separate group.
      *
      * For example,
      *
      * ```js
      * import { defineConfig } from 'rolldown';
      *
      * export default defineConfig({
      *   advancedChunks: {
      *     groups: [
      *       {
      *         name: (moduleId) => moduleId.includes('node_modules') ? 'libs' : 'app',
      *         minSize: 100 * 1024,
      *       },
      *     ],
      *   },
      * });
      * ```
      *
      * :::warning
      * Constraints like `minSize`, `maxSize`, etc. are applied separately for different names returned by the function.
      * :::
      */
      name: string | AdvancedChunksNameFunction;
      /**
      * - Type: `string | RegExp | ((id: string) => boolean | undefined | void);`
      *
      * Controls which modules are captured in this group.
      *
      * - If `test` is a string, the module whose id contains the string will be captured.
      * - If `test` is a regular expression, the module whose id matches the regular expression will be captured.
      * - If `test` is a function, modules for which `test(id)` returns `true` will be captured.
      * - If `test` is empty, any module will be considered as matched.
      *
      * :::warning
      * When using regular expression, it's recommended to use `[\\/]` to match the path separator instead of `/` to avoid potential issues on Windows.
      * - ✅ Recommended: `/node_modules[\\/]react/`
      * - ❌ Not recommended: `/node_modules/react/`
      * :::
      */
      test?: StringOrRegExp | AdvancedChunksTestFunction;
      /**
      * - Type: `number`
      * - Default: `0`
      *
      * Priority of the group. Group with higher priority will be chosen first to match modules and create chunks. When converting the group to a chunk, modules of that group will be removed from other groups.
      *
      * If two groups have the same priority, the group whose index is smaller will be chosen.
      *
      * For example,
      *
      * ```js
      * import { defineConfig } from 'rolldown';
      *
      * export default defineConfig({
      *  advancedChunks: {
      *   groups: [
      *      {
      *        name: 'react',
      *        test: /node_modules[\\/]react/,
      *        priority: 1,
      *      },
      *      {
      *        name: 'other-libs',
      *        test: /node_modules/,
      *        priority: 2,
      *      },
      *   ],
      * });
      * ```
      *
      * This is a clearly __incorrect__ example. Though `react` group is defined before `other-libs`, it has a lower priority, so the modules in `react` group will be captured in `other-libs` group.
      */
      priority?: number;
      /**
      * - Type: `number`
      * - Default: `0`
      *
      * Minimum size in bytes of the desired chunk. If the accumulated size of the captured modules by this group is smaller than this value, it will be ignored. Modules in this group will fall back to the `automatic chunking` if they are not captured by any other group.
      */
      minSize?: number;
      /**
      * - Type: `number`
      * - Default: `1`
      *
      * Controls if a module should be captured based on how many entry chunks reference it.
      */
      minShareCount?: number;
      /**
      * - Type: `number`
      * - Default: `Infinity`
      *
      * If the accumulated size in bytes of the captured modules by this group is larger than this value, this group will be split into multiple groups that each has size close to this value.
      */
      maxSize?: number;
      /**
      * - Type: `number`
      * - Default: `Infinity`
      *
      * Controls a module could only be captured if its size in bytes is smaller or equal than this value.
      */
      maxModuleSize?: number;
      /**
      * - Type: `number`
      * - Default: `0`
      *
      * Controls a module could only be captured if its size in bytes is larger or equal than this value.
      */
      minModuleSize?: number;
    }[];
  };
  /**
  * Control comments in the output.
  *
  * - `none`: no comments
  * - `inline`: preserve comments that contain `@license`, `@preserve` or starts with `//!` `/*!`
  */
  legalComments?: "none" | "inline";
  plugins?: RolldownOutputPluginOption;
  polyfillRequire?: boolean;
  hoistTransitiveImports?: false;
  preserveModules?: boolean;
  virtualDirname?: string;
  preserveModulesRoot?: string;
  topLevelVar?: boolean;
  /**
  * - Type: `boolean`
  * - Default: `true` for format `es` or if `output.minify` is `true` or object, `false` otherwise
  *
  * Whether to minify internal exports.
  */
  minifyInternalExports?: boolean;
  /**
  * - Type: `boolean`
  * - Default: `false`
  *
  * Clean output directory before emitting output.
  */
  cleanDir?: boolean;
  /** Keep function and class names after bundling.
  *
  * When enabled, the bundler will preserve the original names of functions and classes
  * in the output, which is useful for debugging and error stack traces.
  *
  * @default false
  */
  keepNames?: boolean;
}
//#endregion
//#region src/api/build.d.ts
interface BuildOptions extends InputOptions {
  /**
  * Write the output to the file system
  *
  * @default true
  */
  write?: boolean;
  output?: OutputOptions;
}
/** @category Programmatic APIs */
declare function build(options: BuildOptions): Promise<RolldownOutput>;
/**
* Build multiple outputs __sequentially__.
*/
declare function build(options: BuildOptions[]): Promise<RolldownOutput[]>;
//#endregion
//#region src/api/rolldown/rolldown-build.d.ts
/** @category Programmatic APIs */
declare class RolldownBuild {
  #private;
  static asyncRuntimeShutdown: boolean;
  constructor(inputOptions: InputOptions);
  get closed(): boolean;
  generate(outputOptions?: OutputOptions): Promise<RolldownOutput>;
  write(outputOptions?: OutputOptions): Promise<RolldownOutput>;
  /**
  * Close the build and free resources.
  */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
  get watchFiles(): Promise<string[]>;
}
//#endregion
//#region src/api/rolldown/index.d.ts
/** @category Programmatic APIs */
declare const rolldown: (input: InputOptions) => Promise<RolldownBuild>;
//#endregion
//#region src/options/watch-options.d.ts
/** @category Programmatic APIs */
interface WatchOptions extends InputOptions {
  output?: OutputOptions | OutputOptions[];
}
//#endregion
//#region src/api/watch/watch-emitter.d.ts
type WatcherEvent = "close" | "event" | "restart" | "change";
type ChangeEvent$1 = "create" | "update" | "delete";
type RolldownWatchBuild = BindingWatcherBundler;
/** @category Programmatic APIs */
type RolldownWatcherEvent = {
  code: "START";
} | {
  code: "BUNDLE_START";
} | {
  code: "BUNDLE_END";
  duration: number;
  output: readonly string[];
  result: RolldownWatchBuild;
} | {
  code: "END";
} | {
  code: "ERROR";
  error: Error;
  result: RolldownWatchBuild;
};
declare class WatcherEmitter {
  listeners: Map<WatcherEvent, Array<(...parameters: any[]) => MaybePromise<void>>>;
  timer: any;
  constructor();
  on(event: "change", listener: (id: string, change: {
    event: ChangeEvent$1;
  }) => MaybePromise<void>): this;
  on(event: "event", listener: (data: RolldownWatcherEvent) => MaybePromise<void>): this;
  on(event: "restart" | "close", listener: () => MaybePromise<void>): this;
  off(event: WatcherEvent, listener: (...parameters: any[]) => MaybePromise<void>): this;
  clear(event: WatcherEvent): void;
  onEvent(event: BindingWatcherEvent): Promise<void>;
  close(): Promise<void>;
}
/** @category Programmatic APIs */
type RolldownWatcher = WatcherEmitter;
//#endregion
//#region src/api/watch/index.d.ts
/** @category Programmatic APIs */
declare const watch: (input: WatchOptions | WatchOptions[]) => RolldownWatcher;
//#endregion
//#region src/log/log-handler.d.ts
type LoggingFunction = (log: RollupLog | string | (() => RollupLog | string)) => void;
type LoggingFunctionWithPosition = (log: RollupLog | string | (() => RollupLog | string), pos?: number | {
  column: number;
  line: number;
}) => void;
type WarningHandlerWithDefault = (warning: RollupLog, defaultHandler: LoggingFunction) => void;
//#endregion
//#region src/options/generated/checks-options.d.ts
interface ChecksOptions {
  /**
  * Whether to emit warning when detecting circular dependency
  * @default false
  * */
  circularDependency?: boolean;
  /**
  * Whether to emit warning when detecting eval
  * @default true
  * */
  eval?: boolean;
  /**
  * Whether to emit warning when detecting missing global name
  * @default true
  * */
  missingGlobalName?: boolean;
  /**
  * Whether to emit warning when detecting missing name option for iife export
  * @default true
  * */
  missingNameOptionForIifeExport?: boolean;
  /**
  * Whether to emit warning when detecting mixed exports
  * @default true
  * */
  mixedExports?: boolean;
  /**
  * Whether to emit warning when detecting unresolved entry
  * @default true
  * */
  unresolvedEntry?: boolean;
  /**
  * Whether to emit warning when detecting unresolved import
  * @default true
  * */
  unresolvedImport?: boolean;
  /**
  * Whether to emit warning when detecting filename conflict
  * @default true
  * */
  filenameConflict?: boolean;
  /**
  * Whether to emit warning when detecting common js variable in esm
  * @default true
  * */
  commonJsVariableInEsm?: boolean;
  /**
  * Whether to emit warning when detecting import is undefined
  * @default true
  * */
  importIsUndefined?: boolean;
  /**
  * Whether to emit warning when detecting empty import meta
  * @default true
  * */
  emptyImportMeta?: boolean;
  /**
  * Whether to emit warning when detecting cannot call namespace
  * @default true
  * */
  cannotCallNamespace?: boolean;
  /**
  * Whether to emit warning when detecting configuration field conflict
  * @default true
  * */
  configurationFieldConflict?: boolean;
  /**
  * Whether to emit warning when detecting prefer builtin feature
  * @default true
  * */
  preferBuiltinFeature?: boolean;
  /**
  * Whether to emit warning when detecting could not clean directory
  * @default true
  * */
  couldNotCleanDirectory?: boolean;
  /**
  * Whether to emit warning when detecting plugin timings
  * @default true
  * */
  pluginTimings?: boolean;
}
//#endregion
//#region src/options/normalized-input-options.d.ts
/** @category Plugin APIs */
interface NormalizedInputOptions {
  input: string[] | Record<string, string>;
  cwd: string;
  platform: InputOptions["platform"];
  shimMissingExports: boolean;
  context: string;
}
//#endregion
//#region src/options/normalized-output-options.d.ts
type PathsFunction = (id: string) => string;
/** @category Plugin APIs */
type InternalModuleFormat = "es" | "cjs" | "iife" | "umd";
/** @category Plugin APIs */
interface NormalizedOutputOptions {
  name: string | undefined;
  file: string | undefined;
  dir: string | undefined;
  entryFileNames: string | ChunkFileNamesFunction;
  chunkFileNames: string | ChunkFileNamesFunction;
  assetFileNames: string | AssetFileNamesFunction;
  format: InternalModuleFormat;
  exports: NonNullable<OutputOptions["exports"]>;
  sourcemap: boolean | "inline" | "hidden";
  sourcemapBaseUrl: string | undefined;
  cssEntryFileNames: string | ChunkFileNamesFunction;
  cssChunkFileNames: string | ChunkFileNamesFunction;
  inlineDynamicImports: boolean;
  dynamicImportInCjs: boolean;
  externalLiveBindings: boolean;
  banner: AddonFunction;
  footer: AddonFunction;
  postBanner: AddonFunction;
  postFooter: AddonFunction;
  intro: AddonFunction;
  outro: AddonFunction;
  esModule: boolean | "if-default-prop";
  extend: boolean;
  globals: Record<string, string> | GlobalsFunction;
  paths: Record<string, string> | PathsFunction | undefined;
  hashCharacters: "base64" | "base36" | "hex";
  sourcemapDebugIds: boolean;
  sourcemapIgnoreList: boolean | SourcemapIgnoreListOption | StringOrRegExp | undefined;
  sourcemapPathTransform: SourcemapPathTransformOption | undefined;
  minify: false | MinifyOptions | "dce-only";
  legalComments: "none" | "inline";
  polyfillRequire: boolean;
  plugins: RolldownPlugin[];
  preserveModules: boolean;
  virtualDirname: string;
  preserveModulesRoot?: string;
  topLevelVar?: boolean;
  minifyInternalExports?: boolean;
}
//#endregion
//#region src/plugin/fs.d.ts
/** @category Plugin APIs */
interface RolldownFsModule {
  appendFile(path: string, data: string | Uint8Array, options?: {
    encoding?: BufferEncoding | null;
    mode?: string | number;
    flag?: string | number;
  }): Promise<void>;
  copyFile(source: string, destination: string, mode?: string | number): Promise<void>;
  mkdir(path: string, options?: {
    recursive?: boolean;
    mode?: string | number;
  }): Promise<void>;
  mkdtemp(prefix: string): Promise<string>;
  readdir(path: string, options?: {
    withFileTypes?: false;
  }): Promise<string[]>;
  readdir(path: string, options?: {
    withFileTypes: true;
  }): Promise<RolldownDirectoryEntry[]>;
  readFile(path: string, options?: {
    encoding?: null;
    flag?: string | number;
    signal?: AbortSignal;
  }): Promise<Uint8Array>;
  readFile(path: string, options?: {
    encoding: BufferEncoding;
    flag?: string | number;
    signal?: AbortSignal;
  }): Promise<string>;
  realpath(path: string): Promise<string>;
  rename(oldPath: string, newPath: string): Promise<void>;
  rmdir(path: string, options?: {
    recursive?: boolean;
  }): Promise<void>;
  stat(path: string): Promise<RolldownFileStats>;
  lstat(path: string): Promise<RolldownFileStats>;
  unlink(path: string): Promise<void>;
  writeFile(path: string, data: string | Uint8Array, options?: {
    encoding?: BufferEncoding | null;
    mode?: string | number;
    flag?: string | number;
  }): Promise<void>;
}
/** @category Plugin APIs */
type BufferEncoding = "ascii" | "utf8" | "utf16le" | "ucs2" | "base64" | "base64url" | "latin1" | "binary" | "hex";
/** @category Plugin APIs */
interface RolldownDirectoryEntry {
  isFile(): boolean;
  isDirectory(): boolean;
  isSymbolicLink(): boolean;
  name: string;
}
/** @category Plugin APIs */
interface RolldownFileStats {
  isFile(): boolean;
  isDirectory(): boolean;
  isSymbolicLink(): boolean;
  size: number;
  mtime: Date;
  ctime: Date;
  atime: Date;
  birthtime: Date;
}
//#endregion
//#region src/plugin/hook-filter.d.ts
/** @category Plugin APIs */
type GeneralHookFilter<Value = StringOrRegExp> = MaybeArray<Value> | {
  include?: MaybeArray<Value>;
  exclude?: MaybeArray<Value>;
};
interface FormalModuleTypeFilter {
  include?: ModuleType[];
}
/** @category Plugin APIs */
type ModuleTypeFilter = ModuleType[] | FormalModuleTypeFilter;
/** @category Plugin APIs */
interface HookFilter {
  /**
  * This filter is used to do a pre-test to determine whether the hook should be called.
  *
  * @example
  * Include all `id`s that contain `node_modules` in the path.
  * ```js
  * { id: '**'+'/node_modules/**' }
  * ```
  * @example
  * Include all `id`s that contain `node_modules` or `src` in the path.
  * ```js
  * { id: ['**'+'/node_modules/**', '**'+'/src/**'] }
  * ```
  * @example
  * Include all `id`s that start with `http`
  * ```js
  * { id: /^http/ }
  * ```
  * @example
  * Exclude all `id`s that contain `node_modules` in the path.
  * ```js
  * { id: { exclude: '**'+'/node_modules/**' } }
  * ```
  * @example
  * Formal pattern to define includes and excludes.
  * ```
  * { id : {
  *   include: ['**'+'/foo/**', /bar/],
  *   exclude: ['**'+'/baz/**', /qux/]
  * }}
  * ```
  */
  id?: GeneralHookFilter;
  moduleType?: ModuleTypeFilter;
  code?: GeneralHookFilter;
}
type TUnionWithTopLevelFilterExpressionArray<T> = T | TopLevelFilterExpression[];
//#endregion
//#region src/plugin/minimal-plugin-context.d.ts
/** @category Plugin APIs */
interface PluginContextMeta {
  rollupVersion: string;
  rolldownVersion: string;
  watchMode: boolean;
}
/** @category Plugin APIs */
interface MinimalPluginContext {
  readonly pluginName: string;
  error: (e: RollupError | string) => never;
  info: LoggingFunction;
  warn: LoggingFunction;
  debug: LoggingFunction;
  meta: PluginContextMeta;
}
//#endregion
//#region src/plugin/parallel-plugin.d.ts
type ParallelPlugin = {
  _parallel: {
    fileUrl: string;
    options: unknown;
  };
};
/** @internal */
type DefineParallelPluginResult<Options> = (options: Options) => ParallelPlugin;
declare function defineParallelPlugin<Options>(pluginPath: string): DefineParallelPluginResult<Options>;
//#endregion
//#region src/plugin/plugin-context.d.ts
/** @category Plugin APIs */
interface EmittedAsset {
  type: "asset";
  name?: string;
  fileName?: string;
  originalFileName?: string;
  source: AssetSource;
}
interface EmittedChunk {
  type: "chunk";
  name?: string;
  fileName?: string;
  preserveSignature?: "strict" | "allow-extension" | "exports-only" | false;
  id: string;
  importer?: string;
}
interface EmittedPrebuiltChunk {
  type: "prebuilt-chunk";
  fileName: string;
  code: string;
  exports?: string[];
  map?: SourceMap;
  sourcemapFileName?: string;
}
/** @category Plugin APIs */
type EmittedFile = EmittedAsset | EmittedChunk | EmittedPrebuiltChunk;
interface PluginContextResolveOptions {
  isEntry?: boolean;
  skipSelf?: boolean;
  custom?: CustomPluginOptions;
}
/** @category Plugin APIs */
type GetModuleInfo = (moduleId: string) => ModuleInfo | null;
/** @category Plugin APIs */
interface PluginContext extends MinimalPluginContext {
  fs: RolldownFsModule;
  emitFile(file: EmittedFile): string;
  getFileName(referenceId: string): string;
  getModuleIds(): IterableIterator<string>;
  getModuleInfo: GetModuleInfo;
  addWatchFile(id: string): void;
  load(options: {
    id: string;
    resolveDependencies?: boolean;
  } & Partial<PartialNull<ModuleOptions>>): Promise<ModuleInfo>;
  parse(input: string, options?: ParserOptions | null): Program;
  resolve(source: string, importer?: string, options?: PluginContextResolveOptions): Promise<ResolvedId | null>;
}
//#endregion
//#region src/plugin/transform-plugin-context.d.ts
/** @category Plugin APIs */
interface TransformPluginContext extends PluginContext {
  debug: LoggingFunctionWithPosition;
  info: LoggingFunctionWithPosition;
  warn: LoggingFunctionWithPosition;
  error(e: RollupError | string, pos?: number | {
    column: number;
    line: number;
  }): never;
  getCombinedSourcemap(): SourceMap;
}
//#endregion
//#region src/types/module-side-effects.d.ts
interface ModuleSideEffectsRule {
  test?: RegExp;
  external?: boolean;
  sideEffects: boolean;
}
type ModuleSideEffectsOption = boolean | readonly string[] | ModuleSideEffectsRule[] | ((id: string, external: boolean) => boolean | undefined) | "no-external";
/**
* When passing an object, you can fine-tune the tree-shaking behavior.
*/
type TreeshakingOptions = {
  /**
  * **Values:**
  *
  * - **`true`**: All modules are assumed to have side effects and will be included in the bundle even if none of their exports are used.
  * - **`false`**: No modules have side effects. This enables aggressive tree-shaking, removing any modules whose exports are not used.
  * - **`string[]`**: Array of module IDs that have side effects. Only modules in this list will be preserved if unused; all others can be tree-shaken when their exports are unused.
  * - **`'no-external'`**: Assumes no external modules have side effects while preserving the default behavior for local modules.
  * - **`ModuleSideEffectsRule[]`**: Array of rules with `test`, `external`, and `sideEffects` properties for fine-grained control.
  * - **`function`**: Function that receives `(id, external)` and returns whether the module has side effects.
  *
  * **Important:** Setting this to `false` or using an array/string assumes that your modules and their dependencies have no side effects other than their exports. Only use this if you're certain that removing unused modules won't break your application.
  *
  * > [!NOTE]
  * > **Performance: Prefer `ModuleSideEffectsRule[]` over functions**
  * >
  * > When possible, use rule-based configuration instead of functions. Rules are processed entirely in Rust, while JavaScript functions require runtime calls between Rust and JavaScript, which can hurt CPU utilization during builds.
  * >
  * > **Functions should be a last resort**: Only use the function signature when your logic cannot be expressed with patterns or simple string matching.
  * >
  * > **Rule advantages**: `ModuleSideEffectsRule[]` provides better performance by avoiding Rust-JavaScript runtime calls, clearer intent, and easier maintenance.
  *
  * @example
  * ```js
  * // Assume no modules have side effects (aggressive tree-shaking)
  * treeshake: {
  *   moduleSideEffects: false
  * }
  *
  * // Only specific modules have side effects (string array)
  * treeshake: {
  *   moduleSideEffects: [
  *     'lodash',
  *     'react-dom',
  *   ]
  * }
  *
  * // Use rules for pattern matching and granular control
  * treeshake: {
  *   moduleSideEffects: [
  *     { test: /^node:/, sideEffects: true },
  *     { test: /\.css$/, sideEffects: true },
  *     { test: /some-package/, sideEffects: false, external: false },
  *   ]
  * }
  *
  * // Custom function to determine side effects
  * treeshake: {
  *   moduleSideEffects: (id, external) => {
  *     if (external) return false; // external modules have no side effects
  *     return id.includes('/side-effects/') || id.endsWith('.css');
  *   }
  * }
  *
  * // Assume no external modules have side effects
  * treeshake: {
  *   moduleSideEffects: 'no-external',
  * }
  * ```
  *
  * **Common Use Cases:**
  * - **CSS files**: `{ test: /\.css$/, sideEffects: true }` - preserve CSS imports
  * - **Polyfills**: Add specific polyfill modules to the array
  * - **Plugins**: Modules that register themselves globally on import
  * - **Library development**: Set to `false` for libraries where unused exports should be removed
  * @default true
  */
  moduleSideEffects?: ModuleSideEffectsOption;
  /**
  * Whether to respect `/*@__PURE__*\/` annotations and other tree-shaking hints in the code.
  * @default true
  */
  annotations?: boolean;
  /**
  * Array of function names that should be considered pure (no side effects) even if they can't be automatically detected as pure
  *
  * @example
  * ```js
  * treeshake: {
  *   manualPureFunctions: ['console.log', 'debug.trace']
  * }
  * ```
  * @default []
  */
  manualPureFunctions?: readonly string[];
  /**
  * Whether to assume that accessing unknown global properties might have side effects.
  * @default true
  */
  unknownGlobalSideEffects?: boolean;
  /**
  * Whether to enable tree-shaking for CommonJS modules. When `true`, unused exports from CommonJS modules can be eliminated from the bundle, similar to ES modules. When disabled, CommonJS modules will always be included in their entirety.
  *
  * This option allows rolldown to analyze `exports.property` assignments in CommonJS modules and remove unused exports while preserving the module's side effects.
  *
  * @example
  * ```js
  * // source.js (CommonJS)
  * exports.used = 'This will be kept';
  * exports.unused = 'This will be tree-shaken away';
  *
  * // main.js
  * import { used } from './source.js';
  * // With commonjs: true, only the 'used' export is included in the bundle
  * // With commonjs: false, both exports are included
  * ```
  * @default true
  */
  commonjs?: boolean;
  /**
  * Controls whether reading properties from objects is considered to have side effects. Set to `always` for more conservative behavior.
  * @default false
  */
  propertyReadSideEffects?: false | "always";
  /**
  * Controls whether writing properties to objects is considered to have side effects. Set to `always` for conservative behavior.
  * @default 'always'
  */
  propertyWriteSideEffects?: false | "always";
};
//#endregion
//#region src/types/output-bundle.d.ts
/** @category Plugin APIs */
interface OutputBundle {
  [fileName: string]: OutputAsset | OutputChunk;
}
//#endregion
//#region src/types/rolldown-options-function.d.ts
type RolldownOptionsFunction = (commandLineArguments: Record<string, any>) => MaybePromise<RolldownOptions | RolldownOptions[]>;
//#endregion
//#region src/types/sourcemap.d.ts
/** @category Plugin APIs */
interface ExistingRawSourceMap {
  file?: string | null;
  mappings: string;
  names?: string[];
  sources?: (string | null)[];
  sourcesContent?: (string | null)[];
  sourceRoot?: string;
  version?: number;
  x_google_ignoreList?: number[];
}
type SourceMapInput = ExistingRawSourceMap | string | null;
//#endregion
//#region src/version.d.ts
/** @category Plugin APIs */
declare const VERSION: string;
//#endregion
//#region src/builtin-plugin/utils.d.ts
declare class BuiltinPlugin {
  name: BindingBuiltinPluginName;
  _options?: unknown;
  /** Vite-specific option to control plugin ordering */
  enforce?: "pre" | "post";
  constructor(name: BindingBuiltinPluginName, _options?: unknown);
}
//#endregion
//#region src/constants/plugin.d.ts
declare const ENUMERATED_INPUT_PLUGIN_HOOK_NAMES: readonly ["options", "buildStart", "resolveId", "load", "transform", "moduleParsed", "buildEnd", "onLog", "resolveDynamicImport", "closeBundle", "closeWatcher", "watchChange"];
declare const ENUMERATED_OUTPUT_PLUGIN_HOOK_NAMES: readonly ["augmentChunkHash", "outputOptions", "renderChunk", "renderStart", "renderError", "writeBundle", "generateBundle"];
declare const ENUMERATED_PLUGIN_HOOK_NAMES: [...typeof ENUMERATED_INPUT_PLUGIN_HOOK_NAMES, ...typeof ENUMERATED_OUTPUT_PLUGIN_HOOK_NAMES, "footer", "banner", "intro", "outro"];
/**
* Names of all defined hooks. It's like
* ```ts
* type DefinedHookNames = {
*   options: 'options',
*   buildStart: 'buildStart',
*   ...
* }
* ```
*/
type DefinedHookNames = { readonly [K in (typeof ENUMERATED_PLUGIN_HOOK_NAMES)[number]]: K };
/**
* Names of all defined hooks. It's like
* ```js
* const DEFINED_HOOK_NAMES ={
*   options: 'options',
*   buildStart: 'buildStart',
*   ...
* }
* ```
*/
declare const DEFINED_HOOK_NAMES: DefinedHookNames;
//#endregion
//#region src/plugin/with-filter.d.ts
type OverrideFilterObject = {
  transform?: HookFilterExtension<"transform">["filter"];
  resolveId?: HookFilterExtension<"resolveId">["filter"];
  load?: HookFilterExtension<"load">["filter"];
  pluginNamePattern?: StringOrRegExp[];
};
declare function withFilter<A, T extends RolldownPluginOption<A>>(pluginOption: T, filterObject: OverrideFilterObject | OverrideFilterObject[]): T;
//#endregion
//#region src/plugin/index.d.ts
type ModuleSideEffects = boolean | "no-treeshake" | null;
/** @category Plugin APIs */
type ModuleType = "js" | "jsx" | "ts" | "tsx" | "json" | "text" | "base64" | "dataurl" | "binary" | "empty" | (string & {});
/** @category Plugin APIs */
type ImportKind = BindingHookResolveIdExtraArgs["kind"];
/** @category Plugin APIs */
interface CustomPluginOptions {
  [plugin: string]: any;
}
/** @category Plugin APIs */
interface ModuleOptions {
  moduleSideEffects: ModuleSideEffects;
  meta: CustomPluginOptions;
  invalidate?: boolean;
  packageJsonPath?: string;
}
/** @category Plugin APIs */
interface ResolvedId extends ModuleOptions {
  external: boolean | "absolute";
  id: string;
}
/** @category Plugin APIs */
interface PartialResolvedId extends Partial<PartialNull<ModuleOptions>> {
  external?: boolean | "absolute" | "relative";
  id: string;
}
/** @category Plugin APIs */
interface SourceDescription extends Partial<PartialNull<ModuleOptions>> {
  code: string;
  map?: SourceMapInput;
  moduleType?: ModuleType;
}
/** @category Plugin APIs */
interface ResolveIdExtraOptions {
  custom?: CustomPluginOptions;
  isEntry: boolean;
  kind: BindingHookResolveIdExtraArgs["kind"];
}
/** @category Plugin APIs */
type ResolveIdResult = string | NullValue | false | PartialResolvedId;
/** @category Plugin APIs */
type LoadResult = NullValue | string | SourceDescription;
/** @category Plugin APIs */
type TransformResult = NullValue | string | (Omit<SourceDescription, "code"> & {
  code?: string | BindingMagicString;
});
type RenderedChunkMeta = {
  chunks: Record<string, RenderedChunk>;
};
/** @category Plugin APIs */
interface FunctionPluginHooks {
  [DEFINED_HOOK_NAMES.onLog]: (this: MinimalPluginContext, level: LogLevel, log: RollupLog) => NullValue | boolean;
  [DEFINED_HOOK_NAMES.options]: (this: MinimalPluginContext, options: InputOptions) => NullValue | InputOptions;
  [DEFINED_HOOK_NAMES.outputOptions]: (this: MinimalPluginContext, options: OutputOptions) => NullValue | OutputOptions;
  [DEFINED_HOOK_NAMES.buildStart]: (this: PluginContext, options: NormalizedInputOptions) => void;
  [DEFINED_HOOK_NAMES.resolveId]: (this: PluginContext, source: string, importer: string | undefined, extraOptions: ResolveIdExtraOptions) => ResolveIdResult;
  /**
  * @deprecated
  * This hook is only for rollup plugin compatibility. Please use `resolveId` instead.
  */
  [DEFINED_HOOK_NAMES.resolveDynamicImport]: (this: PluginContext, source: string, importer: string | undefined) => ResolveIdResult;
  [DEFINED_HOOK_NAMES.load]: (this: PluginContext, id: string) => MaybePromise<LoadResult>;
  [DEFINED_HOOK_NAMES.transform]: (this: TransformPluginContext, code: string, id: string, meta: BindingTransformHookExtraArgs & {
    moduleType: ModuleType;
    magicString?: BindingMagicString;
    ast?: Program;
  }) => TransformResult;
  [DEFINED_HOOK_NAMES.moduleParsed]: (this: PluginContext, moduleInfo: ModuleInfo) => void;
  [DEFINED_HOOK_NAMES.buildEnd]: (this: PluginContext, err?: Error) => void;
  [DEFINED_HOOK_NAMES.renderStart]: (this: PluginContext, outputOptions: NormalizedOutputOptions, inputOptions: NormalizedInputOptions) => void;
  [DEFINED_HOOK_NAMES.renderChunk]: (this: PluginContext, code: string, chunk: RenderedChunk, outputOptions: NormalizedOutputOptions, meta: RenderedChunkMeta) => NullValue | string | {
    code: string;
    map?: SourceMapInput;
  };
  [DEFINED_HOOK_NAMES.augmentChunkHash]: (this: PluginContext, chunk: RenderedChunk) => string | void;
  [DEFINED_HOOK_NAMES.renderError]: (this: PluginContext, error: Error) => void;
  [DEFINED_HOOK_NAMES.generateBundle]: (this: PluginContext, outputOptions: NormalizedOutputOptions, bundle: OutputBundle, isWrite: boolean) => void;
  [DEFINED_HOOK_NAMES.writeBundle]: (this: PluginContext, outputOptions: NormalizedOutputOptions, bundle: OutputBundle) => void;
  [DEFINED_HOOK_NAMES.closeBundle]: (this: PluginContext) => void;
  [DEFINED_HOOK_NAMES.watchChange]: (this: PluginContext, id: string, event: {
    event: ChangeEvent;
  }) => void;
  [DEFINED_HOOK_NAMES.closeWatcher]: (this: PluginContext) => void;
}
type ChangeEvent = "create" | "update" | "delete";
type PluginOrder = "pre" | "post" | null;
type ObjectHookMeta = {
  order?: PluginOrder;
};
/** @category Plugin APIs */
type ObjectHook<T, O = {}> = T | ({
  handler: T;
} & ObjectHookMeta & O);
type SyncPluginHooks = DefinedHookNames["augmentChunkHash" | "onLog" | "outputOptions"];
/** @category Plugin APIs */
type AsyncPluginHooks = Exclude<keyof FunctionPluginHooks, SyncPluginHooks>;
type FirstPluginHooks = DefinedHookNames["load" | "resolveDynamicImport" | "resolveId"];
type SequentialPluginHooks = DefinedHookNames["augmentChunkHash" | "generateBundle" | "onLog" | "options" | "outputOptions" | "renderChunk" | "transform"];
type AddonHooks = DefinedHookNames["banner" | "footer" | "intro" | "outro"];
type OutputPluginHooks = DefinedHookNames["augmentChunkHash" | "generateBundle" | "outputOptions" | "renderChunk" | "renderError" | "renderStart" | "writeBundle"];
/** @internal */
type ParallelPluginHooks = Exclude<keyof FunctionPluginHooks | AddonHooks, FirstPluginHooks | SequentialPluginHooks>;
/** @category Plugin APIs */
type HookFilterExtension<K$1 extends keyof FunctionPluginHooks> = K$1 extends "transform" ? {
  filter?: TUnionWithTopLevelFilterExpressionArray<HookFilter>;
} : K$1 extends "load" ? {
  filter?: TUnionWithTopLevelFilterExpressionArray<Pick<HookFilter, "id">>;
} : K$1 extends "resolveId" ? {
  filter?: TUnionWithTopLevelFilterExpressionArray<{
    id?: GeneralHookFilter<RegExp>;
  }>;
} : K$1 extends "renderChunk" ? {
  filter?: TUnionWithTopLevelFilterExpressionArray<Pick<HookFilter, "code">>;
} : {};
type PluginHooks = { [K in keyof FunctionPluginHooks]: ObjectHook<K extends AsyncPluginHooks ? MakeAsync<FunctionPluginHooks[K]> : FunctionPluginHooks[K], HookFilterExtension<K> & (K extends ParallelPluginHooks ? {
  /**
  * @deprecated
  * this is only for rollup Plugin type compatibility.
  * hooks always work as `sequential: true`.
  */
  sequential?: boolean;
} : {})> };
type AddonHookFunction = (this: PluginContext, chunk: RenderedChunk) => string | Promise<string>;
type AddonHook = string | AddonHookFunction;
interface OutputPlugin extends Partial<{ [K in keyof PluginHooks as K & OutputPluginHooks]: PluginHooks[K] }>, Partial<{ [K in AddonHooks]: ObjectHook<AddonHook> }> {
  name: string;
}
/** @category Plugin APIs */
interface Plugin<A = any> extends OutputPlugin, Partial<PluginHooks> {
  api?: A;
}
type RolldownPlugin<A = any> = Plugin<A> | BuiltinPlugin | ParallelPlugin;
type RolldownPluginOption<A = any> = MaybePromise<NullValue<RolldownPlugin<A>> | {
  name: string;
} | false | RolldownPluginOption[]>;
type RolldownOutputPlugin = OutputPlugin | BuiltinPlugin;
type RolldownOutputPluginOption = MaybePromise<NullValue<RolldownOutputPlugin> | {
  name: string;
} | false | RolldownOutputPluginOption[]>;
//#endregion
//#region src/options/transform-options.d.ts
interface TransformOptions extends Omit<TransformOptions$1, "sourceType" | "lang" | "cwd" | "sourcemap" | "define" | "inject" | "jsx"> {
  /**
  * Replace global variables or [property accessors](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Property_accessors) with the provided values.
  *
  * # Examples
  *
  * - Replace the global variable `IS_PROD` with `true`
  *
  * ```js rolldown.config.js
  * export default defineConfig({ transform: { define: { IS_PROD: 'true' } } })
  * ```
  *
  * Result:
  *
  * ```js
  * // Input
  * if (IS_PROD) {
  *   console.log('Production mode')
  * }
  *
  * // After bundling
  * if (true) {
  *   console.log('Production mode')
  * }
  * ```
  *
  * - Replace the property accessor `process.env.NODE_ENV` with `'production'`
  *
  * ```js rolldown.config.js
  * export default defineConfig({ transform: { define: { 'process.env.NODE_ENV': "'production'" } } })
  * ```
  *
  * Result:
  *
  * ```js
  * // Input
  * if (process.env.NODE_ENV === 'production') {
  *  console.log('Production mode')
  * }
  *
  * // After bundling
  * if ('production' === 'production') {
  * console.log('Production mode')
  * }
  *
  * ```
  */
  define?: Record<string, string>;
  /**
  * Inject import statements on demand.
  *
  * The API is aligned with `@rollup/plugin-inject`.
  *
  * ## Supported patterns
  * ```js
  * {
  *   // import { Promise } from 'es6-promise'
  *   Promise: ['es6-promise', 'Promise'],
  *
  *   // import { Promise as P } from 'es6-promise'
  *   P: ['es6-promise', 'Promise'],
  *
  *   // import $ from 'jquery'
  *   $: 'jquery',
  *
  *   // import * as fs from 'node:fs'
  *   fs: ['node:fs', '*'],
  *
  *   // Inject shims for property access pattern
  *   'Object.assign': path.resolve( 'src/helpers/object-assign.js' ),
  * }
  * ```
  */
  inject?: Record<string, string | [string, string]>;
  /**
  * Remove labeled statements with these label names.
  *
  * Labeled statements are JavaScript statements prefixed with a label identifier.
  * This option allows you to strip specific labeled statements from the output,
  * which is useful for removing debug-only code in production builds.
  *
  * ## Example
  *
  * ```js rolldown.config.js
  * export default defineConfig({ transform: { dropLabels: ['DEBUG', 'DEV'] } })
  * ```
  *
  * Result:
  *
  * ```js
  * // Input
  * DEBUG: console.log('Debug info');
  * DEV: {
  *   console.log('Development mode');
  * }
  * console.log('Production code');
  *
  * // After bundling
  * console.log('Production code');
  * ```
  */
  dropLabels?: string[];
  jsx?: false | "react" | "react-jsx" | "preserve" | JsxOptions;
}
//#endregion
//#region src/options/input-options.d.ts
type InputOption = string | string[] | Record<string, string>;
type ExternalOptionFunction = (id: string, parentId: string | undefined, isResolved: boolean) => NullValue<boolean>;
type ExternalOption = StringOrRegExp | StringOrRegExp[] | ExternalOptionFunction;
type ModuleTypes = Record<string, "js" | "jsx" | "ts" | "tsx" | "json" | "text" | "base64" | "dataurl" | "binary" | "empty" | "css" | "asset">;
interface WatcherOptions {
  skipWrite?: boolean;
  buildDelay?: number;
  notify?: {
    pollInterval?: number;
    compareContents?: boolean;
  };
  include?: StringOrRegExp | StringOrRegExp[];
  exclude?: StringOrRegExp | StringOrRegExp[];
  onInvalidate?: (id: string) => void;
  clearScreen?: boolean;
}
type MakeAbsoluteExternalsRelative = boolean | "ifRelativeSource";
type DevModeOptions = boolean | {
  host?: string;
  port?: number;
  implement?: string;
  lazy?: boolean;
};
type OptimizationOptions = {
  /**
  * Inline imported constant values during bundling instead of preserving variable references.
  *
  * When enabled, constant values from imported modules will be inlined at their usage sites,
  * potentially reducing bundle size and improving runtime performance by eliminating variable lookups.
  *
  * **Options:**
  * - `true`: equivalent to `{ mode: 'all', pass: 1 }`, enabling constant inlining for all eligible constants with a single pass.
  * - `false`: Disable constant inlining
  * - `{ mode: 'smart' | 'all', pass?: number }`:
  *   - `mode: 'smart'`: Only inline constants in specific scenarios where it is likely to reduce bundle size and improve performance.
  *     Smart mode inlines constants in these specific scenarios:
  *     1. `if (test) {} else {}` - condition expressions in if statements
  *     2. `test ? a : b` - condition expressions in ternary operators
  *     3. `test1 || test2` - logical OR expressions
  *     4. `test1 && test2` - logical AND expressions
  *     5. `test1 ?? test2` - nullish coalescing expressions
  *  - `mode: 'all'`: Inline all imported constants wherever they are used.
  *  - `pass`: Number of passes to perform for inlining constants.
  *
  * @example
  * ```js
  * // Input files:
  * // constants.js
  * export const API_URL = 'https://api.example.com';
  *
  * // main.js
  * import { API_URL } from './constants.js';
  * console.log(API_URL);
  *
  * // With inlineConst: true, the bundled output becomes:
  * console.log('https://api.example.com');
  *
  * // Instead of:
  * const API_URL = 'https://api.example.com';
  * console.log(API_URL);
  * ```
  *
  * @default false
  */
  inlineConst?: boolean | {
    mode?: "all" | "smart";
    pass?: number;
  };
  /**
  * Use PIFE pattern for module wrappers
  */
  pifeForModuleWrappers?: boolean;
};
type AttachDebugOptions = "none" | "simple" | "full";
type ChunkModulesOrder = "exec-order" | "module-id";
type OnLogFunction = (level: LogLevel, log: RollupLog, defaultHandler: LogOrStringHandler) => void;
type OnwarnFunction = (warning: RollupLog, defaultHandler: (warning: RollupLogWithString | (() => RollupLogWithString)) => void) => void;
interface InputOptions {
  /**
  * Defines entries and location(s) of entry modules for the bundle. Relative paths are resolved based on the `cwd` option.
  * {@include ./docs/input.md}
  */
  input?: InputOption;
  plugins?: RolldownPluginOption;
  /**
  * Specifies which modules should be treated as external and not bundled. External modules will be left as import statements in the output.
  * {@include ./docs/external.md}
  */
  external?: ExternalOption;
  resolve?: {
    /**
    * @example
    * ```js
    * resolve: {
    *   alias: {
    *     '@': '/src',
    *     'utils': './src/utils',
    *   }
    * }
    * ```
    * > [!WARNING]
    * > `resolve.alias` will not call `resolveId` hooks of other plugin.
    * > If you want to call `resolveId` hooks of other plugin, use `viteAliasPlugin` from `rolldown/experimental` instead.
    * > You could find more discussion in [this issue](https://github.com/rolldown/rolldown/issues/3615)
    */
    alias?: Record<string, string[] | string | false>;
    /**
    * Fields in package.json to check for aliased paths.
    */
    aliasFields?: string[][];
    /**
    * Condition names to use when resolving exports in package.json. Defaults based on platform and import kind:
    * - **Browser platform**: `["import", "browser", "default"]` for import statements, `["require", "browser", "default"]` for require() calls
    * - **Node platform**: `["import", "node", "default"]` for import statements, `["require", "node", "default"]` for require() calls
    * - **Neutral platform**: `["import", "default"]` for import statements, `["require", "default"]` for require() calls
    */
    conditionNames?: string[];
    /**
    * Map of extensions to alternative extensions.
    *
    * With writing `import './foo.js'` in a file, you want to resolve it to `foo.ts` instead of `foo.js`.
    * You can achieve this by setting: `extensionAlias: { '.js': ['.ts', '.js'] }`.
    */
    extensionAlias?: Record<string, string[]>;
    /**
    * Fields in package.json to check for exports.
    */
    exportsFields?: string[][];
    /**
    * Extensions to try when resolving files. These are tried in order from first to last.
    * @default ['.tsx', '.ts', '.jsx', '.js', '.json']
    */
    extensions?: string[];
    /**
    * Fields in package.json to check for entry points. Defaults based on platform:
    * - **Node**: `['main', 'module']`
    * - **Browser**: `['browser', 'module', 'main']`
    * - **Neutral**: `[]` (relies on exports field)
    */
    mainFields?: string[];
    /**
    * Filenames to try when resolving directories.
    * @default ['index']
    */
    mainFiles?: string[];
    /**
    * Directories to search for modules.
    * @default ['node_modules']
    */
    modules?: string[];
    /**
    * Whether to follow symlinks when resolving modules.
    * @default true
    */
    symlinks?: boolean;
    /**
    * @deprecated Use the top-level `tsconfig` option instead.
    */
    tsconfigFilename?: string;
  };
  /**
  * The working directory to use when resolving relative paths in the configuration.
  * @default process.cwd()
  */
  cwd?: string;
  /**
  * Expected platform where the code run.
  *
  *  When the platform is set to neutral:
  *    - When bundling is enabled the default output format is set to esm, which uses the export syntax introduced with ECMAScript 2015 (i.e. ES6). You can change the output format if this default is not appropriate.
  *    - The main fields setting is empty by default. If you want to use npm-style packages, you will likely have to configure this to be something else such as main for the standard main field used by node.
  *    - The conditions setting does not automatically include any platform-specific values.
  *
  * @default
  * - 'node' if the format is 'cjs'
  * - 'browser' for other formats
  * {@include ./docs/platform.md}
  */
  platform?: "node" | "browser" | "neutral";
  /**
  * When `true`, creates shim variables for missing exports instead of throwing an error.
  * @default false
  * {@include ./docs/shim-missing-exports.md}
  */
  shimMissingExports?: boolean;
  /**
  * Controls tree-shaking (dead code elimination). When `true`, unused code will be removed from the bundle to reduce bundle size.
  * @default true
  */
  treeshake?: boolean | TreeshakingOptions;
  /**
  * Controls the verbosity of console logging during the build.
  * @default 'info'
  */
  logLevel?: LogLevelOption;
  /**
  * Custom handler for logs. Called for each log message before it's written to the console.
  */
  onLog?: OnLogFunction;
  /**
  * Custom handler for warnings during the build process.
  * @deprecated
  * :::: warning Deprecated
  * This is a legacy API. Consider using `onLog` instead for better control over all log types.
  * ::: details Migration to `onLog`
  * To migrate from `onwarn` to `onLog`, check the `level` parameter to filter for
  * warnings:
  * ```js
  * // Before: Using `onwarn`
  * export default {
  *   onwarn(warning, defaultHandler) {
  *     // Suppress certain warnings
  *     if (warning.code === 'CIRCULAR_DEPENDENCY') return;
  *     // Handle other warnings with default behavior
  *     defaultHandler(warning);
  *   },
  * };
  * ```
  * ```js
  * // After: Using `onLog`
  * export default {
  *   onLog(level, log, defaultHandler) {
  *     // Handle only warnings (same behavior as `onwarn`)
  *     if (level === 'warn') {
  *       // Suppress certain warnings
  *       if (log.code === 'CIRCULAR_DEPENDENCY') return;
  *       // Handle other warnings with default behavior
  *       defaultHandler(level, log);
  *     } else {
  *       // Let other log levels pass through
  *       defaultHandler(level, log);
  *     }
  *   },
  * };
  * ```
  * :::
  * ::::
  */
  onwarn?: OnwarnFunction;
  /**
  * Maps file patterns to module types, controlling how files are processed. This is conceptually similar to esbuild's loader option, allowing you to specify how different file extensions should be handled.
  */
  moduleTypes?: ModuleTypes;
  /**
  * Experimental features that may change in future releases and can introduce behavior change without a major version bump.
  */
  experimental?: {
    /**
    * Lets modules be executed in the order they are declared.
    *
    * This is done by injecting runtime helpers to ensure that modules are executed in the order they are imported. External modules won't be affected.
    *
    * > [!WARNING]
    * > Enabling this option may negatively increase bundle size. It is recommended to use this option only when absolutely necessary.
    * @default false
    */
    strictExecutionOrder?: boolean;
    /**
    * Disable live bindings for exported variables.
    * @default false
    */
    disableLiveBindings?: boolean;
    /**
    * Enable Vite compatible mode.
    * @default false
    */
    viteMode?: boolean;
    /**
    * When enabled, `new URL()` calls will be transformed to a stable asset URL which includes the updated name and content hash.
    * It is necessary to pass `import.meta.url` as the second argument to the
    * `new URL` constructor, otherwise no transform will be applied.
    * :::warning
    * JavaScript and TypeScript files referenced via `new URL('./file.js', import.meta.url)` or `new URL('./file.ts', import.meta.url)` will **not** be transformed or bundled. The file will be copied as-is, meaning TypeScript files remain untransformed and dependencies are not resolved.
    *
    * The expected behavior for JS/TS files is still being discussed and may
    * change in future releases. See [#7258](https://github.com/rolldown/rolldown/issues/7258) for more context.
    * :::
    * @example
    * ```js
    * // main.js
    * const url = new URL('./styles.css', import.meta.url);
    * console.log(url);
    *
    * // Example output after bundling WITHOUT the option (default)
    * const url = new URL('./styles.css', import.meta.url);
    * console.log(url);
    *
    * // Example output after bundling WITH `experimental.resolveNewUrlToAsset` set to `true`
    * const url = new URL('assets/styles-CjdrdY7X.css', import.meta.url);
    * console.log(url);
    * ```
    * @default false
    */
    resolveNewUrlToAsset?: boolean;
    devMode?: DevModeOptions;
    /**
    * Control which order should use when rendering modules in chunk.
    *
    * Available options:
    * - `exec-order`: Almost equivalent to the topological order of the module graph, but specially handling when module graph has cycle.
    * - `module-id`: This is more friendly for gzip compression, especially for some javascript static asset lib (e.g. icon library)
    * > [!NOTE]
    * > Try to sort the modules by their module id if possible(Since rolldown scope hoist all modules in the chunk, we only try to sort those modules by module id if we could ensure runtime behavior is correct after sorting).
    * @default 'exec-order'
    */
    chunkModulesOrder?: ChunkModulesOrder;
    /**
    * Attach debug information to the output bundle.
    *
    * Available modes:
    * - `none`: No debug information is attached.
    * - `simple`: Attach comments indicating which files the bundled code comes from. These comments could be removed by the minifier.
    * - `full`: Attach detailed debug information to the output bundle. These comments are using legal comment syntax, so they won't be removed by the minifier.
    *
    * > [!WARNING]
    * > You shouldn't use `full` in the production build.
    * @default 'simple'
    */
    attachDebugInfo?: AttachDebugOptions;
    /**
    * Enables automatic generation of a chunk import map asset during build.
    *
    * This map only includes chunks with hashed filenames, where keys are derived from the facade module
    * name or primary chunk name. It produces stable and unique hash-based filenames, effectively preventing
    * cascading cache invalidation caused by content hashes and maximizing browser cache reuse.
    *
    * The output defaults to `importmap.json` unless overridden via `fileName`. A base URL prefix
    * (default `"/"`) can be applied to all paths. The resulting JSON is a valid import map and can be
    * directly injected into HTML via `<script type="importmap">`.
    *
    * @example
    * ```js
    * {
    *   experimental: {
    *     chunkImportMap: {
    *       baseUrl: '/',
    *       fileName: 'importmap.json'
    *     }
    *   },
    *   plugins: [
    *     {
    *       name: 'inject-import-map',
    *       generateBundle(_, bundle) {
    *         const chunkImportMap = bundle['importmap.json'];
    *         if (chunkImportMap?.type === 'asset') {
    *           const htmlPath = path.resolve('index.html');
    *           let html = fs.readFileSync(htmlPath, 'utf-8');
    *
    *           html = html.replace(
    *             /<script\s+type="importmap"[^>]*>[\s\S]*?<\/script>/i,
    *             `<script type="importmap">${chunkImportMap.source}<\/script>`
    *           );
    *
    *           fs.writeFileSync(htmlPath, html);
    *           delete bundle['importmap.json'];
    *         }
    *       }
    *     }
    *   ]
    * }
    * ```
    *
    * > [!TIP]
    * > If you want to learn more, you can check out the example here: [examples/chunk-import-map](https://github.com/rolldown/rolldown/tree/main/examples/chunk-import-map)
    * @default false
    */
    chunkImportMap?: boolean | {
      baseUrl?: string;
      fileName?: string;
    };
    /**
    * Enable on-demand wrapping of modules.
    * @default false
    */
    onDemandWrapping?: boolean;
    /**
    * Enable incremental build support. Required to be used with `watch` mode.
    * @default false
    */
    incrementalBuild?: boolean;
    /**
    * Enable high-resolution source maps for transform operations.
    * @default false
    */
    transformHiresSourcemap?: boolean | "boundary";
    /**
    * Use native Rust implementation of MagicString for source map generation.
    *
    * [MagicString](https://github.com/rich-harris/magic-string) is a JavaScript library commonly used by bundlers
    * for string manipulation and source map generation. When enabled, rolldown will use a native Rust
    * implementation of MagicString instead of the JavaScript version, providing significantly better performance
    * during source map generation and code transformation.
    *
    * **Benefits**
    *
    * - **Improved Performance**: The native Rust implementation is typically faster than the JavaScript version,
    *   especially for large codebases with extensive source maps.
    * - **Background Processing**: Source map generation is performed asynchronously in a background thread,
    *   allowing the main bundling process to continue without blocking. This parallel processing can significantly
    *   reduce overall build times when working with JavaScript transform hooks.
    * - **Better Integration**: Seamless integration with rolldown's native Rust architecture.
    *
    * @example
    * ```js
    * export default {
    *   experimental: {
    *     nativeMagicString: true
    *   },
    *   output: {
    *     sourcemap: true
    *   }
    * }
    * ```
    *
    * > [!NOTE]
    * > This is an experimental feature. While it aims to provide identical behavior to the JavaScript
    * > implementation, there may be edge cases. Please report any discrepancies you encounter.
    * > For a complete working example, see [examples/native-magic-string](https://github.com/rolldown/rolldown/tree/main/examples/native-magic-string)
    * @default false
    */
    nativeMagicString?: boolean;
    /**
    * Control whether to optimize chunks by allowing entry chunks to have different exports than the underlying entry module.
    * This optimization can reduce the number of generated chunks.
    *
    * When enabled, rolldown will try to insert common modules directly into existing chunks rather than creating
    * separate chunks for them, which can result in fewer output files and better performance.
    *
    * This optimization is automatically disabled when any module uses top-level await (TLA) or contains TLA dependencies,
    * as it could affect execution order guarantees.
    *
    * @default true
    */
    chunkOptimization?: boolean;
  };
  /**
  * Configure how the code is transformed. This process happens after the `transform` hook.
  *
  * To transpile [legacy decorators](https://github.com/tc39/proposal-decorators/tree/4ac0f4cd31bd0f2e8170cb4c5136e51671e46c8d), you could use
  *
  * ```js
  * export default defineConfig({
  *   transform: {
  *     decorator: {
  *       legacy: true,
  *     },
  *   },
  * })
  * ```
  *
  * For latest decorators proposal, rolldown is able to bundle them but doesn't support transpiling them yet.
  */
  transform?: TransformOptions;
  watch?: WatcherOptions | false;
  /**
  * Controls which warnings are emitted during the build process. Each option can be set to `true` (emit warning) or `false` (suppress warning).
  */
  checks?: ChecksOptions;
  makeAbsoluteExternalsRelative?: MakeAbsoluteExternalsRelative;
  devtools?: {
    sessionId?: string;
  };
  /**
  * Controls how entry chunk exports are preserved. This determines whether Rolldown needs to create facade chunks (additional wrapper chunks) to maintain the exact export signatures of entry modules, or whether it can combine entry modules with other chunks for optimization.
  * @default 'strict'
  * {@include ./docs/preserve-entry-signatures.md}
  */
  preserveEntrySignatures?: false | "strict" | "allow-extension" | "exports-only";
  /**
  * Configure optimization features for the bundler.
  */
  optimization?: OptimizationOptions;
  /**
  * The value of `this` at the top level of each output chunk. For IIFE and UMD formats, this defaults to `'window'` or `'global'` depending on the platform.
  * @example
  * **Set custom context**
  * ```js
  * export default {
  *   context: 'globalThis',
  *   output: {
  *     format: 'iife',
  *   },
  * };
  * ```
  * **Use window for browser builds**
  * ```js
  * export default {
  *   context: 'window',
  *   platform: 'browser',
  *   output: {
  *     format: 'iife',
  *   },
  * };
  * ```
  * {@include ./docs/context.md}
  */
  context?: string;
  /**
  * Configures TypeScript configuration file resolution and usage.
  * {@include ./docs/tsconfig.md}
  * @default undefined (no tsconfig resolution)
  */
  tsconfig?: true | string;
}
//#endregion
//#region src/types/rolldown-options.d.ts
interface RolldownOptions extends InputOptions {
  output?: OutputOptions | OutputOptions[];
}
//#endregion
//#region src/types/config-export.d.ts
/**
* Type for `default export` of `rolldown.config.js` file.
*/
type ConfigExport = RolldownOptions | RolldownOptions[] | RolldownOptionsFunction;
//#endregion
//#region src/utils/define-config.d.ts
declare function defineConfig(config: RolldownOptions): RolldownOptions;
declare function defineConfig(config: RolldownOptions[]): RolldownOptions[];
declare function defineConfig(config: RolldownOptionsFunction): RolldownOptionsFunction;
declare function defineConfig(config: ConfigExport): ConfigExport;
//#endregion
export { RolldownFsModule as $, BuiltinPlugin as A, RenderedModule as At, EmittedPrebuiltChunk as B, ResolveIdResult as C, PreRenderedAsset as Ct, SourceDescription as D, OutputAsset as Dt, RolldownPluginOption as E, StringOrRegExp as Et, OutputBundle as F, SourcemapIgnoreListOption as Ft, MinimalPluginContext as G, PluginContext as H, TreeshakingOptions as I, HookFilter as J, PluginContextMeta as K, TransformPluginContext as L, ExistingRawSourceMap as M, SourceMap as Mt, SourceMapInput as N, freeExternalMemory as Nt, TransformResult as O, OutputChunk as Ot, RolldownOptionsFunction as P, ModuleInfo as Pt, RolldownFileStats as Q, EmittedAsset as R, ResolveIdExtraOptions as S, OutputOptions as St, RolldownPlugin as T, PartialNull as Tt, DefineParallelPluginResult as U, GetModuleInfo as V, defineParallelPlugin as W, BufferEncoding as X, ModuleTypeFilter as Y, RolldownDirectoryEntry as Z, ModuleType as _, GeneratedCodeOptions as _t, InputOption as a, WarningHandlerWithDefault as at, PartialResolvedId as b, MinifyOptions as bt, OptimizationOptions as c, RolldownWatcherEvent as ct, CustomPluginOptions as d, RolldownBuild as dt, InternalModuleFormat as et, FunctionPluginHooks as f, BuildOptions as ft, ModuleOptions as g, ChunkingContext as gt, LoadResult as h, ChunkFileNamesFunction as ht, ExternalOption as i, LoggingFunction as it, VERSION as j, RolldownOutput as jt, withFilter as k, RenderedChunk as kt, WatcherOptions as l, WatchOptions as lt, ImportKind as m, AddonFunction as mt, ConfigExport as n, NormalizedInputOptions as nt, InputOptions as o, watch as ot, HookFilterExtension as p, build as pt, GeneralHookFilter as q, RolldownOptions as r, ChecksOptions as rt, ModuleTypes as s, RolldownWatcher as st, defineConfig as t, NormalizedOutputOptions as tt, AsyncPluginHooks as u, rolldown as ut, ObjectHook as v, GeneratedCodePreset as vt, ResolvedId as w, MaybePromise as wt, Plugin as x, ModuleFormat as xt, ParallelPluginHooks as y, GlobalsFunction as yt, EmittedFile as z };