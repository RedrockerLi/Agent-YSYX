`timescale 1ns / 1ps

// 33-bit subtractor used by the radix-2 divider iteration.  The low 32 bits
// use the carry-select adder; the top bit is the 33rd remainder bit.
module sub33 (
  input  [32:0] a,
  input  [31:0] b,
  output [32:0] d,
  output        ge
);

  wire [31:0] sum;
  wire        cout;

  adder32 u_add (
    .a    (a[31:0]),
    .b    (~b),
    .cin  (1'b1),
    .sum  (sum),
    .cout (cout)
  );

  assign ge = a[32] | cout;
  assign d  = {a[32] & cout, sum};

endmodule
