//#region src/_utils.cli.ts
const noColor = globalThis.process?.env?.NO_COLOR === "1" || globalThis.process?.env?.TERM === "dumb";
const resets = {
	1: 22,
	31: 39,
	32: 39,
	33: 39,
	34: 39,
	35: 39,
	36: 39,
	90: 39
};
const _c = (c) => (text) => {
	if (noColor) return text;
	const off = resets[c] ?? 0;
	return `\u001B[${c}m${text}\u001B[${off}m`;
};
const Colors = {
	bold: _c(1),
	red: _c(31),
	green: _c(32),
	yellow: _c(33),
	blue: _c(34),
	magenta: _c(35),
	cyan: _c(36),
	gray: _c(90),
	url: (title, url) => noColor ? `[${title}](${url})` : `\u001B]8;;${url}\u001B\\${title}\u001B]8;;\u001B\\`
};

//#endregion
export { Colors };