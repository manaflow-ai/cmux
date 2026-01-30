// # spell-checker:ignore rivy

declare namespace XDG {
	/**
	Directory for user-specific non-essential data files.

	@example
	```js
	import xdg = require('xdg-portable');

	xdg.cache();
	//(mac)=> '/Users/rivy/Library/Caches'
	//(nix)=> '/home/rivy/.cache'
	//(win)=> 'C:\\Users\\rivy\\AppData\\Local\\cache'
	```
	*/
	function cache(): string;

	/**
	Directory for user-specific configuration files.

	@example
	```js
	import xdg = require('xdg-portable');

	xdg.config();
	//(mac)=> '/Users/rivy/Library/Preferences'
	//(nix)=> '/home/rivy/.config'
	//(win)=> 'C:\\Users\\rivy\\AppData\\Roaming\\xdg.config'
	```
	*/
	function config(): string;

	/**
	Directory for user-specific data files.

	@example
	```js
	import xdg = require('xdg-portable');

	xdg.data();
	//(mac)=> '/Users/rivy/Library/Application Support'
	//(nix)=> '/home/rivy/.local/share'
	//(win)=> 'C:\\Users\\rivy\\AppData\\Roaming\\xdg.data'
	```
	*/
	function data(): string;

	/**
	Directory for user-specific non-essential runtime files and other file objects (such as sockets, named pipes, etc).

	@example
	```js
	import xdg = require('xdg-portable');

	xdg.runtime();
	//(mac)=> undefined
	//(nix)=> '/run/user/rivy'
	//(win)=> undefined
	```
	*/
	function runtime(): string | undefined;

	/**
	Directory for user-specific state files (non-essential and more volatile than configuration files).

	@example
	```js
	import xdg = require('xdg-portable');

	xdg.state();
	//(mac)=> '/Users/rivy/Library/State'
	//(nix)=> '/home/rivy/.local/state'
	//(win)=> 'C:\\Users\\rivy\\AppData\\Local\\xdg.state'
	```
	*/
	function state(): string;

	/**
	Preference-ordered array of base directories to search for configuration files; includes `.config()` directory as first entry.

	@example
	```js
	import xdg = require('xdg-portable');

	xdg.configDirs();
	//(mac)=> ['/Users/rivy/Library/Preferences']
	//(nix)=> ['/home/rivy/.config', '/etc/xdg']
	//(win)=> ['C:\\Users\\rivy\\AppData\\Roaming\\xdg.config']
	```
	*/
	function configDirs(): readonly string[];

	/**
	Preference-ordered array of base directories to search for data files; include `.data()` directory as first entry.

	@example
	```js
	import xdg = require('xdg-portable');

	xdg.dataDirs();
	//(mac)=> ['/Users/rivy/Library/Preferences']
	//(nix)=> ['/home/rivy/.local/share', '/usr/local/share/', '/usr/share/']
	//(win)=> ['C:\\Users\\rivy\\AppData\\Roaming\\xdg.data']
	```
	*/
	function dataDirs(): readonly string[];
}
declare function XDG(): typeof XDG;
export = XDG;
