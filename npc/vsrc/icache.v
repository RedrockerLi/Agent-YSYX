`timescale 1ns / 1ps

// 2-way set-associative instruction cache with a synchronous line read.
// A request is accepted in S_IDLE, the array read and tag check are captured
// at that edge, and the 128-bit line is returned in S_RESP.
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

  localparam NUM_SETS = 1 << SET_WIDTH;

  reg                 way0_valid [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way0_tag   [NUM_SETS-1:0];
  reg [127:0]         way0_data  [NUM_SETS-1:0];

  reg                 way1_valid [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way1_tag   [NUM_SETS-1:0];
  reg [127:0]         way1_data  [NUM_SETS-1:0];

  reg                 lru        [NUM_SETS-1:0];

  localparam S_IDLE        = 3'd0;
  localparam S_RESP        = 3'd1;
  localparam S_REFILL      = 3'd2;
  localparam S_REFILL_DONE = 3'd3;
  localparam S_DRAIN       = 3'd4;

  reg [2:0]   state;
  reg         mem_inflight;

  reg [31:0]  saved_addr;
  reg [1:0]   saved_word_sel;
  reg [127:0] line0_r, line1_r;
  reg         hit0_r, hit1_r;

  reg [1:0]   refill_beat;
  reg [127:0] refill_buf;
  reg         victim_way;

  wire [SET_WIDTH-1:0] index_w    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] tag_w      = req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [1:0]           word_sel_w = req_addr[3:2];

  wire [SET_WIDTH-1:0] saved_index = saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] saved_tag   = saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];

  wire hit0_w = way0_valid[index_w] && (way0_tag[index_w] == tag_w);
  wire hit1_w = way1_valid[index_w] && (way1_tag[index_w] == tag_w);

  wire [127:0] line0_w = way0_data[index_w];
  wire [127:0] line1_w = way1_data[index_w];

  wire [2:0] words_served = 3'd4 - {1'b0, word_sel_w};

  assign req_ready  = (state == S_IDLE) && !flush && !fence_i;
  assign resp_valid = ((state == S_RESP) || (state == S_REFILL_DONE)) && !flush && !fence_i;
  assign resp_line  = (state == S_RESP) ? (hit0_r ? line0_r : line1_r) : refill_buf;
  assign resp_word_sel = saved_word_sel;

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
      // A redirected fetch may not start a new refill until the outstanding
      // AXI transaction drains; otherwise the old beats would be mistaken for
      // the new line.
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
            saved_word_sel <= word_sel_w;
            line0_r        <= line0_w;
            line1_r        <= line1_w;
            hit0_r         <= hit0_w;
            hit1_r         <= hit1_w;

            if (hit0_w || hit1_w) begin
              hit_count  <= hit_count + {29'b0, words_served};
              lru[index_w] <= hit0_w ? 1'b1 : 1'b0;
              state      <= S_RESP;
            end else begin
              miss_count    <= miss_count + {29'b0, words_served};
              victim_way    <= lru[index_w];
              mem_req_valid <= 1'b1;
              mem_req_addr  <= {req_addr[31:4], 4'b0000};
              mem_req_len   <= 8'd3;
              refill_beat   <= 2'b00;
              state         <= S_REFILL;
            end
          end
        end

        S_RESP: begin
          state <= S_IDLE;
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

        S_DRAIN: begin
          mem_req_valid <= 1'b0;
          if (mem_resp_valid && mem_resp_rlast) begin
            mem_inflight <= 1'b0;
            state        <= S_IDLE;
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

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
