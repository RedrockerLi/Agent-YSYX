`timescale 1ns / 1ps

// 2-way set-associative instruction cache with a banked, two-cycle line read.
//
// The 64 sets are split into 8 banks of 8 sets.  The request cycle reads the
// 8:1 set mux inside every bank into bank registers; the next cycle selects
// the bank and checks tags.  This keeps the 64:1 mux off one cycle while the
// fetch FIFO absorbs the extra read latency.
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
  localparam BANK_WIDTH = 3;
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
  localparam S_READ2       = 3'd1;
  localparam S_RESP        = 3'd2;
  localparam S_REFILL      = 3'd3;
  localparam S_REFILL_DONE = 3'd4;
  localparam S_DRAIN       = 3'd5;

  reg [2:0]   state;
  reg         mem_inflight;

  reg [31:0]  saved_addr;
  reg [1:0]   saved_word_sel;

  // Request address decode.
  wire [BANK_WIDTH-1:0] req_bank    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH+BANK_WIDTH];
  wire [IN_BANK-1:0]    req_set     = req_addr[OFFSET_WIDTH+BANK_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0]  req_tag     = req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [1:0]            req_word    = req_addr[3:2];

  // Bank reads: 8:1 set mux per bank, both ways.
  wire [127:0]         rd0_line  [0:NUM_BANKS-1];
  wire [127:0]         rd1_line  [0:NUM_BANKS-1];
  wire [TAG_WIDTH-1:0] rd0_tag   [0:NUM_BANKS-1];
  wire [TAG_WIDTH-1:0] rd1_tag   [0:NUM_BANKS-1];
  wire                 rd0_valid [0:NUM_BANKS-1];
  wire                 rd1_valid [0:NUM_BANKS-1];

  genvar gb;
  generate
    for (gb = 0; gb < NUM_BANKS; gb = gb + 1) begin : g_bank
      wire [SET_WIDTH-1:0] rd_idx = {gb[BANK_WIDTH-1:0], req_set};
      assign rd0_line[gb]  = way0_data[rd_idx];
      assign rd1_line[gb]  = way1_data[rd_idx];
      assign rd0_tag[gb]   = way0_tag[rd_idx];
      assign rd1_tag[gb]   = way1_tag[rd_idx];
      assign rd0_valid[gb] = way0_valid[rd_idx];
      assign rd1_valid[gb] = way1_valid[rd_idx];
    end
  endgenerate

  // Stage-1 registers (bank candidates).
  reg [127:0]         s1_line0  [0:NUM_BANKS-1];
  reg [127:0]         s1_line1  [0:NUM_BANKS-1];
  reg [TAG_WIDTH-1:0] s1_tag0   [0:NUM_BANKS-1];
  reg [TAG_WIDTH-1:0] s1_tag1   [0:NUM_BANKS-1];
  reg                 s1_valid0 [0:NUM_BANKS-1];
  reg                 s1_valid1 [0:NUM_BANKS-1];
  reg [BANK_WIDTH-1:0] s1_bank;
  reg [TAG_WIDTH-1:0]  s1_tag;

  // Stage-2 selected line and hit.
  reg [127:0] line0_r, line1_r;
  reg         hit0_r, hit1_r;

  // Refill state.
  reg [1:0]   refill_beat;
  reg [127:0] refill_buf;
  reg         victim_way;

  assign req_ready  = (state == S_IDLE) && !flush && !fence_i;
  assign resp_valid = ((state == S_RESP && (hit0_r || hit1_r)) ||
                       (state == S_REFILL_DONE)) && !flush && !fence_i;
  assign resp_line  = (state == S_RESP) ? (hit0_r ? line0_r : line1_r) : refill_buf;
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
      line0_r         <= 128'b0;
      line1_r         <= 128'b0;
      hit0_r          <= 1'b0;
      hit1_r          <= 1'b0;
      victim_way      <= 1'b0;
      mem_inflight    <= 1'b0;
      hit_count       <= 32'b0;
      miss_count      <= 32'b0;
      s1_bank         <= {BANK_WIDTH{1'b0}};
      s1_tag          <= {TAG_WIDTH{1'b0}};
      for (i = 0; i < NUM_BANKS; i = i + 1) begin
        s1_line0[i]  <= 128'b0;
        s1_line1[i]  <= 128'b0;
        s1_tag0[i]   <= {TAG_WIDTH{1'b0}};
        s1_tag1[i]   <= {TAG_WIDTH{1'b0}};
        s1_valid0[i] <= 1'b0;
        s1_valid1[i] <= 1'b0;
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
      if ((mem_inflight || mem_req_ack) && !(mem_resp_valid && mem_resp_rlast)) begin
        mem_inflight <= 1'b1;
        state        <= S_DRAIN;
      end else begin
        mem_inflight <= 1'b0;
        state        <= S_IDLE;
      end
    end else begin
      case (state)
        S_IDLE: begin
          if (req_valid) begin
            saved_addr     <= req_addr;
            saved_word_sel <= req_word;
            s1_bank        <= req_bank;
            s1_tag         <= req_tag;
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
              s1_line0[i]  <= rd0_line[i];
              s1_line1[i]  <= rd1_line[i];
              s1_tag0[i]   <= rd0_tag[i];
              s1_tag1[i]   <= rd1_tag[i];
              s1_valid0[i] <= rd0_valid[i];
              s1_valid1[i] <= rd1_valid[i];
            end
            state <= S_READ2;
          end
        end

        S_READ2: begin
          line0_r <= s1_line0[s1_bank];
          line1_r <= s1_line1[s1_bank];
          hit0_r  <= s1_valid0[s1_bank] && (s1_tag0[s1_bank] == s1_tag);
          hit1_r  <= s1_valid1[s1_bank] && (s1_tag1[s1_bank] == s1_tag);
          state   <= S_RESP;
        end

        S_RESP: begin
          if (hit0_r || hit1_r) begin
            hit_count       <= hit_count + {29'b0, words_saved};
            lru[saved_index] <= hit0_r ? 1'b1 : 1'b0;
            state           <= S_IDLE;
          end else begin
            miss_count    <= miss_count + {29'b0, words_saved};
            victim_way    <= lru[saved_index];
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
          if (victim_way == 1'b0) begin
            way0_valid[saved_index] <= 1'b1;
            way0_tag[saved_index]   <= saved_tag;
            way0_data[saved_index]  <= refill_buf;
            lru[saved_index]        <= 1'b1;
          end else begin
            way1_valid[saved_index] <= 1'b1;
            way1_tag[saved_index]   <= saved_tag;
            way1_data[saved_index]  <= refill_buf;
            lru[saved_index]        <= 1'b0;
          end
          state <= S_IDLE;
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
