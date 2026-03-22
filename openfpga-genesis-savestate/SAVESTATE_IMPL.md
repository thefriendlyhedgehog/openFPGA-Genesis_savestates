# Save-State Implementation Notes

## Overview

Adds save-state support (APF commands 0x00A0 / 0x00A4) to the Sega Genesis
openFPGA core.  Savestate data lives at APF address `0x50000000` and is
streamed byte-by-byte via the APF data-unloader / data-loader interfaces.
No large intermediate BRAM buffer is used; `savestate_ctrl` acts as virtual
memory, routing reads/writes directly to/from each peripheral.

---

## Binary layout

| Offset     | Size   | Contents |
|------------|--------|----------|
| `0x00000`  | 16 B   | Header: `"APFGN001"` (8 B) + version u32 + total\_size u32 (LE) |
| `0x00010`  | 64 KB  | WRAM — 68K main RAM (port B, 16-bit words) |
| `0x10010`  | 64 KB  | VRAM — VDP VRAM (port B, 32-bit words, 4 bytes each) |
| `0x20010`  | 8 KB   | Z80 RAM (port B, 8-bit) |
| `0x22010`  | 256 B  | 68K CPU registers (`ss_m68k_state[623:0]`, 78 B, padded) |
| `0x22110`  | 64 B   | Z80 CPU registers (`ss_z80_reg[211:0]`, 27 B, padded) |
| `0x22150`  | 512 B  | VDP state (see below) |
| `0x22350`  | 512 B  | YM2612 (jt12) shadow register file, 1 B/address × 512 |
| `0x22550`  | 64 B   | PSG (`ss_psg_state[63:0]`, 8 B, padded) |
| **Total**  | **0x22590** | **141,712 bytes** |

### VDP state layout (512 B at `0x22150`)

| Sub-offset | Size | Contents |
|------------|------|----------|
| `+0x00`    | 32 B | REG[0..31] (one byte each) |
| `+0x20`    | 4 B  | ADDR/CODE/PENDING packed: bit[23]=PENDING, bits[22:17]=CODE, bits[16:0]=ADDR |
| `+0x24`    | 2 B  | STATUS register |
| `+0x26`    | 2 B  | padding |
| `+0x28`    | 128 B| CRAM[0..63] as 16-bit words (9-bit value in LE, MSB only in bit[0] of high byte) |
| `+0xA8`    | 64 B | VSRAM0[0..31] as 16-bit words (11-bit value, top 3 bits in low 3 bits of high byte) |
| `+0xE8`    | 64 B | VSRAM1[0..31] same encoding |
| `+0x128`   | 216 B| padding |

---

## Files changed

### `src/fpga/core/rtl/FX68K/fx68k.sv`
- Added `ss_state_out`, `ss_state_in`, `ss_state_load` ports to `fx68k` and
  `excUnit`.
- PSW restore: `always_ff` block in `excUnit` now has an
  `else if (ss_state_load)` branch restoring `{pswT, pswS, pswI}` from bits
  `[591], [589], [586:584]` of `ss_state_in`.

### `src/fpga/core/rtl/T80/T80s.vhd`
- Added `REG`, `DIRSet`, `DIR` ports (pass-through to inner `T80`).

### `src/fpga/core/rtl/vdp.vhd`
- Added 20 save-state ports: shadow read ports for CRAM/VSRAM, write-load
  ports for REG/STATE/CRAM/VSRAM.
- Internal shadow arrays `CRAM_SHADOW`, `VSRAM0_SHADOW`, `VSRAM1_SHADOW`
  track writes to CRAM/VSRAM so the save path can read them without port
  contention with the renderer.
- Restore uses last-assignment-wins VHDL semantics inside the main DTC/DMA
  clocked process.

### `src/fpga/core/rtl/system.sv`
- Added ~60 save-state ports covering WRAM/VRAM/Z80RAM port B, CPU state,
  VDP state, FM shadow reg file, PSG state.
- Added `SS_VBUS_SEL` output (exposes internal `VBUS_SEL` for DMA drain
  counter in `savestate_ctrl`).
