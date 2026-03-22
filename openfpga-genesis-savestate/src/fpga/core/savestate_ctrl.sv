// savestate_ctrl.sv
// Genesis save-state controller for Analogue Pocket openFPGA
//
// Savestate binary layout (byte addresses, all in clk_sys domain):
//   0x00000  16B   Header: "APFGN001" (8B) + version u32 (4B) + total_size u32 (4B)
//   0x00010  64KB  WRAM  (68K main RAM, 16-bit port B)
//   0x10010  64KB  VRAM  (32-bit port B, 4 bytes per VRAM word)
//   0x20010  8KB   Z80 RAM  (8-bit port B)
//   0x22010  256B  68K CPU state  (ss_m68k_state[623:0], padded)
//   0x22110  64B   Z80 CPU state  (ss_z80_reg[211:0], padded)
//   0x22150  512B  VDP state:
//               [+0x00..+0x1F] REG[0..31]        32B
//               [+0x20..+0x23] ADDR/CODE/PENDING  4B
//               [+0x24..+0x25] STATUS             2B
//               [+0x26..+0x27] padding            2B
//               [+0x28..+0xA7] CRAM[0..63] × 2B  128B  (9-bit val in 16-bit word)
//               [+0xA8..+0xE7] VSRAM0[0..31] × 2B 64B  (11-bit val in 16-bit word)
//               [+0xE8..+0x127] VSRAM1[0..31] × 2B 64B
//               [+0x128..+0x1FF] padding
//   0x22350  512B  YM2612 (jt12) shadow reg file, 1B/addr, 512 addrs
//   0x22550  64B   PSG (jt89) state: ss_psg_state[63:0] (8B), padded
//   --------
//   TOTAL = 0x22590 bytes
//
// ALM-optimized version:
//   - Shift-register accumulation instead of byte-indexed barrel shifters
//   - Registered region enum instead of 26+ comparators
//   - Single offset calculation per path

