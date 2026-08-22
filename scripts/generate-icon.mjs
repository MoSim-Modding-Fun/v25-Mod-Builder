// Generates build/icon.ico with a full set of standard Windows icon sizes.
// png-to-ico's own auto-resize only produces 16/32/48/256, skipping 24/64/96/128 -
// sizes Windows actually requests in various DPI scales and UI contexts (jump
// lists, "large icons" view, taskbar at 125%/150%/175% scaling, etc). When a
// size it needs isn't embedded, Windows upscales the nearest smaller frame
// instead of downscaling the source, which is exactly what reads as blurry.
// So: pre-render every size ourselves from the full-res source, then hand
// png-to-ico the finished buffers to package (it packages as-is, no re-resize).
import { Jimp } from 'jimp';
import pngToIco from 'png-to-ico';
import fs from 'fs';

const SIZES = [16, 24, 32, 48, 64, 96, 128, 256];

const src = await Jimp.read('build/icon.png');
const buffers = [];
for (const size of SIZES) {
  const resized = src.clone().resize({ w: size, h: size });
  buffers.push(await resized.getBuffer('image/png'));
}

const ico = await pngToIco(buffers);
fs.writeFileSync('build/icon.ico', ico);
console.log('wrote build/icon.ico with sizes:', SIZES.join(', '));
