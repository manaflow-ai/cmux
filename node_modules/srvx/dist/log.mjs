import { Colors } from "./_chunks/_utils.cli-B2YzwlOv.mjs";

//#region src/log.ts
const statusColors = {
	1: "blue",
	2: "green",
	3: "yellow"
};
const log = (_options = {}) => {
	return async (req, next) => {
		const start = performance.now();
		const res = await next();
		const duration = performance.now() - start;
		const statusColor = statusColors[Math.floor(res.status / 100)] || "red";
		console.log(`${Colors.gray(`[${new Date().toLocaleTimeString()}]`)} ${Colors.bold(req.method)} ${Colors.blue(req.url)} [${Colors[statusColor](res.status + "")}] ${Colors.gray(`(${duration.toFixed(2)}ms)`)}`);
		return res;
	};
};

//#endregion
export { log };