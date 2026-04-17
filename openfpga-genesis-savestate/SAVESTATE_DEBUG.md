# Savestate Debug Guide

> **Read `SAVESTATE_HANDOFF.md` first.** It has the current (2026-04-17)
> status, the off-by-one byte-shift finding, and what to do next. This
> file retains the older architectural notes, FSM tables, and build
> instructions that are still accurate.

## Status (2026-03-28 — superseded, see SAVESTATE_HANDOFF.md for current)

### Current Symptoms
- **Save state**: works (data is written to SD card successfully)
- **Load state**: black screen with audio playing, interlacing artifacts
- Audio working = CPUs ARE running after restore (PAUSE_EN/ss_halt released)
- Black screen = VDP video output is wrong after restore
- Pocket APF crash codes observed: RPC: 0xB4C725F9, CR: 0x07, VR: 0x23
- `interact.json` debug sliders (`slider_u32` and `number_u32`) do NOT appear in the Pocket menu — **this debugging approach failed**. The Pocket may not support these types, or the file isn't being loaded. Need alternative debug approach.
- **Update (2026-04-14):** Differential save-load-save test revealed an
  off-by-one byte shift in the load path (WRAM/Z80RAM/M68K/VDPREG all
  return `B[i] == A[i-1]`). See `SAVESTATE_HANDOFF.md` and the scripts
  in `tools/` for reproduction. This is the primary blocker, not the
  VDP/CPU state issues described below.

### What Was Tried
1. `number_u32` type in interact.json → not visible
2. `slider_u32` type in interact.json → not visible
3. VDP register apply during vblank wait → still black screen

### Recommended Next Debug Approach
**Option A: On-screen debug overlay.** Modify the video output path in core_top.sv to render debug state as colored bars or hex digits during vblank or in a corner of the screen. This is self-contained and doesn't depend on interact.json.

**Option B: SD card log file.** The Pocket supports debug logging to `/System/Logs/` on the SD card (enable in Developer Settings). The Chip32 VM log may show the savestate handshake sequence.

**Option C: Conditional compilation.** Build two versions: one with the 68K/Z80 fixes, one without. The "without" version showed the blue backdrop (VDP worked, CPUs dead). Compare behavior to isolate whether the regression is from 68K T0 force, Z80 reset, or vblank wait.

**Option D: Output debug state as backdrop color.** After load completes, have the savestate_ctrl write a specific value to VDP CRAM entry 0 (backdrop) encoding the FSM final state. This would show as a visible color.

---

## Architecture Overview

### Clock Domains
- `clk_74a` (74.25 MHz): APF bridge, host/target commands, data_loader/unloader
- `clk_sys` (53.69 MHz): Genesis system — 68K, Z80, VDP, FM, PSG
- `current_pix_clk` (varies): Video output to Pocket display

### PAUSE_EN Signal
`PAUSE_EN = (cs_menu_pause_enable & osnotify_inmenu_s) | ss_halt`
- `cs_menu_pause_enable` defaults to 0 (disabled in core)
- So `PAUSE_EN = ss_halt` only
- PAUSE_EN gates: M68K_CLKENp/n, Z80_CLKENp/n, PSG_CLKEN, FM_CLKEN
- PAUSE_EN does **NOT** gate the VDP pixel clock — VDP continues rendering during halt
- This means VDP register changes during halt are immediately visible in video output

### Savestate Protocol (APF ↔ Core)
Source: `core_bridge_cmd.v` host commands 0x00A0 (save) and 0x00A4 (load)

**Save flow:**
1. APF asserts `savestate_start` (level, in clk_74a)
2. Core detects rising edge (via CDC synch_3), asserts `save_ack` for ≥1 cycle
3. Core asserts `save_busy` during operation
4. Core freezes state (`ss_halt=1`), waits for DMA drain
5. Core asserts `save_ok` — data is now readable via data_unloader at 0x50000000
6. APF reads all bytes via bridge
7. Core detects last byte read, clears `ss_halt`, clears `save_ok`

**Load flow:**
1. APF writes savestate data to 0x50000000 via bridge (data_loader)
   - **Data arrives BEFORE the load command** (APF pre-fills buffer)
   - The core must capture data as it arrives (early halt on header validation)
2. APF asserts `savestate_load`
3. Core detects rising edge, asserts `load_ack` for ≥1 cycle
4. Core asserts `load_busy`
5. If data already received, immediately enters APPLY sequence
6. APPLY sequence loads register state into CPUs/VDP/FM/PSG
7. Core asserts `load_ok`, clears `ss_halt`, clears `load_busy`

