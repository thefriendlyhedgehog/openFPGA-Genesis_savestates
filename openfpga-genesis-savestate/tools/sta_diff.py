#!/usr/bin/env python3
"""Region-aware diff of two Genesis savestate .sta files.

Maps each payload byte to its savestate region (based on
savestate_ctrl.sv address layout) and reports per-region
byte-diff counts, plus first N diffs as hexdump.

Usage:
    sta_diff.py <A.sta> <B.sta>

Typical use:
    1. Take save "A" (presave), load it, then take save "B" (postload).
    2. If the FPGA restored A correctly, B should equal A byte-for-byte
       in every non-header region (modulo timestamps / APF wrapper).
    3. If a region in B differs from A, the restore path for that region
       is broken. Shift analysis (sta_shift_check.py) shows whether the
       corruption is a simple off-by-N byte shift or something else.
"""
import sys

# APF wrapper offset (confirmed 0x255 in Pocket save files)
APF_HEADER_OFFSET = 0x255

# Savestate payload is 0x22590 bytes starting at APF_HEADER_OFFSET
PAYLOAD_SIZE = 0x22590

# Region map from savestate_ctrl.sv localparams:
#   WRAM_BASE   = 0x00010 (64 KB)
#   VRAM_BASE   = 0x10010 (64 KB)
#   Z80RAM_BASE = 0x20010 (8 KB)
#   M68K_BASE   = 0x22010 (256 B)
#   Z80REG_BASE = 0x22110 (64 B)
#   VDP_BASE    = 0x22150
#     VDP REG    +0x00..+0x1F (32 B)
#     VDP STATE  +0x20..+0x27 (8 B)
#     VDP CRAM   +0x28..+0xA7 (128 B)
#     VSRAM0     +0xA8..+0xE7 (64 B)
#     VSRAM1     +0xE8..+0x127 (64 B)
#   FM_BASE     = 0x22350 (512 B)
#   PSG_BASE    = 0x22550 (8 B)
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


def region_of(off):
    for name, lo, hi in REGIONS:
        if lo <= off < hi:
            return name
    return "OOB"


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <A.sta> <B.sta>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], 'rb') as f:
        a_full = f.read()
    with open(sys.argv[2], 'rb') as f:
        b_full = f.read()

    # APF wrapper diff
    apf_diffs = sum(1 for i in range(APF_HEADER_OFFSET) if a_full[i] != b_full[i])
    print(f"=== APF wrapper (0x000..0x{APF_HEADER_OFFSET:03x}) ===")
    print(f"{apf_diffs} byte diffs in APF wrapper (expected: timestamp/filename)")
    print()

    # Payload diff
    a = a_full[APF_HEADER_OFFSET:APF_HEADER_OFFSET + PAYLOAD_SIZE]
    b = b_full[APF_HEADER_OFFSET:APF_HEADER_OFFSET + PAYLOAD_SIZE]

    print(f"=== Savestate payload (0x{APF_HEADER_OFFSET:03x}..0x{APF_HEADER_OFFSET+PAYLOAD_SIZE:05x}) ===")
    print(f"Payload size: {len(a)} bytes")
    print()

    # Per-region diff counts
    region_diffs = {name: 0 for name, _, _ in REGIONS}
    region_sizes = {name: (hi - lo) for name, lo, hi in REGIONS}
    first_diff = {}
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            r = region_of(i)
            region_diffs[r] += 1
            if r not in first_diff:
                first_diff[r] = i

    print(f"{'Region':12s} {'Size':>8s} {'Diffs':>8s} {'%':>7s} {'First':>8s}")
    print("-" * 50)
    total_diffs = 0
    for name, lo, hi in REGIONS:
        d = region_diffs[name]
        s = region_sizes[name]
        pct = (d / s * 100) if s else 0
        first = f"0x{first_diff[name]:05x}" if name in first_diff else "-"
        marker = " <--" if d > 0 else ""
        print(f"{name:12s} {s:>8d} {d:>8d} {pct:>6.1f}% {first:>8s}{marker}")
        total_diffs += d
    print("-" * 50)
    print(f"{'TOTAL':12s} {len(a):>8d} {total_diffs:>8d}")
    print()

    # Show first differences per region
    print("=== First differences per region (up to 8 per region) ===")
    shown = {name: 0 for name, _, _ in REGIONS}
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            r = region_of(i)
            if shown[r] < 8:
                pay_off = APF_HEADER_OFFSET + i
                print(f"  [{r:8s}] payload[0x{i:05x}]  file[0x{pay_off:05x}]  A=0x{x:02x}  B=0x{y:02x}")
                shown[r] += 1


if __name__ == '__main__':
    main()
