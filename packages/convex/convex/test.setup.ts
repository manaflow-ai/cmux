// Include both TS source and generated JS files so convex-test can locate "_generated"
export const modules = import.meta.glob(["./**/*.ts", "./**/*.js"]);