**Critical timing:** `savestate_load` is asserted as a level in clk_74a. The core_bridge_cmd holds it high until it sees `load_ack`. The CDC synch_3 adds ~3 clk_sys cycles of latency. Our FSM uses rising edge detection on the CDC output.

### Data Flow: Load Path
```
APF bridge writes (clk_74a) → data_loader FIFO → ssw_en/ssw_addr/ssw_data (clk_sys)
                                                     ↓
                              ┌─────────────── addr_to_region() classifies
                              ↓                      ↓                    ↓
                         RGN_WRAM/VRAM/Z80RAM    RGN_M68K/Z80/PSG/VDP  RGN_FM/CRAM/VSRAM
                              ↓                      ↓                    ↓
                     Combinational writes      Shift register accum   Inline writes
                     to dual-port BRAM          into load_*_sr        to FM/CRAM/VSRAM
                     (gated by ss_halt)              ↓
                                              ST_LOAD_APPLY fires
                                              ss_*_load pulses
```

### Savestate Binary Layout
```
Offset    Size    Region        Notes
0x00000   16B     Header        "APFGN001" + version + size
0x00010   64KB    WRAM          68K main RAM, 16-bit (big-endian, upper/lower DPRAMs)
0x10010   64KB    VRAM          32-bit aligned, 4 bytes per VRAM word
0x20010   8KB     Z80 RAM       8-bit
0x22010   256B    68K CPU       ss_m68k_state[1023:0], 128 bytes used, rest padding
0x22110   64B     Z80 CPU       ss_z80_reg[211:0], 27 bytes used, rest padding
0x22150   512B    VDP           REG(32B) + STATE(4B) + STATUS(2B) + pad(2B) +
                                CRAM(128B) + VSRAM0(64B) + VSRAM1(64B) + pad
0x22350   512B    FM            jt12 shadow reg file, 1 byte per address
0x22550   64B     PSG           ss_psg_state[63:0], 8 bytes used, rest padding
TOTAL = 0x22590 bytes
```

---

## Debug Register (bridge readback)

A packed 32-bit debug word is available at bridge address `0x00100000` (low 16 bits) and `0x00100004` (high 16 bits). These are wired in the bridge read mux in core_top.sv. The debug word is generated combinationally from `savestate_ctrl` internal signals.

**NOTE: interact.json readback DOES NOT WORK on the user's Pocket.** The `number_u32` and `slider_u32` types were not visible in the interact menu. Either the Pocket firmware doesn't support them, or the interact.json isn't being loaded from the SD card. An alternative debug readback method is needed.

### Debug Bit Layout
```
[31:16] = last ssw_addr >> 2   (last data_loader write address, divided by 4)
[15]    = load_ok              (load completed successfully)
[14]    = load_busy            (load in progress)
[13]    = save_busy            (save in progress)
[12]    = boot_ready           (boot holdoff expired, ~78ms after reset)
[11]    = header_validated     (got "AP" magic bytes)
[10]    = load_data_received   (last byte of savestate data arrived)
[9]     = ss_halt              (CPUs frozen)
[8:4]   = apply_state          (sub-state during LOAD_APPLY)
[3:0]   = state                (main FSM state)
```

### FSM States [3:0]
| Value | Name           | Description                          |
|-------|----------------|--------------------------------------|
| 0     | ST_IDLE        | Waiting for save/load command        |
| 1     | ST_SAVE_ACK    | Acknowledged save; halting CPUs      |
| 2     | ST_SAVE_DRAIN  | Waiting for DMA to quiesce (128 cyc) |
| 3     | ST_SAVE_READY  | Frozen; firmware reading data        |
| 4     | ST_SAVE_DONE   | Releasing halt                       |
| 5     | ST_LOAD_ACK    | Acknowledged load; halting CPUs      |
| 6     | ST_LOAD_RUN    | Receiving data from APF              |
| 7     | ST_LOAD_APPLY  | Applying register state (sub-states) |
| 8     | ST_LOAD_DONE   | Load complete; releasing halt        |

