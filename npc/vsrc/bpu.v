`timescale 1ns / 1ps

// Branch prediction unit with a two-stage lookup aligned to the fetch
// request/response:
//   stage 1 (request cycle): BTB tag/target + BHT read into flops
//   stage 2 (response cycle): hit/taken/RAS selection
// Four words of a fetched line are looked up together and stored in the
// instruction queue, so the IF/ID capture never sees the BTB read path.
module bpu #(
  parameter BTB_ENTRIES = 32,
  parameter INDEX_WIDTH = 5,  // 2^5 = 32
  parameter RAS_DEPTH   = 8
)(
  input             clock,
  input             reset,

  // Pipelined lookup interface (four words per fetch request).
  input             lookup_valid,
  input      [31:0] lookup_pc0,
  input      [31:0] lookup_pc1,
  input      [31:0] lookup_pc2,
  input      [31:0] lookup_pc3,
  output            lookup_taken0,
  output            lookup_taken1,
  output            lookup_taken2,
  output            lookup_taken3,
  output     [31:0] lookup_target0,
  output     [31:0] lookup_target1,
  output     [31:0] lookup_target2,
  output     [31:0] lookup_target3,

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
  // 2'b00: Strongly Not Taken, 2'b01: Weakly Not Taken,
  // 2'b10: Weakly Taken, 2'b11: Strongly Taken
  reg [1:0]           bht [BTB_ENTRIES-1:0];

  // 3. RAS: Return Address Stack
  reg [31:0]          ras_stack [RAS_DEPTH-1:0];
  reg [2:0]           ras_ptr;

  // Stage 1: BTB/BHT read for four consecutive words.
  wire [INDEX_WIDTH-1:0] idx0 = lookup_pc0[INDEX_WIDTH+1 : 2];
  wire [INDEX_WIDTH-1:0] idx1 = lookup_pc1[INDEX_WIDTH+1 : 2];
  wire [INDEX_WIDTH-1:0] idx2 = lookup_pc2[INDEX_WIDTH+1 : 2];
  wire [INDEX_WIDTH-1:0] idx3 = lookup_pc3[INDEX_WIDTH+1 : 2];

  wire [TAG_WIDTH-1:0] tag0 = lookup_pc0[31 : INDEX_WIDTH+2];
  wire [TAG_WIDTH-1:0] tag1 = lookup_pc1[31 : INDEX_WIDTH+2];
  wire [TAG_WIDTH-1:0] tag2 = lookup_pc2[31 : INDEX_WIDTH+2];
  wire [TAG_WIDTH-1:0] tag3 = lookup_pc3[31 : INDEX_WIDTH+2];

  reg        s1_valid;
  reg [31:0] s1_pc    [0:3];
  reg        s1_hit   [0:3];
  reg        s1_is_ret[0:3];
  reg        s1_bht   [0:3];
  reg [31:0] s1_target[0:3];

  integer i;
  always @(posedge clock) begin
    if (reset) begin
      s1_valid <= 1'b0;
      for (i = 0; i < 4; i = i + 1) begin
        s1_pc[i]     <= 32'b0;
        s1_hit[i]    <= 1'b0;
        s1_is_ret[i] <= 1'b0;
        s1_bht[i]    <= 1'b0;
        s1_target[i] <= 32'b0;
      end
    end else begin
      s1_valid    <= lookup_valid;
      s1_pc[0]    <= lookup_pc0;
      s1_pc[1]    <= lookup_pc1;
      s1_pc[2]    <= lookup_pc2;
      s1_pc[3]    <= lookup_pc3;
      s1_hit[0]   <= btb_valid[idx0] && (btb_tag[idx0] == tag0);
      s1_hit[1]   <= btb_valid[idx1] && (btb_tag[idx1] == tag1);
      s1_hit[2]   <= btb_valid[idx2] && (btb_tag[idx2] == tag2);
      s1_hit[3]   <= btb_valid[idx3] && (btb_tag[idx3] == tag3);
      s1_is_ret[0] <= btb_is_ret[idx0];
      s1_is_ret[1] <= btb_is_ret[idx1];
      s1_is_ret[2] <= btb_is_ret[idx2];
      s1_is_ret[3] <= btb_is_ret[idx3];
      s1_bht[0]   <= bht[idx0][1];
      s1_bht[1]   <= bht[idx1][1];
      s1_bht[2]   <= bht[idx2][1];
      s1_bht[3]   <= bht[idx3][1];
      s1_target[0] <= btb_target[idx0];
      s1_target[1] <= btb_target[idx1];
      s1_target[2] <= btb_target[idx2];
      s1_target[3] <= btb_target[idx3];
    end
  end

  // Stage 2: taken/target selection.  The RAS top is common to all words.
  wire [2:0]  ras_top_idx = (ras_ptr == 3'd0) ? 3'd7 : (ras_ptr - 3'd1);
  wire [31:0] ras_target  = ras_stack[ras_top_idx];

  assign lookup_taken0 = s1_valid && s1_hit[0] && (s1_is_ret[0] || s1_bht[0]);
  assign lookup_taken1 = s1_valid && s1_hit[1] && (s1_is_ret[1] || s1_bht[1]);
  assign lookup_taken2 = s1_valid && s1_hit[2] && (s1_is_ret[2] || s1_bht[2]);
  assign lookup_taken3 = s1_valid && s1_hit[3] && (s1_is_ret[3] || s1_bht[3]);

  assign lookup_target0 = (s1_is_ret[0] && (ras_ptr != 3'd0)) ? ras_target :
                          s1_hit[0] ? s1_target[0] : (s1_pc[0] + 32'd4);
  assign lookup_target1 = (s1_is_ret[1] && (ras_ptr != 3'd0)) ? ras_target :
                          s1_hit[1] ? s1_target[1] : (s1_pc[1] + 32'd4);
  assign lookup_target2 = (s1_is_ret[2] && (ras_ptr != 3'd0)) ? ras_target :
                          s1_hit[2] ? s1_target[2] : (s1_pc[2] + 32'd4);
  assign lookup_target3 = (s1_is_ret[3] && (ras_ptr != 3'd0)) ? ras_target :
                          s1_hit[3] ? s1_target[3] : (s1_pc[3] + 32'd4);

  // Training & State Updates
  wire [INDEX_WIDTH-1:0] train_index = train_pc[INDEX_WIDTH+1 : 2];
  wire [TAG_WIDTH-1:0]   train_tag   = train_pc[31 : INDEX_WIDTH+2];

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
