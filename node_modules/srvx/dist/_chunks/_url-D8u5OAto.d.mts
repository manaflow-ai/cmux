//#region src/_url.d.ts
/**
* Wrapper for URL with fast path access to `.pathname` and `.search` props.
*
* **NOTE:** It is assumed that the input URL is already ecoded and formatted from an HTTP request and contains no hash.
*
* **NOTE:** Triggering the setters or getters on other props will deoptimize to full URL parsing.
*/
declare const FastURL: {
  new (url: string): URL;
};
//#endregion
export { FastURL as FastURL$2 };