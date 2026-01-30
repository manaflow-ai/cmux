<!DOCTYPE markdown><!-- markdownlint-disable no-inline-html -->
<meta charset="utf-8" content="text/markdown" lang="en">
<!-- -## editors ## (emacs/sublime) -*- coding: utf8-nix; tab-width: 4; mode: markdown; indent-tabs-mode: nil; basic-offset: 2; st-word_wrap: 'true' -*- ## (jEdit) :tabSize=4:indentSize=4:mode=markdown: ## (notepad++) vim:tabstop=4:syntax=markdown:expandtab:smarttab:softtabstop=2 ## modeline (see <https://archive.is/djTUD>@@<http://webcitation.org/66W3EhCAP> ) -->
<!-- spell-checker:ignore expandtab markdownlint modeline smarttab softtabstop -->

<!-- markdownlint-disable heading-increment ul-style -->
<!-- spell-checker:ignore rivy Sindre sindresorhus Sorhus -->
<!-- spell-checker:ignore APPDATA LOCALAPPDATA typeof -->

# [xdg-app-paths](https://github.com/rivy/js.xdg-app-paths)

> Get ([XDG](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)-compatible) application-specific (and cross-platform) paths for storing things like cache, config, data, state, etc

[![License][license-image]][license-url]
[![Build status][travis-image]][travis-url]
[![Build status][appveyor-image]][appveyor-url]
[![Coverage status][coverage-image]][coverage-url]
[![Javascript Style Guide][style-image]][style-url]
<br/>
[![NPM version][npm-image]][npm-url]
[![Downloads][downloads-image]][downloads-url]

<!--
## References

// XDG references
// # ref: <https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html> @@ <https://archive.is/aAhtw>
// # ref: <https://specifications.freedesktop.org/basedir-spec/latest/ar01s03.html> @@ <https://archive.is/7N0TN>
// # ref: <https://wiki.archlinux.org/index.php/XDG_Base_Directory> @@ <https://archive.is/VdO9n>
// # ref: <https://wiki.debian.org/XDGBaseDirectorySpecification#state> @@ <http://archive.is/pahId>
// # ref: <https://ploum.net/207-modify-your-application-to-use-xdg-folders> @@ <https://archive.is/f43Gk>
-->

## Installation

```shell
npm install xdg-app-paths
```

## Usage

```js
// MyApp.js
const paths = require('xdg-app-paths');

paths.cache();
//(nix)=> '/home/rivy/.cache/MyApp.js'
//(win)=> 'C:\\Users\\rivy\\AppData\\Local\\MyApp\\Cache'

paths.config();
//(nix)=> '/home/rivy/.config/MyApp.js'
//(win)=> 'C:\\Users\\rivy\\AppData\\Roaming\\MyApp\\Config'

paths.data();
//(nix)=> '/home/rivy/.local/share/MyApp.js'
//(win)=> 'C:\\Users\\rivy\\AppData\\Roaming\\MyApp\\Data'
```

## API

### Initialization

#### `require('xdg-app-paths')( options? ): XDGAppPaths()`

```js
const xdgAppPaths = require('xdg-app-paths');
// or ...
const xdgAppPaths = require('xdg-app-paths')( options );
```

The object returned by the module constructor is an XDGAppPaths Function object, augmented with attached methods. When called directly (eg, `const p = xdgAppPaths(...)`), it acts as a constructor, returning a new, and unrelated, XDGAppPaths object.

> #### `options`
>
> ##### `options: string` => `{ name: string }`
>
> As a shortcut, when supplied as a `string`, options is interpreted as the options name property (ie, `options = { name: options }`).
>
> ##### `options: object`
>
> * default = `{ name: '', suffix: '', isolated: true }`
>
> ###### `options.name: string`
>
> * default = `''`
>
> Name of your application; used to generate the paths. If missing, `null`, or empty (`''`), it is generated automatically from the available process information.
>
> ###### `options.suffix: string`
>
> * default = `''`
>
> Suffix which is appended to the application name when generating the application paths.
>
> ###### `options.isolated: boolean`
>
> * default = `true`
>
> Default isolation flag.

