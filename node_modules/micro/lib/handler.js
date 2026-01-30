// Utilities
const logError = require('./error');

module.exports = async file => {
	let mod;

	try {
		mod = await require(file); // Await to support exporting Promises

		if (mod && typeof mod === 'object') {
			mod = await mod.default; // Await to support es6 module's default export
		}
	} catch (err) {
		logError(`Error when importing ${file}: ${err.stack}`, 'invalid-entry');
		process.exit(1);
	}

	if (typeof mod !== 'function') {
		logError(`The file "${file}" does not export a function.`, 'no-export');
		process.exit(1);
	}

	return mod;
};
