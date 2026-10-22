`timescale 1ns / 1ps

// Parameterized restoring divider for RV32M DIV/DIVU/REM/REMU.
//
// DIV_BITS_PER_CYCLE selects how many quotient bits are produced per cycle:
//   1 -> radix-2,  32 iterations (~35 cycles total)
//   2 -> radix-4,  16 iterations (~19 cycles total)
//   4 -> radix-16,  8 iterations (~11 cycles total)
//
// The per-cycle logic is a chain of DIV_BITS_PER_CYCLE radix-2 compare/
// subtract steps.  The old radix-16 implementation precomputed 15 multiples
// and a q0 add tree in the start cycle; that structure is gone.
module div_unit #(
  parameter DIV_BITS_PER_CYCLE = 2
) (
  input             clock,
  input             reset,
  input             start,      // one-cycle start pulse from EX
  input             accept,     // CPU accepts the result (done && !mem_stall)
  input      [4:0]  alu_op,     // DIV=14, DIVU=15, REM=16, REMU=17
  input      [31:0] src1,
  input      [31:0] src2,
  output reg        busy,
  output            done,
  output reg [31:0] res
);

  localparam K     = DIV_BITS_PER_CYCLE;
  localparam ITERS = 32 / K;
  localparam PW    = 32 + K;                 // partial remainder width
  localparam CW    = (ITERS <= 2) ? 1 : $clog2(ITERS);

  localparam S_IDLE = 3'd0;
  localparam S_CONV = 3'd1;
  localparam S_ITER = 3'd2;
  localparam S_SIGN = 3'd3;
  localparam S_DONE = 3'd4;

  wire is_signed = ~alu_op[0];
  wire is_rem    = alu_op[4];

  reg [2:0]    state;
  reg [31:0]   a_raw, b_raw;
  reg [31:0]   a_mag, b_mag;
  reg          sign1_r, sign2_r;
  reg          is_signed_r, is_rem_r;
  reg [31:0]   dividend;
  reg [31:0]   quot;
  reg [PW-1:0] rem;
  reg [CW-1:0] iter;
  reg          zero_div;
  reg          done_r;

  assign done = done_r;

  wire [31:0] a_mag_neg, b_mag_neg;
  wire        a_mag_cout, b_mag_cout;

  adder32 u_a_mag (
    .a    (~a_raw),
    .b    (32'd0),
    .cin  (1'b1),
    .sum  (a_mag_neg),
    .cout (a_mag_cout)
  );

  adder32 u_b_mag (
    .a    (~b_raw),
    .b    (32'd0),
    .cin  (1'b1),
    .sum  (b_mag_neg),
    .cout (b_mag_cout)
  );

  wire [31:0] a_mag_c = (is_signed_r && sign1_r) ? a_mag_neg : a_raw;
  wire [31:0] b_mag_c = (is_signed_r && sign2_r) ? b_mag_neg : b_raw;

  localparam [31:0]   ITERS_V = ITERS;
  localparam [CW-1:0] LAST    = ITERS_V[CW-1:0] - 1'b1;

  // One cycle worth of restoring division: K serial radix-2 steps.
  reg [PW-1:0] rem_t;
  reg [31:0]   quot_t;
  reg [31:0]   div_t;
  reg [PW:0]   shifted_r;
  reg [PW:0]   b_ext_r;
  reg [PW:0]   diff_r;
  integer      i;

  // Radix-2 fast path: one carry-select subtractor instead of a synthesised
  // 33-bit ripple subtract.
  wire [32:0] div_a33    = {rem[31:0], dividend[31]};
  wire [32:0] div_diff33;
  wire        div_ge33;
  sub33 u_sub33 (
    .a  (div_a33),
    .b  (b_mag),
    .d  (div_diff33),
    .ge (div_ge33)
  );

  always @(*) begin
    rem_t   = rem;
    quot_t  = quot;
    div_t   = dividend;
    if (K == 1) begin
      rem_t  = div_ge33 ? div_diff33 : div_a33;
      quot_t = {quot[30:0], div_ge33};
      div_t  = dividend << 1;
    end else begin
      b_ext_r = {{(PW + 1 - 32){1'b0}}, b_mag};
      for (i = 0; i < K; i = i + 1) begin
        shifted_r = {rem_t, div_t[31]};
        diff_r    = shifted_r - b_ext_r;
        if (shifted_r >= b_ext_r) begin
          rem_t  = diff_r[PW-1:0];
          quot_t = {quot_t[30:0], 1'b1};
        end else begin
          rem_t  = shifted_r[PW-1:0];
          quot_t = {quot_t[30:0], 1'b0};
        end
        div_t = div_t << 1;
      end
    end
  end

  wire q_sign = is_signed_r && (sign1_r ^ sign2_r);
  wire r_sign = is_signed_r && sign1_r;

  wire [31:0] q_neg, r_neg;
  wire        q_neg_cout, r_neg_cout;

  adder32 u_q_neg (
    .a    (~quot),
    .b    (32'd0),
    .cin  (1'b1),
    .sum  (q_neg),
    .cout (q_neg_cout)
  );

  adder32 u_r_neg (
    .a    (~rem[31:0]),
    .b    (32'd0),
    .cin  (1'b1),
    .sum  (r_neg),
    .cout (r_neg_cout)
  );

  wire [31:0] q_final = q_sign ? q_neg : quot;
  wire [31:0] r_final = r_sign ? r_neg : rem[31:0];

  always @(posedge clock) begin
    if (reset) begin
      state       <= S_IDLE;
      busy        <= 1'b0;
      done_r      <= 1'b0;
      res         <= 32'b0;
      a_raw       <= 32'b0;
      b_raw       <= 32'b0;
      a_mag       <= 32'b0;
      b_mag       <= 32'b0;
      sign1_r     <= 1'b0;
      sign2_r     <= 1'b0;
      is_signed_r <= 1'b0;
      is_rem_r    <= 1'b0;
      dividend    <= 32'b0;
      quot        <= 32'b0;
      rem         <= {PW{1'b0}};
      iter        <= {CW{1'b0}};
      zero_div    <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            a_raw       <= src1;
            b_raw       <= src2;
            sign1_r     <= src1[31];
            sign2_r     <= src2[31];
            is_signed_r <= is_signed;
            is_rem_r    <= is_rem;
            busy        <= 1'b1;
            state       <= S_CONV;
          end
        end

        S_CONV: begin
          a_mag    <= a_mag_c;
          b_mag    <= b_mag_c;
          dividend <= a_mag_c;
          quot     <= 32'b0;
          rem      <= {PW{1'b0}};
          iter     <= {CW{1'b0}};
          zero_div <= (b_raw == 32'b0);
          state    <= (b_raw == 32'b0) ? S_SIGN : S_ITER;
        end

        S_ITER: begin
          if (iter == LAST) begin
            quot  <= quot_t;
            rem   <= rem_t;
            state <= S_SIGN;
          end else begin
            quot     <= quot_t;
            rem      <= rem_t;
            dividend <= div_t;
            iter     <= iter + 1'b1;
          end
        end

        S_SIGN: begin
          // quot/rem hold the final magnitudes.  Register the sign-corrected
          // result so the CPU sees a stable value in S_DONE.
          if (zero_div)
            res <= is_rem_r ? a_raw : 32'hffffffff;
          else
            res <= is_rem_r ? r_final : q_final;
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
