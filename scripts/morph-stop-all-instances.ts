import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

import { MorphCloudClient } from "morphcloud";

const rl = createInterface({ input, output });

console.warn("WARNING: This will delete all Morph instances.");
const confirmation = (await rl.question("Type 'delete it' and press enter to continue: ")).trim();

if (confirmation !== "delete it") {
  console.error("Aborting: confirmation did not match.");
  rl.close();
  process.exit(1);
}

rl.close();

const client = new MorphCloudClient();

const instances = await client.instances.list();

const batchSize = Number.parseInt(process.env.BATCH_SIZE ?? "", 10);
const effectiveBatchSize = Number.isFinite(batchSize) && batchSize > 0 ? batchSize : 10;

for (let i = 0; i < instances.length; i += effectiveBatchSize) {
  const batch = instances.slice(i, i + effectiveBatchSize);
  console.log(
    `Stopping batch ${Math.floor(i / effectiveBatchSize) + 1} (${batch.length} instance${
      batch.length === 1 ? "" : "s"
    })`,
  );
  await Promise.all(
    batch.map(async (instance) => {
      console.log(`Stopping instance ${instance.id}`);
      await instance.stop();
    }),
  );
}
