#!/bin/bash
set -euo pipefail
LUMA_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUMA_RENDERER_WORK="$(mktemp -d -t luma-renderer)"
trap 'rm -rf "$LUMA_RENDERER_WORK"' EXIT
git clone https://github.com/oneincase/webwallgl.git "$LUMA_RENDERER_WORK/source"
cd "$LUMA_RENDERER_WORK/source"
git checkout --detach 197abe54266c31d346cebc314e49a26b70c960cc
git apply "$LUMA_PROJECT_ROOT/Vendor/webwallgl-scenescript.patch"
pnpm install --frozen-lockfile --ignore-scripts
cat > luma-entry.ts <<'JS'
export {mount,httpSource,createMediaSource} from './renderer/src/api/index';
export {editorOf} from './renderer/src/editor/controls';
export {parseTex,decodeMips} from './renderer/src/api/core';
JS
cat > luma-build.mjs <<'JS'
import {build} from 'vite';
import {glslPlugin,embeddedGlslPlugin} from './scripts/lib/glsl-plugin.mjs';
import {minRawJsPlugin} from './scripts/lib/min-raw-plugin.mjs';
await build({configFile:false,publicDir:false,plugins:[glslPlugin(),embeddedGlslPlugin(),minRawJsPlugin()],build:{target:'es2022',outDir:'dist/luma',minify:true,lib:{entry:'luma-entry.ts',name:'WebWallGL',formats:['iife'],fileName:()=> 'webwallgl.js'}}});
JS
node luma-build.mjs
cp dist/luma/webwallgl.js "$LUMA_PROJECT_ROOT/Luma/Resources/webwallgl.js"
printf 'Updated the bundled renderer.\n'