### Apply Sub-States [8:4]
| Value | Name           | Description                         |
|-------|----------------|-------------------------------------|
| 0     | APPLY_M68K     | Loading 68K CPU state               |
| 1     | APPLY_Z80_RST  | Asserting Z80 reset (cycle 1)       |
| 2     | APPLY_Z80_RST2 | Holding Z80 reset (cycle 2)         |
| 3     | APPLY_Z80      | Loading Z80 registers via DIRSet    |
| 4     | APPLY_PSG      | Loading PSG state                   |
| 5     | APPLY_VDP_WAIT | Waiting for vblank                  |
| 6     | APPLY_VDP      | Loading VDP registers + state       |
| 7     | APPLY_DONE     | Apply sequence complete             |

---

## Changes Made (this branch, all files)

### 1. `src/fpga/core/savestate_ctrl.sv`
- **68K T0/SIDLE force**: `ss_m68k_state_in[613:611] <= 3'd0` (tState=T0), `ss_m68k_state_in[992:978] <= 15'h0079` (busControl=SIDLE, bus signals deasserted)
- **Z80 reset pulse**: Added `APPLY_Z80_RST` and `APPLY_Z80_RST2` states that assert `ss_z80_reset` for 2 cycles before `APPLY_Z80` (DIRSet register load)
- **VDP vblank wait**: Added `APPLY_VDP_WAIT` state that waits for `vblank` before applying VDP registers (prevents mid-frame interlace/resolution change)
- **Debug output**: Added `output wire [31:0] debug_state` packed from internal signals
- **Vblank input**: Added `input wire vblank` port

### 2. `src/fpga/core/core_top.sv`
- Added `wire ss_z80_reset` and connected to savestate_ctrl `.ss_z80_reset(ss_z80_reset)` and system `.SS_Z80_RESET(ss_z80_reset)`
- Added `wire [31:0] ss_debug_state` and connected to savestate_ctrl `.debug_state(ss_debug_state)`
- Connected `.vblank(vblank_sys)` to savestate_ctrl
- Added bridge read at `0x00100000` (debug lo) and `0x00100004` (debug hi)

### 3. `src/fpga/core/rtl/system.sv`
- Added `input SS_Z80_RESET` port
- Changed Z80 instantiation: `.RESET_n(Z80_RESET_N & ~SS_Z80_RESET)` (was `.RESET_n(Z80_RESET_N)`)

### 4. `dist/Cores/ericlewis.Genesis/interact.json`
- Added `SS Debug Lo` (slider_u32, address 0x00100000) and `SS Debug Hi` (slider_u32, address 0x00100004)
- **NOTE: These don't appear in the Pocket menu.** May need different approach.

---

## Key Analysis

### Why "blue screen" → "black screen with audio" After Changes

