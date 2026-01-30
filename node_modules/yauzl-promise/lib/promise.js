/* --------------------
 * yauzl-promise module
 * Return native Promise
 * ------------------*/

'use strict';

// Exports
let NativePromise;
try {
	NativePromise = Promise;
} catch(e) {}

module.exports = NativePromise;
