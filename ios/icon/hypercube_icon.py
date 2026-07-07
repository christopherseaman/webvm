#!/usr/bin/env python3
"""Hyper Cube icon v8: v7b under true 3D perspective.
Rotate a cube + perspective-divide so the NEAR corner (clear-face wires) and
FAR corner (grid vanishing point) no longer overlap — near sits up-and-right of
far, faces foreshorten from rhombi to trapezoids. Everything (grid traced-L
pattern, orange wireframe, front clear-face edges) is defined in 3D and projected."""
import math, sys

W = 1024
CC = 512
YAW = math.radians(-40)
PITCH = math.radians(31)      # < iso 35.26 -> tilts the diagonal so near/far separate
D = 8.0
SCALE = 4100
K = 7
CYCLES = 1.5
BEADS = 7
PAL = ["#ff7b1a", "#ffcf1f", "#7dff4a", "#3ad1ff", "#ff4fa8", "#ff2f57", "#b24bff"]
FRAME = "#0a0912"
NEON = "#ff8a3a"
BG0, BG1 = "#160b26", "#04030a"

cosY, sinY = math.cos(YAW), math.sin(YAW)
cosP, sinP = math.cos(PITCH), math.sin(PITCH)
def rot(p):
    x, y, z = p
    x, z = x*cosY + z*sinY, -x*sinY + z*cosY
    y, z = y*cosP - z*sinP, y*sinP + z*cosP
    return (x, y, z)
def proj(p):                                   # p in 0..1 cube coords -> screen
    x, y, z = rot((p[0]-0.5, p[1]-0.5, p[2]-0.5))
    s = SCALE / (D - z)
    return (CC + x*s, CC - y*s)
def add3(a, b): return (a[0]+b[0], a[1]+b[1], a[2]+b[2])
def mul3(a, t): return (a[0]*t, a[1]*t, a[2]*t)
def lerp2(a, b, t): return (a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t)
def hx(h): return tuple(int(h[i:i+2], 16) for i in (1, 3, 5))
def pal(x):
    n = len(PAL); fx = (x % 1.0)*n; i = int(fx) % n; j = (i+1) % n; f = fx-int(fx)
    a, b = hx(PAL[i]), hx(PAL[j])
    return "#%02x%02x%02x" % tuple(round(a[k]+(b[k]-a[k])*f) for k in range(3))

FAR = (0, 0, 0); NEAR = (1, 1, 1)
STRUTS = [((0,1,0),(0,0,1),(1,0,0)), ((1,0,0),(0,0,1),(0,1,0)), ((0,0,1),(0,1,0),(1,0,0))]
NEAR_EDGES = [(NEAR,(0,1,1)), (NEAR,(1,0,1)), (NEAR,(1,1,0))]     # clear-face front wires
FAR_EDGES  = [(FAR,(0,1,0)), (FAR,(1,0,0)), (FAR,(0,0,1))]        # interior seams
EQUATOR = [((0,1,0),(1,1,0)), ((0,1,0),(0,1,1)), ((1,0,0),(1,1,0)),
           ((1,0,0),(1,0,1)), ((0,0,1),(1,0,1)), ((0,0,1),(0,1,1))]

pN, pF = proj(NEAR), proj(FAR)
print(f"NEAR proj {pN[0]:.0f},{pN[1]:.0f}   FAR proj {pF[0]:.0f},{pF[1]:.0f}   "
      f"(near is {'right' if pN[0]>pF[0] else 'left'} & {'up' if pN[1]<pF[1] else 'down'} of far)", file=sys.stderr)

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">']
svg.append(f'''<defs>
  <radialGradient id="bg" cx="50%" cy="46%" r="75%">
    <stop offset="0%" stop-color="{BG0}"/><stop offset="100%" stop-color="{BG1}"/>
  </radialGradient>
  <filter id="glow" x="-120%" y="-120%" width="340%" height="340%">
    <feGaussianBlur in="SourceGraphic" stdDeviation="2.5" result="b0"/>
    <feGaussianBlur in="SourceGraphic" stdDeviation="7"   result="b1"/>
    <feGaussianBlur in="SourceGraphic" stdDeviation="16"  result="b2"/>
    <feGaussianBlur in="SourceGraphic" stdDeviation="32"  result="b3"/>
    <feMerge>
      <feMergeNode in="b3"/><feMergeNode in="b2"/><feMergeNode in="b1"/>
      <feMergeNode in="b2"/><feMergeNode in="b1"/><feMergeNode in="b0"/>
      <feMergeNode in="SourceGraphic"/>
    </feMerge>
  </filter>
</defs>''')
svg.append(f'<rect width="{W}" height="{W}" fill="url(#bg)"/>')

# grid traced-L lines (3D, projected), colour+width patterned by 2D arc length
M = 16
segs = []
for (A, d1, d2) in STRUTS:
    for i in range(K + 1):
        f = i / K
        S = mul3(A, f)
        a1 = add3(S, d1); a2 = add3(S, d2)
        pts = ([proj(add3(lerp2(a1, S, 0), (0,0,0)))] if False else [])
        samp = []
        for m in range(M + 1):
            p3 = (a1[0]+(S[0]-a1[0])*m/M, a1[1]+(S[1]-a1[1])*m/M, a1[2]+(S[2]-a1[2])*m/M)
            samp.append(proj(p3))
        for m in range(1, M + 1):
            p3 = (S[0]+(a2[0]-S[0])*m/M, S[1]+(a2[1]-S[1])*m/M, S[2]+(a2[2]-S[2])*m/M)
            samp.append(proj(p3))
        dl = [math.dist(samp[n], samp[n+1]) for n in range(len(samp)-1)]
        tot = sum(dl) or 1
        acc = 0.0
        for n in range(len(samp)-1):
            t = (acc + dl[n]*0.5) / tot; acc += dl[n]
            col = pal(t * CYCLES)
            wid = 2.5 + 5.5*(0.5 + 0.5*math.sin(t*2*math.pi*BEADS))
            pa, pb = samp[n], samp[n+1]
            segs.append(f'<line x1="{pa[0]:.1f}" y1="{pa[1]:.1f}" x2="{pb[0]:.1f}" y2="{pb[1]:.1f}" '
                        f'stroke="{col}" stroke-width="{wid:.1f}" stroke-linecap="round"/>')
svg.append(f'<g filter="url(#glow)">{"".join(segs)}</g>')

# orange wireframe: equator + interior seams (dark bar + neon), near-corner front edges thicker
def edge(e, wdark, wneon):
    p, q = proj(e[0]), proj(e[1])
    ln = f'x1="{p[0]:.1f}" y1="{p[1]:.1f}" x2="{q[0]:.1f}" y2="{q[1]:.1f}"'
    return (f'<line {ln} stroke="{FRAME}" stroke-width="{wdark}" stroke-linecap="round"/>',
            f'<line {ln} stroke="{NEON}" stroke-width="{wneon}" stroke-linecap="round"/>')
darks, neons = [], []
for e in EQUATOR + FAR_EDGES:
    d, n = edge(e, 30, 5); darks.append(d); neons.append(n)
for e in NEAR_EDGES:
    d, n = edge(e, 34, 6); darks.append(d); neons.append(n)
svg.append("".join(darks))
svg.append(f'<g filter="url(#glow)">{"".join(neons)}</g>')

svg.append('</svg>')
out = sys.argv[1] if len(sys.argv) > 1 else "/dev/stdout"
open(out, "w").write("\n".join(svg))
print(f"wrote {out}")
