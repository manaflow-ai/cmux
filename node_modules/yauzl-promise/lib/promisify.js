/* --------------------
 * yauzl-promise module
 * Promisify yauzl
 * ------------------*/

'use strict';

// Modules
const cloner = require('yauzl-clone');

// Constants
const STATE = Symbol(),
	STORED_ERROR = Symbol();

// Exports
module.exports = (yauzl, Promise) => {
	const {ZipFile, Entry} = yauzl;

	// Promisify open + from... methods
	promisifyMethod(yauzl, Promise, 'open');
	promisifyMethod(yauzl, Promise, 'fromFd');
	promisifyMethod(yauzl, Promise, 'fromBuffer');
	promisifyMethod(yauzl, Promise, 'fromRandomAccessReader');

	// Promisify `close` method
	promisifyClose(ZipFile, Promise);

	// Promisify ZipFile `readEntry` method
	promisifyReadEntry(ZipFile, Promise);

	// Add ZipFile `readEntries` + `walkEntries` methods
	ZipFile.prototype.readEntries = readEntries;
	addWalkEntriesMethod(ZipFile, Promise);

	// Promisify ZipFile `openReadStream` method
	promisifyOpenReadStream(ZipFile, Promise);

	// Add Entry `openReadStream` method
	Entry.prototype.openReadStream = entryOpenReadStream;

	// Add reference to Entry to ZipFile (used by `readEntries`)
	ZipFile.Entry = Entry;
};

/*
 * Promisify open/from... method
 */
function promisifyMethod(yauzl, Promise, fnName) {
	const fromBuffer = fnName == 'fromBuffer';

	cloner.patch(yauzl, fnName, original => {
		return function(path, totalSize, options) {
			return new Promise((resolve, reject) => {
				options = Object.assign({}, options, {lazyEntries: true, autoClose: false});

				original(path, totalSize, options, (err, zipFile) => {
					if (err) return reject(err);
					opened(zipFile, resolve, fromBuffer, yauzl);
				});
			});
		};
	});
}

function opened(zipFile, resolve, fromBuffer, yauzl) {
	// For `.fromBuffer()` calls, adapt `reader` to emit close event
	if (fromBuffer) {
		zipFile.reader.unref = yauzl.RandomAccessReader.prototype.unref;
		zipFile.reader.close = cb => cb();
	}

	// Init
	clearState(zipFile);
	clearError(zipFile);

	// Intercept events
	zipFile.intercept('entry', emittedEntry);
	zipFile.intercept('end', emittedEnd);
	zipFile.intercept('close', emittedClose);
	zipFile.intercept('error', emittedError);

	// Resolve promise with zip object
	resolve(zipFile);
}

/*
 * Error event handler
 */
function emittedError(err) {
	// jshint validthis:true
	// If operation in progress, reject its promise
	const state = getState(this);
	if (state) {
		clearState(this);
		return state.reject(err);
	}

	// Store error to be returned on next call to
	// `.readEntry()`, `.close()` or `.openReadStream()`.
	if (!getError(this)) setError(this, err);
}

function rejectWithStoredError(zipFile, reject) {
	const err = getError(zipFile);
	clearError(zipFile);
	reject(err);
}

/*
 * Promisify ZipFile `close` method
 */
function promisifyClose(ZipFile, Promise) {
	const close = ZipFile.prototype.close;

	ZipFile.prototype.close = function() {
		return new Promise((resolve, reject) => {
			if (getError(this)) return rejectWithStoredError(this, reject);
			if (!this.isOpen) return resolve();
			if (getState(this)) return reject(new Error('Previous operation has not completed yet'));

			setState(this, {action: 'close', resolve, reject});
			close.call(this);
		});
	};
}

function emittedClose() {
	// jshint validthis:true
	// If not closing, emit error
	const state = getState(this);
	if (!state || state.action != 'close') return this.emit('error', new Error('Unexpected \'close\' event emitted'));

	clearState(this);

	// Resolve promise
	state.resolve();
}

