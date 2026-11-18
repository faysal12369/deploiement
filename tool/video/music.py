# An original, royalty-free chill lo-fi loop for the guide videos, synthesised from scratch (standard library only).
#   python music.py <seconds> <out.wav>
# 72 BPM, Dm9 - G13 - Cmaj9 - Am9: soft electric piano with tremolo and a small room, round bass, swung brushes-like
# drums, a sparse pentatonic melody, vinyl crackle and hiss. Fades in and out to the exact length of the video.
import array, math, random, sys, wave

SR = 44100
T = float(sys.argv[1])
OUT = sys.argv[2]
N = int(T * SR)
TAIL = 4 * SR
random.seed(7)

BPM = 72
BEAT = 60 / BPM
BAR = 4 * BEAT
NBARS = int(T / BAR) + 1

def hz(m):
    return 440 * 2 ** ((m - 69) / 12)

def bus():
    return [0.0] * (N + TAIL), [0.0] * (N + TAIL)

def add(b, buf, at, gl, gr):
    L, R = b
    o = int(at * SR)
    if o >= N or o < 0:
        return
    n = min(len(buf), len(L) - o)
    L[o:o + n] = [a + v * gl for a, v in zip(L[o:o + n], buf[:n])]
    R[o:o + n] = [a + v * gr for a, v in zip(R[o:o + n], buf[:n])]

def lowpass(x, fc):
    a = 1 - math.exp(-2 * math.pi * fc / SR)
    y = 0.0
    out = [0.0] * len(x)
    for i, v in enumerate(x):
        y += a * (v - y)
        out[i] = y
    return out

def comb(x, d, g):
    y = x[:d] + [0.0] * (len(x) - d)
    i, n = d, len(x)
    while i < n:
        j = min(i + d, n)
        y[i:j] = [a + g * b for a, b in zip(x[i:j], y[i - d:j - d])]
        i = j
    return y

# ---- instruments -----------------------------------------------------------------------------------------------------
def ep_note(m, dur, vel):
    """Electric piano: sine body, fading 2nd/3rd harmonics, a short bell-like tine at the attack."""
    f = hz(m)
    n = int((dur + 1.0) * SR)
    w = 2 * math.pi * f / SR
    rel = int(dur * SR)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        env = (1 - math.exp(-t / 0.004)) * math.exp(-t / 1.9)
        if i > rel:
            env *= math.exp(-(i - rel) / (0.22 * SR))
        ph = w * i
        out[i] = vel * env * (math.sin(ph) + 0.22 * math.exp(-t / 0.5) * math.sin(2 * ph)
                              + 0.06 * math.exp(-t / 0.2) * math.sin(3 * ph) + 0.05 * math.exp(-t / 0.025) * math.sin(7 * ph))
    return out

def chord(notes, dur):
    n = int((dur + 1.2) * SR)
    out = [0.0] * n
    for k, m in enumerate(notes):
        note = ep_note(m, dur, 0.24 * (0.9 + 0.2 * random.random()))
        o = int(k * 0.014 * SR)  # a slow strum, lowest note first
        m2 = min(len(note), n - o)
        out[o:o + m2] = [a + b for a, b in zip(out[o:o + m2], note[:m2])]
    return out

def bass_note(m, dur):
    f = hz(m)
    n = int((dur + 0.25) * SR)
    w = 2 * math.pi * f / SR
    rel = int(dur * SR)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        env = (1 - math.exp(-t / 0.008)) * math.exp(-t / 1.1)
        if i > rel:
            env *= math.exp(-(i - rel) / (0.05 * SR))
        out[i] = env * (math.sin(w * i) + 0.25 * math.sin(2 * w * i) * math.exp(-t / 0.3))
    return out

def kick():
    n = int(0.4 * SR)
    out, ph = [0.0] * n, 0.0
    for i in range(n):
        t = i / SR
        ph += 2 * math.pi * (48 + 75 * math.exp(-t / 0.028)) / SR
        out[i] = math.sin(ph) * math.exp(-t / 0.17) * (1 - math.exp(-t / 0.001))
    return out

def noise(n):
    return [random.random() * 2 - 1 for _ in range(n)]

def highpass(x):
    return [x[0]] + [b - a for a, b in zip(x, x[1:])]

def snare():
    n = int(0.3 * SR)
    hiss = lowpass(highpass(noise(n)), 5000)
    return [(0.9 * hiss[i] * math.exp(-i / SR / 0.075) + 0.5 * math.sin(2 * math.pi * 185 * i / SR) * math.exp(-i / SR / 0.045))
            for i in range(n)]

def hat():
    n = int(0.07 * SR)
    hiss = highpass(highpass(noise(n)))
    return [hiss[i] * math.exp(-i / SR / 0.016) for i in range(n)]

def lead_note(m, dur):
    """Soft rounded lead with a late, gentle vibrato."""
    f = hz(m)
    n = int((dur + 0.9) * SR)
    rel = int(dur * SR)
    out, ph = [0.0] * n, 0.0
    for i in range(n):
        t = i / SR
        vib = 1 + 0.0018 * math.sin(2 * math.pi * 5.2 * t) * min(1.0, max(0.0, (t - 0.25) / 0.4))
        ph += 2 * math.pi * f * vib / SR
        env = (1 - math.exp(-t / 0.03)) * math.exp(-t / 1.3)
        if i > rel:
            env *= math.exp(-(i - rel) / (0.18 * SR))
        out[i] = env * (math.sin(ph) + 0.12 * math.sin(2 * ph))
    return out

