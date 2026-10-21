`timescale 1ns / 1ps

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
  output            resp_valid,
  output     [31:0] resp_rdata,
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

  // Cache Storage Arrays: 2 Ways
  reg                 way0_valid [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way0_tag   [NUM_SETS-1:0];
  reg [127:0]         way0_data  [NUM_SETS-1:0];

  reg                 way1_valid [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way1_tag   [NUM_SETS-1:0];
  reg [127:0]         way1_data  [NUM_SETS-1:0];

  // 1-bit LRU per set: 0 -> way0 is LRU, 1 -> way1 is LRU
  reg                 lru        [NUM_SETS-1:0];

  // Address Decoding
  wire [SET_WIDTH-1:0]    index    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0]    tag      = req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [1:0]              word_sel = req_addr[3:2];

  // Hit Detection
  wire hit0 = way0_valid[index] && (way0_tag[index] == tag);
  wire hit1 = way1_valid[index] && (way1_tag[index] == tag);
  wire hit  = (hit0 || hit1) && !fence_i;

  wire [31:0] hit0_word = (word_sel == 2'b00) ? way0_data[index][31:0] :
                          (word_sel == 2'b01) ? way0_data[index][63:32] :
                          (word_sel == 2'b10) ? way0_data[index][95:64] :
                                                way0_data[index][127:96];

  wire [31:0] hit1_word = (word_sel == 2'b00) ? way1_data[index][31:0] :
                          (word_sel == 2'b01) ? way1_data[index][63:32] :
                          (word_sel == 2'b10) ? way1_data[index][95:64] :
                                                way1_data[index][127:96];

  // State Machine
  localparam S_IDLE        = 2'd0;
  localparam S_REFILL      = 2'd1;
  localparam S_REFILL_DONE = 2'd2;

  reg [1:0]   state;
  reg [1:0]   refill_beat;
  reg [127:0] refill_buf;
  reg [31:0]  saved_addr;
  reg         victim_way;
  reg         discard_pending;

  wire [1:0] saved_word_sel = saved_addr[3:2];

  wire [31:0] refill_word = (saved_word_sel == 2'b00) ? refill_buf[31:0] :
                            (saved_word_sel == 2'b01) ? refill_buf[63:32] :
                            (saved_word_sel == 2'b10) ? refill_buf[95:64] :
                                                        refill_buf[127:96];

  assign resp_valid = (state == S_IDLE) ? (req_valid && hit && !flush) :
                      (state == S_REFILL_DONE && !discard_pending && !flush);
  assign resp_rdata = (state == S_IDLE) ? (hit0 ? hit0_word : hit1_word) : refill_word;

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
      victim_way      <= 1'b0;
      discard_pending <= 1'b0;
      hit_count       <= 32'b0;
      miss_count      <= 32'b0;
      for (i = 0; i < NUM_SETS; i = i + 1) begin
        way0_valid[i] <= 1'b0;
        way1_valid[i] <= 1'b0;
        lru[i]        <= 1'b0;
      end
    end else if (fence_i) begin
      // fence.i invalidates all lines in ICache
      for (i = 0; i < NUM_SETS; i = i + 1) begin
        way0_valid[i] <= 1'b0;
        way1_valid[i] <= 1'b0;
        lru[i]        <= 1'b0;
      end
      state           <= S_IDLE;
      mem_req_valid   <= 1'b0;
      discard_pending <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (req_valid && !flush) begin
            if (hit) begin
              hit_count  <= hit_count + 32'd1;
              lru[index] <= hit0 ? 1'b1 : 1'b0; // set opposite as LRU
            end else begin
              miss_count      <= miss_count + 32'd1;
              saved_addr      <= req_addr;
              victim_way      <= lru[index];
              mem_req_valid   <= 1'b1;
              mem_req_addr    <= {req_addr[31:4], 4'b0000};
              mem_req_len     <= 8'd3; // 4 beats = 16 bytes
              refill_beat     <= 2'b00;
              discard_pending <= 1'b0;
              state           <= S_REFILL;
            end
          end
        end

        S_REFILL: begin
          if (mem_req_ack) begin
            mem_req_valid <= 1'b0;
          end
          if (flush) begin
            discard_pending <= 1'b1;
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
              state         <= S_REFILL_DONE;
            end
          end
        end

        S_REFILL_DONE: begin
          // Update cache arrays
          if (victim_way == 1'b0) begin
            way0_valid[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b1;
            way0_tag[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]   <= saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];
            way0_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]  <= refill_buf;
            lru[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]        <= 1'b1;
          end else begin
            way1_valid[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b1;
            way1_tag[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]   <= saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];
            way1_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]  <= refill_buf;
            lru[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]        <= 1'b0;
          end
          discard_pending <= 1'b0;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
