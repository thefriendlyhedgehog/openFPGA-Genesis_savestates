# Savestate debug tools

Diagnostic scripts for the Genesis openFPGA savestate implementation.

## sta_diff.py

Region-aware byte diff of two `.sta` savestate files from the Pocket SD card.
Maps every payload byte to its region (WRAM, VRAM, Z80RAM, M68K, Z80REG,
VDPREG, VDPST, CRAM, VSRAM0/1, FM, PSG) and reports per-region diff counts.

```
tools/sta_diff.py /path/to/A.sta /path/to/B.sta
```

**Intended workflow: save-load-save differential.**

1. Save state "A" while the game is paused in a known state.
2. Load state A.
3. Save state "B" immediately (without progressing the game).
4. If the load path works, B should equal A byte-for-byte in every region.
5. Any region where B != A identifies a broken restore path.

## sta_shift_check.py

Same input as `sta_diff.py`, but instead of counting diffs it asks:
"for what shift `s` does `B[i] == A[i - s]` hold?"  A high match rate at
`s != 0` means the data is arriving off-by-N.

```
tools/sta_shift_check.py /path/to/A.sta /path/to/B.sta
```

This is how the 2026-04-14 investigation discovered that WRAM, Z80RAM,
VDPREG, and M68K all come back shifted by +1 byte after a load. See
`../SAVESTATE_HANDOFF.md` for the implications.

## File layout of a Pocket savestate

```
0x000..0x254   APF wrapper (header, timestamp, filename)
0x255..        Core payload, 0x22590 bytes, starting with "APFGN001" magic
```

Region offsets within the payload match `savestate_ctrl.sv` `*_BASE`
localparams.
