# Phase 1 — Disambiguation (complete)

Date: 2026-04-17
Input files:
- `A.sta`: `20260414_154126_USR_00000000_Sonic 2 Improvement v5.2 (2019-04-04)(l.sta` (pre-save)
- `B.sta`: `20260414_162445_USR_00000000_Sonic 2 Improvement v5.2 (2019-04-04)(l.sta` (post-crashed-load re-save)

Both 194 048 bytes, APF wrapper identical, payload `0x22590` bytes starting
with `APFGN001`.

## Smoking gun

At payload offset `0x8E` onward (inside WRAM body), **14 consecutive bytes
satisfy `B[off] == A[off-1]`**:

```
 off  A[off] B[off]  A[off-1]
0x08e  0x72   0x01    0x01 <-- B==A[off-1]
0x08f  0x01   0x72    0x72 <-- B==A[off-1]
0x090  0x3c   0x01    0x01 <-- B==A[off-1]
0x091  0xa0   0x3c    0x3c <-- B==A[off-1]
...
0x09b  0x01   0x74    0x74 <-- B==A[off-1]
```

This is a textbook +1 byte shift.

## Load-vs-save disambiguation

The save path emits the `APFGN001` magic as a hard-coded constant, so
header bytes cannot be used alone to tell whether save or load is buggy.
Instead: look at the **first byte of every region** in B:

| Region  | B[region_base..+3] | First byte |
|---------|--------------------|-----------:|
| WRAM    | `00000000`         | `0x00`     |
| VRAM    | `00000000`         | `0x00`     |
| Z80RAM  | `00f33180`         | `0x00`     |
| M68K    | `00000000`         | `0x00`     |
| Z80REG  | `00021308`         | `0x00`     |
| VDPREG  | `00047430`         | `0x00`     |
| VDPST   | `0080fa00`         | `0x00`     |
| CRAM    | `00000100`         | `0x00`     |
| VSRAM0  | `00000000`         | `0x00`     |
| VSRAM1  | `00000000`         | `0x00`     |
| FM      | `00000000`         | `0x00`     |
| PSG     | `000047a4`         | `0x00`     |

**Every region's first byte is `0x00` — the DPRAM reset value. The first
byte of each region was never written during load.**

Combined with the shift proof above, the bug is:
- **Not** in the save path — save faithfully dumps whatever is in the
  RAMs / shift registers, and the regions that happen to have been
  written correctly (FM, VSRAM1, and the zero-heavy tails) come back
  clean.
- **In the load path**, specifically in the byte-write pipeline from
  APF/data_loader into savestate_ctrl's write enables. Bytes arrive
  one cycle ahead of where they should — the first byte of each
  region (or of the overall stream) is lost to the reset value, and
  all subsequent bytes land one address later than intended.

## Global vs. per-region shift

The per-region shift table shows `+1` dominates (WRAM 98.2 %, Z80RAM
99.7 %, VDPREG 96.9 %), while VRAM (95.4 % at shift 0) and FM (99.8 %
at shift 0) are unaffected. The explanation:

- VRAM commits one 32-bit word only when its 4-byte accumulator is
  full. A 1-byte lag in the ssw pipeline shifts bytes within each
  4-byte buffer, producing a per-word permutation rather than a
  bytewise shift — the measurement framework can't see it as a "shift"
  so it scores as ~random at every offset.
- FM uses a separate write port (`jt12` shadow regfile), not the
  ssw→DPRAM path, so it sidesteps the bug entirely.
- The whole-payload shift score peaks at +1 (71 %) but is depressed
  by VRAM and by the region boundary artifacts — consistent with a
  uniform one-cycle pipeline lag that manifests bytewise in the
  byte-write regions and differently in the word-write region.

## Next step (Phase 2)

Reproduce in simulation. The bug lives somewhere between:
1. `data_loader.sv` latching `write_addr`, `write_data`, `write_en` at
   the wrong relative cycles (most likely); or
2. `savestate_ctrl.sv` sampling `ssw_data` one cycle after `ssw_addr`
   (less likely — the connection is flat wires).

Phase 2 plan: drive a byte ramp (0x01, 0x02, 0x03, …) into data_loader
and check that, on every cycle where `write_en=1`, `write_data` equals
`write_addr - write_addr_base + 1`. If it doesn't, the fix goes in
data_loader.