/*
 * Promisify ZipFile `readEntry` method
 */
function promisifyReadEntry(ZipFile, Promise) {
	const readEntry = ZipFile.prototype.readEntry;

	ZipFile.prototype.readEntry = function() {
		return new Promise((resolve, reject) => {
			if (getError(this)) return rejectWithStoredError(this, reject);
			if (!this.isOpen) return reject(new Error('ZipFile is not open'));
			if (getState(this)) return reject(new Error('Previous operation has not completed yet'));

			setState(this, {action: 'read', resolve, reject});
			readEntry.call(this);
		});
	};
}

function emittedEntry(entry) {
	// jshint validthis:true
	// If not reading, emit error
	const state = getState(this);
	if (!state || state.action != 'read') return this.emit('error', new Error(`Unexpected '${entry ? 'entry' : 'end'}' event emitted`));

	clearState(this);

	// Set reference to zipFile on entry (used by `entry.openReadStream()`)
	if (entry) entry.zipFile = this;

	// Resolve promise with entry
	state.resolve(entry);
}

function emittedEnd() {
	// jshint validthis:true
	emittedEntry.call(this, null);
}

/*
 * Functions to access state
 */
function getState(zipFile) {
	return zipFile[STATE];
}

function setState(zipFile, state) {
	zipFile[STATE] = state;
}

function clearState(zipFile) {
	zipFile[STATE] = undefined;
}

function getError(zipFile) {
	return zipFile[STORED_ERROR];
}

function setError(zipFile, state) {
	zipFile[STORED_ERROR] = state;
}

function clearError(zipFile) {
	zipFile[STORED_ERROR] = undefined;
}

/*
 * Read all ZipFile entries
 * Reads all entries and returns a promise which resolves with an array of entries
 * `options.max` limits number returned (default 100)
 * `options.max` can be set to `0` for no limit
 */
function readEntries(numEntries) {
	// jshint validthis:true
	const entries = [];
	return this.walkEntries(entry => {
		entries.push(entry);
	}, numEntries).then(() => {
		return entries;
	});
}

/*
 * Walk all ZipFile entries
 * Walks through each entry and calls `fn` with each.
 * Returns a promise which resolves when all have been read.
 */
function addWalkEntriesMethod(ZipFile, Promise) {
	ZipFile.prototype.walkEntries = function(callback, numEntries) {
		callback = wrapFunctionToReturnPromise(callback, Promise);

		return new Promise((resolve, reject) => {
			walkNextEntry(this, callback, numEntries, 0, err => {
				if (err) return reject(err);
				resolve();
			});
		});
	};
}

function walkNextEntry(zipFile, fn, numEntries, count, cb) {
	if (numEntries && count == numEntries) return cb();

	zipFile.readEntry().then(entry => {
		if (!entry) return cb();

		return fn(entry).then(() => {
			walkNextEntry(zipFile, fn, numEntries, count + 1, cb);
		});
	}).catch(err => {
		cb(err);
	});
}

/*
 * Promisify ZipFile `openReadStream` method
 */
function promisifyOpenReadStream(ZipFile, Promise) {
	const openReadStream = ZipFile.prototype.openReadStream;
	ZipFile.prototype.openReadStream = function(entry, options) {
		return new Promise((resolve, reject) => {
			if (getError(this)) return rejectWithStoredError(this, reject);
			openReadStream.call(this, entry, options || {}, (err, stream) => {
				if (err) return reject(err);
				resolve(stream);
			});
		});
	};
}

/*
 * Entry `openReadStream` method
 */
function entryOpenReadStream(options) {
	// jshint validthis:true
	return this.zipFile.openReadStream(this, options);
}

/*
 * Utility functions
 */
function wrapFunctionToReturnPromise(fn, Promise) {
	return function() {
		try {
			const result = fn.apply(this, arguments);
			if (result instanceof Promise) return result;
			return Promise.resolve(result);
		} catch (err) {
			return new Promise((resolve, reject) => { // jshint ignore:line
				reject(err);
			});
		}
	};
}
