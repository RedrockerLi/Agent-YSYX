`timescale 1ns / 1ps

// 2-way set-associative instruction cache.
//
// The 64 sets are read as 16 banks of 4 sets.  A request cycle registers a
// per-bank copy of the set index; the next cycle reads the banks and selects
// the requested bank.  Every index copy drives only its own bank, so the
// address fanout stays local to a bank instead of spanning the whole array.
//
// The refill port is registered with per-way one-hot strobes and a data
// replica per way, so the way select and the 128-bit line are not broadcast
// to the whole array.
module icache #(
  parameter SET_WIDTH    = 6,               // 64 sets
  parameter OFFSET_WIDTH = 4,               // 16 bytes (4 words per line)
  parameter TAG_WIDTH    = 22               // 32 - 6 - 4 = 22 bits
)(
  input             clock,
  input             reset,

  // CPU Interface
  input             req_valid,
  input      [31:0] req_addr,
  output            req_ready,
  output            resp_valid,
  output     [127:0] resp_line,
  output     [1:0]  resp_word_sel,
  input             flush,
  input             fence_i,

  // Memory / Refill Interface
  input             mem_req_ack,
  output reg        mem_req_valid,
  output reg [31:0] mem_req_addr,
  output reg [7:0]  mem_req_len,
  input             mem_resp_valid,
  input      [31:0] mem_resp_rdata,
  input             mem_resp_rlast,

  // Performance Counters
  output reg [31:0] hit_count,
  output reg [31:0] miss_count
);

  localparam NUM_SETS   = 1 << SET_WIDTH;
  localparam [NUM_SETS-1:0] ONE = 1;
  localparam [NUM_BANKS-1:0] ONE_B = 1;
  localparam BANK_WIDTH = 4;
  localparam NUM_BANKS  = 1 << BANK_WIDTH;
  localparam IN_BANK    = SET_WIDTH - BANK_WIDTH;

  reg                 way0_valid [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way0_tag   [NUM_SETS-1:0];
  reg [127:0]         way0_data  [NUM_SETS-1:0];

  reg                 way1_valid [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way1_tag   [NUM_SETS-1:0];
  reg [127:0]         way1_data  [NUM_SETS-1:0];

  reg                 lru        [NUM_SETS-1:0];

  localparam S_IDLE        = 3'd0;
  localparam S_BANK        = 3'd1;
  localparam S_CMP         = 3'd6;
  localparam S_RESP        = 3'd2;
  localparam S_REFILL      = 3'd3;
  localparam S_REFILL_DONE = 3'd4;
  localparam S_DRAIN       = 3'd5;

  reg [2:0]   state;
  reg         mem_inflight;

  reg [31:0]  saved_addr;
  reg [1:0]   saved_word_sel;

  // Request address decode.
  wire [BANK_WIDTH-1:0] req_bank    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH+IN_BANK];
  wire [IN_BANK-1:0]    req_set     = req_addr[OFFSET_WIDTH+IN_BANK-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0]  req_tag     = req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [1:0]            req_word    = req_addr[3:2];

  // Registered request fields.  The bank select is kept one-hot so each
  // select net drives a sixteenth of the mux gates a binary select would.
  reg [BANK_WIDTH-1:0] s1_bank;
  reg [NUM_BANKS-1:0]  s1_oh;
  reg [TAG_WIDTH-1:0]  s1_tag;

  // Per-bank set index copies.
  reg [IN_BANK-1:0] b_set [0:NUM_BANKS-1];

  // Bank reads: 4:1 set mux per bank, both ways.  Each bank uses its own
  // index register.
  wire [127:0]         bank_line0  [0:NUM_BANKS-1];
  wire [127:0]         bank_line1  [0:NUM_BANKS-1];
  wire [TAG_WIDTH-1:0] bank_tag0   [0:NUM_BANKS-1];
  wire [TAG_WIDTH-1:0] bank_tag1   [0:NUM_BANKS-1];
  wire                 bank_valid0 [0:NUM_BANKS-1];
  wire                 bank_valid1 [0:NUM_BANKS-1];
  wire                 bank_lru    [0:NUM_BANKS-1];

  genvar gb;
  generate
    for (gb = 0; gb < NUM_BANKS; gb = gb + 1) begin : g_bank
      wire [SET_WIDTH-1:0] rd_idx = {gb[BANK_WIDTH-1:0], b_set[gb]};
      assign bank_line0[gb]  = way0_data[rd_idx];
      assign bank_line1[gb]  = way1_data[rd_idx];
      assign bank_tag0[gb]   = way0_tag[rd_idx];
      assign bank_tag1[gb]   = way1_tag[rd_idx];
      assign bank_valid0[gb] = way0_valid[rd_idx];
      assign bank_valid1[gb] = way1_valid[rd_idx];
      assign bank_lru[gb]    = lru[rd_idx];
    end
  endgenerate

  // Banks are captured in S_BANK; S_CMP selects the requested bank and
  // compares its tag, so neither cycle carries both a 4-level read and a
  // 22-bit compare.
  reg [127:0]          cand_line0  [0:NUM_BANKS-1];
  reg [127:0]          cand_line1  [0:NUM_BANKS-1];
  reg [TAG_WIDTH-1:0]  cand_tag0   [0:NUM_BANKS-1];
  reg [TAG_WIDTH-1:0]  cand_tag1   [0:NUM_BANKS-1];
  reg                  cand_valid0 [0:NUM_BANKS-1];
  reg                  cand_valid1 [0:NUM_BANKS-1];
  reg                  cand_lru    [0:NUM_BANKS-1];
  reg                  cand_eq0    [0:NUM_BANKS-1];
  reg                  cand_eq1    [0:NUM_BANKS-1];
  reg                  lru_r;

  // One-hot bank select of the captured candidates.
  reg  [127:0]         sel_line0, sel_line1;
  reg  [TAG_WIDTH-1:0] sel_tag0, sel_tag1;
  reg                  sel_valid0, sel_valid1, sel_eq0, sel_eq1, sel_lru;
  integer k;
  always @(*) begin
    sel_line0  = 128'b0;
    sel_line1  = 128'b0;
    sel_tag0   = {TAG_WIDTH{1'b0}};
    sel_tag1   = {TAG_WIDTH{1'b0}};
    sel_valid0 = 1'b0;
    sel_valid1 = 1'b0;
    sel_eq0    = 1'b0;
    sel_eq1    = 1'b0;
    sel_lru    = 1'b0;
    for (k = 0; k < NUM_BANKS; k = k + 1) begin
      sel_line0  = sel_line0  | ({128{s1_oh[k]}}       & cand_line0[k]);
      sel_line1  = sel_line1  | ({128{s1_oh[k]}}       & cand_line1[k]);
      sel_tag0   = sel_tag0   | ({TAG_WIDTH{s1_oh[k]}} & cand_tag0[k]);
      sel_tag1   = sel_tag1   | ({TAG_WIDTH{s1_oh[k]}} & cand_tag1[k]);
      sel_valid0 = sel_valid0 | (s1_oh[k] & cand_valid0[k]);
      sel_valid1 = sel_valid1 | (s1_oh[k] & cand_valid1[k]);
      sel_eq0    = sel_eq0    | (s1_oh[k] & cand_eq0[k]);
      sel_eq1    = sel_eq1    | (s1_oh[k] & cand_eq1[k]);
      sel_lru    = sel_lru    | (s1_oh[k] & cand_lru[k]);
    end
  end

  // Selected hit.
  reg         hit0_r, hit1_r;

  // Refill state.
  reg [1:0]   refill_beat;
  reg [127:0] refill_buf;
  reg         victim_way;

  // Registered refill write port: per-way one-hot strobe, per-way data copy.
  reg [NUM_SETS-1:0]  lru_oh;
  reg                 lru_val_r;
  reg [NUM_SETS-1:0]  rf_w0_oh, rf_w1_oh;
  reg [TAG_WIDTH-1:0] rf_tag_r;
  reg [127:0]         rf_data0, rf_data1;

  assign req_ready  = (state == S_IDLE) && !flush && !fence_i;
  // Registered response: hit and refill data are both captured into the same
  // register, so the fetch FIFO never sees a data mux over the line.
  reg resp_valid_r;
  reg [127:0] resp_line_r;
  assign resp_valid = resp_valid_r && !flush && !fence_i;
  assign resp_line  = resp_line_r;

  // Hit decision of the compare cycle, available before the hit flops.
  wire hit0_c = sel_valid0 && sel_eq0 &&
                (sel_tag0[TAG_WIDTH-1:TAG_WIDTH/2] == s1_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
  wire hit1_c = sel_valid1 && sel_eq1 &&
                (sel_tag1[TAG_WIDTH-1:TAG_WIDTH/2] == s1_tag[TAG_WIDTH-1:TAG_WIDTH/2]);
  assign resp_word_sel = saved_word_sel;

  wire [SET_WIDTH-1:0] saved_index = saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] saved_tag   = saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [2:0] words_saved = 3'd4 - {1'b0, saved_word_sel};

  integer i;
  always @(posedge clock) begin
    if (reset) begin
      state           <= S_IDLE;
      mem_req_valid   <= 1'b0;
      mem_req_addr    <= 32'b0;
      mem_req_len     <= 8'd3;
      refill_beat     <= 2'b0;
      refill_buf      <= 128'b0;
      saved_addr      <= 32'b0;
      saved_word_sel  <= 2'b0;
      s1_bank         <= {BANK_WIDTH{1'b0}};
      s1_oh           <= {NUM_BANKS{1'b0}};
      s1_tag          <= {TAG_WIDTH{1'b0}};
      resp_line_r     <= 128'b0;
      hit0_r          <= 1'b0;
      hit1_r          <= 1'b0;
      lru_r           <= 1'b0;
      victim_way      <= 1'b0;
      mem_inflight    <= 1'b0;
      resp_valid_r    <= 1'b0;
      lru_oh          <= {NUM_SETS{1'b0}};
      lru_val_r       <= 1'b0;
      rf_w0_oh        <= {NUM_SETS{1'b0}};
      rf_w1_oh        <= {NUM_SETS{1'b0}};
      rf_tag_r        <= {TAG_WIDTH{1'b0}};
      rf_data0        <= 128'b0;
      rf_data1        <= 128'b0;
      hit_count       <= 32'b0;
      miss_count      <= 32'b0;
      for (i = 0; i < NUM_BANKS; i = i + 1) begin
        b_set[i]       <= {IN_BANK{1'b0}};
        cand_line0[i]  <= 128'b0;
        cand_line1[i]  <= 128'b0;
        cand_tag0[i]   <= {TAG_WIDTH{1'b0}};
        cand_tag1[i]   <= {TAG_WIDTH{1'b0}};
        cand_valid0[i] <= 1'b0;
        cand_valid1[i] <= 1'b0;
        cand_lru[i]    <= 1'b0;
        cand_eq0[i]    <= 1'b0;
        cand_eq1[i]    <= 1'b0;
      end
      for (i = 0; i < NUM_SETS; i = i + 1) begin
        way0_valid[i] <= 1'b0;
        way1_valid[i] <= 1'b0;
        lru[i]        <= 1'b0;
      end
    end else if (fence_i || flush) begin
      if (fence_i) begin
        for (i = 0; i < NUM_SETS; i = i + 1) begin
          way0_valid[i] <= 1'b0;
          way1_valid[i] <= 1'b0;
          lru[i]        <= 1'b0;
        end
      end
      mem_req_valid <= 1'b0;
      resp_valid_r  <= 1'b0;
      if ((mem_inflight || mem_req_ack) && !(mem_resp_valid && mem_resp_rlast)) begin
        mem_inflight <= 1'b1;
        state        <= S_DRAIN;
      end else begin
        mem_inflight <= 1'b0;
        state        <= S_IDLE;
      end
    end else begin
      resp_valid_r <= 1'b0;
      lru_oh       <= {NUM_SETS{1'b0}};
      rf_w0_oh     <= {NUM_SETS{1'b0}};
      rf_w1_oh     <= {NUM_SETS{1'b0}};

      // Refill write port: one-hot set strobe per way, with a data copy per
      // way so neither the way bit nor the line is broadcast across the array.
      for (i = 0; i < NUM_SETS; i = i + 1) begin
        if (rf_w0_oh[i]) begin
          way0_valid[i] <= 1'b1;
          way0_tag[i]   <= rf_tag_r;
          way0_data[i]  <= rf_data0;
          lru[i]        <= 1'b1;
        end
        if (rf_w1_oh[i]) begin
          way1_valid[i] <= 1'b1;
          way1_tag[i]   <= rf_tag_r;
          way1_data[i]  <= rf_data1;
          lru[i]        <= 1'b0;
        end
        if (lru_oh[i])
          lru[i] <= lru_val_r;
      end

      // Bank read capture runs every cycle: the per-bank index registers are
      // stable across the read and compare cycles, so gating the capture with
      // the state decode would only put a wide enable net in front of the
      // candidate flops.
      for (i = 0; i < NUM_BANKS; i = i + 1) begin
        cand_line0[i]  <= bank_line0[i];
        cand_line1[i]  <= bank_line1[i];
        cand_tag0[i]   <= bank_tag0[i];
        cand_tag1[i]   <= bank_tag1[i];
        cand_valid0[i] <= bank_valid0[i];
        cand_valid1[i] <= bank_valid1[i];
        cand_lru[i]    <= bank_lru[i];
        cand_eq0[i]    <= (bank_tag0[i][TAG_WIDTH/2-1:0] == s1_tag[TAG_WIDTH/2-1:0]);
        cand_eq1[i]    <= (bank_tag1[i][TAG_WIDTH/2-1:0] == s1_tag[TAG_WIDTH/2-1:0]);
      end

      case (state)
        S_IDLE: begin
          if (req_valid) begin
            saved_addr     <= req_addr;
            saved_word_sel <= req_word;
            s1_bank        <= req_bank;
            s1_oh          <= ONE_B << req_bank;
            s1_tag         <= req_tag;
            for (i = 0; i < NUM_BANKS; i = i + 1)
              b_set[i] <= req_set;
            state <= S_BANK;
          end
        end

        S_BANK: begin
          state <= S_CMP;
        end

        S_CMP: begin
          resp_line_r  <= hit0_c ? sel_line0 : sel_line1;
          hit0_r       <= hit0_c;
          hit1_r       <= hit1_c;
          resp_valid_r <= hit0_c || hit1_c;
          lru_r        <= sel_lru;
          state        <= S_RESP;
        end

        S_RESP: begin
          if (hit0_r || hit1_r) begin
            hit_count <= hit_count + {29'b0, words_saved};
            lru_oh    <= ONE << saved_index;
            lru_val_r <= hit0_r;
            state     <= S_IDLE;
          end else begin
            miss_count    <= miss_count + {29'b0, words_saved};
            victim_way    <= lru_r;
            mem_req_valid <= 1'b1;
            mem_req_addr  <= {saved_addr[31:4], 4'b0000};
            mem_req_len   <= 8'd3;
            refill_beat   <= 2'b00;
            state         <= S_REFILL;
          end
        end

        S_REFILL: begin
          if (mem_req_ack) begin
            mem_req_valid <= 1'b0;
            mem_inflight  <= 1'b1;
          end
          if (mem_resp_valid) begin
            case (refill_beat)
              2'b00: refill_buf[31:0]   <= mem_resp_rdata;
              2'b01: refill_buf[63:32]  <= mem_resp_rdata;
              2'b10: refill_buf[95:64]  <= mem_resp_rdata;
              2'b11: refill_buf[127:96] <= mem_resp_rdata;
            endcase
            refill_beat <= refill_beat + 2'd1;

            if (mem_resp_rlast || (refill_beat == 2'b11)) begin
              mem_req_valid <= 1'b0;
              mem_inflight  <= 1'b0;
              state         <= S_REFILL_DONE;
            end
          end
        end

        S_REFILL_DONE: begin
          // Register the refill write port from the completed line; the array
          // write then runs in the next cycle from plain flops.
          rf_w0_oh <= victim_way ? {NUM_SETS{1'b0}} : (ONE << saved_index);
          rf_w1_oh <= victim_way ? (ONE << saved_index) : {NUM_SETS{1'b0}};
          rf_tag_r <= saved_tag;
          rf_data0 <= refill_buf;
          rf_data1 <= refill_buf;
          resp_line_r  <= refill_buf;
          resp_valid_r <= 1'b1;
          state        <= S_IDLE;
        end

        S_DRAIN: begin
          mem_req_valid <= 1'b0;
          if (mem_resp_valid && mem_resp_rlast) begin
            mem_inflight <= 1'b0;
            state        <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
