// Takes the lock at argv[2], prints "held" or "refused", then stays alive
// (holding the lock when it got it) until it is killed.
import { takeLock } from "../../src/lock.ts";

const release = takeLock(process.argv[2] ?? "");
console.log(release ? "held" : "refused");
setInterval(() => {}, 1 << 30);
