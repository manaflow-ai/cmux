# @vercel/build-utils

## 13.2.16

### Patch Changes

- Add maxConcurrency to experimentalTriggers ([#14725](https://github.com/vercel/vercel/pull/14725))

- Add maxConcurrency trigger field ([#14725](https://github.com/vercel/vercel/pull/14725))

## 13.2.15

### Patch Changes

- Optimize `getAvailableNodeVersions` to skip discontinued versions and use non-throwing `statSync` ([#14686](https://github.com/vercel/vercel/pull/14686))

## 13.2.14

### Patch Changes

- Add `experimentalServices` to `vercel.json` ([#14612](https://github.com/vercel/vercel/pull/14612))

## 13.2.13

### Patch Changes

- [python] experimental python runtime framework preset ([#14646](https://github.com/vercel/vercel/pull/14646))

## 13.2.12

### Patch Changes

- Add `findPackageJson` function for optimized package.json lookup without lockfile scanning. This improves `getNodeVersion` performance by avoiding unnecessary lockfile parsing. ([#14658](https://github.com/vercel/vercel/pull/14658))

## 13.2.10

### Patch Changes

- Add 'go' as a valid runtimeLanguage option for Lambda functions ([#14624](https://github.com/vercel/vercel/pull/14624))

## 13.2.9

### Patch Changes

- replace getRuntimeNodeVersion with getNodeVersion ([#14622](https://github.com/vercel/vercel/pull/14622))

## 13.2.8

### Patch Changes

- Remove getSpawnOptions ([#14604](https://github.com/vercel/vercel/pull/14604))

## 13.2.7

### Patch Changes

- Replace getNodeVersion with getRuntimeNodeVersion ([#14600](https://github.com/vercel/vercel/pull/14600))

- Add zero-config support for Koa.js ([#14567](https://github.com/vercel/vercel/pull/14567))

## 13.2.6

### Patch Changes

- Update http links in Node.js version incompatibility message to https ([#14583](https://github.com/vercel/vercel/pull/14583))

- Ensure internal build step runs if a build script is missing ([#14564](https://github.com/vercel/vercel/pull/14564))

## 13.2.5

### Patch Changes

- Adding in user configured deploymentId to build output type ([#14497](https://github.com/vercel/vercel/pull/14497))

- skip secondary installation for vercel.ts ([#14471](https://github.com/vercel/vercel/pull/14471))

## 13.2.4

### Patch Changes

- [python] only create api builders for `.py` files that export an app or handler ([#14493](https://github.com/vercel/vercel/pull/14493))

## 13.2.3

### Patch Changes

- Use `workspace:*` for workspace dependencies ([#14396](https://github.com/vercel/vercel/pull/14396))

## 13.2.2

### Patch Changes

- Bump NFT dependency ([#14373](https://github.com/vercel/vercel/pull/14373))

## 13.2.1

### Patch Changes

- Disables auto instrumentation when the app has manual instrumentation setup ([#14345](https://github.com/vercel/vercel/pull/14345))

## 13.2.0

### Minor Changes

- Remove env var check for node24 ([#14355](https://github.com/vercel/vercel/pull/14355))

## 13.1.2

### Patch Changes

- Support `runtimeLanguage` in build-utils ([#14344](https://github.com/vercel/vercel/pull/14344))

## 13.1.1

### Patch Changes

- Only run introspection when isExperimentalBackendsWithoutIntrospectionEnabled is truthy ([#14336](https://github.com/vercel/vercel/pull/14336))

## 13.1.0

### Minor Changes

- Remove --unsafe-perm from npm install command ([#14302](https://github.com/vercel/vercel/pull/14302))

## 13.0.2

### Patch Changes

- Improve warning messages surrounding Elysia ([#14272](https://github.com/vercel/vercel/pull/14272))

## 13.0.1

### Patch Changes

- Revert "Remove getSpawnOptions" ([#14261](https://github.com/vercel/vercel/pull/14261))

## 13.0.0

### Major Changes

- Remove getSpawnOptions ([#14176](https://github.com/vercel/vercel/pull/14176))

## 12.2.4

### Patch Changes

- Add helper for detecting backend builders ([#14182](https://github.com/vercel/vercel/pull/14182))

## 12.2.3

### Patch Changes

- Add Elysia framework ([#14164](https://github.com/vercel/vercel/pull/14164))

## 12.2.2

### Patch Changes

- Allow Node.js 24 behind env var feature flag ([#14160](https://github.com/vercel/vercel/pull/14160))

## 12.2.1

### Patch Changes

- Add backend util helpers ([#14152](https://github.com/vercel/vercel/pull/14152))

## 12.2.0

### Minor Changes

- Add support for Bun through a vercel.json property ([#14130](https://github.com/vercel/vercel/pull/14130))

## 12.1.3

### Patch Changes

- Revert the prebuilt archive split from 20MB back to 100MB ([#14103](https://github.com/vercel/vercel/pull/14103))

## 12.1.2

### Patch Changes

- Reuse duplicated node builder logic ([#14031](https://github.com/vercel/vercel/pull/14031))

## 12.1.1

### Patch Changes

- Change archive split from 100MB -> 20MB ([#14046](https://github.com/vercel/vercel/pull/14046))

## 12.1.0

### Minor Changes

- Support turbo.jsonc ([#13792](https://github.com/vercel/vercel/pull/13792))

## 12.0.0

### Major Changes

- Drop Node.js 18, bump minimum to Node.js 20 ([#13856](https://github.com/vercel/vercel/pull/13856))

## 11.0.2

### Patch Changes

- Add support for the supportsCancellation function flag ([#13807](https://github.com/vercel/vercel/pull/13807))

## 11.0.1

### Patch Changes

- Fix 404 status for /api routes when using Hono with the vercel dev server ([#13706](https://github.com/vercel/vercel/pull/13706))

## 11.0.0

### Major Changes

- Add support for vlt as a package manager ([#13591](https://github.com/vercel/vercel/pull/13591))

## 10.6.7

### Patch Changes

- Reverting support for `preferredRegion` ([#13566](https://github.com/vercel/vercel/pull/13566))

## 10.6.6

### Patch Changes

- Deprecate Node.js 18.x with warning ([#13549](https://github.com/vercel/vercel/pull/13549))

## 10.6.5

### Patch Changes

- rename experimental maxAttempts to maxDeliveries ([#13534](https://github.com/vercel/vercel/pull/13534))

## 10.6.4

### Patch Changes

- simplify experimental triggers ([#13527](https://github.com/vercel/vercel/pull/13527))

## 10.6.3

### Patch Changes

- make POST method required ([#13518](https://github.com/vercel/vercel/pull/13518))

- Update more handling for experimentalTriggers ([#13517](https://github.com/vercel/vercel/pull/13517))

## 10.6.2

### Patch Changes

- Add CloudEventTrigger support for Lambda functions ([#13503](https://github.com/vercel/vercel/pull/13503))

## 10.6.1

### Patch Changes

- next package uses @vercel/routing-utils HasField rather than redefining & stricter validation. ([#13409](https://github.com/vercel/vercel/pull/13409))

- Make architecture a defined property on Lambda classes to apply when creating ([#13398](https://github.com/vercel/vercel/pull/13398))

- [env-vars] expose VERCEL_PROJECT_ID as NEXT_PUBLIC_VERCEL_PROJECT_ID ([#13431](https://github.com/vercel/vercel/pull/13431))

## 10.6.0

### Minor Changes

- provide a more verbose error when package.json is not valid ([#13346](https://github.com/vercel/vercel/pull/13346))

- Allow configuring functions `architecture` via the `vercel.json` configuration ([#13344](https://github.com/vercel/vercel/pull/13344))

## 10.5.1

### Patch Changes

- Display warning when yarn dynamic require error may happen ([#13143](https://github.com/vercel/vercel/pull/13143))

- [build-utils] increase max memory limit ([#13162](https://github.com/vercel/vercel/pull/13162))

## 10.5.0

### Minor Changes

- Disable yarn global cache before installs so build cache caches deps ([#13144](https://github.com/vercel/vercel/pull/13144))

## 10.4.0

### Minor Changes

- Expose pnpm6 within the detected package manager path for future versions of the build container ([#13132](https://github.com/vercel/vercel/pull/13132))

## 10.3.2

### Patch Changes

- Add support for expire values in Next.js prerender manifest ([#13087](https://github.com/vercel/vercel/pull/13087))

- Detect yarn version from lockfile version ([#13118](https://github.com/vercel/vercel/pull/13118))

## 10.3.1

### Patch Changes

- Parse yarn.lock file version ([#13114](https://github.com/vercel/vercel/pull/13114))

- [env-vars] expose VERCEL_DEPLOYMENT_ID as NEXT_PUBLIC_VERCEL_DEPLOYMENT_ID ([#13115](https://github.com/vercel/vercel/pull/13115))

- Fix vitest-e2e glob to include integration.test.ts ([#13097](https://github.com/vercel/vercel/pull/13097))

## 10.3.0

### Minor Changes

- Delay pnpm@10 preferred date ([#13100](https://github.com/vercel/vercel/pull/13100))

### Patch Changes

- Type-check tests ([#13096](https://github.com/vercel/vercel/pull/13096))

## 10.2.0

### Minor Changes

- Detect v9 pnpm lock files as pnpm 10 for new projects ([#13072](https://github.com/vercel/vercel/pull/13072))

### Patch Changes

- Improve build log messages surrounding pnpm 10 ([#13088](https://github.com/vercel/vercel/pull/13088))

- [build-utils] extract checkIfAlreadyInstalled helper to clarify intent ([#13060](https://github.com/vercel/vercel/pull/13060))

- Allow pnpm 10 to use package.json#packageManager without an engines error ([#13083](https://github.com/vercel/vercel/pull/13083))

## 10.1.0

### Minor Changes

- [envs] add `VERCEL_TARGET_ENV` to prefixed env vars ([#13069](https://github.com/vercel/vercel/pull/13069))

## 10.0.1

### Patch Changes

- [build-utils] Move `runNpmInstallSema` closer to where it's used ([#13061](https://github.com/vercel/vercel/pull/13061))

- [build-utils] extract getInstallCommandForPackageManager to module scope ([#13058](https://github.com/vercel/vercel/pull/13058))

- [build-utils] remove redundant sema release ([#13059](https://github.com/vercel/vercel/pull/13059))

- Revert support pnpm 10 ([#13064](https://github.com/vercel/vercel/pull/13064))

## 10.0.0

### Major Changes

- Detect v9 pnpm lockfiles as pnpm 10 generated ([#12852](https://github.com/vercel/vercel/pull/12852))

## 9.3.1

### Patch Changes

- [build-utils] extract install command specific logic into helper ([#13049](https://github.com/vercel/vercel/pull/13049))

- [build-utils] remove dead node 16 check ([#13047](https://github.com/vercel/vercel/pull/13047))

## 9.3.0

### Minor Changes

- Support process tracing ([#12894](https://github.com/vercel/vercel/pull/12894))

## 9.2.1

### Patch Changes

- Add tracer utility to @vercel/build-utils ([#13013](https://github.com/vercel/vercel/pull/13013))

## 9.2.0

### Minor Changes

- Add .yarn/cache to build cache ([#12961](https://github.com/vercel/vercel/pull/12961))

## 9.1.1

### Patch Changes

- [cli] shift node 16 deprecation date to 2025-02-03 ([#12981](https://github.com/vercel/vercel/pull/12981))

## 9.1.0

### Minor Changes

- Add `useWebApi` property to `NodejsLambda` class ([#12873](https://github.com/vercel/vercel/pull/12873))

- [build-utils] convert NodeVersion to class and add state getter ([#12883](https://github.com/vercel/vercel/pull/12883))
  [ruby] convert RubyVersion to class and add state getter

## 9.0.1

### Patch Changes

- Revert build utils refactor ([#12818](https://github.com/vercel/vercel/pull/12818))

## 9.0.0

### Major Changes

- Change getPathOverrideForPackageManager() to use detectedLockfile argument ([#12813](https://github.com/vercel/vercel/pull/12813))

### Patch Changes

- Refactor build-util usage to reuse detected lockfile ([#12813](https://github.com/vercel/vercel/pull/12813))

- add support for `images.qualities` ([#12813](https://github.com/vercel/vercel/pull/12813))

## 8.8.0

### Minor Changes

- Add bun detection using bun.lock ([#12740](https://github.com/vercel/vercel/pull/12740))

## 8.7.0

### Minor Changes

- Support splitting archive deployments in parts. ([#12671](https://github.com/vercel/vercel/pull/12671))

## 8.6.0

### Minor Changes

- Add support for `NOW_EPHEMERAL_FILES_S3_URL`, `NOW_FILES_CLOUDFRONT_URL` and `NOW_FILES_S3_URL` environment variables ([#12643](https://github.com/vercel/vercel/pull/12643))

## 8.5.0

### Minor Changes

- Remove `VERCEL_ALLOW_NODEJS22` env var check ([#12614](https://github.com/vercel/vercel/pull/12614))

## 8.4.12

### Patch Changes

- Support allowHeader from Next.js for filtering request headers during revalidation ([#12420](https://github.com/vercel/vercel/pull/12420))

## 8.4.11

### Patch Changes

- Improve parsing of `turbo.json` ([#12266](https://github.com/vercel/vercel/pull/12266))

- Fix corepack `packageManager` detection on monorepos ([#12258](https://github.com/vercel/vercel/pull/12258))

## 8.4.10

### Patch Changes

- Parse `turbo.json` as json5 ([#12259](https://github.com/vercel/vercel/pull/12259))

## 8.4.9

### Patch Changes

- Fix special version specifier handling for `turbo` ([#12249](https://github.com/vercel/vercel/pull/12249))

## 8.4.8

### Patch Changes

- Revert "[build-utils] Fix corepack `packageManager` detection on monorepos" ([#12242](https://github.com/vercel/vercel/pull/12242))

## 8.4.7

### Patch Changes

- Disable corepack when Turborepo does not support `COREPACK_HOME` ([#12211](https://github.com/vercel/vercel/pull/12211))

- Fix corepack `packageManager` detection on monorepos ([#12219](https://github.com/vercel/vercel/pull/12219))

## 8.4.6

### Patch Changes

- add support for `images.localPatterns` ([#12195](https://github.com/vercel/vercel/pull/12195))

## 8.4.5

### Patch Changes

- [build-utils] add types for `images.remotePatterns.search` to vercel.json ([#12158](https://github.com/vercel/vercel/pull/12158))

## 8.4.4

### Patch Changes

- Allow Node.js v22 behind env var feature flag ([#12159](https://github.com/vercel/vercel/pull/12159))

## 8.4.3

### Patch Changes

- Introduce new chain configuration types for Partial Prerendering ([#12063](https://github.com/vercel/vercel/pull/12063))

## 8.4.2

### Patch Changes

- Revert "Revert "Revert "Fix corepack `packageManager` detection on monorepos""" ([#12099](https://github.com/vercel/vercel/pull/12099))

## 8.4.1

### Patch Changes

- Revert "Revert "Fix corepack `packageManager` detection on monorepos"" ([#11871](https://github.com/vercel/vercel/pull/11871))

## 8.4.0

### Minor Changes

- Change warnings to errors in invalid corepack package manager states ([#12062](https://github.com/vercel/vercel/pull/12062))

## 8.3.9

### Patch Changes

- Provide help when users get ERR_PNPM_UNSUPPORTED_ENGINE errors without corepack ([#12034](https://github.com/vercel/vercel/pull/12034))

- Fix package-manager-warning-1 to happen only happen in correct cases ([#12050](https://github.com/vercel/vercel/pull/12050))

## 8.3.8

### Patch Changes

- Limit `package.json#packageManager` parsing to concrete versions ([#12025](https://github.com/vercel/vercel/pull/12025))

- Catch PNPM_UNSUPPORTED_ENGINE when corepack is enabled and throw a more helpful error ([#12017](https://github.com/vercel/vercel/pull/12017))

## 8.3.7

### Patch Changes

- Revert "Revert "warn on mismatched corepack and detected package managers"" ([#11887](https://github.com/vercel/vercel/pull/11887))

## 8.3.6

### Patch Changes

- Remove implicit reliance on `@types/glob` for downstream consumers ([#11914](https://github.com/vercel/vercel/pull/11914))

## 8.3.5

### Patch Changes

- Revert "warn on mismatched corepack and detected package managers" ([#11879](https://github.com/vercel/vercel/pull/11879))

## 8.3.4

### Patch Changes

- Revert "Fix corepack `packageManager` detection on monorepos" ([#11865](https://github.com/vercel/vercel/pull/11865))

## 8.3.3

### Patch Changes

- Fix corepack `packageManager` detection on monorepos ([#11811](https://github.com/vercel/vercel/pull/11811))

## 8.3.2

### Patch Changes

- reject mismatched corepack and detected package managers ([#11603](https://github.com/vercel/vercel/pull/11603))

## 8.3.1

### Patch Changes

- Add build callback handling ([#11807](https://github.com/vercel/vercel/pull/11807))

## 8.3.0

### Minor Changes

- Adds the ability for builders to define a `diagnostics` step that is called after the build operation is done. ([#11653](https://github.com/vercel/vercel/pull/11653))
  Implements the diagnostics step in the `next` builder.

### Patch Changes

- Add resolved node version range to warning message ([#11742](https://github.com/vercel/vercel/pull/11742))

## 8.2.2

### Patch Changes

- Change node 16.x EOL for Vercel ([#11704](https://github.com/vercel/vercel/pull/11704))

- Improve error message and refactor ([#11706](https://github.com/vercel/vercel/pull/11706))

- [built-utils] Handle case of not having lockfile when corepack is enabled ([#11697](https://github.com/vercel/vercel/pull/11697))

## 8.2.1

### Patch Changes

- [node] update node@16 deprecation day ([#11671](https://github.com/vercel/vercel/pull/11671))

## 8.2.0

### Minor Changes

- fix corepack detection for package manager version determination ([#11596](https://github.com/vercel/vercel/pull/11596))

### Patch Changes

- Fix triggering of ignored project settings node version warning ([#11550](https://github.com/vercel/vercel/pull/11550))

## 8.1.3

### Patch Changes

- [build-utils] log more around package manager detection ([#11594](https://github.com/vercel/vercel/pull/11594))

## 8.1.2

### Patch Changes

- add log to package manager version detection ([#11592](https://github.com/vercel/vercel/pull/11592))

## 8.1.1

### Patch Changes

- [build-utils] pnpm lockfile testing and fixing ([#11591](https://github.com/vercel/vercel/pull/11591))

## 8.1.0

### Minor Changes

- Update pnpm version detection logic ([#11445](https://github.com/vercel/vercel/pull/11445))
  Add support for pnpm 9

## 8.0.0

### Major Changes

- Remove legacy `avoidTopLevelInstall` logic ([#11513](https://github.com/vercel/vercel/pull/11513))

### Patch Changes

- [build-utils] Add `VERCEL_PROJECT_PRODUCTION_URL` framework env var prefix ([#11506](https://github.com/vercel/vercel/pull/11506))

## 7.12.0

### Minor Changes

- Trigger release ([#11465](https://github.com/vercel/vercel/pull/11465))

## 7.11.0

### Minor Changes

- Add `getOsRelease()` and `getProvidedRuntime()` functions ([#11370](https://github.com/vercel/vercel/pull/11370))

## 7.10.0

### Minor Changes

- Allow environment variables to be specified for `EdgeFunction` ([#11029](https://github.com/vercel/vercel/pull/11029))

## 7.9.1

### Patch Changes

- Export `getSupportedNodeVersion` ([#11277](https://github.com/vercel/vercel/pull/11277))

## 7.9.0

### Minor Changes

- Add `base` parameter to `scanParentDirs()` ([#11261](https://github.com/vercel/vercel/pull/11261))

## 7.8.0

### Minor Changes

- Remove `VERCEL_ENABLE_NPM_DEFAULT` env var check ([#11242](https://github.com/vercel/vercel/pull/11242))

### Patch Changes

- Rename variants to flags and remove legacy flags ([#11121](https://github.com/vercel/vercel/pull/11121))

## 7.7.1

### Patch Changes

- [build-utils] increase max memory limit ([#11209](https://github.com/vercel/vercel/pull/11209))

## 7.7.0

### Minor Changes

- Revert "Revert "Default ruby to only currently supported version (3.2.0)"" ([#11137](https://github.com/vercel/vercel/pull/11137))

## 7.6.0

### Minor Changes

- Revert "Default ruby to only currently supported version (3.2.0)" ([#11135](https://github.com/vercel/vercel/pull/11135))

- Mark `flags` as deprecated and replace them with `variants` ([#11098](https://github.com/vercel/vercel/pull/11098))

- [build-utils] change default package manager when no lockfile detected from `yarn` to `npm` (gated behind feature flag) ([#11131](https://github.com/vercel/vercel/pull/11131))

### Patch Changes

- Update internal type for variants ([#11111](https://github.com/vercel/vercel/pull/11111))

## 7.5.1

### Patch Changes

- Add experimental field to Lambda and size to FileFsRef output ([#11059](https://github.com/vercel/vercel/pull/11059))

## 7.5.0

### Minor Changes

- Deprecate `EdgeFunction#name` property ([#11010](https://github.com/vercel/vercel/pull/11010))

## 7.4.1

### Patch Changes

- Extend Node v16 discontinue date to 2024-06-15 ([#10967](https://github.com/vercel/vercel/pull/10967))

## 7.4.0

### Minor Changes

- Adds new helper `getPathForPackageManager()` ([#10918](https://github.com/vercel/vercel/pull/10918))

## 7.3.0

### Minor Changes

- [cli] add `--deprecated` option to `vc project ls` command ([#10919](https://github.com/vercel/vercel/pull/10919))

## 7.2.5

### Patch Changes

- Remove Node.js v20 env var check ([#10834](https://github.com/vercel/vercel/pull/10834))

## 7.2.4

### Patch Changes

- Select Node.js version based on what's available in build-container ([#10822](https://github.com/vercel/vercel/pull/10822))

## 7.2.3

### Patch Changes

- Add experimental flag to allow Node.js v20 ([#10802](https://github.com/vercel/vercel/pull/10802))

## 7.2.2

### Patch Changes

- [cli] Update bun detection and add tests for projects with both bunlock binary and yarn.lock text files ([#10583](https://github.com/vercel/vercel/pull/10583))

## 7.2.1

### Patch Changes

- Internal variants ([#10549](https://github.com/vercel/vercel/pull/10549))

## 7.2.0

### Minor Changes

- Add new optional prerender field: experimentalStreamingLambdaPath ([#10476](https://github.com/vercel/vercel/pull/10476))

- [build-utils] Add zero config detection for bun package manager ([#10486](https://github.com/vercel/vercel/pull/10486))

### Patch Changes

- add `experimentalBypassFor` field to Prerender ([#10481](https://github.com/vercel/vercel/pull/10481))

## 7.1.1

### Patch Changes

- add descriptions to NodeVersion properties ([#10403](https://github.com/vercel/vercel/pull/10403))

- Updated semver dependency ([#10411](https://github.com/vercel/vercel/pull/10411))

## 7.1.0

### Minor Changes

- Support serverless function architecture ([#10392](https://github.com/vercel/vercel/pull/10392))

## 7.0.0

### Major Changes

- BREAKING CHANGE: Drop Node.js 14, bump minimum to Node.js 16 ([#10369](https://github.com/vercel/vercel/pull/10369))

## 6.8.3

### Patch Changes

- Fix `getPrefixedEnvVars()` to handle `VERCEL_BRANCH_URL` ([#10315](https://github.com/vercel/vercel/pull/10315))

## 6.8.2

### Patch Changes

- Push back `nodejs16.x` discontinue date to `2024-02-06` ([#10209](https://github.com/vercel/vercel/pull/10209))

## 6.8.1

### Patch Changes

- Revert "[build-utils] Allow file-ref sema to be controlled through env flag" ([#10167](https://github.com/vercel/vercel/pull/10167))

## 6.8.0

### Minor Changes

- Add `getNodeBinPaths()` and `traverseUpDirectories()` functions ([#10150](https://github.com/vercel/vercel/pull/10150))

## 6.7.5

### Patch Changes

- Publish missing build-utils ([`cd35071f6`](https://github.com/vercel/vercel/commit/cd35071f609d615d47bc04634c123b33768436cb))

## 6.7.4

### Patch Changes

- Remove usage of `env` from Edge Functions and Middleware ([#10018](https://github.com/vercel/vercel/pull/10018))

## 6.7.3

### Patch Changes

- Deprecate Node.js 14.x and 16.x with warning ([#9976](https://github.com/vercel/vercel/pull/9976))
