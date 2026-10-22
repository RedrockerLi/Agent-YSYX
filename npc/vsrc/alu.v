`timescale 1ns / 1ps

module alu (
  input  [4:0]  alu_op,
  input  [31:0] src1,
  input  [31:0] src2,
  output reg [31:0] res
);

  localparam ALU_ADD  = 5'd0;
  localparam ALU_SUB  = 5'd1;
  localparam ALU_SLL  = 5'd2;
  localparam ALU_SLT  = 5'd3;
  localparam ALU_SLTU = 5'd4;
  localparam ALU_XOR  = 5'd5;
  localparam ALU_SRL  = 5'd6;
  localparam ALU_SRA  = 5'd7;
  localparam ALU_OR   = 5'd8;
  localparam ALU_AND  = 5'd9;
  localparam ALU_MUL  = 5'd10;
  localparam ALU_MULH = 5'd11;
  localparam ALU_MULHU= 5'd12;
  localparam ALU_MULHSU=5'd13;
  localparam ALU_DIV  = 5'd14;
  localparam ALU_DIVU = 5'd15;
  localparam ALU_REM  = 5'd16;
  localparam ALU_REMU = 5'd17;

  // The adder/subtractor is shared by ADD, SUB, SLT and SLTU.  A separate
  // carry-select adder keeps the carry chain out of the mapping's hands.
  wire [31:0] add_sum;
  wire [31:0] sub_sum;
  wire        add_cout;
  wire        sub_cout;

  adder32 u_add (
    .a    (src1),
    .b    (src2),
    .cin  (1'b0),
    .sum  (add_sum),
    .cout (add_cout)
  );

  adder32 u_sub (
    .a    (src1),
    .b    (~src2),
    .cin  (1'b1),
    .sum  (sub_sum),
    .cout (sub_cout)
  );

  // Signed comparison uses the sign bits when they differ; otherwise the
  // sign of a-b is sufficient because no overflow can occur in that case.
  wire slt  = (src1[31] != src2[31]) ? src1[31] : sub_sum[31];
  wire sltu = ~sub_cout;

  always @(*) begin
    case (alu_op)
      ALU_ADD:    res = add_sum;
      ALU_SUB:    res = sub_sum;
      ALU_SLL:    res = src1 << src2[4:0];
      ALU_SLT:    res = {31'b0, slt};
      ALU_SLTU:   res = {31'b0, sltu};
      ALU_XOR:    res = src1 ^ src2;
      ALU_SRL:    res = src1 >> src2[4:0];
      ALU_SRA:    res = $signed(src1) >>> src2[4:0];
      ALU_OR:     res = src1 | src2;
      ALU_AND:    res = src1 & src2;
      // MUL/DIV are executed by the multi-cycle MDU units; the ALU result is
      // unused for these opcodes.
      ALU_MUL,
      ALU_MULH,
      ALU_MULHU,
      ALU_MULHSU,
      ALU_DIV,
      ALU_DIVU,
      ALU_REM,
      ALU_REMU:   res = 32'b0;
      default:    res = 32'b0;
    endcase
  end

endmodule
