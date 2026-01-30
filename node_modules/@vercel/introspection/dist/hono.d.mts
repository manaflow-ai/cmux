//#region src/hono.d.ts
declare const handle: (honoModule: any) => {
  new (...args: any[]): {
    [x: string]: any;
  };
  [x: string]: any;
};
//#endregion
export { handle };