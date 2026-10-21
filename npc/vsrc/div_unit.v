`timescale 1ns / 1ps

// 8-cycle radix-16 restoring divider for RV32M DIV/DIVU/REM/REMU.
// One 4-bit quotient digit is produced per cycle (iterations 0..7).
// The CPU holds the divide in EX until `accept` is asserted.
module div_unit (
  input             clock,
  input             reset,
  input             start,      // one-cycle start pulse from EX
  input             accept,     // CPU accepts the result (done && !mem_stall)
  input      [4:0]  alu_op,     // DIV=14, DIVU=15, REM=16, REMU=17
  input      [31:0] src1,
  input      [31:0] src2,
  output reg        busy,
  output            done,
  output     [31:0] res
);

  // -------------------------------------------------------------------------
  // Operand magnitudes and sign information
  // -------------------------------------------------------------------------
  wire        is_signed = ~alu_op[0];
  wire        is_rem    = alu_op[4];
  wire        sign1     = src1[31];
  wire        sign2     = src2[31];

  wire [31:0] a_mag = (is_signed && sign1) ? (~src1 + 32'd1) : src1;
  wire [31:0] b_mag = (is_signed && sign2) ? (~src2 + 32'd1) : src2;

  reg         is_signed_r;
  reg         is_rem_r;
  reg         q_sign_r;
  reg         r_sign_r;
  reg  [31:0] dividend;
  reg  [31:0] quot;
  reg  [31:0] rem;
  reg  [2:0]  iter;

  // Odd multiples of the divisor (36 bits is enough for 15 * (2^32-1)).
  // They must be computed from the start-cycle b_mag, not from a registered
  // divisor (nonblocking assignment would sample the old value).
  reg [35:0] m1, m3, m5, m7, m9, m11, m13, m15;

  wire [35:0] b36_mag = {4'b0, b_mag};
  wire [35:0] m1_s = b36_mag;
  wire [35:0] m3_s = (b36_mag << 1) + b36_mag;
  wire [35:0] m5_s = (b36_mag << 2) + b36_mag;
  wire [35:0] m7_s = (b36_mag << 2) + m3_s;
  wire [35:0] m9_s = (b36_mag << 3) + b36_mag;
  wire [35:0] m11_s = (b36_mag << 3) + m3_s;
  wire [35:0] m13_s = (b36_mag << 3) + m5_s;
  wire [35:0] m15_s = (b36_mag << 3) + m7_s;

  // Combinational multiples derived from the registered odd multiples.
  wire [35:0] k1  = m1;
  wire [35:0] k2  = m1 << 1;
  wire [35:0] k3  = m3;
  wire [35:0] k4  = m1 << 2;
  wire [35:0] k5  = m5;
  wire [35:0] k6  = m3 << 1;
  wire [35:0] k7  = m7;
  wire [35:0] k8  = m1 << 3;
  wire [35:0] k9  = m9;
  wire [35:0] k10 = m5 << 1;
  wire [35:0] k11 = m11;
  wire [35:0] k12 = m3 << 2;
  wire [35:0] k13 = m13;
  wire [35:0] k14 = m7 << 1;
  wire [35:0] k15 = m15;

  // -------------------------------------------------------------------------
  // Iteration chunk and remainder shift
  // -------------------------------------------------------------------------
  reg [3:0] chunk;
  always @(*) begin
    case (iter)
      3'd1: chunk = dividend[27:24];
      3'd2: chunk = dividend[23:20];
      3'd3: chunk = dividend[19:16];
      3'd4: chunk = dividend[15:12];
      3'd5: chunk = dividend[11:8];
      3'd6: chunk = dividend[7:4];
      3'd7: chunk = dividend[3:0];
      default: chunk = 4'b0;
    endcase
  end

  wire [35:0] rem_shift = {rem, chunk};

  // -------------------------------------------------------------------------
  // Quotient digit selection for iterations 1..7
  // -------------------------------------------------------------------------
  wire ge1  = (rem_shift >= k1);
  wire ge2  = (rem_shift >= k2);
  wire ge3  = (rem_shift >= k3);
  wire ge4  = (rem_shift >= k4);
  wire ge5  = (rem_shift >= k5);
  wire ge6  = (rem_shift >= k6);
  wire ge7  = (rem_shift >= k7);
  wire ge8  = (rem_shift >= k8);
  wire ge9  = (rem_shift >= k9);
  wire ge10 = (rem_shift >= k10);
  wire ge11 = (rem_shift >= k11);
  wire ge12 = (rem_shift >= k12);
  wire ge13 = (rem_shift >= k13);
  wire ge14 = (rem_shift >= k14);
  wire ge15 = (rem_shift >= k15);

  reg [3:0] qdigit;
  always @(*) begin
    qdigit = 4'd0;
    if (ge1)  qdigit = 4'd1;
    if (ge2)  qdigit = 4'd2;
    if (ge3)  qdigit = 4'd3;
    if (ge4)  qdigit = 4'd4;
    if (ge5)  qdigit = 4'd5;
    if (ge6)  qdigit = 4'd6;
    if (ge7)  qdigit = 4'd7;
    if (ge8)  qdigit = 4'd8;
    if (ge9)  qdigit = 4'd9;
    if (ge10) qdigit = 4'd10;
    if (ge11) qdigit = 4'd11;
    if (ge12) qdigit = 4'd12;
    if (ge13) qdigit = 4'd13;
    if (ge14) qdigit = 4'd14;
    if (ge15) qdigit = 4'd15;
  end

  reg [35:0] qmul;
  always @(*) begin
    case (qdigit)
      4'd0:  qmul = 36'b0;
      4'd1:  qmul = k1;
      4'd2:  qmul = k2;
      4'd3:  qmul = k3;
      4'd4:  qmul = k4;
      4'd5:  qmul = k5;
      4'd6:  qmul = k6;
      4'd7:  qmul = k7;
      4'd8:  qmul = k8;
      4'd9:  qmul = k9;
      4'd10: qmul = k10;
      4'd11: qmul = k11;
      4'd12: qmul = k12;
      4'd13: qmul = k13;
      4'd14: qmul = k14;
      default: qmul = k15;
    endcase
  end

  wire [35:0] rem_next = rem_shift - qmul;
  wire [31:0] quot_next = {quot[27:0], qdigit};

  // -------------------------------------------------------------------------
  // Start cycle: first 4-bit chunk, including the small-divisor case
  // -------------------------------------------------------------------------
  wire [31:0] src1_chunk0 = {28'b0, a_mag[31:28]};

  reg [3:0] q0;
  always @(*) begin
    q0 = 4'd0;
    if (b_mag <= 32'd15) begin
      if (src1_chunk0 >= (b_mag * 32'd1))  q0 = 4'd1;
      if (src1_chunk0 >= (b_mag * 32'd2))  q0 = 4'd2;
      if (src1_chunk0 >= (b_mag * 32'd3))  q0 = 4'd3;
      if (src1_chunk0 >= (b_mag * 32'd4))  q0 = 4'd4;
      if (src1_chunk0 >= (b_mag * 32'd5))  q0 = 4'd5;
      if (src1_chunk0 >= (b_mag * 32'd6))  q0 = 4'd6;
      if (src1_chunk0 >= (b_mag * 32'd7))  q0 = 4'd7;
      if (src1_chunk0 >= (b_mag * 32'd8))  q0 = 4'd8;
      if (src1_chunk0 >= (b_mag * 32'd9))  q0 = 4'd9;
      if (src1_chunk0 >= (b_mag * 32'd10)) q0 = 4'd10;
      if (src1_chunk0 >= (b_mag * 32'd11)) q0 = 4'd11;
      if (src1_chunk0 >= (b_mag * 32'd12)) q0 = 4'd12;
      if (src1_chunk0 >= (b_mag * 32'd13)) q0 = 4'd13;
      if (src1_chunk0 >= (b_mag * 32'd14)) q0 = 4'd14;
      if (src1_chunk0 >= (b_mag * 32'd15)) q0 = 4'd15;
    end
  end

  wire [35:0] b36 = {4'b0, b_mag};
  wire [35:0] q0mul = (q0[0] ? b36 : 36'b0) +
                      (q0[1] ? (b36 << 1) : 36'b0) +
                      (q0[2] ? (b36 << 2) : 36'b0) +
                      (q0[3] ? (b36 << 3) : 36'b0);
  wire [35:0] rem0 = {4'b0, src1_chunk0} - q0mul;

  // -------------------------------------------------------------------------
  // Result formatting
  // -------------------------------------------------------------------------
  wire [31:0] quot_final = (iter == 3'd7) ? quot_next : quot;
  wire [31:0] rem_final  = (iter == 3'd7) ? rem_next[31:0] : rem;
  wire [31:0] q_corrected = q_sign_r ? (~quot_final + 32'd1) : quot_final;
  wire [31:0] r_corrected = r_sign_r ? (~rem_final + 32'd1) : rem_final;

  // A zero divisor occupies one busy cycle (iter is forced to 7), so the
  // done/accept handshake is identical for every divide instruction.
  assign done = busy && (iter == 3'd7);

  assign res = (src2 == 32'b0) ? (is_rem ? src1 : 32'hffffffff) :
               (is_rem_r ? r_corrected : q_corrected);

  // -------------------------------------------------------------------------
  // Sequential state
  // -------------------------------------------------------------------------
  always @(posedge clock) begin
    if (reset) begin
      busy        <= 1'b0;
      iter        <= 3'd0;
      quot        <= 32'b0;
      rem         <= 32'b0;
      dividend    <= 32'b0;
      is_signed_r <= 1'b0;
      is_rem_r    <= 1'b0;
      q_sign_r    <= 1'b0;
      r_sign_r    <= 1'b0;
      m1  <= 36'b0;
      m3  <= 36'b0;
      m5  <= 36'b0;
      m7  <= 36'b0;
      m9  <= 36'b0;
      m11 <= 36'b0;
      m13 <= 36'b0;
      m15 <= 36'b0;
    end else if (start) begin
      dividend    <= a_mag;
      is_signed_r <= is_signed;
      is_rem_r    <= is_rem;
      q_sign_r    <= is_signed && (sign1 ^ sign2);
      r_sign_r    <= is_signed && sign1;
      quot        <= (src2 == 32'b0) ? 32'b0 : {28'b0, q0};
      rem         <= (src2 == 32'b0) ? 32'b0 : rem0[31:0];
      iter        <= (src2 == 32'b0) ? 3'd7 : 3'd1;
      busy        <= 1'b1;
      m1  <= m1_s;
      m3  <= m3_s;
      m5  <= m5_s;
      m7  <= m7_s;
      m9  <= m9_s;
      m11 <= m11_s;
      m13 <= m13_s;
      m15 <= m15_s;
    end else if (busy) begin
      if (iter == 3'd7) begin
        if (accept) begin
          quot <= quot_next;
          rem  <= rem_next[31:0];
          busy <= 1'b0;
        end
      end else begin
        quot <= quot_next;
        rem  <= rem_next[31:0];
        iter <= iter + 3'd1;
      end
    end
  end

endmodule
