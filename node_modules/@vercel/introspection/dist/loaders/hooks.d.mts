//#region src/loaders/hooks.d.ts
declare function resolve(specifier: string, context: any, nextResolve: any): Promise<any>;
declare function load(url: string, context: any, nextLoad: (url: string, context: any) => Promise<any>): Promise<any>;
//#endregion
export { load, resolve };