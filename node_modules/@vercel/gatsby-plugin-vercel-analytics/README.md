# @vercel/gatsby-plugin-vercel-analytics

---

⚠️ This repo was migrated from https://github.com/vercel/gatsby-plugin-vercel

---

This plugin sends [Core Web Vitals](https://web.dev/vitals/) to Vercel Speed Insights. This plugin is configured by default on Vercel. You **do not** need to install it manually. For more information, [read this post](https://vercel.com/blog/gatsby-analytics).

## Install

```bash
npm i @vercel/gatsby-plugin-vercel-analytics
```

## Usage

```js
// gatsby-config.js
module.exports = {
  plugins: [
    {
      resolve: "@vercel/gatsby-plugin-vercel-analytics",
      options: {
        // (optional) Prints metrics in the console when true
        debug: false,
      },
    },
  ],
};
```

## Inspiration

- [gatsby-plugin-web-vitals](https://github.com/bejamas/gatsby-plugin-web-vitals)
