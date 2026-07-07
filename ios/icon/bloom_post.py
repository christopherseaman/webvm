# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow"]
# ///
"""True raster bloom: render flat SVG at 2x, threshold highlights,
multi-scale Gaussian blur, screen-composite, downsample.
Usage: bloom_post.py in_flat.svg out_base_name
(rsvg-convert used for rasterization — cairosvg's libcairo isn't available here)"""
import sys, re, subprocess
import numpy as np
from PIL import Image, ImageFilter

src, base = sys.argv[1], sys.argv[2]
SS = 2048
THRESH = 0.30
GAIN = 1.15
CBOOST = 1.2            # extra bloom for saturated (rainbow) light
SATB = 0.65             # re-saturate accumulated bloom (fights pastel washout)
LAYERS = [(6, 1.00), (16, 0.75), (40, 0.55), (90, 0.35)]   # (radius@2048, weight)

# strip SVG filters -> flat render (bloom is done here instead)
svg = open(src).read()
svg = re.sub(r' filter="url\(#w?glow\)"', '', svg)
open('_flat.svg', 'w').write(svg)
subprocess.run(['rsvg-convert', '-w', str(SS), '-h', str(SS), '_flat.svg', '-o', '_flat.png'], check=True)

im = np.asarray(Image.open('_flat.png').convert('RGB')).astype(np.float32) / 255.0

# value-based threshold: saturated colors count as fully bright,
# and get a saturation-weighted boost on top
maxc = im.max(axis=2)
minc = im.min(axis=2)
sat = (maxc - minc) / (maxc + 1e-6)
mask = np.clip((maxc - THRESH) / (1.0 - THRESH), 0, 1) * (1.0 + CBOOST * sat)
hi = np.clip(im * mask[..., None], 0, 1)
bloom = np.zeros_like(im)
hi_img = Image.fromarray((hi * 255).astype(np.uint8))
for rad, w in LAYERS:
    b = np.asarray(hi_img.filter(ImageFilter.GaussianBlur(rad))).astype(np.float32) / 255.0
    bloom = 1 - (1 - bloom) * (1 - b * w)          # screen-accumulate layers
mean = bloom.mean(axis=2, keepdims=True)                 # re-saturate bloom
bloom = np.clip(bloom + (bloom - mean) * SATB, 0, 1)
out = 1 - (1 - im) * (1 - np.clip(bloom * GAIN, 0, 1))   # screen over source

full = Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))
for w in (1024, 512, 256, 128, 64):
    full.resize((w, w), Image.LANCZOS).save(f'{base}_{w}.png')
print("bloomed:", [f'{base}_{w}.png' for w in (1024, 512, 256, 128, 64)], file=sys.stderr)
