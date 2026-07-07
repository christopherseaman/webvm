#!/usr/bin/env python3
"""Hyper Cube icon v12: volumetric beams + white physical wireframe.
v9's lattice, but each lattice line is now a BEAM: a soft glowing core with
4 parallel LED-bead rows around it (square cross-section light bar).
Physical cube edges (0 mirror bounces) glow white; reflections stay rainbow."""
import math, sys

W = 1024
CC = 512
YAW = math.radians(-40)
PITCH = math.radians(28)
D = 3.5                 # camera distance in cube units
FIT = 0.80              # cube hull occupies this fraction of canvas
N = 4                   # lattice cells deep beyond the cube in each -axis dir
B = 14                  # LED beads per unit edge (per row)
R0 = 8.2                # bead radius at reference depth
O = 0.026               # beam half-width in cube units (LED row offset)
REFL = 0.84             # mirror reflectivity per bounce
CYCLES = 1.6
PAL = ["#ff2f57", "#ff7b1a", "#ffcf1f", "#7dff4a", "#2ee6a8", "#3ad1ff",
       "#4f6bff", "#b24bff", "#ff4fa8"]
WIRE = "#f1ecff"        # physical wireframe LED color (white)
FRAME = "#0b0a12"
BG0, BG1 = "#1b0d2e", "#05030c"
AMB = "#e26bff"

cosY, sinY = math.cos(YAW), math.sin(YAW)
cosP, sinP = math.cos(PITCH), math.sin(PITCH)

def rot(p):
    x, y, z = p[0]-0.5, p[1]-0.5, p[2]-0.5
    x, z = x*cosY + z*sinY, -x*sinY + z*cosY
    y, z = y*cosP - z*sinP, y*sinP + z*cosP
    return (x, y, z)

corners = [(i, j, k) for i in (0, 1) for j in (0, 1) for k in (0, 1)]
raw = []
for c in corners:
    x, y, z = rot(c)
    s = 1.0 / (D - z)
    raw.append((x*s, y*s))
ext = max(max(abs(u) for u, v in raw), max(abs(v) for u, v in raw))
SCALE = (W/2) * FIT / ext

def proj(p):
    x, y, z = rot(p)
    s = SCALE / (D - z)
    return (CC + x*s, CC - y*s, z)

def hx(h): return tuple(int(h[i:i+2], 16) for i in (1, 3, 5))
def pal(x):
    n = len(PAL); fx = (x % 1.0)*n; i = int(fx) % n; j = (i+1) % n; f = fx-int(fx)
    a, b = hx(PAL[i]), hx(PAL[j])
    return "#%02x%02x%02x" % tuple(round(a[k]+(b[k]-a[k])*f) for k in range(3))
def mix_white(c, f):
    r, g, b2 = hx(c)
    return "#%02x%02x%02x" % (round(r+(255-r)*f), round(g+(255-g)*f), round(b2+(255-b2)*f))

def bounces(v):
    b = 0
    for t in v:
        b += math.ceil(max(0.0, -t, t - 1.0) - 1e-9)
    return b

# silhouette hull
pts2 = [(proj(c)[0], proj(c)[1]) for c in corners]
def hull(ps):
    ps = sorted(set(ps))
    def half(ps):
        h = []
        for p in ps:
            while len(h) >= 2 and (h[-1][0]-h[-2][0])*(p[1]-h[-2][1]) - (h[-1][1]-h[-2][1])*(p[0]-h[-2][0]) <= 0:
                h.pop()
            h.append(p)
        return h
    lo_, hi_ = half(ps), half(ps[::-1])
    return lo_[:-1] + hi_[:-1]
H = hull(pts2)
hull_path = "M " + " L ".join(f"{u:.1f} {v:.1f}" for u, v in H) + " Z"

lo, hi = -N, 1
axes = [((1,0,0), (0,1,0), (0,0,1)),
        ((0,1,0), (1,0,0), (0,0,1)),
        ((0,0,1), (1,0,0), (0,1,0))]

