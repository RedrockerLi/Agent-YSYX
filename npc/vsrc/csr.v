`timescale 1ns / 1ps

module csr (
  input             clk,
  input             rst,
  input      [11:0] csr_addr,
  input      [2:0]  csr_op,     // 001: RW, 010: RS, 011: RC, 101: RWI, 110: RSI, 111: RCI
  input      [31:0] csr_wdata,
  input             csr_wen,
  output reg [31:0] csr_rdata,

  // Exception / Interrupt interface
  input             is_ecall,
  input             is_mret,
  input      [31:0] pc,
  output     [31:0] mtvec_out,
  output     [31:0] mepc_out
);

  reg [31:0] mstatus;
  reg [31:0] mtvec;
  reg [31:0] mepc;
  reg [31:0] mcause;
  reg [63:0] mcycle;

  // 64-bit cycle counter built from two 32-bit carry-select adders.
  wire [31:0] mcycle_lo_sum, mcycle_hi_sum;
  wire        mcycle_lo_cout;

  adder32 u_mcycle_lo (
    .a    (mcycle[31:0]),
    .b    (32'd1),
    .cin  (1'b0),
    .sum  (mcycle_lo_sum),
    .cout (mcycle_lo_cout)
  );

  adder32 u_mcycle_hi (
    .a    (mcycle[63:32]),
    .b    (32'd0),
    .cin  (mcycle_lo_cout),
    .sum  (mcycle_hi_sum),
    .cout ()
  );

  assign mtvec_out = mtvec;
  assign mepc_out  = mepc;

  // Read CSR
  always @(*) begin
    case (csr_addr)
      12'h300: csr_rdata = mstatus;
      12'h305: csr_rdata = mtvec;
      12'h341: csr_rdata = mepc;
      12'h342: csr_rdata = mcause;
      12'hb00,
      12'hc00: csr_rdata = mcycle[31:0];
      12'hb80,
      12'hc80: csr_rdata = mcycle[63:32];
      12'hf11: csr_rdata = 32'h0;        // mvendorid
      12'hf12: csr_rdata = 32'h0;        // marchid
      default: csr_rdata = 32'b0;
    endcase
  end

  // Calculate new CSR value
  reg [31:0] csr_val_new;
  always @(*) begin
    case (csr_op[1:0])
      2'b01: csr_val_new = csr_wdata;                  // RW / RWI
      2'b10: csr_val_new = csr_rdata | csr_wdata;       // RS / RSI
      2'b11: csr_val_new = csr_rdata & (~csr_wdata);    // RC / RCI
      default: csr_val_new = csr_rdata;
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      mstatus <= 32'h00001800; // MPP = 3 (Machine mode)
      mtvec   <= 32'b0;
      mepc    <= 32'b0;
      mcause  <= 32'b0;
      mcycle  <= 64'b0;
    end else begin
      mcycle <= {mcycle_hi_sum, mcycle_lo_sum};

      if (is_ecall) begin
        mepc    <= pc;
        mcause  <= 32'd11; // Environment call from M-mode
        mstatus <= {mstatus[31:13], 2'b11, mstatus[10:8], mstatus[3], mstatus[6:4], 1'b0, mstatus[2:0]};
      end else if (is_mret) begin
        mstatus <= {mstatus[31:13], 2'b00, mstatus[10:8], 1'b1, mstatus[6:4], mstatus[7], mstatus[2:0]};
      end else if (csr_wen) begin
        case (csr_addr)
          12'h300: mstatus <= csr_val_new;
          12'h305: mtvec   <= csr_val_new;
          12'h341: mepc    <= csr_val_new;
          12'h342: mcause  <= csr_val_new;
          default: ;
        endcase
      end
    end
  end

endmodule
