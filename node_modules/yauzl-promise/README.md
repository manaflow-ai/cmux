# yauzl-promise.js

# yauzl unzipping with Promises

## Current status

[![NPM version](https://img.shields.io/npm/v/yauzl-promise.svg)](https://www.npmjs.com/package/yauzl-promise)
[![Build Status](https://img.shields.io/travis/overlookmotel/yauzl-promise/master.svg)](http://travis-ci.org/overlookmotel/yauzl-promise)
[![Dependency Status](https://img.shields.io/david/overlookmotel/yauzl-promise.svg)](https://david-dm.org/overlookmotel/yauzl-promise)
[![Dev dependency Status](https://img.shields.io/david/dev/overlookmotel/yauzl-promise.svg)](https://david-dm.org/overlookmotel/yauzl-promise)
[![Greenkeeper badge](https://badges.greenkeeper.io/overlookmotel/yauzl-promise.svg)](https://greenkeeper.io/)
[![Coverage Status](https://img.shields.io/coveralls/overlookmotel/yauzl-promise/master.svg)](https://coveralls.io/r/overlookmotel/yauzl-promise)

## Usage

Promisified version of [yauzl](https://www.npmjs.com/package/yauzl) for unzipping ZIP files.

### Installation

```
npm install yauzl-promise
```

### Methods

#### `open()` / `fromFd()` / `fromBuffer()` / `fromRandomAccessReader()`

These methods all work as before, but return a Promise rather than taking a callback.

```js
const yauzl = require( 'yauzl-promise' );

const zipFile = await yauzl.open( '/path/to/file' );
```

`lazyEntries` option is automatically enabled. Get file entries using methods listed below.

`autoClose` option is automatically disabled. `ZipFile`s must be closed manually with `.close()`.

#### `zipFile.close()`

Closes file and returns Promise which resolves when all streams are closed.

Files **must** be closed when finished with to avoid resource leakages.

```js
const zipFile = await yauzl.open( '/path/to/file' );
await zipFile.close();
```

#### `zipFile.readEntry()`

Same as original yauzl method, but returning a promise. Promise resolves to an instance of `yauzl.Entry`, or rejects if there is an error.

```js
const entry = await zipFile.readEntry();
console.log( entry );
```

Calling `.readEntry()` again returns the next entry. When there are no entries left, it returns `null`.

#### `zipFile.readEntries( [numEntries] )`

Read several entries and return as an array.

```js
const entries = await zipFile.readEntries( 3 );
entries.forEach( console.log );
```

If `numEntries` is `0`, `null` or `undefined`, reading will continue until all entries are read.

WARNING: This is dangerous. If ZIP contains a large number of files, could lead to crash due to out of memory. Use `.walkEntries()` instead.

#### `zipFile.walkEntries( callback [, numEntries] )`

Read several entries and call `callback` for each.

If `callback` returns a promise, the promise is awaited before reading the next entry. If `callback` throws an error or returns a rejected promise, walking stops and the promise returned by `.walkEntries()` is rejected.

Returns a promise which resolves when all have been read.

```js
await zipFile.walkEntries( entry => {
	console.log( entry );
} );
console.log( 'Done' );
```

If `numEntries` is `0`, `null` or `undefined`, reading will continue until all entries are read.

#### `zipFile.openReadStream( entry [, options] )`

Same as original method but returns promise of a stream.

```js
const readStream = await zipFile.openReadStream( entry );
readStream.pipe( writeStream );
```

#### `entry.openReadStream( [options] )`

As above, but called on an `Entry` object.

```js
const entry = await zipFile.readEntry();
const readStream = await entry.openReadStream();
readStream.pipe( writeStream );
```

### Events

`ZipFile` objects are from a subclass of yauzl's original `ZipFile` class. They are event emitters but do not emit any of the events original yauzl module emits (`entry`, `end`, `close` or `error`).

These events are replaced by the resolution/rejection of promises returned by the methods listed above.

If an `error` event is emitted unexpectedly within yauzl at a time when no operation (`readEntry()` etc) is in progress, that event is consumed to prevent the process from crashing. The next time `readEntry()`, `close()` or `openReadStream()` is called, the promise returned from that method will reject with the previously emitted error.

### Customization

#### Alternative Promise implementation

Promises returned by default are native JS Promises.

`.usePromise()` returns a new `yauzl` object where the methods return promises from the specified Promise constructor.

```js
const Bluebird = require( 'bluebird' );
const yauzl = require( 'yauzl-promise' ).usePromise( Bluebird );

const p = yauzl.open( '/path/to/file' );
console.log( p instanceof Bluebird ); // true
```

NB This does not alter the original `yauzl` object, only the one returned from `.usePromise()`.

```js
const Bluebird = require( 'bluebird' );
const yauzl = require( 'yauzl-promise' )
const yauzlBluebird = yauzl.usePromise( Bluebird );

const p = yauzl.open( '/path/to/file' );
console.log( p instanceof Bluebird ); // false

const p = yauzlBluebird.open( '/path/to/file' );
console.log( p instanceof Bluebird ); // true
```

#### Using another version of yauzl

`.useYauzl()` method promisifies a specific `yauzl` object.

Only useful if you have a modified version of yauzl which you want to promisify.

```js
const yauzlCrc = require( 'yauzl-crc' );
const yauzl = require( 'yauzl-promise' ).useYauzl( yauzlCrc );
```

The yauzl object passed is cloned before it is modified, unless you set `clone` option to `false`:

```js
const yauzlFork = require('my-yauzl-fork');
const yauzl = require( 'yauzl-promise' ).useYauzl( yauzlFork, { clone: false } );
console.log( yauzl == yauzlFork ); // true
```

## Tests

Use `npm test` to run the tests. Use `npm run cover` to check coverage.

## Changelog

See [changelog.md](https://github.com/overlookmotel/yauzl-promise/blob/master/changelog.md)

## Issues

If you discover a bug, please raise an issue on Github. https://github.com/overlookmotel/yauzl-promise/issues

## Contribution

Pull requests are very welcome. Please:

* ensure all tests pass before submitting PR
* add an entry to changelog
* add tests for new features
* document new functionality/API additions in README
