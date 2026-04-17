#!/usr/bin/env python3
"""Check if B is A shifted by N bytes across the whole payload, and per-region.

Usage:
    sta_shift_check.py <A.sta> <B.sta>

Reports, for shifts in [-4,+4], what percentage of bytes satisfy
B[i] == A[i - shift]. A match rate >95% at a non-zero shift is a
strong indicator of an off-by-N bug in the save and/or load path.

Empirically observed (2026-04-14 test data):
    WRAM:    98.2% match at shift +1  (load writes byte[n] to addr[n+1])
    Z80RAM:  99.7% match at shift +1
    VDPREG:  96.9% match at shift +1
    M68K:    high match at shift +1
    VRAM:    95.4% match at shift  0  (4-byte accum buffer absorbs shift)
    FM:      99.8% match at shift  0  (separate port)
"""
import sys

APF_HEADER_OFFSET = 0x255
PAYLOAD_SIZE = 0x22590

REGIONS = [
    ("HEADER",    0x00000, 0x00010),
    ("WRAM",      0x00010, 0x10010),
    ("VRAM",      0x10010, 0x20010),
    ("Z80RAM",    0x20010, 0x22010),
    ("M68K",      0x22010, 0x22110),
    ("Z80REG",    0x22110, 0x22150),
    ("VDPREG",    0x22150, 0x22170),
    ("VDPST",     0x22170, 0x22178),
    ("CRAM",      0x22178, 0x221F8),
    ("VSRAM0",    0x221F8, 0x22238),
    ("VSRAM1",    0x22238, 0x22278),
    ("PAD_FM_LO", 0x22278, 0x22350),
    ("FM",        0x22350, 0x22550),
    ("PSG",       0x22550, 0x22558),
    ("PAD_TAIL",  0x22558, 0x22590),
]


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <A.sta> <B.sta>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], 'rb') as f:
        a = f.read()[APF_HEADER_OFFSET:APF_HEADER_OFFSET + PAYLOAD_SIZE]
    with open(sys.argv[2], 'rb') as f:
        b = f.read()[APF_HEADER_OFFSET:APF_HEADER_OFFSET + PAYLOAD_SIZE]

    print("Whole-payload shift match (B[i] vs A[i-shift]):")
    for s in range(-4, 5):
        matches = 0
        total = 0
        for i in range(len(b)):
            j = i - s
            if 0 <= j < len(a):
                total += 1
                if b[i] == a[j]:
                    matches += 1
        pct = matches / total * 100 if total else 0
        print(f"  shift={s:+d}  matches={matches}/{total}  {pct:.1f}%")

    print()
    print("Per-region best shift (limited to [-2,+2]):")
    for name, lo, hi in REGIONS:
        a_r = a[lo:hi]
        b_r = b[lo:hi]
        if a_r == b_r:
            print(f"  {name:12s}: identical")
            continue
        best_s = None
        best_m = -1
        for s in range(-2, 3):
            matches = 0
            for i in range(len(b_r)):
                j = i - s
                if 0 <= j < len(a_r):
                    if b_r[i] == a_r[j]:
                        matches += 1
            if matches > best_m:
                best_m = matches
                best_s = s
        pct = best_m / len(b_r) * 100 if b_r else 0
        print(f"  {name:12s}: best shift={best_s:+d} matches={best_m}/{len(b_r)} ({pct:.1f}%)")


if __name__ == '__main__':
    main()
