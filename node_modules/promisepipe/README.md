# promisePipe

Safely pipe node.js streams while capturing all errors to a single promise.

## Install

    npm install promisepipe

## API

```
promisePipe(<readable stream>, [transform streams...], <writeable stream>)
```

It returns a native promise. On success the resolved value will be an array of the
streams passed in. When rejected an error object is created with following
keys:

  - `source`: The stream that caused the error
  - `originalError`: Original error from the stream
  - `message`: The error message from original error
  
Note: the last stream in the chain needs to be a writable stream, not a duplex/transform stream. If you use a 3rd party library which returns deplux streams instead of writable streams, you'll need to add something like [`.pipe(devnull())`](https://www.npmjs.com/package/dev-null) to the end, otherwise the promise will never resolve ([#16](https://github.com/epeli/node-promisepipe/issues/16)).

Starting with v3, all streams are destroyed if there's an error to prevent memory leaks.

## Example

```javascript
var promisePipe = require("promisepipe");

promisePipe(
    fs.createReadStream(INPUT_FILE),
    new UpcaseTransform(),
    fs.createWriteStream(OUTPUT_FILE),
).then(function(streams){
    console.log("Done writing to the output file stream!");
}, function(err) {
    console.log("This stream failed:", err.source);
    console.log("Original error was:", err.originalError);
});
```

or with async-wait

```javascript
var promisePipe = require("promisepipe");

(async () => {
  try {
    await promisePipe(
      fs.createReadStream(INPUT_FILE),
      new UpcaseTransform(),
      fs.createWriteStream(OUTPUT_FILE)
    );
    console.log("Done writing to the output file stream!");
  } catch (err) {
    console.log("This stream failed:", err.source);
    console.log("Original error was:", err.originalError);
  }
})();

```

## Why?

Stream piping in node.js is cool, but error handling is not because streams
do not bubble errors to the target streams.

For example if the previous example is written like this:

```javascript
fs.createReadStream(INPUT_FILE)
  .pipe(new UpcaseTransform())
  .pipe(fs.createReadStream(OUTPUT_FILE))
```

It might crash your program at any time. You must handle the errors
from each stream manually like this:

```javascript
fs.createReadStream(INPUT_FILE).on("error", function(err) {
    // handle the error
}).pipe(new UpcaseTransform()).on("error", function(err) {
    // handle the error
}).pipe(fs.createReadStream(OUTPUT_FILE)).on("error", function(err) {
    // handle the error
})
```

Handling errors this way can be very cumbersome. `promisepipe` simplifies
error handling by sending the first error occurance into a promise.