# ---- the song ----------------------------------------------------------------------------------------------------------
CHORDS = [[53, 57, 60, 64], [53, 59, 64, 69], [52, 55, 59, 62], [55, 60, 64, 71]]   # Dm9, G13, Cmaj9, Am9
ROOTS = [38, 43, 36, 33]
PHRASES = [
    [[(76, 0.5, 1), (74, 1.5, 0.5), (69, 2, 1.5)], [(67, 0, 0.5), (69, 0.5, 0.5), (71, 1, 1), (74, 2, 2)],
     [(76, 0, 1.5), (79, 1.5, 0.5), (76, 2, 1), (74, 3, 1)], [(72, 0, 2), (69, 3, 1)]],
    [[(81, 0.5, 1), (79, 1.5, 0.5), (76, 2, 1.5)], [(74, 0, 0.5), (76, 0.5, 0.5), (74, 1, 1), (71, 2, 2)],
     [(79, 0, 1), (76, 1, 1), (74, 2, 0.5), (76, 2.5, 1.5)], [(72, 0, 3)]],
]

keys, dry = bus(), bus()
chord_bufs = [chord(c, BAR) for c in CHORDS]
cache = {}
def cached(k, make):
    if k not in cache:
        cache[k] = make()
    return cache[k]
K, S, HATS = kick(), snare(), [hat() for _ in range(4)]

def jitter():
    return (random.random() - 0.5) * 0.010

def swing(beat):
    whole = math.floor(beat)
    return whole + (0.58 if beat - whole >= 0.5 else beat - whole)

for b in range(NBARS):
    t0 = b * BAR
    c = b % 4
    groove = 2 <= b < NBARS - 2
    add(keys, chord_bufs[c], t0, 0.95, 0.85)
    if b % 2 == 1:
        add(keys, chord_bufs[c][:int(1.6 * BEAT * SR)], t0 + swing(2.5) * BEAT, 0.3, 0.34)
    if groove:
        r = ROOTS[c]
        for m, at, d in [(r, 0, 1.4), (r, 2.5, 0.4), (r + 7, 3, 0.9)]:
            add(dry, cached(('b', m, d), lambda: bass_note(m, d * BEAT)), t0 + swing(at) * BEAT, 0.42, 0.42)
        for at in [0, 2.5] + ([1.75] if c == 3 else []):
            add(dry, K, t0 + at * BEAT, 0.62, 0.62)
        for at in [1, 3]:
            add(dry, S, t0 + at * BEAT + jitter(), 0.2, 0.24)
        if b % 2 == 1:
            add(dry, S, t0 + swing(3.5) * BEAT + jitter(), 0.05, 0.06)
        for k in range(8):
            at = swing(k * 0.5)
            g = 0.075 if k % 2 == 0 else 0.05
            add(dry, random.choice(HATS), t0 + at * BEAT + jitter(), g * 0.7, g)
    # the melody: two phrases from bar 8, a breath, then the first phrase again
    block = b // 4
    if b >= 8 and block in (2, 3, 5) and (block * 4 + 4) <= NBARS - 1:
        for m, at, d in PHRASES[0 if block in (2, 5) else 1][c]:
            add(keys, cached(('l', m, d), lambda: lead_note(m, d * BEAT)), t0 + swing(at) * BEAT + jitter(), 0.16, 0.12)

# ---- room, tremolo, vinyl, master ----------------------------------------------------------------------------------------
wet = []
for side, delays in ((0, (1310, 1637, 1813, 1927)), (1, (1345, 1601, 1777, 1979))):
    x = lowpass(keys[side], 2600)
    acc = [0.0] * len(x)
    for d in delays:
        acc = [a + v for a, v in zip(acc, comb(x, d, 0.8))]
    wet.append(acc)

trem = [0.09 * math.sin(2 * math.pi * 2.3 * i / SR) for i in range(N + TAIL)]
L = [k * (1 + tr) + 0.055 * w + d for k, tr, w, d in zip(keys[0], trem, wet[0], dry[0])]
R = [k * (1 - tr) + 0.055 * w + d for k, tr, w, d in zip(keys[1], trem, wet[1], dry[1])]

hiss = lowpass(noise(N + TAIL), 3200)
crackle = [0.0] * (N + TAIL)
i = 0
while i < N:
    i += int(random.expovariate(4.0) * SR) + 1
    amp = random.uniform(0.015, 0.07) * random.choice((-1, 1))
    for k in range(min(30, N + TAIL - i)):
        crackle[i + k] += amp * math.exp(-k / 4)
crackle = lowpass(crackle, 4500)
L = [a + 0.012 * h + c for a, h, c in zip(L, hiss, crackle)]
R = [a + 0.012 * h + c * 0.8 for a, h, c in zip(R, hiss, crackle)]

L, R = lowpass(L[:N], 7000), lowpass(R[:N], 7000)
peak = max(max(map(abs, L)), max(map(abs, R))) or 1.0
fade_in, fade_out = int(1.2 * SR), int(4.5 * SR)
def gain(i):
    g = 0.56 / peak
    if i < fade_in:
        g *= i / fade_in
    if i > N - fade_out:
        g *= max(0.0, (N - i) / fade_out) ** 1.5
    return g
inter = [0] * (2 * N)
inter[0::2] = [int(32767 * max(-1.0, min(1.0, v * gain(i)))) for i, v in enumerate(L)]
inter[1::2] = [int(32767 * max(-1.0, min(1.0, v * gain(i)))) for i, v in enumerate(R)]
with wave.open(OUT, 'wb') as wf:
    wf.setnchannels(2)
    wf.setsampwidth(2)
    wf.setframerate(SR)
    wf.writeframes(array.array('h', inter).tobytes())
print(f'{OUT}: {T:.1f} s, {NBARS} bars at {BPM} BPM')