`default_nettype none

module savestate_ctrl #(
    parameter SS_SIZE = 18'h22590   // total savestate bytes
)(
    input  wire        clk,
    input  wire        reset,

    // APF savestate commands (synchronised to clk by caller)
    input  wire        save_start,
    input  wire        load_start,
    output reg         save_ack    = 0,
    output reg         save_busy   = 0,
    output reg         save_ok     = 0,
    output reg         save_err    = 0,
    output reg         load_ack    = 0,
    output reg         load_busy   = 0,
    output reg         load_ok     = 0,
    output reg         load_err    = 0,

    // DMA activity (wait before freezing VRAM)
    input  wire        vbus_sel,

    // System halt (OR into PAUSE_EN in core_top)
    output reg         ss_halt     = 0,

    // Data-unloader virtual memory interface (SAVE read path)
    // data_unloader drives read_en / read_addr; we supply read_data
    // INPUT_WORD_SIZE=1 (byte), READ_MEM_CLOCK_DELAY=1
    input  wire        ssr_en,
    input  wire [17:0] ssr_addr,
    output reg   [7:0] ssr_data    = 0,

    // Data-loader write interface (LOAD write path)
    // data_loader drives write_en / write_addr / write_data
    input  wire        ssw_en,
    input  wire [17:0] ssw_addr,
    input  wire  [7:0] ssw_data,

    // WRAM (68K main RAM) port B
    output reg  [14:0] ss_wram_addr,
    output reg         ss_wram_we_u,
    output reg         ss_wram_we_l,
    output reg  [15:0] ss_wram_di,
    input  wire [15:0] ss_wram_do,

    // VRAM port B (32-bit)
    output reg  [13:0] ss_vram_addr,
    output reg         ss_vram_we,
    output reg  [31:0] ss_vram_di,
    input  wire [31:0] ss_vram_do,

    // Z80 RAM port B (8-bit)
    output reg  [12:0] ss_z80ram_addr,
    output reg         ss_z80ram_we,
    output reg   [7:0] ss_z80ram_di,
    input  wire  [7:0] ss_z80ram_do,

    // PSG (jt89) state
    input  wire [63:0] ss_psg_state,
    output reg  [63:0] ss_psg_state_in = 0,
    output reg         ss_psg_load     = 0,

    // FM (jt12) shadow register file
    output reg   [8:0] ss_fm_rd_addr   = 0,
    input  wire  [7:0] ss_fm_rd_data,
    output reg         ss_fm_wr_en     = 0,
    output reg   [8:0] ss_fm_wr_addr   = 0,
    output reg   [7:0] ss_fm_wr_din    = 0,

    // 68K CPU (fx68k) state
    input  wire [623:0] ss_m68k_state,
    output reg  [623:0] ss_m68k_state_in = 0,
    output reg          ss_m68k_load     = 0,

    // Z80 CPU (T80s) state
    input  wire [211:0] ss_z80_reg,
    output reg          ss_z80_dirset   = 0,
    output reg  [211:0] ss_z80_dir      = 0,

    // VDP state
    input  wire [255:0] ss_vdp_reg,
    input  wire  [31:0] ss_vdp_state,
    input  wire  [15:0] ss_vdp_status,
    output reg          ss_vdp_reg_load    = 0,
    output reg  [255:0] ss_vdp_reg_in      = 0,
    output reg   [31:0] ss_vdp_state_in    = 0,
    output reg          ss_vdp_cram_wr_en  = 0,
    output reg   [5:0]  ss_vdp_cram_wr_addr= 0,
    output reg   [8:0]  ss_vdp_cram_wr_data= 0,
    output reg   [5:0]  ss_vdp_cram_rd_addr= 0,
    input  wire  [8:0]  ss_vdp_cram_rd_data,
    output reg          ss_vdp_vsram_wr_en  = 0,
    output reg   [5:0]  ss_vdp_vsram_wr_addr= 0,
    output reg  [10:0]  ss_vdp_vsram_wr_data= 0,
    output reg   [5:0]  ss_vdp_vsram_rd_addr= 0,
    input  wire [10:0]  ss_vdp_vsram_rd_data
);

// -----------------------------------------------------------------------
// Address constants (byte offsets within savestate binary)
// -----------------------------------------------------------------------
localparam [17:0] HEADER_BASE = 18'h00000;
localparam [17:0] WRAM_BASE   = 18'h00010;
localparam [17:0] VRAM_BASE   = 18'h10010;
localparam [17:0] Z80RAM_BASE = 18'h20010;
localparam [17:0] M68K_BASE   = 18'h22010;
localparam [17:0] Z80REG_BASE = 18'h22110;
localparam [17:0] VDP_BASE    = 18'h22150;
localparam [17:0] FM_BASE     = 18'h22350;
localparam [17:0] PSG_BASE    = 18'h22550;
// VDP sub-regions (absolute offsets)
localparam [17:0] VDP_CRAM_BASE   = VDP_BASE + 18'h28;
localparam [17:0] VDP_VSRAM0_BASE = VDP_BASE + 18'hA8;
localparam [17:0] VDP_VSRAM1_BASE = VDP_BASE + 18'hE8;

// Header magic "APFGN001" = bytes 0x41 0x50 0x46 0x47 0x4E 0x30 0x30 0x31
localparam [63:0] HEADER_MAGIC = 64'h4150_4647_4E30_3031;  // "APFGN001" little-endian: A P F G N 0 0 1

// Savestate format version
localparam [31:0] SS_VERSION   = 32'h0000_0001;

// -----------------------------------------------------------------------
// FSM state encoding
// -----------------------------------------------------------------------
localparam [3:0]
    ST_IDLE       = 4'd0,
    ST_SAVE_ACK   = 4'd1,   // pulse save_ack; start halt
    ST_SAVE_DRAIN = 4'd2,   // wait for DMA to finish (up to 128 cycles)
    ST_SAVE_RUN   = 4'd3,   // serve data_unloader reads
    ST_SAVE_DONE  = 4'd4,   // assert save_ok
    ST_LOAD_ACK   = 4'd5,   // pulse load_ack; start halt
    ST_LOAD_RUN   = 4'd6,   // receive data_loader writes
    ST_LOAD_APPLY = 4'd7,   // apply accumulated register state
    ST_LOAD_DONE  = 4'd8;   // assert load_ok

reg [3:0] state = ST_IDLE;

// Drain counter (wait for DMA to quiesce)
reg [6:0] drain_cnt = 0;

// Track whether final byte has been seen during SAVE
wire save_last = ssr_en && (ssr_addr == SS_SIZE - 1);

// -----------------------------------------------------------------------
// Optimization 2: Registered region enum (replaces 26+ comparators)
// -----------------------------------------------------------------------
// Region codes for SAVE read path
localparam [3:0]
    RGN_HEADER   = 4'd0,
    RGN_WRAM     = 4'd1,
    RGN_VRAM     = 4'd2,
    RGN_Z80RAM   = 4'd3,
    RGN_M68K     = 4'd4,
    RGN_Z80REG   = 4'd5,
    RGN_VDPREG   = 4'd6,
    RGN_VDPST    = 4'd7,
    RGN_CRAM     = 4'd8,
    RGN_VSRAM0   = 4'd9,
    RGN_VSRAM1   = 4'd10,
    RGN_FM       = 4'd11,
    RGN_PSG      = 4'd12,
    RGN_PAD      = 4'd13;

// Classify an 18-bit address into a region code.
// Uses comparisons against region boundaries (priority-encoded).
// Quartus synthesizes this as a compact priority encoder.
// The three large regions (WRAM/VRAM/Z80RAM) use the base addresses
// directly; the small 0x22xxx regions use a cascaded if-else chain
// that only activates when addr[17:13] matches.
function [3:0] addr_to_region;
    input [17:0] a;
    begin
        addr_to_region = RGN_PAD;  // default
        if (a < WRAM_BASE)               // 0x00000..0x0000F
            addr_to_region = RGN_HEADER;
        else if (a < VRAM_BASE)           // 0x00010..0x1000F (64KB WRAM)
            addr_to_region = RGN_WRAM;
        else if (a < Z80RAM_BASE)         // 0x10010..0x2000F (64KB VRAM)
            addr_to_region = RGN_VRAM;
        else if (a < M68K_BASE)           // 0x20010..0x2200F (8KB Z80RAM)
            addr_to_region = RGN_Z80RAM;
        else if (a < Z80REG_BASE)         // 0x22010..0x2210F (M68K)
            addr_to_region = RGN_M68K;
        else if (a < VDP_BASE)            // 0x22110..0x2214F (Z80REG)
            addr_to_region = RGN_Z80REG;
        else if (a < VDP_CRAM_BASE) begin // 0x22150..0x22177
            // VDP sub-regions: VDP_BASE=0x22150, bit[5] distinguishes
            // +0x00..+0x1F (REG) vs +0x20..+0x27 (STATE)
            if (!a[5])
                addr_to_region = RGN_VDPREG;
            else
                addr_to_region = RGN_VDPST;
        end
        else if (a < VDP_VSRAM0_BASE)     // CRAM: 0x22178..0x221F7
            addr_to_region = RGN_CRAM;
        else if (a < VDP_VSRAM1_BASE)     // VSRAM0: 0x221F8..0x22237
            addr_to_region = RGN_VSRAM0;
        else if (a < VDP_VSRAM1_BASE + 18'h40)  // VSRAM1: 0x22238..0x22277
            addr_to_region = RGN_VSRAM1;
        else if (a >= FM_BASE && a < PSG_BASE)  // FM: 0x22350..0x2254F
            addr_to_region = RGN_FM;
        else if (a < PSG_BASE + 18'h8)    // PSG: 0x22550..0x22557
            addr_to_region = RGN_PSG;
    end
endfunction

// Registered region for SAVE read-data mux (registered one cycle after ssr_en)
reg [3:0] ssr_region_r = RGN_PAD;
reg [17:0] ssr_addr_r = 0;

always @(posedge clk) begin
    if (ssr_en) begin
        ssr_addr_r  <= ssr_addr;
        ssr_region_r <= addr_to_region(ssr_addr);
    end
end

// Combinatorial region for SAVE address routing (drives BRAM address one cycle ahead)
wire [3:0] ssr_region_c = addr_to_region(ssr_addr);

// Combinatorial region for LOAD write path
wire [3:0] ssw_region_c = addr_to_region(ssw_addr);

// -----------------------------------------------------------------------
// Optimization 3: Simplified offset calculations
// -----------------------------------------------------------------------
// For SAVE read path: offset within region (combinatorial, drives BRAM addr)
// WRAM: starts at 0x00010, so offset = addr - 0x10.
//       addr[17:16]==00, so addr[15:0] - 4'h10 works. But since WRAM_BASE is
//       only 0x10, we can use addr[15:0] directly shifted right (the -0x10
//       only matters for the first word, which is fine for 15-bit word addr).
//       More precisely: (addr - 16'h0010) >> 1
// VRAM: starts at 0x10010, offset = addr[15:0] - 16'h0010, word addr = offset >> 2
// Z80RAM: starts at 0x20010, offset = addr[12:0] - 13'h0010
// FM: starts at 0x22350, offset = addr - FM_BASE (only 9 bits needed)

// Pre-compute a small subtraction for the 0x10 base offset shared by WRAM/VRAM/Z80RAM
wire [15:0] ssr_addr_lo_m10 = ssr_addr[15:0] - 16'h0010;
wire [15:0] ssw_addr_lo_m10 = ssw_addr[15:0] - 16'h0010;

// For regions in the 0x22xxx range, compute offset from region base
// We only need low bits. FM needs 9 bits, CRAM/VSRAM need 7 bits.
// All bases in this range share addr[17:12] = 6'b10_0010 = 0x22xxx
wire [11:0] ssr_addr_lo12 = ssr_addr[11:0];
wire [11:0] ssw_addr_lo12 = ssw_addr[11:0];

// FM offset: addr - 0x22350 = addr[11:0] - 12'h350
wire [8:0] ssr_fm_off = ssr_addr_lo12 - 12'h350;
wire [8:0] ssw_fm_off = ssw_addr_lo12 - 12'h350;

// M68K offset: addr - 0x22010 = addr[11:0] - 12'h010
wire [7:0] ssw_m68k_off = ssw_addr_lo12 - 12'h010;

// Z80REG offset: addr - 0x22110 = addr[11:0] - 12'h110
wire [5:0] ssw_z80reg_off = ssw_addr_lo12 - 12'h110;

// VDP offset: addr - 0x22150 = addr[11:0] - 12'h150
wire [8:0] ssr_vdp_off = ssr_addr_lo12 - 12'h150;
wire [8:0] ssw_vdp_off = ssw_addr_lo12 - 12'h150;

// CRAM offset within CRAM region: vdp_off - 0x28
wire [6:0] ssw_cram_off = ssw_vdp_off - 9'h28;
// VSRAM0 offset: vdp_off - 0xA8
wire [6:0] ssw_vsram0_off = ssw_vdp_off - 9'hA8;
// VSRAM1 offset: vdp_off - 0xE8
wire [6:0] ssw_vsram1_off = ssw_vdp_off - 9'hE8;

// PSG offset: addr - 0x22550 = addr[11:0] - 12'h550
wire [2:0] ssw_psg_off = ssw_addr_lo12 - 12'h550;

// -----------------------------------------------------------------------
// FSM
// -----------------------------------------------------------------------
// LOAD_APPLY sub-state
localparam [4:0]
    APPLY_M68K  = 5'd0,
    APPLY_Z80   = 5'd1,
    APPLY_PSG   = 5'd2,
    APPLY_VDP   = 5'd3,
    APPLY_DONE  = 5'd4;
reg [4:0] apply_state = APPLY_M68K;

// -----------------------------------------------------------------------
// Optimization 1: Shift register accumulation buffers
// -----------------------------------------------------------------------
// data_loader streams bytes in ascending address order.
// Instead of byte-indexed writes (creating barrel shifters), we use shift
// registers. Each new byte shifts into the LSB (or MSB depending on
// convention). Since addresses ascend and byte 0 maps to bits [7:0],
// byte 1 to [15:8], etc., we shift new data in at the top:
//   sr <= {ssw_data, sr[N-1:8]}
// After all bytes are received, sr contains the correct value.

reg [623:0] load_m68k_sr    = 0;   // 78 bytes (624 bits), addresses 0..77
reg [215:0] load_z80_sr     = 0;   // 27 bytes (216 bits); only [211:0] used at apply
reg  [63:0] load_psg_sr     = 0;   // 8 bytes
reg [255:0] load_vdp_reg_sr = 0;   // 32 bytes
reg  [31:0] load_vdp_state_sr = 0; // 4 bytes

// Byte assembly for CRAM/VSRAM (kept as-is, already efficient)
reg   [7:0] load_cram_lo_buf  = 0;
reg   [7:0] load_vsram_lo_buf = 0;

always @(posedge clk) begin
    // Default pulse signals
    save_ack         <= 0;
    load_ack         <= 0;
    ss_psg_load      <= 0;
    ss_m68k_load     <= 0;
    ss_z80_dirset    <= 0;
    ss_vdp_reg_load  <= 0;
    ss_vdp_cram_wr_en  <= 0;
    ss_vdp_vsram_wr_en <= 0;
    ss_fm_wr_en      <= 0;

    if (reset) begin
        state      <= ST_IDLE;
        ss_halt    <= 0;
        save_busy  <= 0;
        save_ok    <= 0;
        save_err   <= 0;
        load_busy  <= 0;
        load_ok    <= 0;
        load_err   <= 0;
    end else begin
        case (state)
        // ----------------------------------------------------------------
        ST_IDLE: begin
            if (save_start && !save_busy && !load_busy) begin
                save_ok    <= 0;
                save_err   <= 0;
                state      <= ST_SAVE_ACK;
            end else if (load_start && !save_busy && !load_busy) begin
                load_ok    <= 0;
                load_err   <= 0;
                state      <= ST_LOAD_ACK;
            end
        end

        // ----------------------------------------------------------------
        ST_SAVE_ACK: begin
            save_ack   <= 1;
            save_busy  <= 1;
            ss_halt    <= 1;
            drain_cnt  <= 0;
            state      <= ST_SAVE_DRAIN;
        end

        // ----------------------------------------------------------------
        ST_SAVE_DRAIN: begin
            // Wait until VDP DMA is done and count extra safety cycles
            if (!vbus_sel) begin
                drain_cnt <= drain_cnt + 1;
                if (&drain_cnt) begin   // 128 cycles of quiet
                    state <= ST_SAVE_RUN;
                end
            end else begin
                drain_cnt <= 0;         // reset counter if DMA still active
            end
        end

        // ----------------------------------------------------------------
        ST_SAVE_RUN: begin
            // Served by read data mux below (combinatorial path for ssr_data).
            // Transition to DONE when final byte has been requested.
            if (save_last) begin
                state <= ST_SAVE_DONE;
            end
        end

        // ----------------------------------------------------------------
        ST_SAVE_DONE: begin
            ss_halt   <= 0;
            save_busy <= 0;
            save_ok   <= 1;
            state     <= ST_IDLE;
        end

        // ----------------------------------------------------------------
        ST_LOAD_ACK: begin
            load_ack   <= 1;
            load_busy  <= 1;
            ss_halt    <= 1;
            apply_state <= APPLY_M68K;
            state      <= ST_LOAD_RUN;
        end

        // ----------------------------------------------------------------
        ST_LOAD_RUN: begin
            if (ssw_en) begin
                // Detect end of savestate
                if (ssw_addr == SS_SIZE - 1)
                    state <= ST_LOAD_APPLY;

                case (ssw_region_c)
                // --- Shift-register accumulation for M68K ---
                RGN_M68K: begin
                    if (ssw_m68k_off < 8'd78)  // 78 bytes = 624 bits
                        load_m68k_sr <= {ssw_data, load_m68k_sr[623:8]};
                end

                // --- Shift-register accumulation for Z80 ---
                RGN_Z80REG: begin
                    if (ssw_z80reg_off < 6'd27)  // 27 bytes → 216 bits
                        load_z80_sr <= {ssw_data, load_z80_sr[215:8]};
                end

                // --- Shift-register accumulation for PSG ---
                RGN_PSG: begin
                    load_psg_sr <= {ssw_data, load_psg_sr[63:8]};
                end

                // --- Shift-register for VDP REG ---
                RGN_VDPREG: begin
                    load_vdp_reg_sr <= {ssw_data, load_vdp_reg_sr[255:8]};
                end

                // --- Shift-register for VDP STATE ---
                RGN_VDPST: begin
                    if (ssw_vdp_off[2:0] < 3'd4)
                        load_vdp_state_sr <= {ssw_data, load_vdp_state_sr[31:8]};
                end

                // --- CRAM inline write (2-byte assembly per entry) ---
                RGN_CRAM: begin
                    if (!ssw_addr[0]) begin
                        load_cram_lo_buf <= ssw_data;
                    end else begin
                        ss_vdp_cram_wr_en   <= 1;
                        ss_vdp_cram_wr_addr <= ssw_cram_off[6:1];
                        ss_vdp_cram_wr_data <= {ssw_data[0], load_cram_lo_buf};
                    end
                end

                // --- VSRAM0 inline write ---
                RGN_VSRAM0: begin
                    if (!ssw_addr[0]) begin
                        load_vsram_lo_buf <= ssw_data;
                    end else begin
                        ss_vdp_vsram_wr_en   <= 1;
                        ss_vdp_vsram_wr_addr <= {1'b0, ssw_vsram0_off[5:1]};
                        ss_vdp_vsram_wr_data <= {ssw_data[2:0], load_vsram_lo_buf};
                    end
                end

                // --- VSRAM1 inline write ---
                RGN_VSRAM1: begin
                    if (!ssw_addr[0]) begin
                        load_vsram_lo_buf <= ssw_data;
                    end else begin
                        ss_vdp_vsram_wr_en   <= 1;
                        ss_vdp_vsram_wr_addr <= {1'b1, ssw_vsram1_off[5:1]};
                        ss_vdp_vsram_wr_data <= {ssw_data[2:0], load_vsram_lo_buf};
                    end
                end

                // --- FM inline write ---
                RGN_FM: begin
                    ss_fm_wr_en   <= 1;
                    ss_fm_wr_addr <= ssw_fm_off;
                    ss_fm_wr_din  <= ssw_data;
                end

                default: ;  // WRAM/VRAM/Z80RAM handled in combinatorial block below
                endcase
            end
        end

        // ----------------------------------------------------------------
        ST_LOAD_APPLY: begin
            // Apply accumulated register state in one sequence
            case (apply_state)
            APPLY_M68K: begin
                ss_m68k_state_in <= load_m68k_sr;
                ss_m68k_load     <= 1;
                apply_state      <= APPLY_Z80;
            end
            APPLY_Z80: begin
                ss_z80_dir     <= load_z80_sr[211:0];
                ss_z80_dirset  <= 1;
                apply_state    <= APPLY_PSG;
            end
            APPLY_PSG: begin
                ss_psg_state_in <= load_psg_sr;
                ss_psg_load     <= 1;
                apply_state     <= APPLY_VDP;
            end
            APPLY_VDP: begin
                ss_vdp_reg_in    <= load_vdp_reg_sr;
                ss_vdp_state_in  <= load_vdp_state_sr;
                ss_vdp_reg_load  <= 1;
                apply_state      <= APPLY_DONE;
            end
            APPLY_DONE: begin
                state <= ST_LOAD_DONE;
            end
            endcase
        end

        // ----------------------------------------------------------------
        ST_LOAD_DONE: begin
            ss_halt    <= 0;
            load_busy  <= 0;
            load_ok    <= 1;
            state      <= ST_IDLE;
        end
        endcase
    end
end

// -----------------------------------------------------------------------
// SAVE: memory address routing (combinatorial, drives BRAM port B addr)
// Uses registered region enum instead of multiple comparators
// -----------------------------------------------------------------------
always @(*) begin
    ss_fm_rd_addr = (ssr_region_c == RGN_FM) ? ssr_fm_off : 9'h0;
end

// VDP CRAM/VSRAM read address for SAVE
wire [6:0] ssr_cram_off   = ssr_vdp_off - 9'h28;
wire [6:0] ssr_vsram0_off = ssr_vdp_off - 9'hA8;
wire [6:0] ssr_vsram1_off = ssr_vdp_off - 9'hE8;

always @(*) begin
    ss_vdp_cram_rd_addr  = (ssr_region_c == RGN_CRAM)   ? ssr_cram_off[6:1]         : 6'h0;
    ss_vdp_vsram_rd_addr = (ssr_region_c == RGN_VSRAM0)  ? {1'b0, ssr_vsram0_off[5:1]} :
                           (ssr_region_c == RGN_VSRAM1)  ? {1'b1, ssr_vsram1_off[5:1]} :
                                                           6'h0;
end

// -----------------------------------------------------------------------
// SAVE: read data mux — uses REGISTERED region enum (ssr_region_r)
// -----------------------------------------------------------------------

// Build header bytes (offset 0..15)
wire [7:0] header_byte =
    (ssr_addr_r[3:0] == 4'h0) ? 8'h41 :   // 'A'
    (ssr_addr_r[3:0] == 4'h1) ? 8'h50 :   // 'P'
    (ssr_addr_r[3:0] == 4'h2) ? 8'h46 :   // 'F'
    (ssr_addr_r[3:0] == 4'h3) ? 8'h47 :   // 'G'
    (ssr_addr_r[3:0] == 4'h4) ? 8'h4E :   // 'N'
    (ssr_addr_r[3:0] == 4'h5) ? 8'h30 :   // '0'
    (ssr_addr_r[3:0] == 4'h6) ? 8'h30 :   // '0'
    (ssr_addr_r[3:0] == 4'h7) ? 8'h31 :   // '1'
    (ssr_addr_r[3:0] == 4'h8) ? SS_VERSION[7:0]   :
    (ssr_addr_r[3:0] == 4'h9) ? SS_VERSION[15:8]  :
    (ssr_addr_r[3:0] == 4'hA) ? SS_VERSION[23:16] :
    (ssr_addr_r[3:0] == 4'hB) ? SS_VERSION[31:24] :
    (ssr_addr_r[3:0] == 4'hC) ? SS_SIZE[7:0]      :
    (ssr_addr_r[3:0] == 4'hD) ? SS_SIZE[15:8]     :
    (ssr_addr_r[3:0] == 4'hE) ? {6'b0, SS_SIZE[17:16]} :
    8'h00;

// Helper: select byte from ss_vram_do based on addr[1:0]
wire [7:0] vram_byte =
    (ssr_addr_r[1:0] == 2'b00) ? ss_vram_do[7:0]   :
    (ssr_addr_r[1:0] == 2'b01) ? ss_vram_do[15:8]  :
    (ssr_addr_r[1:0] == 2'b10) ? ss_vram_do[23:16] :
                                  ss_vram_do[31:24];

// CRAM: 9-bit stored as 16-bit. Even byte = bits[7:0], odd byte = {7'b0, bit[8]}
wire [7:0] cram_byte =
    ssr_addr_r[0] ? {7'b0, ss_vdp_cram_rd_data[8]} : ss_vdp_cram_rd_data[7:0];

// VSRAM: 11-bit stored as 16-bit. Even byte = bits[7:0], odd byte = {5'b0, bits[10:8]}
wire [7:0] vsram_byte =
    ssr_addr_r[0] ? {5'b0, ss_vdp_vsram_rd_data[10:8]} : ss_vdp_vsram_rd_data[7:0];

// For SAVE read of M68K/Z80/PSG/VDP_REG/VDP_STATE: use registered offsets
// to select byte from the live state vectors.
// Compute offsets from the low 12 bits of ssr_addr_r (all these regions
// share addr[17:12] = 0x22x).
wire [11:0] rr_lo12        = ssr_addr_r[11:0];
wire [6:0]  rr_m68k_off    = rr_lo12 - 12'h010;  // M68K_BASE low12 = 0x010
wire [5:0]  rr_z80reg_off  = rr_lo12 - 12'h110;  // Z80REG_BASE low12 = 0x110
wire [8:0]  rr_vdp_off     = rr_lo12 - 12'h150;  // VDP_BASE low12 = 0x150

// M68K state byte select: offset 0..77 → select from 624-bit vector
// This is still a large mux, but it's read-only (no write barrel shifter)
// and only active during SAVE, so it's acceptable.
reg [7:0] m68k_save_byte;
always @(*) begin
    m68k_save_byte = 8'h00;
    if (rr_m68k_off < 7'd78)
        m68k_save_byte = ss_m68k_state[rr_m68k_off[6:0]*8 +: 8];
end

// Z80 reg byte select: offset 0..26 (27 bytes = 212 bits, last byte partial)
reg [7:0] z80reg_save_byte;
always @(*) begin
    z80reg_save_byte = 8'h00;
    if (rr_z80reg_off < 6'd27)
        z80reg_save_byte = ss_z80_reg[rr_z80reg_off[4:0]*8 +: 8];
    else if (rr_z80reg_off == 6'd27)
        z80reg_save_byte = {4'b0, ss_z80_reg[211:208]};
end

// VDP reg byte select: offset 0..31
wire [7:0] vdpreg_save_byte = ss_vdp_reg[rr_vdp_off[4:0]*8 +: 8];

// VDP state byte select: offset 0..7 (state + status + padding)
reg [7:0] vdpst_save_byte;
always @(*) begin
    vdpst_save_byte = 8'h00;
    case (ssr_addr_r[2:0])
        3'd0: vdpst_save_byte = ss_vdp_state[7:0];
        3'd1: vdpst_save_byte = ss_vdp_state[15:8];
        3'd2: vdpst_save_byte = ss_vdp_state[23:16];
        3'd3: vdpst_save_byte = ss_vdp_state[31:24];
        3'd4: vdpst_save_byte = ss_vdp_status[7:0];
        3'd5: vdpst_save_byte = ss_vdp_status[15:8];
        default: vdpst_save_byte = 8'h00;
    endcase
end

// PSG byte select: offset 0..7 (PSG_BASE low 12 = 0x550)
wire [2:0] rr_psg_off = rr_lo12 - 12'h550;
wire [7:0] psg_save_byte = ss_psg_state[rr_psg_off*8 +: 8];

// Main SAVE read data mux — single case on registered region enum
always @(*) begin
    ssr_data = 8'h00;
    case (ssr_region_r)
        RGN_HEADER: ssr_data = header_byte;
        RGN_WRAM:   ssr_data = ssr_addr_r[0] ? ss_wram_do[15:8] : ss_wram_do[7:0];
        RGN_VRAM:   ssr_data = vram_byte;
        RGN_Z80RAM: ssr_data = ss_z80ram_do;
        RGN_M68K:   ssr_data = m68k_save_byte;
        RGN_Z80REG: ssr_data = z80reg_save_byte;
        RGN_VDPREG: ssr_data = vdpreg_save_byte;
        RGN_VDPST:  ssr_data = vdpst_save_byte;
        RGN_CRAM:   ssr_data = cram_byte;
        RGN_VSRAM0: ssr_data = vsram_byte;
        RGN_VSRAM1: ssr_data = vsram_byte;
        RGN_FM:     ssr_data = ss_fm_rd_data;
        RGN_PSG:    ssr_data = psg_save_byte;
        default:    ssr_data = 8'h00;
    endcase
end

// -----------------------------------------------------------------------
// LOAD: memory write path (combinatorial, gated by ssw_en)
// -----------------------------------------------------------------------
wire ssw_in_wram   = ssw_en && (ssw_region_c == RGN_WRAM);
wire ssw_in_vram   = ssw_en && (ssw_region_c == RGN_VRAM);
wire ssw_in_z80ram = ssw_en && (ssw_region_c == RGN_Z80RAM);

// VRAM accumulation buffer: VRAM port B is 32-bit with a single wren_b for all
// byte lanes, so we must assemble 4 bytes before committing a write.
reg [23:0] vram_load_buf = 0;
always @(posedge clk) begin
    if (ssw_in_vram) begin
        case (ssw_addr[1:0])
        2'b00: vram_load_buf[7:0]   <= ssw_data;
        2'b01: vram_load_buf[15:8]  <= ssw_data;
        2'b10: vram_load_buf[23:16] <= ssw_data;
        default: ; // byte 3 assembles the full word combinatorially below
        endcase
    end
end

// Combined SAVE/LOAD memory port B routing (combinatorial)
always @(*) begin
    // WRAM port B
    if (ssw_in_wram) begin
        ss_wram_addr = ssw_addr_lo_m10[15:1];
        ss_wram_we_u = ssw_addr[0];
        ss_wram_we_l = ~ssw_addr[0];
        ss_wram_di   = {ssw_data, ssw_data};
    end else begin
        ss_wram_addr = (ssr_region_c == RGN_WRAM) ? ssr_addr_lo_m10[15:1] : 15'h0;
        ss_wram_we_u = 1'b0;
        ss_wram_we_l = 1'b0;
        ss_wram_di   = 16'h0;
    end

    // VRAM port B (32-bit, single wren_b)
    if (ssw_in_vram) begin
        ss_vram_addr = ssw_addr_lo_m10[15:2];
        ss_vram_we   = (ssw_addr[1:0] == 2'b11);
        ss_vram_di   = {ssw_data, vram_load_buf};
    end else begin
        ss_vram_addr = (ssr_region_c == RGN_VRAM) ? ssr_addr_lo_m10[15:2] : 14'h0;
        ss_vram_we   = 1'b0;
        ss_vram_di   = 32'h0;
    end

    // Z80 RAM port B (8-bit)
    if (ssw_in_z80ram) begin
        ss_z80ram_addr = ssw_addr_lo_m10[12:0];
        ss_z80ram_we   = 1'b1;
        ss_z80ram_di   = ssw_data;
    end else begin
        ss_z80ram_addr = (ssr_region_c == RGN_Z80RAM) ? ssr_addr_lo_m10[12:0] : 13'h0;
        ss_z80ram_we   = 1'b0;
        ss_z80ram_di   = 8'h0;
    end
end

// -----------------------------------------------------------------------
endmodule
`default_nettype wire
