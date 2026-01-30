// # spell-checker:ignore macos APPDATA LOCALAPPDATA
/* eslint-env es6, node */
'use strict';

const path = require('path');
const os = require('os');
const xdg = require('xdg-portable');

const isWinOS = /^win/i.test(process.platform);

function _normalizeOptions(options, isolated) {
	options = options || {};
	if (typeof options !== 'object') {
		options = {isolated: options};
	}

	options.isolated = ((options.isolated === undefined) || (options.isolated === null)) ? isolated : options.isolated;
	if (typeof options.isolated !== 'boolean') {
		throw new TypeError(`Expected boolean for "isolated" argument, got ${typeof options.isolated}`);
	}

	return options;
}

const base = (name, isolated) => {
	const object = {};

	object.cache = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return path.join(xdg.cache(), options.isolated ? name : '');
	};

	object.config = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return path.join(xdg.config(), options.isolated ? name : '');
	};

	object.data = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return path.join(xdg.data(), options.isolated ? name : '');
	};

	object.runtime = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return xdg.runtime() ? path.join(xdg.runtime(), options.isolated ? name : '') : undefined;
	};

	object.state = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return path.join(xdg.state(), options.isolated ? name : '');
	};

	object.configDirs = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return (xdg.configDirs()).map(s => path.join(s, options.isolated ? name : ''));
	};

	object.dataDirs = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return (xdg.dataDirs()).map(s => path.join(s, options.isolated ? name : ''));
	};

	return object;
};

const windows = (name, isolated) => {
	const {env} = process;
	const homedir = os.homedir();
	const tmpdir = os.tmpdir();

	// # ref: <https://www.thewindowsclub.com/local-localnow-roaming-folders-windows-10> @@ <http://archive.is/tDEPl>
	const appData = env.APPDATA || path.join(homedir || tmpdir, 'AppData', 'Roaming'); // APPDATA == "AppData/Roaming" contains data which may follow user between machines
	const localAppData = env.LOCALAPPDATA || path.join(homedir || tmpdir, 'AppData', 'Local'); // LOCALAPPDATA == "AppData/Local" contains local-machine-only user data

	const object = {};

	// Locations for data/config/cache/state are invented (Windows doesn't have a popular convention)

	object.cache = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return (!options.isolated || env.XDG_CACHE_HOME) ?
			path.join(xdg.cache(), options.isolated ? name : '') :
			path.join(localAppData, options.isolated ? name : '', 'Cache');
	};

	object.config = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		const config = (!options.isolated || env.XDG_CONFIG_HOME) ?
			path.join(xdg.config(), options.isolated ? name : '') :
			path.join(appData, options.isolated ? name : '', 'Config');
		return config;
	};

	object.data = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		const data = (!options.isolated || env.XDG_DATA_HOME) ?
			path.join(xdg.data(), options.isolated ? name : '') :
			path.join(appData, options.isolated ? name : '', 'Data');
		return data;
	};

	object.runtime = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return xdg.runtime() ? path.join(xdg.runtime(), options.isolated ? name : '') : undefined;
	};

	object.state = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		return (!options.isolated || env.XDG_STATE_HOME) ?
			path.join(xdg.state(), options.isolated ? name : '') :
			path.join(localAppData, options.isolated ? name : '', 'State');
	};

	object.configDirs = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		const dirs = [object.config(options)];
		if (env.XDG_CONFIG_DIRS) {
			dirs.push(...env.XDG_CONFIG_DIRS.split(path.delimiter).map(s => path.join(s, options.isolated ? name : '')));
		}

		return dirs;
	};

	object.dataDirs = (options = {isolated: null}) => {
		options = _normalizeOptions(options, isolated);
		const dirs = [object.data(options)];
		if (env.XDG_DATA_DIRS) {
			dirs.push(...env.XDG_DATA_DIRS.split(path.delimiter).map(s => path.join(s, options.isolated ? name : '')));
		}

		return dirs;
	};

	return object;
};

class _XDGAppPaths {
	constructor(options = {name: null, suffix: null, isolated: true}) {
		const XDGAppPaths = function (options = {name: null, suffix: null, isolated: true}) {
			return new _XDGAppPaths(options);
		};

		this._fn = XDGAppPaths;

		options = options || {};
		if (typeof options !== 'object') {
			options = {name: options};
		}

		let name = options.name || '';
		if (typeof name !== 'string') {
			throw new TypeError(`Expected string for "name" argument, got ${typeof name}`);
		}

		const suffix = options.suffix || '';
		if (typeof suffix !== 'string') {
			throw new TypeError(`Expected string for "suffix" argument, got ${typeof suffix}`);
		}

		const isolated = ((options.isolated === undefined) || (options.isolated === null)) ? true : options.isolated;
		if (typeof isolated !== 'boolean') {
			throw new TypeError(`Expected boolean for "isolated" argument, got ${typeof isolated}`);
		}

		if (!name) {
			// Find a suitable application name (ref: <https://stackoverflow.com/a/46110961/43774>)
			name = path.parse(process.pkg ? process.execPath : (require.main ? require.main.filename : process.argv[0])).name;
		}

		if (suffix) {
			name += suffix;
		}

		this._fn.$name = () => name;
		this._fn.$isolated = () => isolated;

		// Connect to platform-specific API functions by extension
		const extension = isWinOS ? windows(name, isolated) : base(name, isolated);
		Object.keys(extension).forEach(key => {
			this._fn[key] = extension[key];
		});

		return this._fn;
	}
}

module.exports = new _XDGAppPaths();
