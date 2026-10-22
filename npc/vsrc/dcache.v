`timescale 1ns / 1ps

// 2-way set-associative write-back D-cache.
//
// The sets are read as 8 banks of 8.  A request cycle registers a per-bank
// copy of the set index; the next cycle reads the banks, selects the
// requested bank, and captures the line and hit information.  The response or
// writeback decision is made in S_RESP.
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
  localparam BANK_WIDTH = 3;
  localparam NUM_BANKS  = 1 << BANK_WIDTH;
  localparam IN_BANK    = SET_WIDTH - BANK_WIDTH;

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

  // Registered request.
  reg [1:0]           saved_word_sel;
  reg [31:0]          saved_addr;
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

  // Registered write ports.  The one-hot write index keeps the 6-to-64
  // decode out of the path to the array flops.
  reg [NUM_SETS-1:0] st_wr_oh, rf_wr_oh, fe_clr_oh;
  reg                st_hit0, rf_way, fe_clr_w0, fe_clr_w1;
  reg [31:0]         st_word_r;
  reg [127:0]         cand_line0  [0:NUM_BANKS-1];
  reg [127:0]         cand_line1  [0:NUM_BANKS-1];
  reg [TAG_WIDTH-1:0] cand_tag0   [0:NUM_BANKS-1];
  reg [TAG_WIDTH-1:0] cand_tag1   [0:NUM_BANKS-1];
  reg                 cand_valid0 [0:NUM_BANKS-1];
  reg                 cand_valid1 [0:NUM_BANKS-1];
  reg                 cand_dirty0 [0:NUM_BANKS-1];
  reg                 cand_dirty1 [0:NUM_BANKS-1];
  reg                 cand_lru    [0:NUM_BANKS-1];
  reg                 cand_eq0    [0:NUM_BANKS-1];
  reg                 cand_eq1    [0:NUM_BANKS-1];
  reg         hit0_r, hit1_r;
  reg         valid0_r, valid1_r;
  reg         dirty0_r, dirty1_r;

  // Refill / writeback state.
  reg [127:0] dirty_line_buf;
  reg [127:0] refill_buf;
  reg [127:0] refill_line_r;
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

  wire [BANK_WIDTH-1:0] bank_w    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH+BANK_WIDTH];
  wire [IN_BANK-1:0]    set_w     = req_addr[OFFSET_WIDTH+BANK_WIDTH-1 : OFFSET_WIDTH];
  wire [1:0]            word_sel_w = req_addr[3:2];

  wire [SET_WIDTH-1:0] saved_index = saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] saved_tag   = saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];

  wire is_mmio = (req_addr < 32'h80000000) || (req_addr >= 32'h88000000);

  // Word-plane storage: four 32-bit arrays per way keep the read mux width at
  // 32 bits instead of 128 bits.  The sets are read as 8 banks of 8; each
  // bank is driven by its own registered copy of the set index so the index
  // fanout stays inside a bank.
  reg [BANK_WIDTH-1:0] d_bank;
  reg [TAG_WIDTH-1:0]  d_tag;
  reg [IN_BANK-1:0]    db_set [0:NUM_BANKS-1];

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

  wire hit0_now = cand_valid0[d_bank] && cand_eq0[d_bank] &&
                  (cand_tag0[d_bank][TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
  wire hit1_now = cand_valid1[d_bank] && cand_eq1[d_bank] &&
                  (cand_tag1[d_bank][TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
  wire [127:0] cmp_line = hit0_now ? cand_line0[d_bank] : cand_line1[d_bank];
  wire [31:0]  cmp_word = (saved_word_sel == 2'b00) ? cmp_line[31:0] :
                          (saved_word_sel == 2'b01) ? cmp_line[63:32] :
                          (saved_word_sel == 2'b10) ? cmp_line[95:64] :
                                                      cmp_line[127:96];
  wire [31:0]  cmp_merged = apply_mask(cmp_word, saved_wdata, saved_wmask);

  wire [127:0]         sel_line0  = bank_line0[d_bank];
  wire [127:0]         sel_line1  = bank_line1[d_bank];
  wire [TAG_WIDTH-1:0] sel_tag0   = bank_tag0[d_bank];
  wire [TAG_WIDTH-1:0] sel_tag1   = bank_tag1[d_bank];
  wire                 sel_valid0 = bank_valid0[d_bank];
  wire                 sel_valid1 = bank_valid1[d_bank];
  wire                 sel_dirty0 = bank_dirty0[d_bank];
  wire                 sel_dirty1 = bank_dirty1[d_bank];
  wire                 sel_lru    = bank_lru[d_bank];

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

  wire [127:0] resp_line = hit0_r ? line0_r : line1_r;
  wire [31:0]  resp_hit_word =
      (saved_word_sel == 2'b00) ? resp_line[31:0] :
      (saved_word_sel == 2'b01) ? resp_line[63:32] :
      (saved_word_sel == 2'b10) ? resp_line[95:64] :
                                  resp_line[127:96];
  wire [31:0]  resp_merged_word = apply_mask(resp_hit_word, saved_wdata, saved_wmask);

  wire [31:0]  refill_word =
      (saved_word_sel == 2'b00) ? refill_buf[31:0] :
      (saved_word_sel == 2'b01) ? refill_buf[63:32] :
      (saved_word_sel == 2'b10) ? refill_buf[95:64] :
                                  refill_buf[127:96];
  wire [31:0]  refill_resp_word = saved_write ? apply_mask(refill_word, saved_wdata, saved_wmask) : refill_word;

  wire [127:0] refill_merged =
      (saved_word_sel == 2'b00) ? {refill_buf[127:32], apply_mask(refill_buf[31:0],   saved_wdata, saved_wmask)} :
      (saved_word_sel == 2'b01) ? {refill_buf[127:64], apply_mask(refill_buf[63:32],  saved_wdata, saved_wmask), refill_buf[31:0]} :
      (saved_word_sel == 2'b10) ? {refill_buf[127:96], apply_mask(refill_buf[95:64],  saved_wdata, saved_wmask), refill_buf[63:0]} :
                                  {apply_mask(refill_buf[127:96], saved_wdata, saved_wmask), refill_buf[95:0]};
  // A refill for a read miss writes the fetched line unchanged; only a store
  // miss merges the pending word.
  wire [127:0] refill_store_line = saved_write ? refill_merged : refill_buf;

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

  integer j;
  always @(posedge clock) begin
    if (reset) begin
      state            <= S_IDLE;
      mem_req_valid    <= 1'b0;
      mem_req_write    <= 1'b0;
      mem_req_addr     <= 32'b0;
      mem_req_len      <= 8'd0;
      saved_word_sel   <= 2'b0;
      saved_addr       <= 32'b0;
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
      refill_line_r    <= 128'b0;
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
      st_wr_oh         <= {NUM_SETS{1'b0}};
      rf_wr_oh         <= {NUM_SETS{1'b0}};
      fe_clr_oh        <= {NUM_SETS{1'b0}};
      st_hit0          <= 1'b0;
      rf_way           <= 1'b0;
      fe_clr_w0        <= 1'b0;
      fe_clr_w1        <= 1'b0;
      st_word_r        <= 32'b0;
      for (j = 0; j < NUM_BANKS; j = j + 1) begin
        db_set[j]     <= {IN_BANK{1'b0}};
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
      st_wr_oh     <= {NUM_SETS{1'b0}};
      rf_wr_oh     <= {NUM_SETS{1'b0}};
      fe_clr_oh    <= {NUM_SETS{1'b0}};

      // Storage write ports, driven by the registered one-hot indices.
      for (j = 0; j < NUM_SETS; j = j + 1) begin
        if (fe_clr_oh[j]) begin
          if (fe_clr_w0) begin
            way0_valid[j] <= 1'b0;
            way0_dirty[j] <= 1'b0;
          end
          if (fe_clr_w1) begin
            way1_valid[j] <= 1'b0;
            way1_dirty[j] <= 1'b0;
          end
        end
        if (st_wr_oh[j]) begin
          lru[j] <= st_hit0;
          if (st_hit0) begin
            way0_dirty[j] <= 1'b1;
            case (saved_word_sel)
              2'b00: way0_word0[j] <= st_word_r;
              2'b01: way0_word1[j] <= st_word_r;
              2'b10: way0_word2[j] <= st_word_r;
              2'b11: way0_word3[j] <= st_word_r;
            endcase
          end else begin
            way1_dirty[j] <= 1'b1;
            case (saved_word_sel)
              2'b00: way1_word0[j] <= st_word_r;
              2'b01: way1_word1[j] <= st_word_r;
              2'b10: way1_word2[j] <= st_word_r;
              2'b11: way1_word3[j] <= st_word_r;
            endcase
          end
        end
        if (rf_wr_oh[j]) begin
          if (rf_way) begin
            way1_valid[j] <= 1'b1;
            way1_tag[j]   <= saved_tag;
            way1_dirty[j] <= saved_write;
            way1_word0[j] <= refill_line_r[31:0];
            way1_word1[j] <= refill_line_r[63:32];
            way1_word2[j] <= refill_line_r[95:64];
            way1_word3[j] <= refill_line_r[127:96];
            lru[j]        <= 1'b0;
          end else begin
            way0_valid[j] <= 1'b1;
            way0_tag[j]   <= saved_tag;
            way0_dirty[j] <= saved_write;
            way0_word0[j] <= refill_line_r[31:0];
            way0_word1[j] <= refill_line_r[63:32];
            way0_word2[j] <= refill_line_r[95:64];
            way0_word3[j] <= refill_line_r[127:96];
            lru[j]        <= 1'b1;
          end
        end
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
            saved_word_sel <= word_sel_w;

            if (is_mmio) begin
              mem_req_valid <= 1'b1;
              mem_req_write <= req_write;
              mem_req_addr  <= req_addr;
              mem_req_len   <= 8'd0;
              state         <= S_MMIO_WAIT;
            end else begin
              // Register the address first; the bank read runs from per-bank
              // index copies in the next cycle.
              for (j = 0; j < NUM_BANKS; j = j + 1)
                db_set[j] <= set_w;
              d_bank <= bank_w;
              d_tag  <= req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
              state  <= S_BANK;
            end
          end
        end

        S_BANK: begin
          for (j = 0; j < NUM_BANKS; j = j + 1) begin
            cand_line0[j]  <= bank_line0[j];
            cand_line1[j]  <= bank_line1[j];
            cand_tag0[j]   <= bank_tag0[j];
            cand_tag1[j]   <= bank_tag1[j];
            cand_valid0[j] <= bank_valid0[j];
            cand_valid1[j] <= bank_valid1[j];
            cand_dirty0[j] <= bank_dirty0[j];
            cand_dirty1[j] <= bank_dirty1[j];
            cand_lru[j]    <= bank_lru[j];
            cand_eq0[j]    <= (bank_tag0[j][TAG_WIDTH/2-1:0] == d_tag[TAG_WIDTH/2-1:0]);
            cand_eq1[j]    <= (bank_tag1[j][TAG_WIDTH/2-1:0] == d_tag[TAG_WIDTH/2-1:0]);
          end
          state <= S_CMP;
        end

        S_CMP: begin
          st_wr_oh  <= (saved_write && (hit0_now || hit1_now)) ? (ONE << saved_index)
                                                               : {NUM_SETS{1'b0}};
          st_hit0   <= hit0_now;
          st_word_r <= cmp_merged;
          line0_r   <= cand_line0[d_bank];
          line1_r   <= cand_line1[d_bank];
          sel_tag0_r <= cand_tag0[d_bank];
          sel_tag1_r <= cand_tag1[d_bank];
          sel_valid0_r <= cand_valid0[d_bank];
          sel_valid1_r <= cand_valid1[d_bank];
          sel_dirty0_r <= cand_dirty0[d_bank];
          sel_dirty1_r <= cand_dirty1[d_bank];
          sel_lru_r    <= cand_lru[d_bank];
          resp_valid_r <= (cand_valid0[d_bank] && cand_eq0[d_bank] &&
                           (cand_tag0[d_bank][TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2])) ||
                          (cand_valid1[d_bank] && cand_eq1[d_bank] &&
                           (cand_tag1[d_bank][TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]));
          hit0_r   <= cand_valid0[d_bank] && cand_eq0[d_bank] &&
                      (cand_tag0[d_bank][TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
          hit1_r   <= cand_valid1[d_bank] && cand_eq1[d_bank] &&
                      (cand_tag1[d_bank][TAG_WIDTH-1:TAG_WIDTH/2] == d_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
          valid0_r <= cand_valid0[d_bank];
          valid1_r <= cand_valid1[d_bank];
          dirty0_r <= cand_dirty0[d_bank];
          dirty1_r <= cand_dirty1[d_bank];
          state    <= S_RESP;
        end

        S_RESP: begin
          if (hit0_r || hit1_r) begin
            hit_count <= hit_count + 32'd1;
            state     <= S_IDLE;
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
              mem_req_addr  <= {saved_addr[31:4], 4'b0000};
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
            mem_req_addr  <= {saved_addr[31:4], 4'b0000};
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
          refill_line_r <= refill_store_line;
          rf_wr_oh      <= ONE << saved_index;
          rf_way        <= saved_victim_way;
          resp_valid_r  <= 1'b1;
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
          d_bank <= fence_set[SET_WIDTH-1:IN_BANK];
          state  <= S_FENCE_BANK;
        end

        S_FENCE_BANK: begin
          for (j = 0; j < NUM_BANKS; j = j + 1) begin
            cand_line0[j]  <= bank_line0[j];
            cand_line1[j]  <= bank_line1[j];
            cand_tag0[j]   <= bank_tag0[j];
            cand_tag1[j]   <= bank_tag1[j];
            cand_valid0[j] <= bank_valid0[j];
            cand_valid1[j] <= bank_valid1[j];
            cand_dirty0[j] <= bank_dirty0[j];
            cand_dirty1[j] <= bank_dirty1[j];
            cand_lru[j]    <= bank_lru[j];
          end
          state <= S_FENCE_READ;
        end

        S_FENCE_READ: begin
          fe_clr_oh  <= ONE << fence_set;
          fe_clr_w0  <= (fence_valid0 && fence_dirty0) ||
                        (!(fence_valid0 && fence_dirty0) && !(fence_valid1 && fence_dirty1));
          fe_clr_w1  <= !(fence_valid0 && fence_dirty0);
          fence_line0  <= cand_line0[d_bank];
          fence_line1  <= cand_line1[d_bank];
          fence_valid0 <= cand_valid0[d_bank];
          fence_valid1 <= cand_valid1[d_bank];
          fence_dirty0 <= cand_dirty0[d_bank];
          fence_dirty1 <= cand_dirty1[d_bank];
          fence_tag0   <= cand_tag0[d_bank];
          fence_tag1   <= cand_tag1[d_bank];
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
