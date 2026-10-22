`timescale 1ns / 1ps

// 32-bit carry-select adder with a Kogge-Stone prefix over 4-bit groups.
// The group sums for carry-in 0 and 1 are computed in parallel, and the
// group carries are resolved by a 3-level prefix tree.
module adder32 (
  input  [31:0] a,
  input  [31:0] b,
  input         cin,
  output [31:0] sum,
  output        cout
);

  wire [31:0] sum0, sum1;
  wire [7:0]  cout0, cout1;

  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_group
      wire [4:0] r0 = {1'b0, a[4*g +: 4]} + {1'b0, b[4*g +: 4]};
      wire [4:0] r1 = r0 + 5'd1;
      assign sum0[4*g +: 4] = r0[3:0];
      assign cout0[g]      = r0[4];
      assign sum1[4*g +: 4] = r1[3:0];
      assign cout1[g]      = r1[4];
    end
  endgenerate

  // Group generate / propagate.
  wire [7:0] g0 = cout0;
  wire [7:0] p0 = cout1 & ~cout0;

  // Kogge-Stone prefix, distances 1, 2, 4.
  wire [7:0] g1 = g0 | (p0 & {g0[6:0], 1'b0});
  wire [7:0] p1 = p0 & {p0[6:0], 1'b1};
  wire [7:0] g2 = g1 | (p1 & {g1[5:0], 2'b0});
  wire [7:0] p2 = p1 & {p1[5:0], 2'b11};
  wire [7:0] g3 = g2 | (p2 & {g2[3:0], 4'b0});
  wire [7:0] p3 = p2 & {p2[3:0], 4'b1111};

  wire [7:0] carry;
  assign carry[0] = cin;
  generate
    for (g = 1; g < 8; g = g + 1) begin : g_carry
      assign carry[g] = g3[g-1] | (p3[g-1] & cin);
    end
  endgenerate
  assign cout = g3[7] | (p3[7] & cin);

  generate
    for (g = 0; g < 8; g = g + 1) begin : g_sum
      assign sum[4*g +: 4] = carry[g] ? sum1[4*g +: 4] : sum0[4*g +: 4];
    end
  endgenerate

endmodule
