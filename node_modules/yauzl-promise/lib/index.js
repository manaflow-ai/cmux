/* --------------------
 * yauzl-promise module
 * ------------------*/

'use strict';

// Modules
const yauzlOriginal = require('yauzl'),
	cloner = require('yauzl-clone');

// Imports
const NativePromise = require('./promise'),
	promisify = require('./promisify');

// Exports
function use(Promise, yauzl, options) {
	// Conform options
	options = Object.assign({clone: true}, options);

	// Use defaults if not provided
	if (!Promise) Promise = NativePromise;
	if (!yauzl) yauzl = yauzlOriginal;

	// Clone yauzl unless `options.clone` false
	if (options.clone) {
		yauzl = cloner.clone(yauzl, {subclassZipFile: true, subclassEntry: true});
	} else {
		// Patch ZipFile prototype with events-intercept methods
		cloner.clone(yauzl, {clone: false, eventsIntercept: true});
	}

	// Add promisfied methods
	if (Promise) {
		promisify(yauzl, Promise);
	} else {
		yauzl = {};
	}

	// Add `use` methods
	yauzl.use = use;
	yauzl.usePromise = function(Promise) {
		return use(Promise, null);
	};
	yauzl.useYauzl = function(yauzl, options) {
		return use(null, yauzl, options);
	};

	// Return yauzl object
	return yauzl;
}

module.exports = use();