**Before changes (blue screen):**
- VDP registers loaded correctly (backdrop color visible)
- 68K crashed on resume (corrupted mid-instruction state)
- No audio (68K dead, can't drive FM)
- VDP still rendered backdrop autonomously

**After changes (black screen + audio):**
- 68K running (audio works = 68K writing FM registers)
- Z80 running (reset pulse gave clean state, DIRSet loaded regs)
- VDP video output is wrong
- The 68K is executing from saved PC with T0/SIDLE forced state
- This means the 68K successfully resumed execution
- But something about the video pipeline is broken

**Root cause hypothesis:** The 68K resumes and starts executing game code, which includes VDP register writes. If the saved PC is in the middle of a VDP access sequence (e.g., between writing VDP control port bytes), the 68K's first instruction after resume could write a partial VDP command, corrupting the VDP's internal address/command latch state. This could disable display or corrupt scroll/nametable pointers.

**Alternative hypothesis:** The VDP_WAIT for vblank could be failing. If `vblank` (from `vblank_sys`) is never asserted during PAUSE_EN (because VDP pixel clock runs but the VDP's line counter might not advance if certain clocks are gated), the FSM could be stuck in APPLY_VDP_WAIT forever.

**CRITICAL CHECK:** Verify that vblank_sys still toggles during ss_halt. The VDP pixel clock is NOT gated by PAUSE_EN, but the VDP's *internal clock enables* might be. If the VDP's line counter doesn't advance during pause, vblank will never assert, and APPLY_VDP_WAIT will deadlock.

### Potential Issues to Fix

1. **APPLY_VDP_WAIT deadlock**: If vblank doesn't toggle during ss_halt, this state will never advance. Add a timeout (e.g., 2M cycles ≈ 37ms at 54MHz, well over one frame period) that forces advancement.

2. **68K busControl bit mapping**: The value `15'h0079` for SIDLE needs verification against fx68k.sv. The packing is: `{isByteT4, addrOeDelay, wendReg, isRmcReg, bciByte, isWriteReg, bcPend, addrOe, rRWn, rUDS, rLDS, rAS, busPhase[2:0]}`. SIDLE=1, so busPhase=3'b001. With all control bits deasserted: `{0,0,0,0,0,0,0,0,1,1,1,1, 001}` = 15'b000_0000_0111_1001 = 15'h0079. This looks correct.

3. **Z80 DIRSet timing**: DIRSet fires on the same cycle as ss_z80_reset deassertion. The T80 reset is synchronous to CEN (clock enable). With PAUSE_EN=1, Z80_CLKENn is gated, so the Z80 never sees the reset or DIRSet during halt. Both only take effect when ss_halt drops and clocks resume. **This means the Z80 sees reset deassert and DIRSet simultaneously on the first clock edge after unhalt — this might not work correctly.** The T80 may need multiple clock cycles of reset before DIRSet is valid.

4. **VDP FIELD register**: The VDP's `FIELD` output alternates each vblank in interlace mode. This internal state is not saved/restored. If the game uses interlace mode, FIELD could be wrong after restore, causing the Pocket's display to show the wrong field.

---

## Building and Deploying

### Build Server
```bash
ssh cachy@10.100.100.100   # Shell is fish, use bash -c '...' for complex commands
```

### Quartus
```
/opt/intelFPGA_lite/21.1.1/quartus/bin/quartus_sh
```

### Build Directory
```
/home/cachy/genesis-build/
```

### Full Build Sequence
```bash
# 1. Sync modified source files
scp src/fpga/core/savestate_ctrl.sv cachy@10.100.100.100:genesis-build/core/
scp src/fpga/core/core_top.sv cachy@10.100.100.100:genesis-build/core/
scp src/fpga/core/rtl/system.sv cachy@10.100.100.100:genesis-build/core/rtl/

# 2. Compile (takes ~10-15 minutes)
ssh cachy@10.100.100.100 "bash -c 'cd /home/cachy/genesis-build && /opt/intelFPGA_lite/21.1.1/quartus/bin/quartus_sh --flow compile ap_core 2>&1'"

# 3. Copy and convert bitstream
scp cachy@10.100.100.100:genesis-build/output_files/ap_core.rbf /tmp/ap_core.rbf
python3 -c "
data = open('/tmp/ap_core.rbf','rb').read()
out = bytes(int('{:08b}'.format(b)[::-1],2) for b in data)
open('dist/Cores/ericlewis.Genesis/bitstream.rbf_r','wb').write(out)
"

# 4. Copy to SD card:
#    dist/Cores/ericlewis.Genesis/bitstream.rbf_r
#    dist/Cores/ericlewis.Genesis/interact.json  (if changed)
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `src/fpga/core/savestate_ctrl.sv` | Savestate FSM, data accumulation, APPLY states, debug output |
| `src/fpga/core/core_top.sv` | Top-level wiring, bridge readback, CDC, video pipeline |
| `src/fpga/core/core_bridge_cmd.v` | APF host command handler (0x00A0/0x00A4 savestate protocol) |
| `src/fpga/core/data_loader.sv` | CDC FIFO: bridge writes (clk_74a) → ssw_en/addr/data (clk_sys) |
| `src/fpga/core/data_unloader.sv` | CDC FIFO: ssr_data (clk_sys) → bridge reads (clk_74a) |
| `src/fpga/core/rtl/system.sv` | Genesis system: CPU/VDP/FM/PSG instantiation, bus arbitration |
| `src/fpga/core/rtl/FX68K/fx68k.sv` | 68K CPU with ss_state save/restore |
| `src/fpga/core/rtl/T80/T80.vhd` | Z80 CPU with DIRSet register load |
| `src/fpga/core/rtl/vdp.vhd` | VDP with register/CRAM/VSRAM restore |
| `src/fpga/core/rtl/jt89/jt89.v` | PSG with state save/restore |
| `src/fpga/core/rtl/jt12/jt12_mmr.v` | FM shadow register file |
| `dist/Cores/ericlewis.Genesis/core.json` | `sleep_supported: true` |
| `dist/Cores/ericlewis.Genesis/data.json` | Savestate slot id=11 at 0x50000000 |
| `dist/Cores/ericlewis.Genesis/interact.json` | Pocket menu config (debug entries added) |

## Reference: agg23's NES core savestate implementation
- Repo: `agg23/openfpga-NES`
- Uses `save_state_controller.sv` in `target/pocket/`
- Uses FIFOs for save/load data path (vs our direct shift register approach)
- Working savestate implementation to compare against
