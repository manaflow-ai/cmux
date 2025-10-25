im working on @apps/client/src/routes/\_layout.$teamSlugOrId.environments.tsx and i want to make the following changes:

- make connections a dropdown instead, where the last option lets me "Add GitHub Account" (reuse convex db query for this). each option should have a gear icon that has tooltip that says Add Repos.
- query the 5 most recent repositories directly from the github api instead of using our own convex db (DONT use the )
- when searching, we should still just show 5 of the most recent repos, queried directly from the github api
- instead of showing "Local", show the time it was last used, like 2d ago, etc
- to query stuff in the frontend, we should use the @cmux/www-openapi-client tanstack queryoptions, you should explore packages/www-openapi-client a bit as well as github.repos.route.ts in apps/www as examples.
- create two steps instead; first step is to just select the right repos. second step should have environment name as well as the environment variables. for first step, we need a button that says Select repositories. Then below that, there should be a secondary button that says "Configure manually" with subtle text that explains that the user can configure everything by interacting with a vm through a vscode ui that will be used as a base snapshot. make sure to word things better.

# vscode prompt

in @apps/client/src/routes/\_layout.$teamSlugOrId.environments.tsx after a user continue, we need to provision a morph instance based off of snapshot_hzlmd4kx and then render it
in a vscode iframe in the "configure environment" step. like we move all existing stuff for configure environment to left side and right side should be vscode url in iframe;
use the following code in a hono openapi route in the backend to provision the instance and get the vscode url

```ts
import { MorphCloudClient } from "morphcloud";

const client = new MorphCloudClient();

console.log("Starting instance");
const instance = await client.instances.start({
  snapshotId: "snapshot_hzlmd4kx",
  // 30 minutes
  ttlSeconds: 60 * 30,
  ttlAction: "pause",
  metadata: {
    app: "cmux-dev",
  },
});

const vscodeUrl = instance.networking.httpServices.find(
  (service) => service.port === 39378
)?.url;
if (!vscodeUrl) {
  throw new Error("VSCode URL not found");
}
console.log(`VSCode URL: ${vscodeUrl}`);
const url = `${vscodeUrl}/?folder=/root/workspace`;
console.log(`VSCode Workspace URL: ${url}`);
```
