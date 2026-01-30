# async-listen

Promisify `server.listen` for your HTTP/HTTPS/TCP server.

## Install

```sh
npm install async-listen
```

## Usage

```typescript
import listen from 'async-listen';
import { createServer } from 'http';

async function main() {
	const port = 3000;
	const server = createServer();
	const address = await listen(server, port);
	console.log(address); // => URL('http://127.0.0.1:3000')
}

main().catch(console.error);
```
