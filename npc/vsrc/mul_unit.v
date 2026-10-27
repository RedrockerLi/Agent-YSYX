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

  localparam S_IDLE   = 4'd0;
  localparam S_CONV   = 4'd5;
  localparam S_MULT   = 4'd7;
  localparam S_MULT2  = 4'd11;
  localparam S_ITER   = 4'd1;
  localparam S_FINAL  = 4'd2;
  localparam S_FINAL_HI = 4'd8;
  localparam S_NEG    = 4'd6;
  localparam S_NEG_HI = 4'd9;
  localparam S_NEG_SEL = 4'd10;
  localparam S_SELECT = 4'd3;
  localparam S_DONE   = 4'd4;

  // Operand signs.  Magnitudes are multiplied, then the 64-bit product is
  // negated for the signed variants.  MULHSU treats only src1 as signed.
  wire a_signed = (alu_op == OP_MUL) || (alu_op == OP_MULH) || (alu_op == OP_MULHSU);
  wire b_signed = (alu_op == OP_MUL) || (alu_op == OP_MULH);
  wire neg_c    = ((alu_op == OP_MUL) || (alu_op == OP_MULH)) ? (src1[31] ^ src2[31]) :
                  (alu_op == OP_MULHSU) ? src1[31] : 1'b0;
  wire high_c   = (alu_op != OP_MUL);

  wire [31:0] a_mag_c = (a_signed && src1[31]) ? (~src1 + 32'd1) : src1;
  wire [31:0] b_mag_c = (b_signed && src2[31]) ? (~src2 + 32'd1) : src2;

  reg [3:0]    state;
  reg [31:0]   a_raw, b_raw;
  reg [4:0]    op_r;
  reg [31:0]   a_mag_r, b_mag_r;
  reg [31:0]   b1;
  reg [32:0]   b2;
  reg [33:0]   b3;
  reg [31:0]   a_shift;
  reg [AW-1:0] acc_sum, acc_carry;
  reg [CW-1:0] iter;
  reg          neg_r, high_r;
  reg          done_r;
  reg [63:0]   prod_u;
  reg [63:0]   prod_r;
  reg [31:0]   prod_lo;
  reg          lo_cout_r;
  reg [31:0]   neg_lo_r;
  reg [31:0]   neg_hi_r;
  reg          neg_cout_r;

  // The 64-bit product sum and sign negation are split into two 32-bit
  // carry-select halves, one per cycle.
  wire [31:0] sum_lo, sum_hi;
  wire [31:0] neg_lo_sum, neg_hi_sum;
  wire        sum_lo_cout, neg_lo_cout;

  adder32 u_sum_lo (
    .a    (acc_sum[31:0]),
    .b    (acc_carry[31:0]),
    .cin  (1'b0),
    .sum  (sum_lo),
    .cout (sum_lo_cout)
  );

  adder32 u_sum_hi (
    .a    (acc_sum[63:32]),
    .b    (acc_carry[63:32]),
    .cin  (lo_cout_r),
    .sum  (sum_hi),
    .cout ()
  );

  // Two's-complement negate of the 64-bit product: each 32-bit half is a
  // carry-select of two parallel 16-bit adds.
  wire [31:0] p_lo = prod_u[31:0];
  wire [31:0] p_hi = prod_u[63:32];

  // Each 16-bit half is incremented independently and the high half is
  // selected by the low half's carry, which is a zero-detect rather than the
  // carry chain of a 16-bit adder.
  wire [15:0] nl_lo  = ~p_lo[15:0] + 16'd1;
  wire [15:0] nl_hi  = ~p_lo[31:16] + 16'd1;
  wire        lo_zero = ~|p_lo[15:0];
  assign neg_lo_sum  = {lo_zero ? nl_hi : ~p_lo[31:16], nl_lo};
  assign neg_lo_cout = ~|p_lo;

  wire [15:0] nh_lo = ~p_hi[15:0] + {15'b0, neg_cout_r};
  wire        nh_c  = neg_cout_r && ~|p_hi[15:0];
  assign neg_hi_sum = {nh_c ? (~p_hi[31:16] + 16'd1) : ~p_hi[31:16], nh_lo};

  assign done = done_r;

  // Magnitudes are computed from the latched raw operands in S_CONV, so the
  // forwarding mux and the 32-bit negate/add are not in the start-cycle path.
  wire a_signed_r = (op_r == OP_MUL) || (op_r == OP_MULH) || (op_r == OP_MULHSU);
  wire b_signed_r = (op_r == OP_MUL) || (op_r == OP_MULH);
  // Same carry-select shape as the product negation: the high-half select is
  // the low half's zero detect, not a 16-bit adder carry chain.
  wire [15:0] a_neg_lo = ~a_raw[15:0] + 16'd1;
  wire [15:0] a_neg_hi = ~a_raw[31:16] + 16'd1;
  wire [15:0] b_neg_lo = ~b_raw[15:0] + 16'd1;
  wire [15:0] b_neg_hi = ~b_raw[31:16] + 16'd1;
  wire        a_lo_zero = ~|a_raw[15:0];
  wire        b_lo_zero = ~|b_raw[15:0];
  wire [31:0] a_neg_sum = {a_lo_zero ? a_neg_hi : ~a_raw[31:16], a_neg_lo};
  wire [31:0] b_neg_sum = {b_lo_zero ? b_neg_hi : ~b_raw[31:16], b_neg_lo};

  wire [31:0] a_mag_s = (a_signed_r && a_raw[31]) ? a_neg_sum : a_raw;
  wire [31:0] b_mag_s = (b_signed_r && b_raw[31]) ? b_neg_sum : b_raw;

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

  // 3*b = b + 2*b, built from 16-bit halves so no 32-bit add is needed.
  reg  [16:0] b3_lo_r;
  wire [16:0] b3_hi_w = {1'b0, b1[31:16]} + {1'b0, b1[30:15]} + {16'b0, b3_lo_r[16]};
  wire [1:0]  b3_top  = {1'b0, b1[31]} + {1'b0, b3_hi_w[16]};

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
      a_mag_r   <= 32'b0;
      b_mag_r   <= 32'b0;
      b1        <= 32'b0;
      b2        <= 33'b0;
      b3        <= 34'b0;
      b3_lo_r   <= 17'b0;
      a_shift   <= 32'b0;
      acc_sum   <= {AW{1'b0}};
      acc_carry <= {AW{1'b0}};
      iter      <= {CW{1'b0}};
      neg_r     <= 1'b0;
      high_r    <= 1'b0;
      prod_u    <= 64'b0;
      prod_r    <= 64'b0;
      prod_lo   <= 32'b0;
      lo_cout_r <= 1'b0;
      neg_lo_r  <= 32'b0;
      neg_hi_r  <= 32'b0;
      neg_cout_r <= 1'b0;
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
          // Register the magnitudes first; the multiple generation runs from
          // these flops in the next cycle.
          a_mag_r <= a_mag_s;
          b_mag_r <= b_mag_s;
          b1      <= b_mag_s;
          state   <= S_MULT;
        end

        S_MULT: begin
          b2      <= {1'b0, b1} << 1;
          b3_lo_r <= {1'b0, b1[15:0]} + {1'b0, b1[14:0], 1'b0};
          a_shift <= a_mag_r;
          if ((a_mag_r == 32'b0) || (b_mag_r == 32'b0)) begin
            res    <= 32'b0;
            done_r <= 1'b1;
            state  <= S_DONE;
          end else begin
            state  <= S_MULT2;
          end
        end

        S_MULT2: begin
          // 3*b needs its own cycle: the high half adds on top of the low
          // half's carry.
          b3    <= {b3_top, b3_hi_w[15:0], b3_lo_r[15:0]};
          state <= S_ITER;
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
          prod_lo   <= sum_lo;
          lo_cout_r <= sum_lo_cout;
          state     <= S_FINAL_HI;
        end

        S_FINAL_HI: begin
          prod_u <= {sum_hi, prod_lo};
          state  <= S_NEG;
        end

        S_NEG: begin
          neg_lo_r   <= neg_lo_sum;
          neg_cout_r <= neg_lo_cout;
          state      <= S_NEG_HI;
        end

        S_NEG_HI: begin
          neg_hi_r <= neg_hi_sum;
          state    <= S_NEG_SEL;
        end

        S_NEG_SEL: begin
          prod_r <= neg_r ? {neg_hi_r, neg_lo_r} : prod_u;
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
