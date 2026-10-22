`timescale 1ns / 1ps

// Two-cycle ALU.  The low 16 bits are added in the start cycle; the high
// 16 bits and the final result are produced in the next cycle.  The CPU
// holds the instruction in EX until `done`, like the multi-cycle MDU.
module alu (
  input             clock,
  input             reset,
  input             start,
  input             accept,
  input      [4:0]  alu_op,
  input      [31:0] src1,
  input      [31:0] src2,
  output reg        busy,
  output            done,
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

  localparam S_IDLE = 2'd0;
  localparam S_HIGH = 2'd1;
  localparam S_DONE = 2'd2;

  reg [1:0]  state;
  reg [4:0]  op_r;
  reg [31:0] a_r, b_r;
  reg [16:0] low_r;
  reg        done_r;

  assign done = done_r;

  wire op_sub  = (alu_op == ALU_SUB) || (alu_op == ALU_SLT) || (alu_op == ALU_SLTU);
  wire [31:0] b_lo = op_sub ? ~src2 : src2;
  wire [16:0] low_w = {1'b0, src1[15:0]} + {1'b0, b_lo[15:0]} + {{16{1'b0}}, op_sub};

  wire op_sub_r = (op_r == ALU_SUB) || (op_r == ALU_SLT) || (op_r == ALU_SLTU);
  wire [31:0] b_hi = op_sub_r ? ~b_r : b_r;
  wire [16:0] high_w = {1'b0, a_r[31:16]} + {1'b0, b_hi[31:16]} + {{16{1'b0}}, low_r[16]};
  wire [31:0] add_res = {high_w[15:0], low_r[15:0]};

  always @(posedge clock) begin
    if (reset) begin
      state  <= S_IDLE;
      busy   <= 1'b0;
      done_r <= 1'b0;
      res    <= 32'b0;
      op_r   <= 5'b0;
      a_r    <= 32'b0;
      b_r    <= 32'b0;
      low_r  <= 17'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            op_r  <= alu_op;
            a_r   <= src1;
            b_r   <= src2;
            low_r <= low_w;
            busy  <= 1'b1;
            state <= S_HIGH;
          end
        end

        S_HIGH: begin
          case (op_r)
            ALU_ADD,
            ALU_SUB:  res <= add_res;
            ALU_SLT:  res <= {31'b0, (a_r[31] != b_r[31]) ? a_r[31] : high_w[15]};
            ALU_SLTU: res <= {31'b0, ~high_w[16]};
            ALU_SLL:  res <= a_r << b_r[4:0];
            ALU_SRL:  res <= a_r >> b_r[4:0];
            ALU_SRA:  res <= $signed(a_r) >>> b_r[4:0];
            ALU_XOR:  res <= a_r ^ b_r;
            ALU_OR:   res <= a_r | b_r;
            ALU_AND:  res <= a_r & b_r;
            default:  res <= 32'b0;
          endcase
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
