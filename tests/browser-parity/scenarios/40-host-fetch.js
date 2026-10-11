// fetch() before the session opens a page (a9 shell-tab conditions): the
// host runs each request in a hidden shell tab at the request's origin,
// whose document has a locked-down CSP that still lets the host world
// connect. A request to the primary origin, one to the peer origin, and a
// redirect from the primary to the peer (followed by the host itself, each
// hop in a shell at its own origin, so Local Network Access never applies)
// all reach the server and return its response.
// ---- cell session=hostfetch
const same = await fetch(`${PRIMARY}/api/data?q=same`);
emit("same-origin", [same.status, await same.json()]);
const cross = await fetch(`${PEER}/api/data?q=cross`);
emit("cross-origin", [cross.status, await cross.json()]);
const hop = await fetch(`${PRIMARY}/redirect?to=${encodeURIComponent(`${PEER}/api/data?q=hop`)}`);
emit("redirect-hop", [hop.status, new URL(hop.url).origin === PEER, new URL(hop.url).pathname, await hop.json()]);
