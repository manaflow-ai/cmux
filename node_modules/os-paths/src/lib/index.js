/* eslint-env es6, node */
// # spell-checker:ignore HomeDrive HomePath LocalAppData UserProfile WinDir
'use strict';

const os = require('os');
const paths = require('path');

const isWinOS = /^win/i.test(process.platform);

function normalize_path(path) {
	return paths.normalize(paths.join(path, '.'));
}

const base = () => {
	const { env } = process;

	const object = {};

	object.home = () => normalize_path(os.homedir ? os.homedir() : env.HOME);

	object.temp = () => normalize_path(os.tmpdir ? os.tmpdir() : env.TMPDIR || env.TEMP || env.TMP);

	return object;
};

const windows = () => {
	const { env } = process;

	const object = {};

	object.home = () =>
		normalize_path(
			os.homedir
				? os.homedir()
				: env.USERPROFILE || paths.join(env.HOMEDRIVE, env.HOMEPATH) || env.HOME
		);

	object.temp = () =>
		normalize_path(
			os.tmpdir
				? os.tmpdir()
				: env.TEMP ||
						env.TMP ||
						paths.join(env.LOCALAPPDATA || env.SystemRoot || env.windir, 'Temp')
		);

	return object;
};

class _OSPaths {
	constructor() {
		const OSPaths = function () {
			return new _OSPaths();
		};

		this._fn = OSPaths;

		// Connect to platform-specific API functions by extension
		const extension = isWinOS ? windows() : base();
		Object.keys(extension).forEach((key) => {
			this._fn[key] = extension[key];
		});

		return this._fn;
	}
}

module.exports = new _OSPaths();
