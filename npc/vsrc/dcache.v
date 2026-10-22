`timescale 1ns / 1ps

// 2-way set-associative write-back D-cache.
//
// The array read is synchronous: a request is accepted in S_IDLE, the line
// and hit information are captured at the accept edge, and the response or
// writeback decision is made in S_RESP.  This keeps the 64:1 line mux off the
// path to the load formatter and to the miss victim selection.
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

  localparam NUM_SETS = 1 << SET_WIDTH;

  reg                 way0_valid [NUM_SETS-1:0];
  reg                 way0_dirty [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way0_tag   [NUM_SETS-1:0];
  reg [127:0]         way0_data  [NUM_SETS-1:0];

  reg                 way1_valid [NUM_SETS-1:0];
  reg                 way1_dirty [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way1_tag   [NUM_SETS-1:0];
  reg [127:0]         way1_data  [NUM_SETS-1:0];

  reg                 lru        [NUM_SETS-1:0];

  localparam S_IDLE        = 4'd0;
  localparam S_RESP        = 4'd2;
  localparam S_WB_LINE     = 4'd3;
  localparam S_REFILL      = 4'd4;
  localparam S_REFILL_DONE = 4'd5;
  localparam S_MMIO_WAIT   = 4'd6;
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

  wire [SET_WIDTH-1:0] index_w    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] tag_w      = req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [1:0]           word_sel_w = req_addr[3:2];

  wire [SET_WIDTH-1:0] saved_index = saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] saved_tag   = saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];

  wire is_mmio = (req_addr < 32'h80000000) || (req_addr >= 32'h88000000);

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

  assign resp_valid = (state == S_RESP && (hit0_r || hit1_r)) ||
                      (state == S_REFILL_DONE) ||
                      (state == S_MMIO_WAIT && mem_resp_valid);

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
      for (j = 0; j < NUM_SETS; j = j + 1) begin
        way0_valid[j] <= 1'b0;
        way0_dirty[j] <= 1'b0;
        way1_valid[j] <= 1'b0;
        way1_dirty[j] <= 1'b0;
        lru[j]        <= 1'b0;
      end
    end else begin
      fence_done_r <= 1'b0;

      case (state)
        S_IDLE: begin
          if (fence_i) begin
            fence_set <= {SET_WIDTH{1'b0}};
            state     <= S_FENCE_READ;
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
              // The request address is the EX/MEM flop, so the array read can
              // be registered directly in the accept cycle.
              line0_r  <= way0_data[index_w];
              line1_r  <= way1_data[index_w];
              hit0_r   <= way0_valid[index_w] && (way0_tag[index_w] == tag_w);
              hit1_r   <= way1_valid[index_w] && (way1_tag[index_w] == tag_w);
              valid0_r <= way0_valid[index_w];
              valid1_r <= way1_valid[index_w];
              dirty0_r <= way0_dirty[index_w];
              dirty1_r <= way1_dirty[index_w];
              state    <= S_RESP;
            end
          end
        end

        S_RESP: begin
          if (hit0_r || hit1_r) begin
            hit_count       <= hit_count + 32'd1;
            lru[saved_index]  <= hit0_r ? 1'b1 : 1'b0;
            if (saved_write) begin
              if (hit0_r) begin
                way0_dirty[saved_index] <= 1'b1;
                case (saved_word_sel)
                  2'b00: way0_data[saved_index][31:0]   <= resp_merged_word;
                  2'b01: way0_data[saved_index][63:32]  <= resp_merged_word;
                  2'b10: way0_data[saved_index][95:64]  <= resp_merged_word;
                  2'b11: way0_data[saved_index][127:96] <= resp_merged_word;
                endcase
              end else begin
                way1_dirty[saved_index] <= 1'b1;
                case (saved_word_sel)
                  2'b00: way1_data[saved_index][31:0]   <= resp_merged_word;
                  2'b01: way1_data[saved_index][63:32]  <= resp_merged_word;
                  2'b10: way1_data[saved_index][95:64]  <= resp_merged_word;
                  2'b11: way1_data[saved_index][127:96] <= resp_merged_word;
                endcase
              end
            end
            state <= S_IDLE;
          end else begin
            miss_count       <= miss_count + 32'd1;
            saved_victim_way <= lru[saved_index];
            if ((lru[saved_index] == 1'b0 && valid0_r && dirty0_r) ||
                (lru[saved_index] == 1'b1 && valid1_r && dirty1_r)) begin
              dirty_line_buf <= lru[saved_index] ? line1_r : line0_r;
              mem_req_valid  <= 1'b1;
              mem_req_write  <= 1'b1;
              mem_req_addr   <= {lru[saved_index] ? way1_tag[saved_index] : way0_tag[saved_index], saved_index, 4'b0000};
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
              state         <= S_REFILL_DONE;
            end
          end
        end

        S_REFILL_DONE: begin
          if (saved_victim_way == 1'b0) begin
            way0_valid[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b1;
            way0_tag[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]   <= saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];
            lru[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]        <= 1'b1;
            if (saved_write) begin
              way0_dirty[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b1;
              case (saved_word_sel)
                2'b00: way0_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {refill_buf[127:32], apply_mask(refill_buf[31:0],   saved_wdata, saved_wmask)};
                2'b01: way0_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {refill_buf[127:64], apply_mask(refill_buf[63:32],  saved_wdata, saved_wmask), refill_buf[31:0]};
                2'b10: way0_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {refill_buf[127:96], apply_mask(refill_buf[95:64],  saved_wdata, saved_wmask), refill_buf[63:0]};
                2'b11: way0_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {apply_mask(refill_buf[127:96], saved_wdata, saved_wmask), refill_buf[95:0]};
              endcase
            end else begin
              way0_dirty[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b0;
              way0_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]  <= refill_buf;
            end
          end else begin
            way1_valid[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b1;
            way1_tag[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]   <= saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];
            lru[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]        <= 1'b0;
            if (saved_write) begin
              way1_dirty[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b1;
              case (saved_word_sel)
                2'b00: way1_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {refill_buf[127:32], apply_mask(refill_buf[31:0],   saved_wdata, saved_wmask)};
                2'b01: way1_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {refill_buf[127:64], apply_mask(refill_buf[63:32],  saved_wdata, saved_wmask), refill_buf[31:0]};
                2'b10: way1_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {refill_buf[127:96], apply_mask(refill_buf[95:64],  saved_wdata, saved_wmask), refill_buf[63:0]};
                2'b11: way1_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= {apply_mask(refill_buf[127:96], saved_wdata, saved_wmask), refill_buf[95:0]};
              endcase
            end else begin
              way1_dirty[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]] <= 1'b0;
              way1_data[saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH]]  <= refill_buf;
            end
          end
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

        S_FENCE_READ: begin
          fence_line0  <= way0_data[fence_set];
          fence_line1  <= way1_data[fence_set];
          fence_valid0 <= way0_valid[fence_set];
          fence_valid1 <= way1_valid[fence_set];
          fence_dirty0 <= way0_dirty[fence_set];
          fence_dirty1 <= way1_dirty[fence_set];
          fence_tag0   <= way0_tag[fence_set];
          fence_tag1   <= way1_tag[fence_set];
          state        <= S_FENCE_CHECK;
        end

        S_FENCE_CHECK: begin
          if (fence_valid0 && fence_dirty0) begin
            dirty_line_buf        <= fence_line0;
            way0_dirty[fence_set] <= 1'b0;
            way0_valid[fence_set] <= 1'b0;
            mem_req_valid         <= 1'b1;
            mem_req_write         <= 1'b1;
            mem_req_addr          <= {fence_tag0, fence_set, 4'b0000};
            mem_req_len           <= 8'd3;
            beat_cnt              <= 2'b00;
            state                 <= S_FENCE_WB;
          end else if (fence_valid1 && fence_dirty1) begin
            dirty_line_buf        <= fence_line1;
            way1_dirty[fence_set] <= 1'b0;
            way1_valid[fence_set] <= 1'b0;
            mem_req_valid         <= 1'b1;
            mem_req_write         <= 1'b1;
            mem_req_addr          <= {fence_tag1, fence_set, 4'b0000};
            mem_req_len           <= 8'd3;
            beat_cnt              <= 2'b00;
            state                 <= S_FENCE_WB;
          end else begin
            way0_valid[fence_set] <= 1'b0;
            way1_valid[fence_set] <= 1'b0;
            if (fence_set == NUM_SETS - 1) begin
              fence_done_r <= 1'b1;
              state        <= S_IDLE;
            end else begin
              fence_set <= fence_set + 1'b1;
              state     <= S_FENCE_READ;
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
            state         <= S_FENCE_READ;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
