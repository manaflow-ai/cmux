make it possible in environments tab to modify the list of exposed ports, make openapi hono endpoints for all of them, making sure they are properly authenticated.

make sure to call :

const serviceUrl = await instance.exposeHttpService("my-service", 8080);
await instance.hideHttpService("my-service");

etc. use existing conventions for my-service naming

make sure to prevent user from trying to expose the following reserved ports: 39376 39377 39378 39379 39380 39381 39383

we also need to do versioning for all snapshots so that it's possible to make new versions of snapshots and use them in environments. we'll need a new convex table for storing snapshot versions. we should be able to "rollback" to a previous version of a snapshot as well, but the future versions of the snapshot should still be available to go back to.

AVOID CASTS OR ANYs
