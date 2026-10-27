`timescale 1ns / 1ps

// 2-way set-associative write-back D-cache.
//
// The 64 sets are read as 16 banks of 4.  A request cycle registers a per-bank
// copy of the set index; the next cycle reads the banks and selects one bank
// per group of four into a group candidate register.  The compare cycle picks
// the requested group, compares tags, and registers the line and the hit
// information.  The response or writeback decision is made in S_RESP.  A
// 16:1 read mux therefore never sits on a single cycle boundary: each cycle
// carries a 4:1 mux.
//
// The write ports use pre-decoded one-hot strobes (set one-hot per way, word
// one-hot) and per-way/per-word data replicas, so neither the way select nor
// the word select is broadcast to the whole array.
module dcache #(
  parameter SET_WIDTH    = 6,               // 64 sets
  parameter OFFSET_WIDTH = 4,               // 16 bytes (4 words per line)
  parameter TAG_WIDTH    = 22               // 32 - 6 - 4 = 22 bits
)(
  input             clock,
  input             reset,

  // CPU Interface
  input             req_valid,
  input             req_write,
  input      [31:0] req_addr,
  input      [31:0] req_wdata,
  input      [3:0]  req_wmask,
  output            req_ready,
  output            resp_valid,
  output     [31:0] resp_rdata,
  input             fence_i,
  output            fence_done,

  // Memory Interface (AXI / Refill Arbiter)
  input             mem_req_ack,
  input             mem_write_ack,
  output reg        mem_req_valid,
  output reg        mem_req_write,
  output reg [31:0] mem_req_addr,
  output reg [7:0]  mem_req_len,
  output     [31:0] mem_req_wdata,
  output     [3:0]  mem_req_wstrb,
  output            mem_req_wlast,
  input             mem_grant,
  input             mem_resp_valid,
  input      [31:0] mem_resp_rdata,
  input             mem_resp_rlast,

  // Performance Counters
  output reg [31:0] hit_count,
  output reg [31:0] miss_count
);

  localparam NUM_SETS   = 1 << SET_WIDTH;
  localparam [NUM_SETS-1:0] ONE = 1;
  localparam BANK_WIDTH = 4;
  localparam NUM_BANKS  = 1 << BANK_WIDTH;
  localparam IN_BANK    = SET_WIDTH - BANK_WIDTH;
  localparam GRP_WIDTH  = 2;
  localparam NUM_GRPS   = 1 << GRP_WIDTH;
  localparam IN_GRP     = BANK_WIDTH - GRP_WIDTH;

  reg                 way0_valid [NUM_SETS-1:0];
  reg                 way0_dirty [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way0_tag   [NUM_SETS-1:0];
  reg [31:0]          way0_word0 [NUM_SETS-1:0];
  reg [31:0]          way0_word1 [NUM_SETS-1:0];
  reg [31:0]          way0_word2 [NUM_SETS-1:0];
  reg [31:0]          way0_word3 [NUM_SETS-1:0];

  reg                 way1_valid [NUM_SETS-1:0];
  reg                 way1_dirty [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way1_tag   [NUM_SETS-1:0];
  reg [31:0]          way1_word0 [NUM_SETS-1:0];
  reg [31:0]          way1_word1 [NUM_SETS-1:0];
  reg [31:0]          way1_word2 [NUM_SETS-1:0];
  reg [31:0]          way1_word3 [NUM_SETS-1:0];

  reg                 lru        [NUM_SETS-1:0];

  localparam S_IDLE        = 4'd0;
  localparam S_BANK        = 4'd10;
  localparam S_CMP         = 4'd11;
  localparam S_RESP        = 4'd2;
  localparam S_WB_LINE     = 4'd3;
  localparam S_REFILL      = 4'd4;
  localparam S_REFILL_DONE = 4'd5;
  localparam S_MMIO_WAIT   = 4'd6;
  localparam S_REFILL_MERGE = 4'd13;
  localparam S_FENCE_SETUP = 4'd12;
  localparam S_FENCE_BANK  = 4'd14;
  localparam S_FENCE_READ  = 4'd7;
  localparam S_FENCE_CHECK = 4'd8;
  localparam S_FENCE_WB    = 4'd9;

  reg [3:0]   state;

  // Registered request.  The word select is kept one-hot so the word muxes
  // are driven by four nets of 32 loads instead of two nets of 64.  The
  // refill merge select is precomputed separately so the response muxes and
  // the refill data registers are driven by different nets.
  reg [3:0]           saved_word_oh;
  reg [3:0]           rw_word_oh;
  reg [31:0]          saved_addr;
  // Line address of the pending request, formed in the request cycle so the
  // memory-request register is not loaded from the wide saved_addr net.
  reg [31:0]          req_line_addr;
  reg                 saved_write;
  reg [31:0]          saved_wdata;
  reg [3:0]           saved_wmask;
  reg                 saved_victim_way;

  // Registered read result.
  reg [127:0] line0_r, line1_r;
  reg [TAG_WIDTH-1:0] sel_tag0_r, sel_tag1_r;
  reg         sel_valid0_r, sel_valid1_r;
  reg         sel_dirty0_r, sel_dirty1_r;
  reg         sel_lru_r;

  // Registered write ports.  Every strobe is a one-hot vector and every data
  // input has a per-way/per-word replica, so the array write does not
  // broadcast a way/word select across the 16k data flops.
  reg [NUM_SETS-1:0] st_w0_oh, st_w1_oh;
  reg [NUM_SETS-1:0] rf_w0_oh, rf_w1_oh;
  reg [NUM_SETS-1:0] fe_w0_oh, fe_w1_oh;
  reg [NUM_SETS-1:0] fence_set_oh;
  reg [3:0]          st_word_oh;
  reg [31:0]         st_data [0:7];   // {way, word}
  reg [31:0]         rf_data [0:7];   // {way, word}

  // Group candidates: one selected bank per group of four, both ways.
  reg [127:0]         cand_line0  [0:NUM_GRPS-1];
  reg [127:0]         cand_line1  [0:NUM_GRPS-1];
  reg [TAG_WIDTH-1:0] cand_tag0   [0:NUM_GRPS-1];
  reg [TAG_WIDTH-1:0] cand_tag1   [0:NUM_GRPS-1];
  reg                 cand_valid0 [0:NUM_GRPS-1];
  reg                 cand_valid1 [0:NUM_GRPS-1];
  reg                 cand_dirty0 [0:NUM_GRPS-1];
  reg                 cand_dirty1 [0:NUM_GRPS-1];
  reg                 cand_lru    [0:NUM_GRPS-1];
  reg                 cand_eq0    [0:NUM_GRPS-1];
  reg                 cand_eq1    [0:NUM_GRPS-1];
  // Group select, one-hot.
  wire [127:0]         sel_line0 = ({128{d_grp_oh[0]}} & cand_line0[0]) |
                                   ({128{d_grp_oh[1]}} & cand_line0[1]) |
                                   ({128{d_grp_oh[2]}} & cand_line0[2]) |
                                   ({128{d_grp_oh[3]}} & cand_line0[3]);
  wire [127:0]         sel_line1 = ({128{d_grp_oh[0]}} & cand_line1[0]) |
                                   ({128{d_grp_oh[1]}} & cand_line1[1]) |
                                   ({128{d_grp_oh[2]}} & cand_line1[2]) |
                                   ({128{d_grp_oh[3]}} & cand_line1[3]);
  wire [TAG_WIDTH-1:0] sel_tag0w = ({TAG_WIDTH{d_grp_oh[0]}} & cand_tag0[0]) |
                                   ({TAG_WIDTH{d_grp_oh[1]}} & cand_tag0[1]) |
                                   ({TAG_WIDTH{d_grp_oh[2]}} & cand_tag0[2]) |
                                   ({TAG_WIDTH{d_grp_oh[3]}} & cand_tag0[3]);
  wire [TAG_WIDTH-1:0] sel_tag1w = ({TAG_WIDTH{d_grp_oh[0]}} & cand_tag1[0]) |
                                   ({TAG_WIDTH{d_grp_oh[1]}} & cand_tag1[1]) |
                                   ({TAG_WIDTH{d_grp_oh[2]}} & cand_tag1[2]) |
                                   ({TAG_WIDTH{d_grp_oh[3]}} & cand_tag1[3]);
  wire                 sel_valid0w = (cand_valid0[0] & d_grp_oh[0]) |
                                      (cand_valid0[1] & d_grp_oh[1]) |
                                      (cand_valid0[2] & d_grp_oh[2]) |
                                      (cand_valid0[3] & d_grp_oh[3]);
  wire                 sel_valid1w = (cand_valid1[0] & d_grp_oh[0]) |
                                      (cand_valid1[1] & d_grp_oh[1]) |
                                      (cand_valid1[2] & d_grp_oh[2]) |
                                      (cand_valid1[3] & d_grp_oh[3]);
  wire                 sel_dirty0w = (cand_dirty0[0] & d_grp_oh[0]) |
                                      (cand_dirty0[1] & d_grp_oh[1]) |
                                      (cand_dirty0[2] & d_grp_oh[2]) |
                                      (cand_dirty0[3] & d_grp_oh[3]);
  wire                 sel_dirty1w = (cand_dirty1[0] & d_grp_oh[0]) |
                                      (cand_dirty1[1] & d_grp_oh[1]) |
                                      (cand_dirty1[2] & d_grp_oh[2]) |
                                      (cand_dirty1[3] & d_grp_oh[3]);
  wire                 sel_lruw    = (cand_lru[0] & d_grp_oh[0]) |
                                      (cand_lru[1] & d_grp_oh[1]) |
                                      (cand_lru[2] & d_grp_oh[2]) |
                                      (cand_lru[3] & d_grp_oh[3]);
  wire                 sel_eq0w    = (cand_eq0[0] & d_grp_oh[0]) |
                                      (cand_eq0[1] & d_grp_oh[1]) |
                                      (cand_eq0[2] & d_grp_oh[2]) |
                                      (cand_eq0[3] & d_grp_oh[3]);
  wire                 sel_eq1w    = (cand_eq1[0] & d_grp_oh[0]) |
                                      (cand_eq1[1] & d_grp_oh[1]) |
                                      (cand_eq1[2] & d_grp_oh[2]) |
                                      (cand_eq1[3] & d_grp_oh[3]);

  reg         hit0_r, hit1_r;
  reg         valid0_r, valid1_r;
  reg         dirty0_r, dirty1_r;

  // Refill / writeback state.
  reg [127:0] dirty_line_buf;
  reg [127:0] refill_buf;
  reg [1:0]   beat_cnt;

  // Fence scan state.
  reg [SET_WIDTH-1:0] fence_set;
  reg [127:0]         fence_line0, fence_line1;
  reg                 fence_valid0, fence_valid1;
  reg                 fence_dirty0, fence_dirty1;
  reg [TAG_WIDTH-1:0] fence_tag0, fence_tag1;
  reg                 fence_done_r;

  assign fence_done = fence_done_r;
  assign req_ready  = (state == S_IDLE) && !fence_i;

  wire [BANK_WIDTH-1:0] bank_w    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH+IN_BANK];
  wire [IN_BANK-1:0]    set_w     = req_addr[OFFSET_WIDTH+IN_BANK-1 : OFFSET_WIDTH];
  wire [1:0]            word_sel_w = req_addr[3:2];

  wire [SET_WIDTH-1:0] saved_index = saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] saved_tag   = saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];

  wire is_mmio = (req_addr < 32'h80000000) || (req_addr >= 32'h88000000);

  // Word-plane storage: four 32-bit arrays per way keep the read mux width at
  // 32 bits instead of 128 bits.  The sets are read as 16 banks of 4; each
  // bank is driven by its own registered copy of the set index so the index
  // fanout stays inside a bank.
  reg [BANK_WIDTH-1:0] d_bank;
  reg [TAG_WIDTH-1:0]  d_tag;
  reg [IN_BANK-1:0]    db_set [0:NUM_BANKS-1];

  // The bank select splits into a group index (picked in the compare cycle)
  // and a bank-in-group index (picked while the banks are read).  Both are
  // decoded one-hot from the registered bank index, so each select net
  // drives a quarter of the mux gates a binary select would.

  // Bank indices of the four banks inside each group (one-hot select).
  wire [BANK_WIDTH-1:0] grp_bank0 [0:NUM_GRPS-1];
  wire [BANK_WIDTH-1:0] grp_bank1 [0:NUM_GRPS-1];
  wire [BANK_WIDTH-1:0] grp_bank2 [0:NUM_GRPS-1];
  wire [BANK_WIDTH-1:0] grp_bank3 [0:NUM_GRPS-1];
  genvar gg;
  generate
    for (gg = 0; gg < NUM_GRPS; gg = gg + 1) begin : g_grp
      assign grp_bank0[gg] = {gg[GRP_WIDTH-1:0], 2'd0};
      assign grp_bank1[gg] = {gg[GRP_WIDTH-1:0], 2'd1};
      assign grp_bank2[gg] = {gg[GRP_WIDTH-1:0], 2'd2};
      assign grp_bank3[gg] = {gg[GRP_WIDTH-1:0], 2'd3};
    end
  endgenerate

  // One-hot decodes of the registered bank index.
  wire [NUM_GRPS-1:0]  d_grp_oh = 4'b0001 << d_bank[BANK_WIDTH-1:IN_GRP];
  wire [NUM_GRPS-1:0]  d_lo_oh  = 4'b0001 << d_bank[IN_GRP-1:0];

  wire [127:0]         bank_line0  [0:NUM_BANKS-1];
  wire [127:0]         bank_line1  [0:NUM_BANKS-1];
  wire [TAG_WIDTH-1:0] bank_tag0   [0:NUM_BANKS-1];
  wire [TAG_WIDTH-1:0] bank_tag1   [0:NUM_BANKS-1];
  wire                 bank_valid0 [0:NUM_BANKS-1];
  wire                 bank_valid1 [0:NUM_BANKS-1];
  wire                 bank_dirty0 [0:NUM_BANKS-1];
  wire                 bank_dirty1 [0:NUM_BANKS-1];
  wire                 bank_lru    [0:NUM_BANKS-1];

  genvar gb;
  generate
    for (gb = 0; gb < NUM_BANKS; gb = gb + 1) begin : g_bank
      wire [SET_WIDTH-1:0] rd_idx = {gb[BANK_WIDTH-1:0], db_set[gb]};
      assign bank_line0[gb]  = {way0_word3[rd_idx], way0_word2[rd_idx],
                                way0_word1[rd_idx], way0_word0[rd_idx]};
      assign bank_line1[gb]  = {way1_word3[rd_idx], way1_word2[rd_idx],
                                way1_word1[rd_idx], way1_word0[rd_idx]};
      assign bank_tag0[gb]   = way0_tag[rd_idx];
      assign bank_tag1[gb]   = way1_tag[rd_idx];
      assign bank_valid0[gb] = way0_valid[rd_idx];
      assign bank_valid1[gb] = way1_valid[rd_idx];
      assign bank_dirty0[gb] = way0_dirty[rd_idx];
      assign bank_dirty1[gb] = way1_dirty[rd_idx];
      assign bank_lru[gb]    = lru[rd_idx];
    end
  endgenerate

  function [31:0] apply_mask;
    input [31:0] orig_word;
    input [31:0] new_word;
    input [3:0]  mask;
    begin
      apply_mask = {
        mask[3] ? new_word[31:24] : orig_word[31:24],
        mask[2] ? new_word[23:16] : orig_word[23:16],
        mask[1] ? new_word[15:8]  : orig_word[15:8],
        mask[0] ? new_word[7:0]   : orig_word[7:0]
      };
    end
  endfunction

  // Word select runs on each way separately and the way is picked with a
  // 32-bit mux, so the hit bit fans out to 32 gates instead of 128.
  wire [31:0]  resp_word0 =
      ({32{saved_word_oh[0]}} & line0_r[31:0])  |
      ({32{saved_word_oh[1]}} & line0_r[63:32]) |
      ({32{saved_word_oh[2]}} & line0_r[95:64]) |
      ({32{saved_word_oh[3]}} & line0_r[127:96]);
  wire [31:0]  resp_word1 =
      ({32{saved_word_oh[0]}} & line1_r[31:0])  |
      ({32{saved_word_oh[1]}} & line1_r[63:32]) |
      ({32{saved_word_oh[2]}} & line1_r[95:64]) |
      ({32{saved_word_oh[3]}} & line1_r[127:96]);
  wire [31:0]  resp_hit_word = hit0_r ? resp_word0 : resp_word1;
  wire [31:0]  resp_merged_word = apply_mask(resp_hit_word, saved_wdata, saved_wmask);

  wire [31:0]  refill_word =
      ({32{saved_word_oh[0]}} & refill_buf[31:0])  |
      ({32{saved_word_oh[1]}} & refill_buf[63:32]) |
      ({32{saved_word_oh[2]}} & refill_buf[95:64]) |
      ({32{saved_word_oh[3]}} & refill_buf[127:96]);
  // A refill for a read miss writes the fetched line unchanged; only a store
  // miss merges the pending word, and only that one word is masked.
  wire [31:0]  refill_mask_word = apply_mask(refill_word, saved_wdata, saved_wmask);
  wire [31:0]  refill_resp_word = saved_write ? refill_mask_word : refill_word;

  wire [31:0]  wb_wdata =
      (beat_cnt == 2'b00) ? dirty_line_buf[31:0] :
      (beat_cnt == 2'b01) ? dirty_line_buf[63:32] :
      (beat_cnt == 2'b10) ? dirty_line_buf[95:64] :
                            dirty_line_buf[127:96];

  assign mem_req_wdata = (state == S_MMIO_WAIT) ? saved_wdata :
                         (state == S_WB_LINE || state == S_FENCE_WB) ? wb_wdata : 32'b0;
  assign mem_req_wstrb = (state == S_MMIO_WAIT) ? saved_wmask :
                         (state == S_WB_LINE || state == S_FENCE_WB) ? 4'b1111 : 4'b0;
  assign mem_req_wlast = (state == S_MMIO_WAIT) ? 1'b1 :
                         (state == S_WB_LINE || state == S_FENCE_WB) ? (beat_cnt == 2'b11) : 1'b0;

  // The hit/refill response is registered so the CPU stall logic does not see
  // the state decode; the MMIO response stays combinational.
  reg resp_valid_r;
  assign resp_valid = resp_valid_r || (state == S_MMIO_WAIT && mem_resp_valid);

  assign resp_rdata = (state == S_RESP) ?
                        (saved_write ? resp_merged_word : resp_hit_word) :
                      (state == S_REFILL_DONE) ? refill_resp_word :
                      (state == S_MMIO_WAIT) ? mem_resp_rdata : 32'b0;

  // Fence-clear targets for the current set.
  wire fe_hit0 = fence_valid0 && fence_dirty0;
  wire fe_hit1 = fence_valid1 && fence_dirty1;
  wire fe_do0  = fe_hit0 || (!fe_hit0 && !fe_hit1);
  wire fe_do1  = !fe_hit0;

  integer j;
  always @(posedge clock) begin
    if (reset) begin
      state            <= S_IDLE;
      mem_req_valid    <= 1'b0;
      mem_req_write    <= 1'b0;
      mem_req_addr     <= 32'b0;
      mem_req_len      <= 8'd0;
      saved_word_oh    <= 4'b0;
      rw_word_oh       <= 4'b0;
      saved_addr       <= 32'b0;
      req_line_addr    <= 32'b0;
      saved_write      <= 1'b0;
      saved_wdata      <= 32'b0;
      saved_wmask      <= 4'b0;
      saved_victim_way <= 1'b0;
      line0_r          <= 128'b0;
      line1_r          <= 128'b0;
      sel_tag0_r       <= {TAG_WIDTH{1'b0}};
      sel_tag1_r       <= {TAG_WIDTH{1'b0}};
      sel_valid0_r     <= 1'b0;
      sel_valid1_r     <= 1'b0;
      sel_dirty0_r     <= 1'b0;
      sel_dirty1_r     <= 1'b0;
      sel_lru_r        <= 1'b0;
      resp_valid_r     <= 1'b0;
      hit0_r           <= 1'b0;
      hit1_r           <= 1'b0;
      valid0_r         <= 1'b0;
      valid1_r         <= 1'b0;
      dirty0_r         <= 1'b0;
      dirty1_r         <= 1'b0;
      dirty_line_buf   <= 128'b0;
      refill_buf       <= 128'b0;
      beat_cnt         <= 2'b0;
      fence_set        <= {SET_WIDTH{1'b0}};
      fence_line0      <= 128'b0;
      fence_line1      <= 128'b0;
      fence_valid0     <= 1'b0;
      fence_valid1     <= 1'b0;
      fence_dirty0     <= 1'b0;
      fence_dirty1     <= 1'b0;
      fence_tag0       <= {TAG_WIDTH{1'b0}};
      fence_tag1       <= {TAG_WIDTH{1'b0}};
      fence_done_r     <= 1'b0;
      hit_count        <= 32'b0;
      miss_count       <= 32'b0;
      d_bank           <= {BANK_WIDTH{1'b0}};
      d_tag            <= {TAG_WIDTH{1'b0}};
      st_w0_oh         <= {NUM_SETS{1'b0}};
      st_w1_oh         <= {NUM_SETS{1'b0}};
      rf_w0_oh         <= {NUM_SETS{1'b0}};
      rf_w1_oh         <= {NUM_SETS{1'b0}};
      fe_w0_oh         <= {NUM_SETS{1'b0}};
      fe_w1_oh         <= {NUM_SETS{1'b0}};
      fence_set_oh     <= {NUM_SETS{1'b0}};
      st_word_oh       <= 4'b0;
      for (j = 0; j < 8; j = j + 1) begin
        st_data[j] <= 32'b0;
        rf_data[j] <= 32'b0;
      end
      for (j = 0; j < NUM_BANKS; j = j + 1)
        db_set[j] <= {IN_BANK{1'b0}};
      for (j = 0; j < NUM_GRPS; j = j + 1) begin
        cand_line0[j] <= 128'b0;
        cand_line1[j] <= 128'b0;
        cand_tag0[j]  <= {TAG_WIDTH{1'b0}};
        cand_tag1[j]  <= {TAG_WIDTH{1'b0}};
        cand_valid0[j] <= 1'b0;
        cand_valid1[j] <= 1'b0;
        cand_dirty0[j] <= 1'b0;
        cand_dirty1[j] <= 1'b0;
        cand_lru[j]    <= 1'b0;
        cand_eq0[j]    <= 1'b0;
        cand_eq1[j]    <= 1'b0;
      end
      for (j = 0; j < NUM_SETS; j = j + 1) begin
        way0_valid[j] <= 1'b0;
        way0_dirty[j] <= 1'b0;
        way1_valid[j] <= 1'b0;
        way1_dirty[j] <= 1'b0;
        lru[j]        <= 1'b0;
      end
    end else begin
      fence_done_r <= 1'b0;
      resp_valid_r <= 1'b0;
      st_w0_oh     <= {NUM_SETS{1'b0}};
      st_w1_oh     <= {NUM_SETS{1'b0}};
      rf_w0_oh     <= {NUM_SETS{1'b0}};
      rf_w1_oh     <= {NUM_SETS{1'b0}};
      fe_w0_oh     <= {NUM_SETS{1'b0}};
      fe_w1_oh     <= {NUM_SETS{1'b0}};
      st_word_oh   <= 4'b0;

      // Storage write ports, driven by the registered one-hot strobes and
      // per-way/per-word data replicas.
      for (j = 0; j < NUM_SETS; j = j + 1) begin
        if (st_w0_oh[j]) begin
          way0_dirty[j] <= 1'b1;
          lru[j]        <= 1'b1;
          if (st_word_oh[0]) way0_word0[j] <= st_data[0];
          if (st_word_oh[1]) way0_word1[j] <= st_data[1];
          if (st_word_oh[2]) way0_word2[j] <= st_data[2];
          if (st_word_oh[3]) way0_word3[j] <= st_data[3];
        end
        if (st_w1_oh[j]) begin
          way1_dirty[j] <= 1'b1;
          lru[j]        <= 1'b0;
          if (st_word_oh[0]) way1_word0[j] <= st_data[4];
          if (st_word_oh[1]) way1_word1[j] <= st_data[5];
          if (st_word_oh[2]) way1_word2[j] <= st_data[6];
          if (st_word_oh[3]) way1_word3[j] <= st_data[7];
        end
        if (rf_w0_oh[j]) begin
          way0_valid[j] <= 1'b1;
          way0_tag[j]   <= saved_tag;
          way0_dirty[j] <= saved_write;
          way0_word0[j] <= rf_data[0];
          way0_word1[j] <= rf_data[1];
          way0_word2[j] <= rf_data[2];
          way0_word3[j] <= rf_data[3];
          lru[j]        <= 1'b1;
        end
        if (rf_w1_oh[j]) begin
          way1_valid[j] <= 1'b1;
          way1_tag[j]   <= saved_tag;
          way1_dirty[j] <= saved_write;
          way1_word0[j] <= rf_data[4];
          way1_word1[j] <= rf_data[5];
          way1_word2[j] <= rf_data[6];
          way1_word3[j] <= rf_data[7];
          lru[j]        <= 1'b0;
        end
        if (fe_w0_oh[j]) begin
          way0_valid[j] <= 1'b0;
          way0_dirty[j] <= 1'b0;
        end
        if (fe_w1_oh[j]) begin
          way1_valid[j] <= 1'b0;
          way1_dirty[j] <= 1'b0;
        end
      end

      // Bank read capture runs every cycle: the bank index registers are
      // stable across the read and compare cycles, so gating the capture with
      // the state decode would only add a wide enable net in front of the
      // candidate flops.
      for (j = 0; j < NUM_GRPS; j = j + 1) begin
        cand_line0[j]  <= ({128{d_lo_oh[0]}} & bank_line0[grp_bank0[j]]) |
                          ({128{d_lo_oh[1]}} & bank_line0[grp_bank1[j]]) |
                          ({128{d_lo_oh[2]}} & bank_line0[grp_bank2[j]]) |
                          ({128{d_lo_oh[3]}} & bank_line0[grp_bank3[j]]);
        cand_line1[j]  <= ({128{d_lo_oh[0]}} & bank_line1[grp_bank0[j]]) |
                          ({128{d_lo_oh[1]}} & bank_line1[grp_bank1[j]]) |
                          ({128{d_lo_oh[2]}} & bank_line1[grp_bank2[j]]) |
                          ({128{d_lo_oh[3]}} & bank_line1[grp_bank3[j]]);
        cand_tag0[j]   <= ({TAG_WIDTH{d_lo_oh[0]}} & bank_tag0[grp_bank0[j]]) |
                          ({TAG_WIDTH{d_lo_oh[1]}} & bank_tag0[grp_bank1[j]]) |
                          ({TAG_WIDTH{d_lo_oh[2]}} & bank_tag0[grp_bank2[j]]) |
                          ({TAG_WIDTH{d_lo_oh[3]}} & bank_tag0[grp_bank3[j]]);
        cand_tag1[j]   <= ({TAG_WIDTH{d_lo_oh[0]}} & bank_tag1[grp_bank0[j]]) |
                          ({TAG_WIDTH{d_lo_oh[1]}} & bank_tag1[grp_bank1[j]]) |
                          ({TAG_WIDTH{d_lo_oh[2]}} & bank_tag1[grp_bank2[j]]) |
                          ({TAG_WIDTH{d_lo_oh[3]}} & bank_tag1[grp_bank3[j]]);
        cand_valid0[j] <= (bank_valid0[grp_bank0[j]] & d_lo_oh[0]) |
                          (bank_valid0[grp_bank1[j]] & d_lo_oh[1]) |
                          (bank_valid0[grp_bank2[j]] & d_lo_oh[2]) |
                          (bank_valid0[grp_bank3[j]] & d_lo_oh[3]);
        cand_valid1[j] <= (bank_valid1[grp_bank0[j]] & d_lo_oh[0]) |
                          (bank_valid1[grp_bank1[j]] & d_lo_oh[1]) |
                          (bank_valid1[grp_bank2[j]] & d_lo_oh[2]) |
                          (bank_valid1[grp_bank3[j]] & d_lo_oh[3]);
        cand_dirty0[j] <= (bank_dirty0[grp_bank0[j]] & d_lo_oh[0]) |
                          (bank_dirty0[grp_bank1[j]] & d_lo_oh[1]) |
                          (bank_dirty0[grp_bank2[j]] & d_lo_oh[2]) |
                          (bank_dirty0[grp_bank3[j]] & d_lo_oh[3]);
        cand_dirty1[j] <= (bank_dirty1[grp_bank0[j]] & d_lo_oh[0]) |
                          (bank_dirty1[grp_bank1[j]] & d_lo_oh[1]) |
                          (bank_dirty1[grp_bank2[j]] & d_lo_oh[2]) |
                          (bank_dirty1[grp_bank3[j]] & d_lo_oh[3]);
        cand_lru[j]    <= (bank_lru[grp_bank0[j]] & d_lo_oh[0]) |
                          (bank_lru[grp_bank1[j]] & d_lo_oh[1]) |
                          (bank_lru[grp_bank2[j]] & d_lo_oh[2]) |
                          (bank_lru[grp_bank3[j]] & d_lo_oh[3]);
        cand_eq0[j]    <= ((bank_tag0[grp_bank0[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[0]) |
                          ((bank_tag0[grp_bank1[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[1]) |
                          ((bank_tag0[grp_bank2[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[2]) |
                          ((bank_tag0[grp_bank3[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[3]);
        cand_eq1[j]    <= ((bank_tag1[grp_bank0[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[0]) |
                          ((bank_tag1[grp_bank1[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[1]) |
                          ((bank_tag1[grp_bank2[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[2]) |
                          ((bank_tag1[grp_bank3[j]][TAG_WIDTH/2-1:0] ==
                            d_tag[TAG_WIDTH/2-1:0]) & d_lo_oh[3]);
      end

      case (state)
        S_IDLE: begin
          if (fence_i) begin
            fence_set <= {SET_WIDTH{1'b0}};
            state     <= S_FENCE_SETUP;
          end else if (req_valid) begin
            saved_addr     <= req_addr;
            saved_write    <= req_write;
            saved_wdata    <= req_wdata;
            saved_wmask    <= req_wmask;
            saved_word_oh  <= 4'b0001 << word_sel_w;
            rw_word_oh     <= req_write ? (4'b0001 << word_sel_w) : 4'b0;

            if (is_mmio) begin
              mem_req_valid <= 1'b1;
              mem_req_write <= req_write;
              mem_req_addr  <= req_addr;
              mem_req_len   <= 8'd0;
              state         <= S_MMIO_WAIT;
            end else begin
              // Register the address first; the bank read runs from per-bank
              // index copies in the next cycle.
              req_line_addr <= {req_addr[31:4], 4'b0000};
              for (j = 0; j < NUM_BANKS; j = j + 1)
                db_set[j] <= set_w;
              d_bank   <= bank_w;
              d_tag    <= req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
              state  <= S_BANK;
            end
          end
        end

        S_BANK: begin
          state <= S_CMP;
        end

        S_CMP: begin
          line0_r   <= sel_line0;
          line1_r   <= sel_line1;
          sel_tag0_r <= sel_tag0w;
          sel_tag1_r <= sel_tag1w;
          sel_valid0_r <= sel_valid0w;
          sel_valid1_r <= sel_valid1w;
          sel_dirty0_r <= sel_dirty0w;
          sel_dirty1_r <= sel_dirty1w;
          sel_lru_r    <= sel_lruw;
          resp_valid_r <= (sel_valid0w && sel_eq0w &&
                           (sel_tag0w[TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2])) ||
                          (sel_valid1w && sel_eq1w &&
                           (sel_tag1w[TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]));
          hit0_r   <= sel_valid0w && sel_eq0w &&
                      (sel_tag0w[TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
          hit1_r   <= sel_valid1w && sel_eq1w &&
                      (sel_tag1w[TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
          valid0_r <= sel_valid0w;
          valid1_r <= sel_valid1w;
          dirty0_r <= sel_dirty0w;
          dirty1_r <= sel_dirty1w;
          state    <= S_RESP;
        end

        S_RESP: begin
          if (hit0_r || hit1_r) begin
            hit_count <= hit_count + 32'd1;
            // The write port is registered from the registered hit result, so
            // neither the bank mux nor the word select sits on its path.
            st_w0_oh   <= (saved_write &&  hit0_r) ? (ONE << saved_index) : {NUM_SETS{1'b0}};
            st_w1_oh   <= (saved_write && !hit0_r) ? (ONE << saved_index) : {NUM_SETS{1'b0}};
            st_word_oh <= saved_write ? saved_word_oh : 4'b0;
            st_data[0] <= resp_merged_word;
            st_data[1] <= resp_merged_word;
            st_data[2] <= resp_merged_word;
            st_data[3] <= resp_merged_word;
            st_data[4] <= resp_merged_word;
            st_data[5] <= resp_merged_word;
            st_data[6] <= resp_merged_word;
            st_data[7] <= resp_merged_word;
            state      <= S_IDLE;
          end else begin
            miss_count       <= miss_count + 32'd1;
            saved_victim_way <= sel_lru_r;
            if ((sel_lru_r == 1'b0 && valid0_r && dirty0_r) ||
                (sel_lru_r == 1'b1 && valid1_r && dirty1_r)) begin
              dirty_line_buf <= sel_lru_r ? line1_r : line0_r;
              mem_req_valid  <= 1'b1;
              mem_req_write  <= 1'b1;
              mem_req_addr   <= {sel_lru_r ? sel_tag1_r : sel_tag0_r, saved_index, 4'b0000};
              mem_req_len    <= 8'd3;
              beat_cnt       <= 2'b00;
              state          <= S_WB_LINE;
            end else begin
              mem_req_valid <= 1'b1;
              mem_req_write <= 1'b0;
              mem_req_addr  <= req_line_addr;
              mem_req_len   <= 8'd3;
              beat_cnt      <= 2'b00;
              state         <= S_REFILL;
            end
          end
        end

        S_WB_LINE: begin
          if (mem_req_ack) begin
            mem_req_valid <= 1'b0;
          end
          if (mem_write_ack) begin
            beat_cnt <= beat_cnt + 2'd1;
          end
          if (mem_resp_valid) begin
            mem_req_valid <= 1'b1;
            mem_req_write <= 1'b0;
            mem_req_addr  <= req_line_addr;
            mem_req_len   <= 8'd3;
            beat_cnt      <= 2'b00;
            state         <= S_REFILL;
          end
        end

        S_REFILL: begin
          if (mem_req_ack) begin
            mem_req_valid <= 1'b0;
          end
          if (mem_resp_valid) begin
            case (beat_cnt)
              2'b00: refill_buf[31:0]   <= mem_resp_rdata;
              2'b01: refill_buf[63:32]  <= mem_resp_rdata;
              2'b10: refill_buf[95:64]  <= mem_resp_rdata;
              2'b11: refill_buf[127:96] <= mem_resp_rdata;
            endcase
            beat_cnt <= beat_cnt + 2'd1;

            if (mem_resp_rlast || (beat_cnt == 2'b11)) begin
              mem_req_valid <= 1'b0;
              state         <= S_REFILL_MERGE;
            end
          end
        end

        S_REFILL_MERGE: begin
          // Merge the pending store word into the fetched line in its own
          // cycle; the array write data and index are then plain flops.
          rf_w0_oh  <= saved_victim_way ? {NUM_SETS{1'b0}} : (ONE << saved_index);
          rf_w1_oh  <= saved_victim_way ? (ONE << saved_index) : {NUM_SETS{1'b0}};
          rf_data[0] <= rw_word_oh[0] ? refill_mask_word : refill_buf[31:0];
          rf_data[1] <= rw_word_oh[1] ? refill_mask_word : refill_buf[63:32];
          rf_data[2] <= rw_word_oh[2] ? refill_mask_word : refill_buf[95:64];
          rf_data[3] <= rw_word_oh[3] ? refill_mask_word : refill_buf[127:96];
          rf_data[4] <= rw_word_oh[0] ? refill_mask_word : refill_buf[31:0];
          rf_data[5] <= rw_word_oh[1] ? refill_mask_word : refill_buf[63:32];
          rf_data[6] <= rw_word_oh[2] ? refill_mask_word : refill_buf[95:64];
          rf_data[7] <= rw_word_oh[3] ? refill_mask_word : refill_buf[127:96];
          resp_valid_r <= 1'b1;
          state         <= S_REFILL_DONE;
        end

        S_REFILL_DONE: begin
          state <= S_IDLE;
        end

        S_MMIO_WAIT: begin
          if (mem_req_ack) begin
            mem_req_valid <= 1'b0;
          end
          if (mem_resp_valid) begin
            mem_req_valid <= 1'b0;
            state         <= S_IDLE;
          end
        end

        S_FENCE_SETUP: begin
          // Drive the banked read from registered index copies, like a normal
          // access, so the scan does not take the 64:1 array mux path.
          for (j = 0; j < NUM_BANKS; j = j + 1)
            db_set[j] <= fence_set[IN_BANK-1:0];
          d_bank   <= fence_set[SET_WIDTH-1:IN_BANK];
          state    <= S_FENCE_BANK;
        end

        S_FENCE_BANK: begin
          // Decode the scan set one cycle before the clear strobes use it, so
          // the clear strobe does not carry the 64-bit index decode.
          fence_set_oh <= ONE << fence_set;
          state        <= S_FENCE_READ;
        end

        S_FENCE_READ: begin
          fe_w0_oh  <= fence_set_oh & {NUM_SETS{fe_do0}};
          fe_w1_oh  <= fence_set_oh & {NUM_SETS{fe_do1}};
          fence_line0  <= sel_line0;
          fence_line1  <= sel_line1;
          fence_valid0 <= sel_valid0w;
          fence_valid1 <= sel_valid1w;
          fence_dirty0 <= sel_dirty0w;
          fence_dirty1 <= sel_dirty1w;
          fence_tag0   <= sel_tag0w;
          fence_tag1   <= sel_tag1w;
          state        <= S_FENCE_CHECK;
        end

        S_FENCE_CHECK: begin
          if (fence_valid0 && fence_dirty0) begin
            dirty_line_buf        <= fence_line0;
            mem_req_valid         <= 1'b1;
            mem_req_write         <= 1'b1;
            mem_req_addr          <= {fence_tag0, fence_set, 4'b0000};
            mem_req_len           <= 8'd3;
            beat_cnt              <= 2'b00;
            state                 <= S_FENCE_WB;
          end else if (fence_valid1 && fence_dirty1) begin
            dirty_line_buf        <= fence_line1;
            mem_req_valid         <= 1'b1;
            mem_req_write         <= 1'b1;
            mem_req_addr          <= {fence_tag1, fence_set, 4'b0000};
            mem_req_len           <= 8'd3;
            beat_cnt              <= 2'b00;
            state                 <= S_FENCE_WB;
          end else begin
            if (fence_set == NUM_SETS - 1) begin
              fence_done_r <= 1'b1;
              state        <= S_IDLE;
            end else begin
              fence_set <= fence_set + 1'b1;
              state     <= S_FENCE_SETUP;
            end
          end
        end

        S_FENCE_WB: begin
          if (mem_req_ack) begin
            mem_req_valid <= 1'b0;
          end
          if (mem_write_ack) begin
            beat_cnt <= beat_cnt + 2'd1;
          end
          if (mem_resp_valid) begin
            mem_req_valid <= 1'b0;
            state         <= S_FENCE_SETUP;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
