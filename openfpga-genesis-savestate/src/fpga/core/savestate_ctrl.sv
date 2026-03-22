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

// Accumulated load buffers
reg [623:0] load_m68k_buf  = 0;
reg [211:0] load_z80_buf   = 0;
reg  [63:0] load_psg_buf   = 0;
reg [255:0] load_vdp_reg_buf = 0;
reg  [31:0] load_vdp_state_buf = 0;
reg   [7:0] load_cram_lo_buf = 0;   // low byte of current CRAM entry
reg   [7:0] load_vsram_lo_buf = 0;  // low byte of current VSRAM entry

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
            // All writes handled combinatorially below.
            // Accumulate register buffers; detect end of load.
            if (ssw_en) begin
                // Detect end of savestate: last byte is PSG padding at SS_SIZE-1
                if (ssw_addr == SS_SIZE - 1)
                    state <= ST_LOAD_APPLY;

                // --- Accumulate M68K buffer ---
                if (ssw_addr >= M68K_BASE && ssw_addr < M68K_BASE + 18'h4E)
                    load_m68k_buf[(ssw_addr - M68K_BASE)*8 +: 8] <= ssw_data;

                // --- Accumulate Z80 buffer ---
                if (ssw_addr >= Z80REG_BASE && ssw_addr < Z80REG_BASE + 18'h1B)
                    load_z80_buf[(ssw_addr - Z80REG_BASE)*8 +: 8] <= ssw_data;

                // --- Accumulate PSG buffer ---
                if (ssw_addr >= PSG_BASE && ssw_addr < PSG_BASE + 18'h8)
                    load_psg_buf[(ssw_addr - PSG_BASE)*8 +: 8] <= ssw_data;

                // --- Accumulate VDP REG buffer ---
                if (ssw_addr >= VDP_BASE && ssw_addr < VDP_BASE + 18'h20)
                    load_vdp_reg_buf[(ssw_addr - VDP_BASE)*8 +: 8] <= ssw_data;

                // --- Accumulate VDP STATE buffer ---
                if (ssw_addr >= VDP_BASE + 18'h20 && ssw_addr < VDP_BASE + 18'h24)
                    load_vdp_state_buf[(ssw_addr - VDP_BASE - 18'h20)*8 +: 8] <= ssw_data;

                // --- CRAM inline write (2-byte assembly per entry) ---
                if (ssw_addr >= VDP_CRAM_BASE && ssw_addr < VDP_CRAM_BASE + 18'h80) begin
                    if (!ssw_addr[0]) begin
                        load_cram_lo_buf <= ssw_data;  // store low byte
                    end else begin
                        // Second byte: assemble and write
                        ss_vdp_cram_wr_en   <= 1;
                        ss_vdp_cram_wr_addr <= (ssw_addr - VDP_CRAM_BASE) >> 1;
                        ss_vdp_cram_wr_data <= {ssw_data[0], load_cram_lo_buf};
                    end
                end

                // --- VSRAM0 inline write ---
                if (ssw_addr >= VDP_VSRAM0_BASE && ssw_addr < VDP_VSRAM0_BASE + 18'h40) begin
                    if (!ssw_addr[0]) begin
                        load_vsram_lo_buf <= ssw_data;
                    end else begin
                        ss_vdp_vsram_wr_en   <= 1;
                        ss_vdp_vsram_wr_addr <= {1'b0, (ssw_addr - VDP_VSRAM0_BASE) >> 1};
                        ss_vdp_vsram_wr_data <= {ssw_data[2:0], load_vsram_lo_buf};
                    end
                end

                // --- VSRAM1 inline write ---
                if (ssw_addr >= VDP_VSRAM1_BASE && ssw_addr < VDP_VSRAM1_BASE + 18'h40) begin
                    if (!ssw_addr[0]) begin
                        load_vsram_lo_buf <= ssw_data;
                    end else begin
                        ss_vdp_vsram_wr_en   <= 1;
                        ss_vdp_vsram_wr_addr <= {1'b1, (ssw_addr - VDP_VSRAM1_BASE) >> 1};
                        ss_vdp_vsram_wr_data <= {ssw_data[2:0], load_vsram_lo_buf};
                    end
                end

                // --- FM inline write ---
                if (ssw_addr >= FM_BASE && ssw_addr < FM_BASE + 18'h200) begin
                    ss_fm_wr_en   <= 1;
                    ss_fm_wr_addr <= ssw_addr - FM_BASE;
                    ss_fm_wr_din  <= ssw_data;
                end
            end
        end

        // ----------------------------------------------------------------
        ST_LOAD_APPLY: begin
            // Apply accumulated register state in one sequence
            case (apply_state)
            APPLY_M68K: begin
                ss_m68k_state_in <= load_m68k_buf;
                ss_m68k_load     <= 1;
                apply_state      <= APPLY_Z80;
            end
            APPLY_Z80: begin
                ss_z80_dir     <= load_z80_buf;
                ss_z80_dirset  <= 1;
                apply_state    <= APPLY_PSG;
            end
            APPLY_PSG: begin
                ss_psg_state_in <= load_psg_buf;
                ss_psg_load     <= 1;
                apply_state     <= APPLY_VDP;
            end
            APPLY_VDP: begin
                ss_vdp_reg_in    <= load_vdp_reg_buf;
                ss_vdp_state_in  <= load_vdp_state_buf;
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
// SAVE: memory address combinatorial routing (pre-clock, 1-cycle ahead)
// Driven from ssr_addr (current, before register) so BRAM output is ready
// one cycle later when ssr_data is sampled.
// -----------------------------------------------------------------------
wire        in_wram    = (ssr_addr >= WRAM_BASE)   && (ssr_addr < VRAM_BASE);
wire        in_vram    = (ssr_addr >= VRAM_BASE)   && (ssr_addr < Z80RAM_BASE);
wire        in_z80ram  = (ssr_addr >= Z80RAM_BASE) && (ssr_addr < M68K_BASE);
wire        in_vdpcram = (ssr_addr >= VDP_CRAM_BASE)   && (ssr_addr < VDP_VSRAM0_BASE);
wire        in_vdpvsr0 = (ssr_addr >= VDP_VSRAM0_BASE) && (ssr_addr < VDP_VSRAM1_BASE);
wire        in_vdpvsr1 = (ssr_addr >= VDP_VSRAM1_BASE) && (ssr_addr < VDP_VSRAM1_BASE + 18'h40);
wire        in_fm      = (ssr_addr >= FM_BASE)     && (ssr_addr < PSG_BASE);

// FM: combinatorial read (1-cycle combinatorial output from shadow reg file)
wire [17:0] fm_offset = ssr_addr - FM_BASE;
always @(*) ss_fm_rd_addr = in_fm ? fm_offset[8:0] : 9'h0;

// VDP CRAM/VSRAM read for SAVE
wire [17:0] vsram0_offset = ssr_addr - VDP_VSRAM0_BASE;
wire [17:0] vsram1_offset = ssr_addr - VDP_VSRAM1_BASE;
always @(*) begin
    ss_vdp_cram_rd_addr  = in_vdpcram ? (ssr_addr - VDP_CRAM_BASE) >> 1 : 6'h0;
    ss_vdp_vsram_rd_addr = in_vdpvsr0 ? {1'b0, vsram0_offset[5:1]} :
                           in_vdpvsr1 ? {1'b1, vsram1_offset[5:1]} :
                                        6'h0;
end

// -----------------------------------------------------------------------
// SAVE: read data mux — combinatorial select based on REGISTERED address
// (latched on read_en cycle, valid one cycle later when data_unloader reads)
// -----------------------------------------------------------------------
reg [17:0] ssr_addr_r = 0;
always @(posedge clk) begin
    if (ssr_en) ssr_addr_r <= ssr_addr;
end

// Decode which region the registered address falls in
wire        rr_header  = (ssr_addr_r < WRAM_BASE);
wire        rr_wram    = (ssr_addr_r >= WRAM_BASE)   && (ssr_addr_r < VRAM_BASE);
wire        rr_vram    = (ssr_addr_r >= VRAM_BASE)   && (ssr_addr_r < Z80RAM_BASE);
wire        rr_z80ram  = (ssr_addr_r >= Z80RAM_BASE) && (ssr_addr_r < M68K_BASE);
wire        rr_m68k    = (ssr_addr_r >= M68K_BASE)   && (ssr_addr_r < Z80REG_BASE);
wire        rr_z80reg  = (ssr_addr_r >= Z80REG_BASE) && (ssr_addr_r < VDP_BASE);
wire        rr_vdpreg  = (ssr_addr_r >= VDP_BASE)    && (ssr_addr_r < VDP_BASE + 18'h20);
wire        rr_vdpst   = (ssr_addr_r >= VDP_BASE + 18'h20) && (ssr_addr_r < VDP_BASE + 18'h28);
wire        rr_cram    = (ssr_addr_r >= VDP_CRAM_BASE)   && (ssr_addr_r < VDP_VSRAM0_BASE);
wire        rr_vsr0    = (ssr_addr_r >= VDP_VSRAM0_BASE) && (ssr_addr_r < VDP_VSRAM1_BASE);
wire        rr_vsr1    = (ssr_addr_r >= VDP_VSRAM1_BASE) && (ssr_addr_r < VDP_VSRAM1_BASE + 18'h40);
wire        rr_fm      = (ssr_addr_r >= FM_BASE)     && (ssr_addr_r < PSG_BASE);
wire        rr_psg     = (ssr_addr_r >= PSG_BASE)    && (ssr_addr_r < PSG_BASE + 18'h8);

// Build header bytes (offset 0..15)
// bytes 0-7: magic "APFGN001" = 0x41 0x50 0x46 0x47 0x4E 0x30 0x30 0x31
// bytes 8-11: version = SS_VERSION (little-endian)
// bytes 12-15: total_size = SS_SIZE (little-endian)
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

always @(*) begin
    ssr_data = 8'h00;
    if (rr_header) ssr_data = header_byte;
    else if (rr_wram)   ssr_data = ssr_addr_r[0] ? ss_wram_do[15:8]  : ss_wram_do[7:0];
    else if (rr_vram)   ssr_data = vram_byte;
    else if (rr_z80ram) ssr_data = ss_z80ram_do;
    else if (rr_m68k) begin
        // 68K state: 624 bits = 78 bytes, padded to 256B
        if (ssr_addr_r - M68K_BASE < 18'h4E)
            ssr_data = ss_m68k_state[(ssr_addr_r - M68K_BASE)*8 +: 8];
    end
    else if (rr_z80reg) begin
        // Z80 state: 212 bits = 26.5 bytes → 27 bytes, padded to 64B
        if (ssr_addr_r - Z80REG_BASE < 18'h1B)
            ssr_data = ss_z80_reg[(ssr_addr_r - Z80REG_BASE)*8 +: 8];
        else if (ssr_addr_r - Z80REG_BASE == 18'h1B)
            ssr_data = {4'b0, ss_z80_reg[211:208]};
    end
    else if (rr_vdpreg) ssr_data = ss_vdp_reg[(ssr_addr_r - VDP_BASE)*8 +: 8];
    else if (rr_vdpst) begin
        // VDP state/status bytes at +0x20..+0x27
        if (ssr_addr_r[2:0] < 3'd4)
            ssr_data = ss_vdp_state[(ssr_addr_r[1:0])*8 +: 8];
        else if (ssr_addr_r[2:0] == 3'd4)
            ssr_data = ss_vdp_status[7:0];
        else if (ssr_addr_r[2:0] == 3'd5)
            ssr_data = ss_vdp_status[15:8];
    end
    else if (rr_cram)  ssr_data = cram_byte;
    else if (rr_vsr0)  ssr_data = vsram_byte;
    else if (rr_vsr1)  ssr_data = vsram_byte;
    else if (rr_fm)    ssr_data = ss_fm_rd_data;  // shadow reg: combinatorial 1-cycle
    else if (rr_psg)   ssr_data = ss_psg_state[(ssr_addr_r - PSG_BASE)*8 +: 8];
end

// -----------------------------------------------------------------------
// LOAD: memory write path (combinatorial, gated by ssw_en)
// -----------------------------------------------------------------------
wire ssw_in_wram   = ssw_en && (ssw_addr >= WRAM_BASE)   && (ssw_addr < VRAM_BASE);
wire ssw_in_vram   = ssw_en && (ssw_addr >= VRAM_BASE)   && (ssw_addr < Z80RAM_BASE);
wire ssw_in_z80ram = ssw_en && (ssw_addr >= Z80RAM_BASE) && (ssw_addr < M68K_BASE);

// VRAM accumulation buffer: VRAM port B is 32-bit with a single wren_b for all
// byte lanes, so we must assemble 4 bytes before committing a write.
// Bytes 0-2 are stored here on each cycle; byte 3 triggers the write.
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
// Priority: LOAD writes take precedence over SAVE reads (they never overlap).
always @(*) begin
    // WRAM port B
    // WRAM dpram is 16-bit port B; write upper or lower byte depending on
    // the address LSB. Both halves of ss_wram_di carry ssw_data so the
    // correct half is selected by we_u / we_l.
    if (ssw_in_wram) begin
        ss_wram_addr = (ssw_addr - WRAM_BASE) >> 1;
        ss_wram_we_u = ssw_addr[0];      // odd byte  → upper byte
        ss_wram_we_l = ~ssw_addr[0];     // even byte → lower byte
        ss_wram_di   = {ssw_data, ssw_data};
    end else begin
        ss_wram_addr = in_wram ? (ssr_addr - WRAM_BASE) >> 1 : 15'h0;
        ss_wram_we_u = 1'b0;
        ss_wram_we_l = 1'b0;
        ss_wram_di   = 16'h0;
    end

    // VRAM port B (32-bit, single wren_b)
    // Write only when we've received the 4th byte of a 32-bit word.
    if (ssw_in_vram) begin
        ss_vram_addr = (ssw_addr - VRAM_BASE) >> 2;
        ss_vram_we   = (ssw_addr[1:0] == 2'b11);
        ss_vram_di   = {ssw_data, vram_load_buf};   // byte3 | buf[23:0]
    end else begin
        ss_vram_addr = in_vram ? (ssr_addr - VRAM_BASE) >> 2 : 14'h0;
        ss_vram_we   = 1'b0;
        ss_vram_di   = 32'h0;
    end

    // Z80 RAM port B (8-bit)
    if (ssw_in_z80ram) begin
        ss_z80ram_addr = (ssw_addr - Z80RAM_BASE);
        ss_z80ram_we   = 1'b1;
        ss_z80ram_di   = ssw_data;
    end else begin
        ss_z80ram_addr = in_z80ram ? (ssr_addr - Z80RAM_BASE) : 13'h0;
        ss_z80ram_we   = 1'b0;
        ss_z80ram_di   = 8'h0;
    end
end

// -----------------------------------------------------------------------
endmodule
`default_nettype wire
