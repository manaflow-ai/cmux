# Changelog

## 1.0.0

* Initial release

## 1.1.0

* Promisify `.close` method
* `.readEntries` + `.walkEntries` avoid creating long promise chains (closes #2)
* `.walkEntries` awaits promise from callback (closes #1)
* `ZipFile` is not event emitter (closes #3)
* Test for `.open` returning rejected promise if IO error
* Update `mocha` dev dependency

## 1.1.1

* Fix: No crash on unexpected errors/events from reader
* Fix: Do not clone ZipFile or Entry if not required
* Fix: Typos in error messages
* Do not copy event emitter properties to `ZipFile` instances
* Refactor: Only use jshint `validthis` in functions that need it

## 2.0.0

* `useYauzl` clones yauzl object provided
* `useYauzl` clone option
* `ZipFile` + `Entry` subclass originals
* Use events-intercept module for capturing events
* Store state in symbol attributes
* Refactor: `opened` function
* Tests for `.usePromise` + `.useYauzl`

## 2.0.1

* `.close` method works for zip files from `.fromBuffer`
* Tests for all access methods
* Lint: Tests indentation

## 2.1.0

* Use `yauzl-clone` module for cloning yauzl object
* Fix: Add `fd-slicer` dev dependency

## 2.1.1

* Update `yauzl-clone` dependency
* README update

## 2.1.2

* Update `yauzl-clone` dependency

## 2.1.3

* Update `yauzl-clone` dependency
* Fix changelog typo
* Run Travis CI tests on Node v10
* Update dev dependencies