def lerp3(base, a, t):
    return (base[0] + a[0]*t, base[1] + a[1]*t, base[2] + a[2]*t)

cores = []   # (z, svg)  soft beam cores, drawn under beads
beads = []   # (z, x, y, r, color, opacity, is_wire)
M = 6        # core samples per unit
for ai, (a, u, v) in enumerate(axes):
    for j in range(lo, hi+1):
        for k in range(lo, hi+1):
            base = (u[0]*j + v[0]*k, u[1]*j + v[1]*k, u[2]*j + v[2]*k)
            hue0 = 0.13*(j - k) + 0.37*ai
            # ---- beam core: translucent glowing bar along the line ----
            for m in range(lo*M, hi*M):
                t0, t1 = m/M, (m+1)/M
                pm = lerp3(base, a, (t0+t1)/2)
                b = bounces(pm)
                opa = REFL**b
                if opa < 0.06:
                    continue
                if b == 0 and j in (0, 1) and k in (0, 1) and (j, k) != (0, 0):
                    continue      # white-frame-owned edge (silhouette/near); far-corner Y keeps its LEDs
                x0, y0, z0 = proj(lerp3(base, a, t0))
                x1, y1, z1 = proj(lerp3(base, a, t1))
                zm = (z0+z1)/2
                r = R0 * (D - 0.9) / (D - zm)
                if r < 0.5:
                    continue
                col = pal(hue0 + (t0+t1)/2 * CYCLES/(hi-lo))
                wd = r * 2.8
                cores.append((zm, f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" y2="{y1:.1f}" '
                              f'stroke="{col}" stroke-width="{wd:.1f}" stroke-opacity="{0.42*opa:.2f}" '
                              f'stroke-linecap="round"/>'))
            # ---- LED bead rows ----
            for m in range(lo*B, hi*B):
                t = (m + 0.5) / B
                p = lerp3(base, a, t)
                b = bounces(p)
                opa = REFL**b
                if opa < 0.05:
                    continue
                if b == 0 and j in (0, 1) and k in (0, 1) and (j, k) != (0, 0):
                    continue      # no bead dots along the white frame; far-corner Y keeps its LEDs
                px, py, z = proj(p)
                r = R0 * (D - 0.9) / (D - z)
                if r < 0.5:
                    continue
                col = pal(hue0 + t*CYCLES/(hi-lo))
                if b == 0:
                    r *= 1.15         # physical LED strips pop
                if r >= 1.8 and opa > 0.15:
                    # 4 parallel rows around the beam core (square cross-section)
                    for du, dv in ((O, O), (O, -O), (-O, O), (-O, -O)):
                        q = (p[0] + u[0]*du + v[0]*dv,
                             p[1] + u[1]*du + v[1]*dv,
                             p[2] + u[2]*du + v[2]*dv)
                        qx, qy, qz = proj(q)
                        beads.append((qz, qx, qy, r*0.62, col, opa))
                else:
                    beads.append((z, px, py, r, col, opa))