### Methods

All returned path strings are simple, platform-compatible, strings and are *not* guaranteed to exist. The application is responsible for construction of the directories. If needed, [`make-dir`](https://www.npmjs.com/package/make-dir) or [`mkdirp`](https://www.npmjs.com/package/mkdirp) can be used to create the directories.

#### `xdgAppPaths.cache( dir_options? ): string`

Returns the directory for non-essential data files

#### `xdgAppPaths.config( dir_options? ): string`

Returns the directory for config files

#### `xdgAppPaths.data( dir_options? ): string`

Returns the directory for data files

#### `xdgAppPaths.runtime( dir_options? ): string?`

Returns the directory for runtime files; may return `undefined`

#### `xdgAppPaths.state( dir_options? ): string`

Returns the directory for state files.

#### `xdgAppPaths.configDirs( dir_options? ): string[]`

Returns a priority-sorted list of possible directories for configuration file storage (includes `paths.config()` as the first entry)

#### `xdgAppPaths.dataDirs( dir_options? ): string[]`

Returns a priority-sorted list of possible directories for data file storage (includes `paths.data()` as the first entry)

> #### `dir_options`
>
> ##### `dir_options: boolean` => `{ isolated: boolean }`
>
> As a shortcut, when supplied as a `boolean`, dir_options is interpreted as the dir_options isolated property (ie, `dir_options = { isolated: dir_options }`).
>
> ##### `dir_options: object`
>
> * default = `{ isolated: true }`
>
> ###### `dir_options.isolated: boolean`
>
> * default = `true`
>
> Isolation flag; used to override the default isolation mode, when needed.

#### `xdgAppPaths.$name(): string`

Application name used for path construction (from supplied or auto-generated information)

#### `xdgAppPaths.$isolated(): boolean`

Default isolation mode used by the particular XDGAppPaths instance

## Example

```js
// MyApp.js
const locatePath = require('locate-path');
const mkdirp = require('mkdirp');
const path = require('path');

const appPaths = require('xdg-app-paths');
// Extend appPaths with a "log" location
appPaths.log = (options = {isolated: appPaths.$isolated()}) => {
    if (typeof options === 'boolean') {
        options = {isolated: options};
    }

    const isolated = ((options.isolated === undefined) || (options.isolated === null)) ? appPaths.$isolated() : options.isolated;
    return path.join(appPaths.state(options), (isolated ? '' : appPaths.$name() + '-') + 'log');
};

// log file
const logPath = path.join(appPaths.log(), 'debug.txt');
mkdirp.sync(path.dirname(logPath), 0o700);

// config file
// * search for config file within user preferred directories; otherwise, use preferred directory
const possibleConfigPaths = appPaths.configDirs()
    .concat(appPaths.configDirs({isolated: !appPaths.$isolated()}))
    .map(v => path.join(v, appPaths.$name() + '.json'));
const configPath = locatePath.sync(possibleConfigPaths) || possibleConfigPaths[0];
// debug(logPath, 'configPath="%s"', configPath);
mkdirp.sync(path.dirname(configPath), 0o700);

// cache file
const cacheDir = path.join(appPaths.cache());
// debug(logPath, 'cacheDir="%s"', cacheDir);
mkdirp.sync(cacheDir, 0o700);
const cachePath = {};
cachePath.orders = path.join(cacheDir, 'orders.json');
cachePath.customers = path.join(cacheDir, 'customers.json');
//...
```

## Discussion

The [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html) defines categories of user information (ie, "cache", "config", "data", ...), defines their standard storage locations, and defines the standard process for user configuration of those locations (using `XDG_CACHE_HOME`, etc).

Applications supporting the XDG convention are expected to store user-specific files within these locations, either within the common/shared directory (eg, `` `${xdg.cache()}/filename` ``) or within a more isolated application-defined subdirectory (eg, `` `${xdg.config()/dir/filename` ``; `dir` usually being the application name).

### Windows ("win32") specific notes

Windows has an alternate convention, offering just two standard locations for applications to persist data, either `%APPDATA%` (for files which may "roam" with the user between hosts) and `%LOCALAPPDATA%` (for local-machine-only files). All application files are expected to be stored within an application-unique subdirectory in one of those two locations, usually under a directory matching the application name. There is no further popular convention used to segregate the file types (ie, into "cache", "config", ...) in any way similar to the XDG specification.

So, to support basic XDG-like behavior (that is, segregating the information types into type-specific directories), this module supports a new convention for Windows hosts (taken from [`xdg-portable`](https://www.npmjs.com/package/xdg-portable)), placing the specific types of files into subdirectories under either `%APPDATA%` or `%LOCALAPPDATA%`, as appropriate for the file type. The default directories used for the windows platform are listed by [`xdg-portable`](https://www.npmjs.com/package/xdg-portable#api).

By default, this module returns paths which are isolated, application-specific sub-directories under the respective common/shared base directories. These sub-directories are purely dedicated to use by the application. If, however, the application requires access to the common/shared areas, the `isolated: false` option may be used during initialization (or as an optional override for specific function calls) to generate and return the common/shared paths. Note, that when using the command/shared directories, care must be taken not use file names which collide with those used by other applications.

### Origins

This module was forked from [sindresorhus/env-paths](https://github.com/sindresorhus/env-paths) in order to add cross-platform portability and support simpler cross-platform applications.

## Related

- [`xdg-portable`](https://www.npmjs.com/package/xdg-portable) ... XDG Base Directory paths (cross-platform)
- [`env-paths`](https://www.npmjs.com/package/env-paths) ... inspiration for this module

## License

MIT © [Roy Ivy III](https://github.com/rivy), [Sindre Sorhus](https://sindresorhus.com)

<!-- badge references -->

[npm-image]: https://img.shields.io/npm/v/xdg-app-paths.svg?style=flat
[npm-url]: https://npmjs.org/package/xdg-app-paths

<!-- [appveyor-image]: https://ci.appveyor.com/api/projects/status/.../branch/master?svg=true -->
[appveyor-image]: https://img.shields.io/appveyor/ci/rivy/js-xdg-app-paths/master.svg?style=flat&logo=AppVeyor&logoColor=silver
[appveyor-url]: https://ci.appveyor.com/project/rivy/js-xdg-app-paths
<!-- [travis-image]: https://travis-ci.org/rivy/js.xdg-app-paths.svg?branch=master -->
<!-- [travis-image]: https://img.shields.io/travis/rivy/js.xdg-app-paths/master.svg?style=flat&logo=Travis-CI&logoColor=silver -->
[travis-image]: https://img.shields.io/travis/rivy/js.xdg-app-paths/master.svg?style=flat
[travis-url]: https://travis-ci.org/rivy/js.xdg-app-paths

<!-- [coverage-image]: https://img.shields.io/coveralls/github/rivy/xdg-app-paths/master.svg -->
<!-- [coverage-url]: https://coveralls.io/github/rivy/xdg-app-paths -->
[coverage-image]: https://img.shields.io/codecov/c/github/rivy/js.xdg-app-paths/master.svg
[coverage-url]: https://codecov.io/gh/rivy/js.xdg-app-paths
[downloads-image]: http://img.shields.io/npm/dm/xdg-app-paths.svg?style=flat
[downloads-url]: https://npmjs.org/package/xdg-app-paths
[license-image]: https://img.shields.io/npm/l/xdg-app-paths.svg?style=flat
[license-url]: license
<!-- [style-image]: https://img.shields.io/badge/code_style-standard-darkcyan.svg -->
<!-- [style-url]: https://standardjs.com -->
[style-image]: https://img.shields.io/badge/code_style-XO-darkcyan.svg
[style-url]: https://github.com/xojs/xo
