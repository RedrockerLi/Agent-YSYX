`timescale 1ns / 1ps

module ysyx_261018_dcache #(
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
  output            resp_valid,
  output     [31:0] resp_rdata,
  input             fence_i,
  output            fence_done,

  // Memory Interface (AXI / Refill Arbiter)
  output reg        mem_req_valid,
  output reg        mem_req_write,
  output reg [31:0] mem_req_addr,
  output reg [7:0]  mem_req_len,
  output reg [31:0] mem_req_wdata,
  output reg [3:0]  mem_req_wstrb,
  output reg        mem_req_wlast,
  input             mem_grant,
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
  reg                 way0_dirty [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way0_tag   [NUM_SETS-1:0];
  reg [127:0]         way0_data  [NUM_SETS-1:0];

  reg                 way1_valid [NUM_SETS-1:0];
  reg                 way1_dirty [NUM_SETS-1:0];
  reg [TAG_WIDTH-1:0] way1_tag   [NUM_SETS-1:0];
  reg [127:0]         way1_data  [NUM_SETS-1:0];

  // 1-bit LRU per set: 0 -> way0 is LRU, 1 -> way1 is LRU
  reg                 lru        [NUM_SETS-1:0];

  // Address Decoding
  wire [SET_WIDTH-1:0] index    = req_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] tag      = req_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [1:0]           word_sel = req_addr[3:2];

  wire is_mmio = (req_addr < 32'h80000000) || (req_addr >= 32'h88000000);

  // Hit Detection (only for cacheable DRAM accesses)
  wire hit0 = way0_valid[index] && (way0_tag[index] == tag);
  wire hit1 = way1_valid[index] && (way1_tag[index] == tag);
  wire hit  = (hit0 || hit1) && !is_mmio && !fence_i;

  wire [31:0] hit0_word = (word_sel == 2'b00) ? way0_data[index][31:0] :
                          (word_sel == 2'b01) ? way0_data[index][63:32] :
                          (word_sel == 2'b10) ? way0_data[index][95:64] :
                                                way0_data[index][127:96];

  wire [31:0] hit1_word = (word_sel == 2'b00) ? way1_data[index][31:0] :
                          (word_sel == 2'b01) ? way1_data[index][63:32] :
                          (word_sel == 2'b10) ? way1_data[index][95:64] :
                                                way1_data[index][127:96];

  // Byte-level masking function for 32-bit words
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

  // State Machine
  localparam S_IDLE        = 4'd0;
  localparam S_WB_LINE     = 4'd1;
  localparam S_REFILL      = 4'd2;
  localparam S_REFILL_DONE = 4'd3;
  localparam S_MMIO_WAIT   = 4'd4;
  localparam S_FENCE_SCAN  = 4'd5;
  localparam S_FENCE_WB    = 4'd6;

  reg [3:0]   state;
  reg [31:0]  saved_addr;
  reg         saved_write;
  reg [31:0]  saved_wdata;
  reg [3:0]   saved_wmask;
  reg         saved_victim_way;
  reg [127:0] dirty_line_buf;
  reg [127:0] refill_buf;
  reg [1:0]   beat_cnt;

  reg [SET_WIDTH-1:0] fence_set;
  reg                 fence_way;
  reg                 fence_done_r;

  assign fence_done = fence_done_r;

  wire [SET_WIDTH-1:0] saved_index    = saved_addr[OFFSET_WIDTH+SET_WIDTH-1 : OFFSET_WIDTH];
  wire [TAG_WIDTH-1:0] saved_tag      = saved_addr[31 : OFFSET_WIDTH+SET_WIDTH];
  wire [1:0]           saved_word_sel = saved_addr[3:2];

  wire [31:0] refill_word = (saved_word_sel == 2'b00) ? refill_buf[31:0] :
                            (saved_word_sel == 2'b01) ? refill_buf[63:32] :
                            (saved_word_sel == 2'b10) ? refill_buf[95:64] :
                                                        refill_buf[127:96];

  assign resp_valid = (state == S_IDLE) ? (req_valid && hit) :
                      (state == S_REFILL_DONE) ? 1'b1 :
                      (state == S_MMIO_WAIT) ? mem_resp_valid : 1'b0;

  assign resp_rdata = (state == S_IDLE) ? (hit0 ? hit0_word : hit1_word) :
                      (state == S_REFILL_DONE) ? refill_word :
                      (state == S_MMIO_WAIT) ? mem_resp_rdata : 32'b0;

  integer j;
  always @(posedge clock) begin
    if (reset) begin
      state            <= S_IDLE;
      mem_req_valid    <= 1'b0;
      mem_req_write    <= 1'b0;
      mem_req_addr     <= 32'b0;
      mem_req_len      <= 8'd0;
      mem_req_wdata    <= 32'b0;
      mem_req_wstrb    <= 4'b0;
      mem_req_wlast    <= 1'b0;
      saved_addr       <= 32'b0;
      saved_write      <= 1'b0;
      saved_wdata      <= 32'b0;
      saved_wmask      <= 4'b0;
      saved_victim_way <= 1'b0;
      dirty_line_buf   <= 128'b0;
      refill_buf       <= 128'b0;
      beat_cnt         <= 2'b0;
      fence_set        <= 6'b0;
      fence_way        <= 1'b0;
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
            fence_set <= 6'b0;
            fence_way <= 1'b0;
            state     <= S_FENCE_SCAN;
          end else if (req_valid) begin
            saved_addr  <= req_addr;
            saved_write <= req_write;
            saved_wdata <= req_wdata;
            saved_wmask <= req_wmask;

            if (is_mmio) begin
              // MMIO bypass
              mem_req_valid <= 1'b1;
              mem_req_write <= req_write;
              mem_req_addr  <= req_addr;
              mem_req_len   <= 8'd0; // single beat
              mem_req_wdata <= req_wdata;
              mem_req_wstrb <= req_wmask;
              mem_req_wlast <= 1'b1;
              state         <= S_MMIO_WAIT;
            end else if (hit) begin
              hit_count  <= hit_count + 32'd1;
              lru[index] <= hit0 ? 1'b1 : 1'b0;
              if (req_write) begin
                // Store Hit: update matching word and set dirty
                if (hit0) begin
                  way0_dirty[index] <= 1'b1;
                  case (word_sel)
                    2'b00: way0_data[index][31:0]   <= apply_mask(way0_data[index][31:0],   req_wdata, req_wmask);
                    2'b01: way0_data[index][63:32]  <= apply_mask(way0_data[index][63:32],  req_wdata, req_wmask);
                    2'b10: way0_data[index][95:64]  <= apply_mask(way0_data[index][95:64],  req_wdata, req_wmask);
                    2'b11: way0_data[index][127:96] <= apply_mask(way0_data[index][127:96], req_wdata, req_wmask);
                  endcase
                end else begin
                  way1_dirty[index] <= 1'b1;
                  case (word_sel)
                    2'b00: way1_data[index][31:0]   <= apply_mask(way1_data[index][31:0],   req_wdata, req_wmask);
                    2'b01: way1_data[index][63:32]  <= apply_mask(way1_data[index][63:32],  req_wdata, req_wmask);
                    2'b10: way1_data[index][95:64]  <= apply_mask(way1_data[index][95:64],  req_wdata, req_wmask);
                    2'b11: way1_data[index][127:96] <= apply_mask(way1_data[index][127:96], req_wdata, req_wmask);
                  endcase
                end
              end
            end else begin
              // Miss: select victim
              miss_count       <= miss_count + 32'd1;
              saved_victim_way <= lru[index];
              if ((lru[index] == 1'b0 && way0_valid[index] && way0_dirty[index]) ||
                  (lru[index] == 1'b1 && way1_valid[index] && way1_dirty[index])) begin
                // Victim is dirty: write back 16 bytes
                dirty_line_buf <= lru[index] ? way1_data[index] : way0_data[index];
                mem_req_valid  <= 1'b1;
                mem_req_write  <= 1'b1;
                mem_req_addr   <= {lru[index] ? way1_tag[index] : way0_tag[index], index, 4'b0000};
                mem_req_len    <= 8'd3;
                mem_req_wdata  <= lru[index] ? way1_data[index][31:0] : way0_data[index][31:0];
                mem_req_wstrb  <= 4'b1111;
                mem_req_wlast  <= 1'b0;
                beat_cnt       <= 2'b00;
                state          <= S_WB_LINE;
              end else begin
                // Victim is clean: directly refill
                mem_req_valid <= 1'b1;
                mem_req_write <= 1'b0;
                mem_req_addr  <= {req_addr[31:4], 4'b0000};
                mem_req_len   <= 8'd3;
                beat_cnt      <= 2'b00;
                state         <= S_REFILL;
              end
            end
          end
        end

        S_WB_LINE: begin
          if (mem_resp_valid) begin
            // Write back complete: start refill
            mem_req_valid <= 1'b1;
            mem_req_write <= 1'b0;
            mem_req_addr  <= {saved_addr[31:4], 4'b0000};
            mem_req_len   <= 8'd3;
            mem_req_wlast <= 1'b0;
            beat_cnt      <= 2'b00;
            state         <= S_REFILL;
          end else if (mem_grant && (beat_cnt != 2'b11)) begin
            beat_cnt      <= beat_cnt + 2'd1;
            mem_req_wlast <= (beat_cnt == 2'b10);
            case (beat_cnt + 2'd1)
              2'b01: mem_req_wdata <= dirty_line_buf[63:32];
              2'b10: mem_req_wdata <= dirty_line_buf[95:64];
              2'b11: mem_req_wdata <= dirty_line_buf[127:96];
              default: mem_req_wdata <= dirty_line_buf[31:0];
            endcase
          end
        end

        S_REFILL: begin
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
          // Update cache arrays
          if (saved_victim_way == 1'b0) begin
            way0_valid[saved_index] <= 1'b1;
            way0_tag[saved_index]   <= saved_tag;
            lru[saved_index]        <= 1'b1;
            if (saved_write) begin
              way0_dirty[saved_index] <= 1'b1;
              case (saved_word_sel)
                2'b00: way0_data[saved_index] <= {refill_buf[127:32], apply_mask(refill_buf[31:0],   saved_wdata, saved_wmask)};
                2'b01: way0_data[saved_index] <= {refill_buf[127:64], apply_mask(refill_buf[63:32],  saved_wdata, saved_wmask), refill_buf[31:0]};
                2'b10: way0_data[saved_index] <= {refill_buf[127:96], apply_mask(refill_buf[95:64],  saved_wdata, saved_wmask), refill_buf[63:0]};
                2'b11: way0_data[saved_index] <= {apply_mask(refill_buf[127:96], saved_wdata, saved_wmask), refill_buf[95:0]};
              endcase
            end else begin
              way0_dirty[saved_index] <= 1'b0;
              way0_data[saved_index]  <= refill_buf;
            end
          end else begin
            way1_valid[saved_index] <= 1'b1;
            way1_tag[saved_index]   <= saved_tag;
            lru[saved_index]        <= 1'b0;
            if (saved_write) begin
              way1_dirty[saved_index] <= 1'b1;
              case (saved_word_sel)
                2'b00: way1_data[saved_index] <= {refill_buf[127:32], apply_mask(refill_buf[31:0],   saved_wdata, saved_wmask)};
                2'b01: way1_data[saved_index] <= {refill_buf[127:64], apply_mask(refill_buf[63:32],  saved_wdata, saved_wmask), refill_buf[31:0]};
                2'b10: way1_data[saved_index] <= {refill_buf[127:96], apply_mask(refill_buf[95:64],  saved_wdata, saved_wmask), refill_buf[63:0]};
                2'b11: way1_data[saved_index] <= {apply_mask(refill_buf[127:96], saved_wdata, saved_wmask), refill_buf[95:0]};
              endcase
            end else begin
              way1_dirty[saved_index] <= 1'b0;
              way1_data[saved_index]  <= refill_buf;
            end
          end
          state <= S_IDLE;
        end

        S_MMIO_WAIT: begin
          if (mem_resp_valid) begin
            mem_req_valid <= 1'b0;
            state         <= S_IDLE;
          end
        end

        S_FENCE_SCAN: begin
          if (way0_valid[fence_set] && way0_dirty[fence_set]) begin
            dirty_line_buf        <= way0_data[fence_set];
            way0_dirty[fence_set] <= 1'b0;
            way0_valid[fence_set] <= 1'b0;
            mem_req_valid         <= 1'b1;
            mem_req_write         <= 1'b1;
            mem_req_addr          <= {way0_tag[fence_set], fence_set, 4'b0000};
            mem_req_len           <= 8'd3;
            mem_req_wdata         <= way0_data[fence_set][31:0];
            mem_req_wstrb         <= 4'b1111;
            mem_req_wlast         <= 1'b0;
            beat_cnt              <= 2'b00;
            state                 <= S_FENCE_WB;
          end else if (way1_valid[fence_set] && way1_dirty[fence_set]) begin
            dirty_line_buf        <= way1_data[fence_set];
            way1_dirty[fence_set] <= 1'b0;
            way1_valid[fence_set] <= 1'b0;
            mem_req_valid         <= 1'b1;
            mem_req_write         <= 1'b1;
            mem_req_addr          <= {way1_tag[fence_set], fence_set, 4'b0000};
            mem_req_len           <= 8'd3;
            mem_req_wdata         <= way1_data[fence_set][31:0];
            mem_req_wstrb         <= 4'b1111;
            mem_req_wlast         <= 1'b0;
            beat_cnt              <= 2'b00;
            state                 <= S_FENCE_WB;
          end else begin
            way0_valid[fence_set] <= 1'b0;
            way1_valid[fence_set] <= 1'b0;
            if (fence_set == 6'd63) begin
              fence_done_r <= 1'b1;
              state        <= S_IDLE;
            end else begin
              fence_set <= fence_set + 6'd1;
            end
          end
        end

        S_FENCE_WB: begin
          if (mem_resp_valid) begin
            mem_req_valid <= 1'b0;
            mem_req_wlast <= 1'b0;
            state         <= S_FENCE_SCAN;
          end else if (mem_grant && (beat_cnt != 2'b11)) begin
            beat_cnt      <= beat_cnt + 2'd1;
            mem_req_wlast <= (beat_cnt == 2'b10);
            case (beat_cnt + 2'd1)
              2'b01: mem_req_wdata <= dirty_line_buf[63:32];
              2'b10: mem_req_wdata <= dirty_line_buf[95:64];
              2'b11: mem_req_wdata <= dirty_line_buf[127:96];
              default: mem_req_wdata <= dirty_line_buf[31:0];
            endcase
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
