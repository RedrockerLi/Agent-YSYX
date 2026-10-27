`timescale 1ns / 1ps

// Three-stage ALU.  The start cycle registers the forwarded operands; S_HIGH
// computes the four 8-bit group sums (with and without a carry-in), the shift
// (4:1 stages) and the branch compare; S_SEL resolves the carry chain and
// selects the result with a registered one-hot op.
module alu (
  input             clock,
  input             reset,
  input             start,
  input             accept,
  input      [4:0]  alu_op,
  input      [2:0]  cmp_op,
  input      [31:0] src1,
  input      [31:0] src2,
  input      [31:0] cmp_a,
  input      [31:0] cmp_b,
  output reg        busy,
  output            done,
  output reg [31:0] res,
  output reg        cmp_out
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

  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_HIGH = 2'd1;
  localparam [1:0] S_SEL  = 2'd3;
  localparam [1:0] S_DONE = 2'd2;

  reg [1:0]  state;
  reg [2:0]  cmp_op_r;
  reg [31:0] cmp_a_r, cmp_b_r;
  reg [31:0] op_oh;
  reg [31:0] a_r, b_r;
  reg [31:0] b_sum_r;
  // The 32-bit add is split across S_HIGH and S_SEL: S_HIGH produces the four
  // 8-bit group sums (with and without a carry-in), S_SEL resolves the carry
  // chain and selects the groups.  Keeping the 8-bit adders parallel to each
  // other holds the S_HIGH path at one adder delay.
  reg [8:0]  g0_r, g1_r, g2_r, g3_r;
  reg [8:0]  g1p_r, g2p_r, g3p_r;
  reg [31:0] sh_r;
  reg        done_r;

  assign done = done_r;

  // ---- barrel shifter: three 4:1 stages --------------------------------
  function [31:0] shl4;
    input [31:0] x;
    input [1:0]  s;
    begin
      case (s)
        2'd0: shl4 = x;
        2'd1: shl4 = {x[30:0], 1'b0};
        2'd2: shl4 = {x[29:0], 2'b0};
        default: shl4 = {x[28:0], 3'b0};
      endcase
    end
  endfunction

  function [31:0] srl4;
    input [31:0] x;
    input [1:0]  s;
    begin
      case (s)
        2'd0: srl4 = x;
        2'd1: srl4 = {1'b0, x[31:1]};
        2'd2: srl4 = {2'b0, x[31:2]};
        default: srl4 = {3'b0, x[31:3]};
      endcase
    end
  endfunction

  function [31:0] sra4;
    input [31:0] x;
    input [1:0]  s;
    begin
      case (s)
        2'd0: sra4 = x;
        2'd1: sra4 = {x[31], x[31:1]};
        2'd2: sra4 = {{2{x[31]}}, x[31:2]};
        default: sra4 = {{3{x[31]}}, x[31:3]};
      endcase
    end
  endfunction

  function [31:0] shl16;
    input [31:0] x;
    input [1:0]  s;
    begin
      case (s)
        2'd0: shl16 = x;
        2'd1: shl16 = {x[27:0], 4'b0};
        2'd2: shl16 = {x[23:0], 8'b0};
        default: shl16 = {x[19:0], 12'b0};
      endcase
    end
  endfunction

  function [31:0] srl16;
    input [31:0] x;
    input [1:0]  s;
    begin
      case (s)
        2'd0: srl16 = x;
        2'd1: srl16 = {4'b0, x[31:4]};
        2'd2: srl16 = {8'b0, x[31:8]};
        default: srl16 = {12'b0, x[31:12]};
      endcase
    end
  endfunction

  function [31:0] sra16;
    input [31:0] x;
    input [1:0]  s;
    begin
      case (s)
        2'd0: sra16 = x;
        2'd1: sra16 = {{4{x[31]}}, x[31:4]};
        2'd2: sra16 = {{8{x[31]}}, x[31:8]};
        default: sra16 = {{12{x[31]}}, x[31:12]};
      endcase
    end
  endfunction

  wire [4:0]  shamt = b_r[4:0];
  wire [31:0] sl16 = shl16(shl4(a_r, shamt[1:0]), shamt[3:2]);
  wire [31:0] sr16 = srl16(srl4(a_r, shamt[1:0]), shamt[3:2]);
  wire [31:0] sa16 = sra16(sra4(a_r, shamt[1:0]), shamt[3:2]);
  wire [31:0] sl = shamt[4] ? {sl16[15:0], 16'b0} : sl16;
  wire [31:0] sr = shamt[4] ? {16'b0, sr16[31:16]} : sr16;
  wire [31:0] sa = shamt[4] ? {{16{a_r[31]}}, sa16[31:16]} : sa16;

  wire [31:0] sh_val = op_oh[ALU_SLL] ? sl :
                       op_oh[ALU_SRL] ? sr :
                       op_oh[ALU_SRA] ? sa : 32'b0;
  wire [31:0] op_one = (32'd1 << alu_op);

  // ---- arithmetic ------------------------------------------------------
  wire op_sub   = (alu_op == ALU_SUB) || (alu_op == ALU_SLT) || (alu_op == ALU_SLTU);
  wire op_sub_r = op_oh[ALU_SUB] | op_oh[ALU_SLT] | op_oh[ALU_SLTU];

  wire [8:0] g0  = {1'b0, a_r[7:0]}   + {1'b0, b_sum_r[7:0]}   + {8'b0, op_sub_r};
  wire [8:0] g1  = {1'b0, a_r[15:8]}  + {1'b0, b_sum_r[15:8]};
  wire [8:0] g2  = {1'b0, a_r[23:16]} + {1'b0, b_sum_r[23:16]};
  wire [8:0] g3  = {1'b0, a_r[31:24]} + {1'b0, b_sum_r[31:24]};
  wire [8:0] g1p = {1'b0, a_r[15:8]}  + {1'b0, b_sum_r[15:8]}  + 9'd1;
  wire [8:0] g2p = {1'b0, a_r[23:16]} + {1'b0, b_sum_r[23:16]} + 9'd1;
  wire [8:0] g3p = {1'b0, a_r[31:24]} + {1'b0, b_sum_r[31:24]} + 9'd1;

  wire c2 = g0_r[8] ? g1p_r[8] : g1_r[8];
  wire c3 = c2      ? g2p_r[8] : g2_r[8];

  wire [31:0] add_sum =
      {c3 ? g3p_r[7:0] : g3_r[7:0],
       c2 ? g2p_r[7:0] : g2_r[7:0],
       g0_r[8] ? g1p_r[7:0] : g1_r[7:0],
       g0_r[7:0]};
  wire add_cout = c3 ? g3p_r[8] : g3_r[8];

  wire [31:0] slt_val  = {31'b0, (a_r[31] != b_r[31]) ? a_r[31] : add_sum[31]};
  wire [31:0] sltu_val = {31'b0, ~add_cout};

  wire sel_add   = op_oh[ALU_ADD] | op_oh[ALU_SUB];
  wire sel_shift = op_oh[ALU_SLL] | op_oh[ALU_SRL] | op_oh[ALU_SRA];

  wire [31:0] res_w = ({32{sel_add}}          & add_sum)   |
                      ({32{sel_shift}}        & sh_r)      |
                      ({32{op_oh[ALU_SLT]}}   & slt_val)   |
                      ({32{op_oh[ALU_SLTU]}}  & sltu_val)  |
                      ({32{op_oh[ALU_XOR]}}   & (a_r ^ b_r)) |
                      ({32{op_oh[ALU_OR]}}    & (a_r | b_r)) |
                      ({32{op_oh[ALU_AND]}}   & (a_r & b_r));

  // Branch comparison from registered operands, so the decision does not
  // travel through the forwarding mux.
  wire cmp_w = (cmp_op_r == 3'b000) ? (cmp_a_r == cmp_b_r) :
               (cmp_op_r == 3'b001) ? (cmp_a_r != cmp_b_r) :
               (cmp_op_r == 3'b100) ? ($signed(cmp_a_r) < $signed(cmp_b_r)) :
               (cmp_op_r == 3'b101) ? ($signed(cmp_a_r) >= $signed(cmp_b_r)) :
               (cmp_op_r == 3'b110) ? (cmp_a_r < cmp_b_r) :
               (cmp_op_r == 3'b111) ? (cmp_a_r >= cmp_b_r) : 1'b0;

  always @(posedge clock) begin
    if (reset) begin
      state    <= S_IDLE;
      busy     <= 1'b0;
      done_r   <= 1'b0;
      res      <= 32'b0;
      op_oh    <= 32'b0;
      cmp_out  <= 1'b0;
      cmp_op_r <= 3'b0;
      cmp_a_r  <= 32'b0;
      cmp_b_r  <= 32'b0;
      a_r      <= 32'b0;
      b_r      <= 32'b0;
      b_sum_r  <= 32'b0;
      g0_r     <= 9'b0;
      g1_r     <= 9'b0;
      g2_r     <= 9'b0;
      g3_r     <= 9'b0;
      g1p_r    <= 9'b0;
      g2p_r    <= 9'b0;
      g3p_r    <= 9'b0;
      sh_r     <= 32'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            op_oh    <= op_one;
            cmp_op_r <= cmp_op;
            cmp_a_r  <= cmp_a;
            cmp_b_r  <= cmp_b;
            a_r      <= src1;
            b_r      <= src2;
            b_sum_r  <= op_sub ? ~src2 : src2;
            busy     <= 1'b1;
            state    <= S_HIGH;
          end
        end

        S_HIGH: begin
          g0_r  <= g0;
          g1_r  <= g1;
          g2_r  <= g2;
          g3_r  <= g3;
          g1p_r <= g1p;
          g2p_r <= g2p;
          g3p_r <= g3p;
          sh_r  <= sh_val;
          cmp_out <= cmp_w;
          state <= S_SEL;
        end

        S_SEL: begin
          res    <= res_w;
          done_r <= 1'b1;
          state  <= S_DONE;
        end

        S_DONE: begin
          if (accept) begin
            busy   <= 1'b0;
            done_r <= 1'b0;
            state  <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
