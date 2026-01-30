# async-listen

`listen()` for use with `async` / `await`.

## Example

```typescript
import listen from 'async-listen';
import { createServer } from 'http';

async function main() {
	const port = 3000;
	const server = createServer();
	const address = await listen(server, port);
	console.log(address);
	// 'http://127.0.0.1:3000'
}

main().catch(console.error);
```
