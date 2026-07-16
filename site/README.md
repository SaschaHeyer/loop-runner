# Loop Runner landing page

Static, dependency-free-at-runtime landing page in the "claymation workshop" style of the Loop
Engineering Headless key art. Tailwind CSS v4 is compiled ahead of time; the built stylesheet is
committed, so the folder deploys to any static host as-is.

```
site/
├── index.html      the page (all sections, inline SVG art)
├── main.js         copy buttons · scroll reveals · terminal typewriter
├── tailwind.css    Tailwind v4 source: @theme palette, keyframes, clay components
├── dist/style.css  built output (committed — keep in sync)
└── package.json    build scripts
```

## Develop

```bash
cd site
npm install
npm run watch     # rebuild dist/style.css on change
npm run serve     # http://localhost:4173
```

## Build (before committing HTML/CSS/JS changes)

```bash
npm run build
```

## Deploy

Any static host works — point it at `site/`:

- **GitHub Pages**: serve the repo with a Pages workflow whose `path: site`, or copy `site/` into a
  `gh-pages` branch.
- **Vercel / Netlify / Cloudflare Pages**: set the project root (or publish directory) to `site/`.
  No build step needed since `dist/style.css` is committed.

## Design system

Palette and type live in `tailwind.css` under `@theme`: bone / cream stage, navy curtain,
terracotta clay, coral, sage, lavender, one green status LED. Display face is Baloo 2, body is
DM Sans, code is JetBrains Mono (Google Fonts). Reusable pieces: `.clay`, `.clay-navy`,
`.clay-chip`, `.btn-clay`, `.clay-letters`, and the `bob / sway / blink / led-pulse / plop /
marquee / flow` animation classes. All motion respects `prefers-reduced-motion`.
