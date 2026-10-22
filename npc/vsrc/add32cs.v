`timescale 1ns / 1ps

// 32-bit adder as four parallel 8-bit adds with a carry select.  The group
// sums for carry-in 0 and 1 are computed together, then the group carries are
// resolved with a two-level select, keeping the carry chain short.
module add32cs (
  input  [31:0] a,
  input  [31:0] b,
  input         cin,
  output [31:0] sum,
  output        cout
);

  wire [8:0] s0 = {1'b0, a[7:0]}   + {1'b0, b[7:0]}   + {8'b0, cin};
  wire [8:0] s1 = {1'b0, a[15:8]}  + {1'b0, b[15:8]};
  wire [8:0] s2 = {1'b0, a[23:16]} + {1'b0, b[23:16]};
  wire [8:0] s3 = {1'b0, a[31:24]} + {1'b0, b[31:24]};

  wire [8:0] s1p = s1 + 9'd1;
  wire [8:0] s2p = s2 + 9'd1;
  wire [8:0] s3p = s3 + 9'd1;

  wire c1 = s0[8];
  wire c2 = c1 ? s1p[8] : s1[8];
  wire c3 = c2 ? s2p[8] : s2[8];

  assign sum  = {c3 ? s3p[7:0] : s3[7:0],
                 c2 ? s2p[7:0] : s2[7:0],
                 c1 ? s1p[7:0] : s1[7:0],
                 s0[7:0]};
  assign cout = c3 ? s3p[8] : s3[8];

endmodule
