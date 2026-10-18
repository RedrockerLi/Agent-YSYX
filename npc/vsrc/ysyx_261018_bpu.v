`timescale 1ns / 1ps

module ysyx_261018_bpu #(
  parameter BTB_ENTRIES = 64,
  parameter INDEX_WIDTH = 6,  // 2^6 = 64
  parameter RAS_DEPTH   = 8
)(
  input             clock,
  input             reset,

  // Prediction Interface (IF Stage)
  input      [31:0] if_pc,
  output            pred_taken,
  output     [31:0] pred_target,

  // Training / Resolution Interface (EX Stage)
  input             train_valid,
  input      [31:0] train_pc,
  input             train_taken,
  input      [31:0] train_target,
  input             train_is_call,
  input             train_is_ret,
  input             train_mispred,

  // Performance Counters
  output reg [31:0] total_pred_cnt,
  output reg [31:0] correct_pred_cnt
);

  localparam TAG_WIDTH = 32 - 2 - INDEX_WIDTH;

  // 1. BTB Arrays
  reg                 btb_valid  [BTB_ENTRIES-1:0];
  reg [TAG_WIDTH-1:0] btb_tag    [BTB_ENTRIES-1:0];
  reg [31:0]          btb_target [BTB_ENTRIES-1:0];
  reg                 btb_is_ret [BTB_ENTRIES-1:0];

  // 2. BHT: 2-bit Saturating Counters
  // 2'b00: Strongly Not Taken, 2'b01: Weakly Not Taken, 2'b10: Weakly Taken, 2'b11: Strongly Taken
  reg [1:0]           bht [BTB_ENTRIES-1:0];

  // 3. RAS: Return Address Stack
  reg [31:0]          ras_stack [RAS_DEPTH-1:0];
  reg [2:0]           ras_ptr;

  // Lookup in IF stage
  wire [INDEX_WIDTH-1:0] if_index = if_pc[INDEX_WIDTH+1 : 2];
  wire [TAG_WIDTH-1:0]   if_tag   = if_pc[31 : INDEX_WIDTH+2];

  wire btb_hit = btb_valid[if_index] && (btb_tag[if_index] == if_tag);
  wire bht_taken = bht[if_index][1]; // bit 1 indicates taken

  // RAS top-of-stack prediction
  wire [2:0]  ras_top_idx = (ras_ptr == 3'd0) ? 3'd7 : (ras_ptr - 3'd1);
  wire [31:0] ras_target  = ras_stack[ras_top_idx];

  assign pred_taken  = btb_hit && (btb_is_ret[if_index] || bht_taken);
  assign pred_target = (btb_hit && btb_is_ret[if_index] && (ras_ptr != 0)) ? ras_target :
                       btb_hit ? btb_target[if_index] : (if_pc + 32'd4);

  // Training & State Updates
  wire [INDEX_WIDTH-1:0] train_index = train_pc[INDEX_WIDTH+1 : 2];
  wire [TAG_WIDTH-1:0]   train_tag   = train_pc[31 : INDEX_WIDTH+2];

  integer i;
  always @(posedge clock) begin
    if (reset) begin
      ras_ptr          <= 3'd0;
      total_pred_cnt   <= 32'd0;
      correct_pred_cnt <= 32'd0;
      for (i = 0; i < BTB_ENTRIES; i = i + 1) begin
        btb_valid[i]  <= 1'b0;
        btb_tag[i]    <= {TAG_WIDTH{1'b0}};
        btb_target[i] <= 32'b0;
        btb_is_ret[i] <= 1'b0;
        bht[i]        <= 2'b01; // initial: weakly not taken
      end
      for (i = 0; i < RAS_DEPTH; i = i + 1) begin
        ras_stack[i] <= 32'b0;
      end
    end else begin
      if (train_valid) begin
        total_pred_cnt <= total_pred_cnt + 32'd1;
        if (!train_mispred) begin
          correct_pred_cnt <= correct_pred_cnt + 32'd1;
        end

        // Update BTB
        if (train_taken || train_is_ret || train_is_call) begin
          btb_valid[train_index]  <= 1'b1;
          btb_tag[train_index]    <= train_tag;
          btb_target[train_index] <= train_target;
          btb_is_ret[train_index] <= train_is_ret;
        end

        // Update BHT
        case (bht[train_index])
          2'b00: bht[train_index] <= train_taken ? 2'b01 : 2'b00;
          2'b01: bht[train_index] <= train_taken ? 2'b10 : 2'b00;
          2'b10: bht[train_index] <= train_taken ? 2'b11 : 2'b01;
          2'b11: bht[train_index] <= train_taken ? 2'b11 : 2'b10;
        endcase

        // Update RAS
        if (train_is_call) begin
          ras_stack[ras_ptr] <= train_pc + 32'd4;
          ras_ptr <= ras_ptr + 3'd1;
        end else if (train_is_ret) begin
          if (ras_ptr != 3'd0) begin
            ras_ptr <= ras_ptr - 3'd1;
          end
        end
      end
    end
  end

endmodule
