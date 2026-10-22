`timescale 1ns / 1ps

// Parameterized radix-4 multiplier for RV32M MUL/MULH/MULHU/MULHSU.
//
// MUL_BITS_PER_CYCLE selects the number of multiplier bits consumed per
// cycle: 2 (16 iterations), 4 (8 iterations) or 8 (4 iterations).  The
// accumulator is kept in carry-save form, so each cycle only costs a small
// CSA tree; the single carry-propagate add is done in a separate final cycle.
module mul_unit #(
  parameter MUL_BITS_PER_CYCLE = 4
) (
  input             clock,
  input             reset,
  input             start,
  input             accept,
  input      [4:0]  alu_op,     // MUL=10, MULH=11, MULHU=12, MULHSU=13
  input      [31:0] src1,
  input      [31:0] src2,
  output reg        busy,
  output            done,
  output reg [31:0] res
);

  localparam DIGITS = MUL_BITS_PER_CYCLE / 2;   // 1, 2, 4
  localparam NITER  = 16 / DIGITS;              // 16, 8, 4
  localparam CW     = (NITER <= 2) ? 1 : $clog2(NITER);
  localparam AW     = 66 + 2 * DIGITS;          // carry-save accumulator width

  localparam [4:0] OP_MUL    = 5'd10;
  localparam [4:0] OP_MULH   = 5'd11;
  localparam [4:0] OP_MULHU  = 5'd12;
  localparam [4:0] OP_MULHSU = 5'd13;

  localparam [31:0]   NITER_V = NITER;
  localparam [CW-1:0] LAST    = NITER_V[CW-1:0] - 1'b1;

  localparam S_IDLE   = 3'd0;
  localparam S_CONV   = 3'd5;
  localparam S_ITER   = 3'd1;
  localparam S_FINAL  = 3'd2;
  localparam S_SELECT = 3'd3;
  localparam S_DONE   = 3'd4;

  // Operand signs.  Magnitudes are multiplied, then the 64-bit product is
  // negated for the signed variants.  MULHSU treats only src1 as signed.
  wire a_signed = (alu_op == OP_MUL) || (alu_op == OP_MULH) || (alu_op == OP_MULHSU);
  wire b_signed = (alu_op == OP_MUL) || (alu_op == OP_MULH);
  wire neg_c    = ((alu_op == OP_MUL) || (alu_op == OP_MULH)) ? (src1[31] ^ src2[31]) :
                  (alu_op == OP_MULHSU) ? src1[31] : 1'b0;
  wire high_c   = (alu_op != OP_MUL);

  wire [31:0] a_mag_c = (a_signed && src1[31]) ? (~src1 + 32'd1) : src1;
  wire [31:0] b_mag_c = (b_signed && src2[31]) ? (~src2 + 32'd1) : src2;

  reg [2:0]    state;
  reg [31:0]   a_raw, b_raw;
  reg [4:0]    op_r;
  reg [31:0]   b1;
  reg [32:0]   b2;
  reg [33:0]   b3;
  reg [31:0]   a_shift;
  reg [AW-1:0] acc_sum, acc_carry;
  reg [CW-1:0] iter;
  reg          neg_r, high_r;
  reg          done_r;
  reg [AW-1:0] prod_r;

  assign done = done_r;

  // Magnitudes are computed from the latched raw operands in S_CONV, so the
  // forwarding mux and the 32-bit negate/add are not in the start-cycle path.
  wire a_signed_r = (op_r == OP_MUL) || (op_r == OP_MULH) || (op_r == OP_MULHSU);
  wire b_signed_r = (op_r == OP_MUL) || (op_r == OP_MULH);
  wire [31:0] a_mag_s = (a_signed_r && a_raw[31]) ? (~a_raw + 32'd1) : a_raw;
  wire [31:0] b_mag_s = (b_signed_r && b_raw[31]) ? (~b_raw + 32'd1) : b_raw;

  // Partial products for the current group of radix-4 digits.
  wire [1:0]  digit [0:DIGITS-1];
  wire [33:0] mult  [0:DIGITS-1];
  wire [AW-1:0] pp  [0:DIGITS-1];

  genvar gj;
  generate
    for (gj = 0; gj < DIGITS; gj = gj + 1) begin : g_pp
      // Process the multiplier MSB first.  Within a group the first digit is
      // the most significant one, so its partial product is shifted furthest.
      assign digit[gj] = a_shift[31 - 2*gj -: 2];
      assign mult[gj]  = (digit[gj] == 2'd0) ? 34'd0 :
                         (digit[gj] == 2'd1) ? {2'b0, b1} :
                         (digit[gj] == 2'd2) ? {1'b0, b2} : b3;
      assign pp[gj]    = {{(AW-34){1'b0}}, mult[gj]} << (2*(DIGITS-1-gj));
    end
  endgenerate

  // 3:2 carry-save compressor.  Returns {sum, carry}; the carry vector is
  // already shifted left by one, so the represented value is sum + carry.
  function [2*AW-1:0] csa3;
    input [AW-1:0] x;
    input [AW-1:0] y;
    input [AW-1:0] z;
    begin
      csa3 = {x ^ y ^ z, ((x & y) | (x & z) | (y & z)) << 1};
    end
  endfunction

  wire [AW-1:0] sum_s   = acc_sum   << (2*DIGITS);
  wire [AW-1:0] carry_s = acc_carry << (2*DIGITS);
  wire [AW-1:0] s0, c0, s1, c1, s2, c2, s3, c3;
  wire [AW-1:0] next_sum, next_carry;

  generate
    if (DIGITS == 1) begin : g_csa1
      assign {s0, c0}    = csa3(sum_s, carry_s, pp[0]);
      assign next_sum    = s0;
      assign next_carry  = c0;
    end else if (DIGITS == 2) begin : g_csa2
      assign {s0, c0}    = csa3(sum_s, carry_s, pp[0]);
      assign {s1, c1}    = csa3(s0, c0, pp[1]);
      assign next_sum    = s1;
      assign next_carry  = c1;
    end else begin : g_csa4
      assign {s0, c0}    = csa3(sum_s, carry_s, pp[0]);
      assign {s1, c1}    = csa3(pp[1], pp[2], pp[3]);
      assign {s2, c2}    = csa3(s0, c0, s1);
      assign {s3, c3}    = csa3(s2, c2, c1);
      assign next_sum    = s3;
      assign next_carry  = c3;
    end
  endgenerate

  always @(posedge clock) begin
    if (reset) begin
      state     <= S_IDLE;
      busy      <= 1'b0;
      done_r    <= 1'b0;
      res       <= 32'b0;
      a_raw     <= 32'b0;
      b_raw     <= 32'b0;
      op_r      <= 5'b0;
      b1        <= 32'b0;
      b2        <= 33'b0;
      b3        <= 34'b0;
      a_shift   <= 32'b0;
      acc_sum   <= {AW{1'b0}};
      acc_carry <= {AW{1'b0}};
      iter      <= {CW{1'b0}};
      neg_r     <= 1'b0;
      high_r    <= 1'b0;
      prod_r    <= {AW{1'b0}};
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            a_raw     <= src1;
            b_raw     <= src2;
            op_r      <= alu_op;
            neg_r     <= neg_c;
            high_r    <= high_c;
            acc_sum   <= {AW{1'b0}};
            acc_carry <= {AW{1'b0}};
            iter      <= {CW{1'b0}};
            busy      <= 1'b1;
            state     <= S_CONV;
          end
        end

        S_CONV: begin
          b1        <= b_mag_s;
          b2        <= {1'b0, b_mag_s} << 1;
          b3        <= ({2'b0, b_mag_s} << 1) + {2'b0, b_mag_s};
          a_shift   <= a_mag_s;
          if ((a_mag_s == 32'b0) || (b_mag_s == 32'b0)) begin
            res    <= 32'b0;
            done_r <= 1'b1;
            state  <= S_DONE;
          end else begin
            state  <= S_ITER;
          end
        end

        S_ITER: begin
          acc_sum   <= next_sum;
          acc_carry <= next_carry;
          a_shift   <= a_shift << (2*DIGITS);
          if (iter == LAST) begin
            state <= S_FINAL;
          end else begin
            iter  <= iter + 1'b1;
          end
        end

        S_FINAL: begin
          // ~sum + ~carry + 2 == -(sum + carry) in two's complement.
          prod_r <= (neg_r ? ~acc_sum : acc_sum) +
                    (neg_r ? ~acc_carry : acc_carry) +
                    {{(AW-2){1'b0}}, neg_r, 1'b0};
          state  <= S_SELECT;
        end

        S_SELECT: begin
          res    <= high_r ? prod_r[63:32] : prod_r[31:0];
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
