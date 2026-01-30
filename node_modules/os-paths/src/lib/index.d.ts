// # spell-checker:ignore rivy
declare namespace OSPaths {
	function home(): string;
	function temp(): string;
}
declare function OSPaths(): typeof OSPaths;
export = OSPaths;
