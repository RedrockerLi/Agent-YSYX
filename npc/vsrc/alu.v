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

  wire signed [63:0] mul_s_s = $signed({{32{src1[31]}}, src1}) * $signed({{32{src2[31]}}, src2});
  wire        [63:0] mul_u_u = {32'b0, src1} * {32'b0, src2};
  wire signed [63:0] mul_s_u = $signed({{32{src1[31]}}, src1}) * $signed({32'b0, src2});

  always @(*) begin
    case (alu_op)
      ALU_ADD:    res = src1 + src2;
      ALU_SUB:    res = src1 - src2;
      ALU_SLL:    res = src1 << src2[4:0];
      ALU_SLT:    res = ($signed(src1) < $signed(src2)) ? 32'd1 : 32'd0;
      ALU_SLTU:   res = (src1 < src2) ? 32'd1 : 32'd0;
      ALU_XOR:    res = src1 ^ src2;
      ALU_SRL:    res = src1 >> src2[4:0];
      ALU_SRA:    res = $signed(src1) >>> src2[4:0];
      ALU_OR:     res = src1 | src2;
      ALU_AND:    res = src1 & src2;
      ALU_MUL:    res = mul_s_s[31:0];
      ALU_MULH:   res = mul_s_s[63:32];
      ALU_MULHU:  res = mul_u_u[63:32];
      ALU_MULHSU: res = mul_s_u[63:32];
      ALU_DIV: begin
        if (src2 == 32'b0)
          res = 32'hffffffff;
        else if (src1 == 32'h80000000 && src2 == 32'hffffffff)
          res = 32'h80000000;
        else
          res = $signed(src1) / $signed(src2);
      end
      ALU_DIVU: begin
        if (src2 == 32'b0)
          res = 32'hffffffff;
        else
          res = src1 / src2;
      end
      ALU_REM: begin
        if (src2 == 32'b0)
          res = src1;
        else if (src1 == 32'h80000000 && src2 == 32'hffffffff)
          res = 32'b0;
        else
          res = $signed(src1) % $signed(src2);
      end
      ALU_REMU: begin
        if (src2 == 32'b0)
          res = src1;
        else
          res = src1 % src2;
      end
      default:    res = 32'b0;
    endcase
  end

endmodule
