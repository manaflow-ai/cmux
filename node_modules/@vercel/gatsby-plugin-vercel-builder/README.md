# @vercel/gatsby-plugin-vercel-builder

This plugin generates [Vercel Build Output API v3](https://vercel.com/docs/build-output-api/v3) for Gatsby v4+ projects.

The Vercel platform automatically injects this plugin for you if it can detect Gatsby v4+ in your project's `package.json` dependencies. If detected, you will see a log message in your project's [build logs](https://vercel.com/docs/concepts/deployments/logs#build-logs) as follows:

> Injecting Gatsby.js plugin "@vercel/gatsby-plugin-vercel-builder" to package.json

If auto-detection is not working, this plugin can also be installed and used manually:

1. `npm install @vercel/gatsby-plugin-vercel-builder`
2. Add `'@vercel/gatsby-plugin-vercel-builder'` to your `gatsby-config.(t|j)s` file, such as:

```js
module.exports = {
  plugins: ['@vercel/gatsby-plugin-vercel-builder'],
};
```

3. 🚀 Ship It 🎉
