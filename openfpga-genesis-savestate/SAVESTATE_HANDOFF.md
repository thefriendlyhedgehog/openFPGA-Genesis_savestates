# Savestate Handoff — Current State, Root-Cause Findings, and What to Try Next

_Last updated: 2026-04-17. Previous model context: `determined-elion` branch._

This document is the single entry point for picking this project up cold. It
supersedes the status sections of `SAVESTATE_DEBUG.md` (which is kept for the
older architectural notes and build instructions). Read this first.

---

## TL;DR

- Genesis/MegaDrive openFPGA core with save/load support on the Analogue Pocket.
- **Save writes to SD. Load currently produces a black screen on hardware.**
- We have **conclusive evidence** from a save-load-save differential test that
  the load path writes every byte **one address ahead of where it belongs**
  for WRAM, Z80RAM, M68K, and VDPREG regions. The VRAM and FM regions are
  unaffected because VRAM uses a 4-byte accumulation buffer and FM uses a
  separate port.
- **The +1 byte shift has not been fixed.** No more speculative bitstream
  builds until the shift is traced to its source in `savestate_ctrl.sv`
  and/or `data_loader.sv`. The user has explicitly prohibited another
  blind build-and-see cycle (see `feedback_debug_iteration.md` in user
  memory).

## What has already been verified

1. The VDP region-decode bug (`!a[5]` → `!(a[5] & a[4])`) is fixed in
   `savestate_ctrl.sv` `addr_to_region()`.
2. The Z80 `RESET_n` is no longer gated by `SS_LOADING`; DIRSet can actually
   reach the T80 state machine. Confirmed by reading `T80.vhd` — the DIRSet
   branch is unreachable while `RESET_n=0`.
3. T80 internal cycle state (`MCycle`, `TState`, `IR`, `ISet`, `XY_State`,
   `Halt_FF`, `M1_n`) is now force-reset inside the DIRSet branch, so the
   Z80 resumes with a clean M1/T1 fetch at the loaded PC.
4. `fx68k.sv` `ss_state_load` now loops 0..16 instead of 0..17 — loading
   index 17 (`REG_DT`) was clobbering the live temporary register with the
   zero-padded upper bits of `ss_regs_in`.
5. `system.sv` resets the MBUS/ZBUS state machines and the VRAM port-B
   selector only during **load** (`SS_LOADING`), not during save — save
   must preserve in-flight bus state.
6. Header validation ("AP" prefix) and a 78 ms boot holdoff guard the
   early-halt logic against spurious APF bridge probes during boot.
7. `clk_sys == MCLK` — no CDC between `savestate_ctrl` and the CPUs.
8. `data_loader.sv` READ_WRITE state latches `write_addr`, `write_data`,
   and `write_en` together on the same cycle. No obvious off-by-one there.

## The +1 byte shift — smoking gun

Saved A (presave), loaded A, then saved again as B while the core was
black-screened. Ran `tools/sta_shift_check.py A.sta B.sta`:

| Region  | Best shift | Match rate | Notes                           |
|---------|-----------:|-----------:|---------------------------------|
| WRAM    | **+1**     | 98.2%      | combinational write to DPRAM    |
| Z80RAM  | **+1**     | 99.7%      | combinational write to DPRAM    |
| VDPREG  | **+1**     | 96.9%      | registered byte-indexed case    |
| M68K    | **+1**     | high       | registered byte-indexed case    |
| VRAM    |  0         | 95.4%      | 4-byte accumulator, absorbs shift |
| FM      |  0         | 99.8%      | jt12 separate port              |

