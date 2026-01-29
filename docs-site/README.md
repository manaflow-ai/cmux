# cmuxterm Documentation

Documentation website for [cmuxterm](https://github.com/manaflow-ai/cmuxterm), built with [Fumadocs](https://fumadocs.vercel.app) and Next.js.

## Development

```bash
# Install dependencies
npm install

# Start dev server
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) to view the docs.

## Deployment

This site is deployed to Vercel. Push to main to trigger a deployment.

### Manual Deploy

```bash
npm run build
npx vercel --prod
```

## Structure

```
docs-site/
├── app/                  # Next.js app router
│   ├── docs/            # Documentation pages
│   └── page.tsx         # Landing page
├── content/
│   └── docs/            # MDX documentation files
└── lib/
    └── source.ts        # Fumadocs source configuration
```

## Adding Documentation

1. Create a new `.mdx` file in `content/docs/`
2. Add frontmatter with title and description
3. Add the page to `content/docs/meta.json`

Example:

```mdx
---
title: My Page
description: Description of my page
---

# My Page

Content here...
```