beads.sort(key=lambda b: b[0])
cores.sort(key=lambda c: c[0])
print(f"{len(beads)} beads, {len(cores)} core segs", file=sys.stderr)

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">']
svg.append(f'''<defs>
  <radialGradient id="bg" cx="50%" cy="46%" r="75%">
    <stop offset="0%" stop-color="{BG0}"/><stop offset="100%" stop-color="{BG1}"/>
  </radialGradient>
  <radialGradient id="amb" cx="50%" cy="50%" r="50%">
    <stop offset="0%" stop-color="{AMB}" stop-opacity="0.34"/>
    <stop offset="70%" stop-color="{AMB}" stop-opacity="0.10"/>
    <stop offset="100%" stop-color="{AMB}" stop-opacity="0"/>
  </radialGradient>
  <clipPath id="cube"><path d="{hull_path}"/></clipPath>
  <filter id="glow" x="-60%" y="-60%" width="220%" height="220%" color-interpolation-filters="sRGB">
    <!-- true bloom: threshold highlights, multi-scale blur, screen-composite -->
    <feComponentTransfer in="SourceGraphic" result="hi0">
      <feFuncR type="linear" slope="1.55" intercept="-0.19"/>
      <feFuncG type="linear" slope="1.55" intercept="-0.19"/>
      <feFuncB type="linear" slope="1.55" intercept="-0.19"/>
    </feComponentTransfer>
    <feColorMatrix in="hi0" type="saturate" values="1.8" result="hi"/>
    <feGaussianBlur in="hi" stdDeviation="5" result="b1"/>
    <feGaussianBlur in="hi" stdDeviation="14" result="b2"/>
    <feGaussianBlur in="hi" stdDeviation="32" result="b3"/>
    <feGaussianBlur in="hi" stdDeviation="60" result="b4r"/>
    <feComponentTransfer in="b4r" result="b4">
      <feFuncR type="linear" slope="0.5"/><feFuncG type="linear" slope="0.5"/><feFuncB type="linear" slope="0.5"/>
    </feComponentTransfer>
    <feBlend in="b1" in2="b2" mode="screen" result="b12"/>
    <feBlend in="b12" in2="b3" mode="screen" result="b123"/>
    <feBlend in="b123" in2="b4" mode="screen" result="bloom"/>
    <feBlend in="SourceGraphic" in2="bloom" mode="screen"/>
  </filter>
  <filter id="wglow" x="-80%" y="-80%" width="260%" height="260%" color-interpolation-filters="sRGB">
    <feGaussianBlur in="SourceGraphic" stdDeviation="4" result="c1"/>
    <feGaussianBlur in="SourceGraphic" stdDeviation="12" result="c2"/>
    <feBlend in="c1" in2="c2" mode="screen" result="cb"/>
    <feBlend in="SourceGraphic" in2="cb" mode="screen"/>
  </filter>
</defs>''')
svg.append(f'<rect width="{W}" height="{W}" fill="url(#bg)"/>')
svg.append(f'<circle cx="{CC}" cy="{CC}" r="470" fill="url(#amb)"/>')

parts = ["".join(s for z, s in cores)]
for z, x, y, r, c, o in beads:
    parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="{c}" fill-opacity="{o:.2f}"/>')
    if r > 1.4:
        parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r*0.42:.1f}" '
                     f'fill="{mix_white(c, 0.75)}" fill-opacity="{o:.2f}"/>')
dots = "".join(parts)
svg.append(f'<g filter="url(#glow)"><g clip-path="url(#cube)">'
           f'<path d="{hull_path}" fill="#060410"/>{dots}</g></g>')

# frame: black bars with white neon core on the 9 visible physical edges
NEAR = (1, 1, 1)
near_edges = [(NEAR, (0, 1, 1)), (NEAR, (1, 0, 1)), (NEAR, (1, 1, 0))]
frame = [f'<path d="{hull_path}" fill="none" stroke="{FRAME}" stroke-width="60" stroke-linejoin="round"/>']
neon = [f'<path d="{hull_path}" fill="none" stroke="{WIRE}" stroke-width="9" stroke-linejoin="round"/>']
for e in near_edges:
    p, q = proj(e[0]), proj(e[1])
    ln = f'x1="{p[0]:.1f}" y1="{p[1]:.1f}" x2="{q[0]:.1f}" y2="{q[1]:.1f}"'
    frame.append(f'<line {ln} stroke="{FRAME}" stroke-width="52" stroke-linecap="round"/>')
    neon.append(f'<line {ln} stroke="{WIRE}" stroke-width="8" stroke-linecap="round"/>')
svg.append("".join(frame))
svg.append(f'<g filter="url(#wglow)">{"".join(neon)}</g>')
svg.append('</svg>')

out = sys.argv[1] if len(sys.argv) > 1 else "/dev/stdout"
open(out, "w").write("\n".join(svg))
print(f"wrote {out}", file=sys.stderr)
