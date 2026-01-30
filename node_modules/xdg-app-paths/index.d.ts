// # spell-checker:ignore rivy
declare namespace XDGAppPaths {
	function cache(dir_options?: boolean | {isolated: boolean}): string;
	function config(dir_options?: boolean | {isolated: boolean}): string;
	function data(dir_options?: boolean | {isolated: boolean}): string;
	function runtime(dir_options?: boolean | {isolated: boolean}): string | undefined;
	function state(dir_options?: boolean | {isolated: boolean}): string;

	function configDirs(dir_options?: boolean | {isolated: boolean}): string[];
	function dataDirs(dir_options?: boolean | {isolated: boolean}): string[];

	function $name(): string;
	function $isolated(): boolean;
}
declare function XDGAppPaths( options?: string | {name: string, suffix: string, isolated: boolean} ): typeof XDGAppPaths;
export = XDGAppPaths;
