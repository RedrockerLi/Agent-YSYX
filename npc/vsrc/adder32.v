`timescale 1ns / 1ps

// 32-bit Kogge-Stone prefix adder.  Five prefix levels resolve every carry
// in parallel instead of a carry-select group chain.
module adder32 (
  input  [31:0] a,
  input  [31:0] b,
  input         cin,
  output [31:0] sum,
  output        cout
);

  wire [31:0] p0 = a ^ b;
  wire [31:0] g0 = a & b;

  wire [31:0] p1 = p0 & {p0[30:0], 1'b1};
  wire [31:0] g1 = g0 | (p0 & {g0[30:0], 1'b0});

  wire [31:0] p2 = p1 & {p1[29:0], 2'b11};
  wire [31:0] g2 = g1 | (p1 & {g1[29:0], 2'b00});

  wire [31:0] p3 = p2 & {p2[27:0], 4'b1111};
  wire [31:0] g3 = g2 | (p2 & {g2[27:0], 4'b0000});

  wire [31:0] p4 = p3 & {p3[23:0], 8'hFF};
  wire [31:0] g4 = g3 | (p3 & {g3[23:0], 8'h00});

  wire [31:0] p5 = p4 & {p4[15:0], 16'hFFFF};
  wire [31:0] g5 = g4 | (p4 & {g4[15:0], 16'h0000});

  wire [31:0] carry;
  assign carry[0] = cin;

  genvar i;
  generate
    for (i = 1; i < 32; i = i + 1) begin : g_carry
      assign carry[i] = g5[i-1] | (p5[i-1] & cin);
    end
  endgenerate

  assign sum  = p0 ^ carry;
  assign cout = g5[31] | (p5[31] & cin);

endmodule
