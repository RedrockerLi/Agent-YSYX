`timescale 1ns / 1ps

module ysyx_261018_regfile #(
  parameter NUM_REGS = 32
) (
  input             clk,
  input             rst,
  input      [4:0]  rs1_addr,
  input      [4:0]  rs2_addr,
  output     [31:0] rs1_data,
  output     [31:0] rs2_data,
  input             wen,
  input      [4:0]  rd_addr,
  input      [31:0] wdata
);

  reg [31:0] rf [0:NUM_REGS-1];

  assign rs1_data = (rs1_addr == 5'b0) ? 32'b0 :
                    (wen && (rd_addr == rs1_addr)) ? wdata : rf[rs1_addr];
  assign rs2_data = (rs2_addr == 5'b0) ? 32'b0 :
                    (wen && (rd_addr == rs2_addr)) ? wdata : rf[rs2_addr];

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < NUM_REGS; i = i + 1) begin
        rf[i] <= 32'b0;
      end
    end else if (wen && (rd_addr != 5'b0)) begin
      rf[rd_addr] <= wdata;
    end
  end

  function [31:0] get_gpr_val(input [4:0] idx);
    get_gpr_val = (idx == 5'b0) ? 32'b0 : rf[idx];
  endfunction

endmodule