- WRAM and VRAM port B addresses/write-enables muxed between LOADING init
  path and SS path when `SS_BUSY`.

### `src/fpga/core/savestate_ctrl.sv` *(new)*
- FSM: IDLE → SAVE_ACK → SAVE_DRAIN → SAVE_RUN → SAVE_DONE
         IDLE → LOAD_ACK → LOAD_RUN → LOAD_APPLY → LOAD_DONE
- SAVE path: serves `data_unloader` byte reads from virtual memory map.
  WRAM/VRAM/Z80RAM reads go to BRAM port B; CPU/VDP/FM/PSG state read
  from combinatorial outputs.
- LOAD path: routes `data_loader` byte writes to WRAM/VRAM/Z80RAM port B.
  VRAM writes accumulate 4 bytes before committing a 32-bit write (required
  because port B has a single `wren_b` for all byte lanes).
  CRAM/VSRAM and FM register writes happen inline during LOAD_RUN.
  M68K/Z80/PSG/VDP register state is accumulated in buffers and applied in
  a short LOAD_APPLY sequence after the streaming write completes.
- SAVE_DRAIN waits for VDP DMA to quiesce (128 quiet cycles after
  `VBUS_SEL` deasserts) before reading VRAM.

### `src/fpga/core/core_top.sv`
- `savestate_supported = 1`, `savestate_addr = 0x50000000`,
  `savestate_size = savestate_maxloadsize = 0x22590`.
- Added `ss_data_unloader` (`ADDRESS_MASK_UPPER_4=5`, `ADDRESS_SIZE=18`,
  `INPUT_WORD_SIZE=1`, `READ_MEM_CLOCK_DELAY=1`).
- Added `ss_data_loader` (`ADDRESS_MASK_UPPER_4=5`, `ADDRESS_SIZE=18`,
  `OUTPUT_WORD_SIZE=1`, `WRITE_MEM_CLOCK_DELAY=4`).
- CDC synchronisers for `savestate_start`/`load` (74a→sys) and all
  ack/busy/ok/err signals (sys→74a).
- `savestate_ctrl` instantiated and wired to all system SS ports.
- `PAUSE_EN` updated: `(cs_menu_pause_enable & osnotify_inmenu_s) | ss_halt`.

---

## Design decisions and trade-offs

### No BRAM buffer
The Cyclone V 5CEBA4 in the Analogue Pocket has ~384 KB of M10K block RAM.
Most is already consumed by WRAM (64 KB), VRAM (64 KB), and Z80 RAM (8 KB).
A 141 KB intermediate buffer would require ~113 M10K blocks and leave too
few for other use.  Instead, `savestate_ctrl` acts as a streaming virtual
memory; reads and writes go directly to the peripheral BRAMs.

### CRAM/VSRAM shadow copies
VDP rendering continues even while CPUs are paused.  The rendering
processes have priority over port A of the CRAM/VSRAM DualPortRAMs.
Shadow arrays (`CRAM_SHADOW`, `VSRAM0_SHADOW`, `VSRAM1_SHADOW`) in
`vdp.vhd` track every port-A write so the save path can read them safely
via the `SS_CRAM_RD_*` / `SS_VSRAM_RD_*` ports.

### YM2612 pipeline state not captured
`jt12` exposes a shadow register file that matches what the host wrote, but
internal pipeline state (envelope generators, phase accumulators, operator
outputs) is not captured.  Audio will resume from silence for in-flight
notes when a state is loaded.  This is the same limitation as MiSTer's
Genesis core.

### VDP DMA drain
Before reading VRAM, `savestate_ctrl` waits for `SS_VBUS_SEL` (the VDP DMA
active flag) to deassert and then counts 128 additional quiet cycles.  This
ensures VRAM is not read mid-DMA.  The 68K and Z80 clocks are paused by
`ss_halt` → `PAUSE_EN` before the drain starts.

---

## Build instructions

Build as normal with Quartus.  Ensure all four modified RTL files
(`fx68k.sv`, `T80s.vhd`, `vdp.vhd`, `system.sv`) and the new
`savestate_ctrl.sv` are included in the Quartus project file.  The
`savestate_ctrl` module has no extra IP dependencies.
