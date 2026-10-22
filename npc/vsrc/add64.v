`timescale 1ns / 1ps

// 64-bit carry-select adder: two 32-bit carry-select groups with the high
// group's carry chosen by the low group's carry-out.
module add64 (
  input  [63:0] a,
  input  [63:0] b,
  input         cin,
  output [63:0] sum
);

  wire [31:0] lo_sum;
  wire [31:0] hi_sum0, hi_sum1;
  wire        lo_cout;
  wire        hi_cout0, hi_cout1;

  adder32 u_lo (
    .a    (a[31:0]),
    .b    (b[31:0]),
    .cin  (cin),
    .sum  (lo_sum),
    .cout (lo_cout)
  );

  adder32 u_hi0 (
    .a    (a[63:32]),
    .b    (b[63:32]),
    .cin  (1'b0),
    .sum  (hi_sum0),
    .cout (hi_cout0)
  );

  adder32 u_hi1 (
    .a    (a[63:32]),
    .b    (b[63:32]),
    .cin  (1'b1),
    .sum  (hi_sum1),
    .cout (hi_cout1)
  );

  assign sum = {lo_cout ? hi_sum1 : hi_sum0, lo_sum};

endmodule