Interpretation: `B[i] == A[i-1]` ⇒ load wrote `A[i]` into FPGA address `i+1`.
The address counter is one ahead of the data byte. This affects every path
that commits a single byte per `ssw_en` pulse. Paths that accumulate bytes
(VRAM's 4-byte buffer) absorb the shift and paths that route through a
different port (jt12 FM) don't see it at all.

**This is the primary blocker.** Everything else above is secondary.

## Where the shift probably is

Three candidates in order of likelihood:

### 1. `data_loader.sv` address/data registration mismatch

The dcfifo between `clk_74a` and `clk_sys` hands out `write_addr` and
`write_data`, and `write_en` is derived from the state machine. If the
address or data is registered one cycle later than the enable, the
downstream consumer sees `ssw_en` with the **next** address paired with
the **current** data — i.e., the shift we see. Look for:

- Separate `always @(posedge clk_sys)` blocks for addr/data vs. enable.
- An address counter that advances before `write_en` is asserted.
- An unintended register stage on `write_data` that's absent on `write_addr`.

### 2. `savestate_ctrl.sv` `ssw_addr_lo_m10` / `ssw_region_c`

`ssw_region_c` is combinational on `ssw_addr`. But `ssw_m68k_off`,
`ssw_vdp_off`, `ssw_addr_lo12` etc. are all derived combinationally from
`ssw_addr` as well, so they should be stable on the same cycle as
`ssw_en`. Sanity-check:

- Is `ssw_addr` itself registered with the same latency as `ssw_data`?
- Does the first byte of each region (e.g. `ssw_m68k_off == 0`) actually
  appear on the same cycle as the first `ssw_en` for that region, or one
  cycle late?

### 3. Save side (`ssr_*` read path), not load

Less likely but possible. If the save-side **read** path emits one extra
leading byte or is off-by-one in `ssr_addr` vs. `ssr_data`, then B would
be shifted relative to FPGA memory. To distinguish load-side from save-side
shift, compare known-constant bytes in A against expected values:

- The "APFGN001" magic at payload offset 0..7 should be exactly those
  bytes in any correctly written savestate. If A has the magic at 0..7
  but B has `'\0','A','P','F','G','N','0','0'` at 0..7, the shift is in
  the save path. If B has the magic at 0..7 too, the shift is in the load
  path.

## What NOT to do

- **Do not rebuild the bitstream** until you have a specific, tested fix
  in simulation. The user has said "Do NOT send another build and tell me
  to look and see what happens" (2026-04-14). Every build costs ~15 minutes
  and the vague "black screen again" feedback doesn't pin down root cause.
- **Do not revert the register-level fixes** (T80 cycle state, fx68k
  REG_DT, VDP region decode, Z80 RESET_n gating). These are correct and
  necessary; they're just not the last remaining bug.
- **Do not add more speculative "defensive" state resets** to the APPLY
  sub-states. The shift bug means we're loading the wrong data into the
  right registers — no amount of state reset on the CPU side will fix
  garbage data.

## What to do

Work in roughly this order:

1. **Confirm which side has the shift.** Read `A.sta` byte 0x255..0x25C
   and `B.sta` byte 0x255..0x25C. "APFGN001" in both ⇒ load bug. Shifted
   in B ⇒ save bug. (Existing `.sta` files are no longer at `/tmp/` — ask
   the user for the SD card path: `/Volumes/NO NAME/Memories/Save States/ericlewis.Genesis/`.)
2. **Sim-repro the shift.** Extend `tb_savestate_data.sv` (already in repo)
   or write a new `tb_savestate_ctrl.sv` that drives 128 bytes into the
   M68K region via synthetic `ssw_en`/`ssw_addr`/`ssw_data` and checks
   `load_m68k_sr`. If iverilog shows the bytes land correctly in sim, the
   bug is in `data_loader.sv`, not `savestate_ctrl.sv`.
3. **Trace `data_loader.sv`.** The state machine is small. Verify that
   `write_addr`, `write_data`, and `write_en` present on the same edge,
   to the same consumer.
4. **Fix the shift in source.** Do not touch APPLY/FSM code until the
   shift is resolved.
5. **Re-run the save-load-save diff on hardware.** Only at this point
   should a new bitstream be considered, and only with the user's explicit
   go-ahead.
6. **Iterate on any remaining CPU-state restore issues.** The shift is
   almost certainly the cause of the current black screen; other fixes
   should only be attempted after the data itself is landing correctly.

## File-by-file state of the worktree

All are **uncommitted** working-tree changes at the time of handoff.

| File | Status | Purpose |
|------|--------|---------|
| `src/fpga/core/savestate_ctrl.sv` | modified | VDP region decode fix; `ss_vram_sel` + `ss_loading` outputs; header "AP" validation + boot holdoff; 2-cycle M68K apply (SETUP/FIRE); direct byte-indexed writes for M68K/VDPREG/VDPST; `ss_halt` gate removed from WRAM/VRAM/Z80RAM write enables (diagnostic) |
| `src/fpga/core/core_top.sv` | modified | Savestate bridge at `0x40000000` (was `0x50000000`); wires `ss_vram_sel`/`ss_loading` through to `system` |
| `src/fpga/core/rtl/system.sv` | modified | `SS_LOADING`/`SS_VRAM_SEL` ports; MBUS/ZBUS reset only during load; VRAM port B mux uses `SS_VRAM_SEL`; Z80 `RESET_n` no longer gated by load |
| `src/fpga/core/rtl/FX68K/fx68k.sv` | modified | Load loop 0..16 (skip REG_DT) |
| `src/fpga/core/rtl/T80/T80.vhd` | modified | Force clean cycle state in DIRSet branch |
| `src/fpga/core/rtl/vdp.vhd` | modified | DMA/FIFO blind-reset removed from state restore (caused same-session corruption) |
| `src/fpga/core/tb_savestate_data.sv` | **untracked** | Existing testbench for save/load round-trip of register-based regions |
| `tools/sta_diff.py` | **new** | Region-aware .sta diff |
| `tools/sta_shift_check.py` | **new** | Shift-N pattern detector |
| `tools/README.md` | **new** | Tool usage |
| `SAVESTATE_DEBUG.md` | existing | Older architectural notes (keep) |
| `SAVESTATE_HANDOFF.md` | **this file** | Current state + next steps |
| `dist/Cores/ericlewis.Genesis/bitstream.rbf_r` | modified | Last-built bitstream (contains the bug — do not rely on it) |
| `dist/Cores/ericlewis.Genesis/data.json` | modified | Address range for savestate slot |

## Build info (unchanged from SAVESTATE_DEBUG.md)

- Host: `cachy@10.100.100.100` (password stored in user memory)
- Quartus: `/opt/intelFPGA_lite/21.1.1/quartus/bin/quartus_sh`
- Build dir: `/home/cachy/genesis-build/`
- Full build ~11 minutes. Convert `.sof`→`.rbf_r` with bit-reversal.
- **Do not rebuild until the shift bug is fixed in sim.**

## Relevant prior commits on `claude/determined-elion`

```
6ab57f3 Rebuild bitstream with VDP region fix and AREA optimization
e62f0af Rebuild bitstream: fix boot black screen + optimize for ALM fit
a90a273 Fix black screen: add header validation guard to early halt
6503ba1 Fix bitstream: apply bit-reversal for Analogue Pocket rbf_r format
579d7c1 Fix FM region boundary bug found by simulation, add testbench
124f54f Rebuild bitstream with Quartus 21.1.1 Lite (matching project target)
50a81b1 Optimize savestate for Cyclone V ALM fit and add compiled bitstream
9380c72 Add save-state support to Genesis/MegaDrive openFPGA core
```

The uncommitted working-tree changes will be committed as part of this
handoff so the next model picks up a clean tree.
