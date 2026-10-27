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
  localparam S_CONV2 = 3'd5;
  localparam S_ITER = 3'd2;
  localparam S_ITER2 = 3'd7;
  localparam S_SIGN = 3'd3;
  localparam S_SIGN2 = 3'd6;
  localparam S_DONE = 3'd4;

  wire is_signed = ~alu_op[0];
  wire is_rem    = alu_op[4];

  reg [2:0]    state;
  reg [31:0]   a_raw, b_raw;
  reg [31:0]   a_neg_r, b_neg_r;
  reg [31:0]   a_mag, b_mag;
  reg          sign1_r, sign2_r;
  reg          is_signed_r, is_rem_r;
  reg [31:0]   dividend;
  reg [31:0]   q_neg_r, r_neg_r;
  reg [31:0]   quot;
  reg [PW-1:0] rem;
  reg [CW-1:0] iter;
  reg          zero_div;
  reg          done_r;

  assign done = done_r;

  // 32-bit two's-complement negate as two parallel 16-bit halves.  The high
  // half is selected by the low half's zero detect, not by a carry chain.
  wire [15:0] a_neg_lo = ~a_raw[15:0] + 16'd1;
  wire [15:0] a_neg_hi = ~a_raw[31:16] + 16'd1;
  wire [15:0] b_neg_lo = ~b_raw[15:0] + 16'd1;
  wire [15:0] b_neg_hi = ~b_raw[31:16] + 16'd1;
  wire        a_lo_zero = ~|a_raw[15:0];
  wire        b_lo_zero = ~|b_raw[15:0];
  wire [31:0] a_mag_neg = {a_lo_zero ? a_neg_hi : ~a_raw[31:16], a_neg_lo};
  wire [31:0] b_mag_neg = {b_lo_zero ? b_neg_hi : ~b_raw[31:16], b_neg_lo};

  wire [31:0] a_mag_c = (is_signed_r && sign1_r) ? a_neg_r : a_raw;
  wire [31:0] b_mag_c = (is_signed_r && sign2_r) ? b_neg_r : b_raw;

  localparam [31:0]   ITERS_V = ITERS;
  localparam [CW-1:0] LAST    = ITERS_V[CW-1:0] - 1'b1;

  // One cycle worth of restoring division: K serial radix-2 steps.
  reg [PW-1:0] rem_t;
  reg [31:0]   quot_t;
  reg [31:0]   div_t;
  // Radix-2 iteration registers: the compare/subtract and the restore/select
  // are split so the subtract tail does not chain into the remainder flops.
  reg [32:0]   a33_r, diff33_r;
  reg          ge_r;
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

  wire [15:0] q_neg_lo = ~quot[15:0] + 16'd1;
  wire [15:0] q_neg_hi = ~quot[31:16] + 16'd1;
  wire [15:0] r_neg_lo = ~rem[15:0] + 16'd1;
  wire [15:0] r_neg_hi = ~rem[31:16] + 16'd1;
  wire        q_lo_zero = ~|quot[15:0];
  wire        r_lo_zero = ~|rem[15:0];
  wire [31:0] q_neg = {q_lo_zero ? q_neg_hi : ~quot[31:16], q_neg_lo};
  wire [31:0] r_neg = {r_lo_zero ? r_neg_hi : ~rem[31:16], r_neg_lo};

  wire [31:0] q_final = q_sign ? q_neg_r : quot;
  wire [31:0] r_final = r_sign ? r_neg_r : rem[31:0];

  always @(posedge clock) begin
    if (reset) begin
      state       <= S_IDLE;
      busy        <= 1'b0;
      done_r      <= 1'b0;
      res         <= 32'b0;
      a_raw       <= 32'b0;
      b_raw       <= 32'b0;
      a_neg_r     <= 32'b0;
      b_neg_r     <= 32'b0;
      a_mag       <= 32'b0;
      b_mag       <= 32'b0;
      sign1_r     <= 1'b0;
      sign2_r     <= 1'b0;
      is_signed_r <= 1'b0;
      is_rem_r    <= 1'b0;
      dividend    <= 32'b0;
      q_neg_r     <= 32'b0;
      r_neg_r     <= 32'b0;
      quot        <= 32'b0;
      a33_r       <= 33'b0;
      diff33_r    <= 33'b0;
      ge_r        <= 1'b0;
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
          // Register the negated magnitudes first; the sign mux gets its own
          // cycle so the 32-bit increment is not followed by a mux.
          a_neg_r  <= a_mag_neg;
          b_neg_r  <= b_mag_neg;
          zero_div <= (b_raw == 32'b0);
          state    <= S_CONV2;
        end

        S_CONV2: begin
          a_mag    <= a_mag_c;
          b_mag    <= b_mag_c;
          dividend <= a_mag_c;
          quot     <= 32'b0;
          rem      <= {PW{1'b0}};
          iter     <= {CW{1'b0}};
          state    <= zero_div ? S_SIGN : S_ITER;
        end

        S_ITER: begin
          if (K == 1) begin
            a33_r    <= div_a33;
            diff33_r <= div_diff33;
            ge_r     <= div_ge33;
            dividend <= dividend << 1;
            state    <= S_ITER2;
          end else if (iter == LAST) begin
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

        S_ITER2: begin
          rem  <= ge_r ? diff33_r : a33_r;
          quot <= {quot[30:0], ge_r};
          if (iter == LAST)
            state <= S_SIGN;
          else begin
            iter  <= iter + 1'b1;
            state <= S_ITER;
          end
        end

        S_SIGN: begin
          // quot/rem hold the final magnitudes.  The negations get their own
          // cycle so the 32-bit add and the sign mux are not chained.
          q_neg_r <= q_neg;
          r_neg_r <= r_neg;
          state   <= S_SIGN2;
        end

        S_SIGN2: begin
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
