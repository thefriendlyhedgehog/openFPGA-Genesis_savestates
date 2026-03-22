// tb_savestate_ctrl.sv — Testbench for savestate_ctrl module
// Tests: FSM flow, address decode, save read path, load write path,
//        shift register accumulation, BRAM port routing

`default_nettype none

module tb_savestate_ctrl (
    input wire clk,
    input wire reset,

    // Test control interface (driven by C++ harness)
    input  wire        test_save_start,
    input  wire        test_load_start,
    output wire        test_save_ack,
    output wire        test_save_busy,
    output wire        test_save_ok,
    output wire        test_save_err,
    output wire        test_load_ack,
    output wire        test_load_busy,
    output wire        test_load_ok,
    output wire        test_load_err,
    output wire        test_ss_halt,
    output wire [3:0]  test_fsm_state,

    // Expose data_unloader sim interface
    input  wire        sim_ssr_en,
    input  wire [17:0] sim_ssr_addr,
    output wire  [7:0] sim_ssr_data,

    // Expose data_loader sim interface
    input  wire        sim_ssw_en,
    input  wire [17:0] sim_ssw_addr,
    input  wire  [7:0] sim_ssw_data,

    // Memory verification outputs
    output wire [14:0] out_wram_addr,
    output wire        out_wram_we_u,
    output wire        out_wram_we_l,
    output wire [15:0] out_wram_di,
    output wire [13:0] out_vram_addr,
    output wire        out_vram_we,
    output wire [31:0] out_vram_di,
    output wire [12:0] out_z80ram_addr,
    output wire        out_z80ram_we,
    output wire  [7:0] out_z80ram_di,

    // Peripheral apply verification
    output wire        out_m68k_load,
    output wire        out_z80_dirset,
    output wire        out_psg_load,
    output wire        out_vdp_reg_load,
    output wire        out_fm_wr_en,
    output wire  [8:0] out_fm_wr_addr,
    output wire  [7:0] out_fm_wr_din,
    output wire        out_cram_wr_en,
    output wire  [5:0] out_cram_wr_addr,
    output wire  [8:0] out_cram_wr_data,
    output wire        out_vsram_wr_en,
    output wire  [5:0] out_vsram_wr_addr,
    output wire [10:0] out_vsram_wr_data,

    // Loaded state verification
    output wire [623:0] out_m68k_state_in,
    output wire [211:0] out_z80_dir,
    output wire  [63:0] out_psg_state_in,
    output wire [255:0] out_vdp_reg_in,
    output wire  [31:0] out_vdp_state_in
);

// -----------------------------------------------------------------------
// Mock memory arrays
// -----------------------------------------------------------------------
reg [15:0] mock_wram  [0:32767];   // 64KB = 32K x 16-bit
reg [31:0] mock_vram  [0:16383];   // 64KB = 16K x 32-bit
reg  [7:0] mock_z80ram[0:8191];    // 8KB

// Initialize with known pattern
integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1) mock_wram[i]   = i[15:0] ^ 16'hA5A5;
    for (i = 0; i < 16384; i = i + 1) mock_vram[i]    = {i[15:0], i[15:0]} ^ 32'hDEADBEEF;
    for (i = 0; i < 8192;  i = i + 1) mock_z80ram[i]  = i[7:0] ^ 8'h5A;
end

// -----------------------------------------------------------------------
// Mock peripheral state vectors
// -----------------------------------------------------------------------
// M68K: 624 bits = 78 bytes, fill with incrementing pattern
reg [623:0] mock_m68k_state;
initial begin
    for (i = 0; i < 78; i = i + 1)
        mock_m68k_state[i*8 +: 8] = i[7:0] ^ 8'hCC;
end

// Z80: 212 bits = 27 bytes (last byte partial)
reg [211:0] mock_z80_reg;
initial begin
    for (i = 0; i < 26; i = i + 1)
        mock_z80_reg[i*8 +: 8] = i[7:0] ^ 8'h33;
    mock_z80_reg[211:208] = 4'hA;
end

// VDP regs: 256 bits = 32 bytes
reg [255:0] mock_vdp_reg;
initial begin
    for (i = 0; i < 32; i = i + 1)
        mock_vdp_reg[i*8 +: 8] = i[7:0] ^ 8'h77;
end

// VDP state: 32 bits
reg [31:0] mock_vdp_state = 32'h12345678;

// VDP status: 16 bits
reg [15:0] mock_vdp_status = 16'hABCD;

// PSG: 64 bits = 8 bytes
reg [63:0] mock_psg_state = 64'hFEDCBA9876543210;

// FM: 512 bytes register file
reg [7:0] mock_fm_regs [0:511];
initial begin
    for (i = 0; i < 512; i = i + 1)
        mock_fm_regs[i] = i[7:0] ^ 8'hBB;
end

// CRAM: 64 entries x 9 bits
reg [8:0] mock_cram [0:63];
initial begin
    for (i = 0; i < 64; i = i + 1)
        mock_cram[i] = i[8:0] ^ 9'h155;
end

// VSRAM: 64 entries x 11 bits (two sets of 32)
reg [10:0] mock_vsram [0:63];
initial begin
    for (i = 0; i < 64; i = i + 1)
        mock_vsram[i] = i[10:0] ^ 11'h2AA;
end

// -----------------------------------------------------------------------
// Wire up savestate_ctrl
// -----------------------------------------------------------------------
wire [14:0] ss_wram_addr;
wire        ss_wram_we_u, ss_wram_we_l;
wire [15:0] ss_wram_di;
wire [15:0] ss_wram_do;
wire [13:0] ss_vram_addr;
wire        ss_vram_we;
wire [31:0] ss_vram_di;
wire [31:0] ss_vram_do;
wire [12:0] ss_z80ram_addr;
wire        ss_z80ram_we;
wire  [7:0] ss_z80ram_di;
wire  [7:0] ss_z80ram_do;
wire  [8:0] ss_fm_rd_addr;
wire  [7:0] ss_fm_rd_data;
wire        ss_fm_wr_en;
wire  [8:0] ss_fm_wr_addr;
wire  [7:0] ss_fm_wr_din;
wire  [5:0] ss_vdp_cram_rd_addr;
wire  [8:0] ss_vdp_cram_rd_data;
wire  [5:0] ss_vdp_vsram_rd_addr;
wire [10:0] ss_vdp_vsram_rd_data;

// Memory read ports (1-cycle latency simulation)
reg [15:0] wram_rd_reg;
reg [31:0] vram_rd_reg;
reg  [7:0] z80ram_rd_reg;
reg  [7:0] fm_rd_reg;
reg  [8:0] cram_rd_reg;
reg [10:0] vsram_rd_reg;

always @(posedge clk) begin
    wram_rd_reg   <= mock_wram[ss_wram_addr];
    vram_rd_reg   <= mock_vram[ss_vram_addr];
    z80ram_rd_reg <= mock_z80ram[ss_z80ram_addr];
    fm_rd_reg     <= mock_fm_regs[ss_fm_rd_addr];
    cram_rd_reg   <= mock_cram[ss_vdp_cram_rd_addr];
    vsram_rd_reg  <= mock_vsram[ss_vdp_vsram_rd_addr];
end

assign ss_wram_do          = wram_rd_reg;
assign ss_vram_do          = vram_rd_reg;
assign ss_z80ram_do        = z80ram_rd_reg;
assign ss_fm_rd_data       = fm_rd_reg;
assign ss_vdp_cram_rd_data = cram_rd_reg;
assign ss_vdp_vsram_rd_data= vsram_rd_reg;

// Handle writes to mock memory during LOAD
always @(posedge clk) begin
    if (ss_wram_we_l) mock_wram[ss_wram_addr][7:0]  <= ss_wram_di[7:0];
    if (ss_wram_we_u) mock_wram[ss_wram_addr][15:8]  <= ss_wram_di[15:8];
    if (ss_vram_we)   mock_vram[ss_vram_addr]         <= ss_vram_di;
    if (ss_z80ram_we) mock_z80ram[ss_z80ram_addr]     <= ss_z80ram_di;
end

// Wire declarations for outputs
wire        ss_halt;
wire        save_ack, save_busy, save_ok, save_err;
wire        load_ack, load_busy, load_ok, load_err;
wire [7:0]  ssr_data;
wire        ss_m68k_load;
wire [623:0] ss_m68k_state_in;
wire        ss_z80_dirset;
wire [211:0] ss_z80_dir;
wire [63:0] ss_psg_state_in;
wire        ss_psg_load;
wire        ss_vdp_reg_load;
wire [255:0] ss_vdp_reg_in;
wire [31:0] ss_vdp_state_in;
wire        ss_vdp_cram_wr_en;
wire [5:0]  ss_vdp_cram_wr_addr;
wire [8:0]  ss_vdp_cram_wr_data;
wire        ss_vdp_vsram_wr_en;
wire [5:0]  ss_vdp_vsram_wr_addr;
wire [10:0] ss_vdp_vsram_wr_data;

savestate_ctrl #(
    .SS_SIZE(18'h22590)
) uut (
    .clk            (clk),
    .reset          (reset),
    .save_start     (test_save_start),
    .load_start     (test_load_start),
    .save_ack       (save_ack),
    .save_busy      (save_busy),
    .save_ok        (save_ok),
    .save_err       (save_err),
    .load_ack       (load_ack),
    .load_busy      (load_busy),
    .load_ok        (load_ok),
    .load_err       (load_err),
    .vbus_sel       (1'b0),          // No DMA activity in test
    .ss_halt        (ss_halt),
    .ssr_en         (sim_ssr_en),
    .ssr_addr       (sim_ssr_addr),
    .ssr_data       (ssr_data),
    .ssw_en         (sim_ssw_en),
    .ssw_addr       (sim_ssw_addr),
    .ssw_data       (sim_ssw_data),
    .ss_wram_addr   (ss_wram_addr),
    .ss_wram_we_u   (ss_wram_we_u),
    .ss_wram_we_l   (ss_wram_we_l),
    .ss_wram_di     (ss_wram_di),
    .ss_wram_do     (ss_wram_do),
    .ss_vram_addr   (ss_vram_addr),
    .ss_vram_we     (ss_vram_we),
    .ss_vram_di     (ss_vram_di),
    .ss_vram_do     (ss_vram_do),
    .ss_z80ram_addr (ss_z80ram_addr),
    .ss_z80ram_we   (ss_z80ram_we),
    .ss_z80ram_di   (ss_z80ram_di),
    .ss_z80ram_do   (ss_z80ram_do),
    .ss_psg_state   (mock_psg_state),
    .ss_psg_state_in(ss_psg_state_in),
    .ss_psg_load    (ss_psg_load),
    .ss_fm_rd_addr  (ss_fm_rd_addr),
    .ss_fm_rd_data  (ss_fm_rd_data),
    .ss_fm_wr_en    (ss_fm_wr_en),
    .ss_fm_wr_addr  (ss_fm_wr_addr),
    .ss_fm_wr_din   (ss_fm_wr_din),
    .ss_m68k_state  (mock_m68k_state),
    .ss_m68k_state_in(ss_m68k_state_in),
    .ss_m68k_load   (ss_m68k_load),
    .ss_z80_reg     (mock_z80_reg),
    .ss_z80_dirset  (ss_z80_dirset),
    .ss_z80_dir     (ss_z80_dir),
    .ss_vdp_reg     (mock_vdp_reg),
    .ss_vdp_state   (mock_vdp_state),
    .ss_vdp_status  (mock_vdp_status),
    .ss_vdp_reg_load(ss_vdp_reg_load),
    .ss_vdp_reg_in  (ss_vdp_reg_in),
    .ss_vdp_state_in(ss_vdp_state_in),
    .ss_vdp_cram_wr_en  (ss_vdp_cram_wr_en),
    .ss_vdp_cram_wr_addr(ss_vdp_cram_wr_addr),
    .ss_vdp_cram_wr_data(ss_vdp_cram_wr_data),
    .ss_vdp_cram_rd_addr(ss_vdp_cram_rd_addr),
    .ss_vdp_cram_rd_data(ss_vdp_cram_rd_data),
    .ss_vdp_vsram_wr_en  (ss_vdp_vsram_wr_en),
    .ss_vdp_vsram_wr_addr(ss_vdp_vsram_wr_addr),
    .ss_vdp_vsram_wr_data(ss_vdp_vsram_wr_data),
    .ss_vdp_vsram_rd_addr(ss_vdp_vsram_rd_addr),
    .ss_vdp_vsram_rd_data(ss_vdp_vsram_rd_data)
);

// -----------------------------------------------------------------------
// Output assignments
// -----------------------------------------------------------------------
assign test_save_ack  = save_ack;
assign test_save_busy = save_busy;
assign test_save_ok   = save_ok;
assign test_save_err  = save_err;
assign test_load_ack  = load_ack;
assign test_load_busy = load_busy;
assign test_load_ok   = load_ok;
assign test_load_err  = load_err;
assign test_ss_halt   = ss_halt;
assign test_fsm_state = uut.state;
assign sim_ssr_data   = ssr_data;

assign out_wram_addr  = ss_wram_addr;
assign out_wram_we_u  = ss_wram_we_u;
assign out_wram_we_l  = ss_wram_we_l;
assign out_wram_di    = ss_wram_di;
assign out_vram_addr  = ss_vram_addr;
assign out_vram_we    = ss_vram_we;
assign out_vram_di    = ss_vram_di;
assign out_z80ram_addr= ss_z80ram_addr;
assign out_z80ram_we  = ss_z80ram_we;
assign out_z80ram_di  = ss_z80ram_di;

assign out_m68k_load    = ss_m68k_load;
assign out_z80_dirset   = ss_z80_dirset;
assign out_psg_load     = ss_psg_load;
assign out_vdp_reg_load = ss_vdp_reg_load;
assign out_fm_wr_en     = ss_fm_wr_en;
assign out_fm_wr_addr   = ss_fm_wr_addr;
assign out_fm_wr_din    = ss_fm_wr_din;
assign out_cram_wr_en   = ss_vdp_cram_wr_en;
assign out_cram_wr_addr = ss_vdp_cram_wr_addr;
assign out_cram_wr_data = ss_vdp_cram_wr_data;
assign out_vsram_wr_en  = ss_vdp_vsram_wr_en;
assign out_vsram_wr_addr= ss_vdp_vsram_wr_addr;
assign out_vsram_wr_data= ss_vdp_vsram_wr_data;

assign out_m68k_state_in = ss_m68k_state_in;
assign out_z80_dir       = ss_z80_dir;
assign out_psg_state_in  = ss_psg_state_in;
assign out_vdp_reg_in    = ss_vdp_reg_in;
assign out_vdp_state_in  = ss_vdp_state_in;

endmodule
`default_nettype wire
