/**
 * This file gets copied out of the `pkg` snapshot filesystem into the `vc dev`
 * builder cache directory, so it's very important that it does not rely on any
 * modules from npm that would not be available in that directory (so basically,
 * only Vercel Runtimes and `@vercel/build-utils`.
 */
const { FileFsRef } = require('@vercel/build-utils');

process.on('unhandledRejection', err => {
  // eslint-disable-next-line no-console
  console.error('Exiting builder due to build error:');
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});

process.on('message', onMessage);

function onMessage(message) {
  processMessage(message).catch(err => {
    Object.defineProperty(err, 'message', { enumerable: true });
    Object.defineProperty(err, 'stack', { enumerable: true });
    process.removeListener('message', onMessage);
    process.send({ type: 'buildResult', error: err }, () => process.exit(1));
  });
}

async function processMessage(message) {
  const { requirePath, buildOptions } = message;
  const builder = require(requirePath);

  // Convert the `files` to back into `FileFsRef` instances
  for (const name of Object.keys(buildOptions.files)) {
    const ref = Object.assign(
      Object.create(FileFsRef.prototype),
      buildOptions.files[name]
    );
    buildOptions.files[name] = ref;
  }

  const result = await builder.build(buildOptions);

  // `@vercel/next` sets this, but it causes "Converting circular
  // structure to JSON" errors, so delete the property...
  delete result.childProcesses;

  if (builder.version === 3) {
    if (result.output.type === 'Lambda') {
      result.output.zipBuffer = await result.output.createZip();
    }
  } else {
    for (const output of Object.values(result.output)) {
      if (output.type === 'Lambda') {
        output.zipBuffer = await output.createZip();
      }
    }
  }

  process.send({ type: 'buildResult', result });
}

process.send({ type: 'ready' });
