`timescale 1ns / 1ps

// 16-bit adder built as two parallel 8-bit adds with a carry select.  The
// carry chain of the library's gates makes a 16-bit carry propagate adder too
// slow for the target period, while the 8-bit halves plus one mux fit.
module add16cs (
  input  [15:0] a,
  input  [15:0] b,
  input         cin,
  output [15:0] sum,
  output        cout
);

  wire [8:0] lo0 = {1'b0, a[7:0]} + {1'b0, b[7:0]} + {8'b0, cin};
  wire [8:0] hi0 = {1'b0, a[15:8]} + {1'b0, b[15:8]};
  wire [8:0] hi1 = hi0 + 9'd1;
  wire [8:0] his = lo0[8] ? hi1 : hi0;

  assign sum  = {his[7:0], lo0[7:0]};
  assign cout = his[8];

endmodule
