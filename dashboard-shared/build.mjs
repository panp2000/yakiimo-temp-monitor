import { build } from "esbuild";

await build({
  entryPoints: ["src/global.ts"],
  bundle: true,
  format: "iife",
  globalName: "YakiimoDashboard",
  outfile: "dist/dashboard-shared.js",
  target: "es2020",
  platform: "browser",
  minify: false, // debugability 優先
});
