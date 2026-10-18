`timescale 1ns / 1ps

module ysyx_261018 (
  input         clock,
  input         reset,
  input         io_interrupt,
  input  [31:0] io_master_awready,
  input  [31:0] io_slave_awvalid
);

  // DPI-C imports for simulation memory access and trap detection
  import "DPI-C" context function int  pmem_read(input int raddr, input byte rlen);
  import "DPI-C" context function void pmem_write(input int waddr, input int wdata, input byte wmask);
  import "DPI-C" context function void npc_ebreak(input int pc, input int a0);

  reg [31:0] pc;

  // DPI-C exports for testbench inspection and DiffTest
  export "DPI-C" function get_pc;
  function int get_pc();
    get_pc = pc;
  endfunction

  export "DPI-C" function get_gpr;
  function int get_gpr(input int idx);
    get_gpr = u_regfile.get_gpr_val(idx[4:0]);
  endfunction

  // 1. Instruction Fetch
  wire [31:0] inst = pmem_read(pc, 8'd4);

  // 2. Decode fields
  wire [6:0]  opcode = inst[6:0];
  wire [4:0]  rd     = inst[11:7];
  wire [2:0]  funct3 = inst[14:12];
  wire [4:0]  rs1    = inst[19:15];
  wire [4:0]  rs2    = inst[24:20];
  wire [6:0]  funct7 = inst[31:25];

  // Immediates
  wire [31:0] immI = {{20{inst[31]}}, inst[31:20]};
  wire [31:0] immS = {{20{inst[31]}}, inst[31:25], inst[11:7]};
  wire [31:0] immB = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
  wire [31:0] immU = {inst[31:12], 12'b0};
  wire [31:0] immJ = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
  wire [31:0] zimm = {27'b0, inst[19:15]};

  // Instruction categories
  wire is_lui    = (opcode == 7'b0110111);
  wire is_auipc  = (opcode == 7'b0010111);
  wire is_jal    = (opcode == 7'b1101111);
  wire is_jalr   = (opcode == 7'b1100111 && funct3 == 3'b000);
  wire is_branch = (opcode == 7'b1100011);
  wire is_load   = (opcode == 7'b0000011);
  wire is_store  = (opcode == 7'b0100011);
  wire is_alu_i  = (opcode == 7'b0010011);
  wire is_alu_r  = (opcode == 7'b0110011);
  wire is_system = (opcode == 7'b1110011);
  wire is_fence  = (opcode == 7'b0001111);

  // System sub-instructions
  wire is_ebreak = is_system && (funct3 == 3'b000) && (inst[31:20] == 12'h001);
  wire is_ecall  = is_system && (funct3 == 3'b000) && (inst[31:20] == 12'h000);
  wire is_mret   = is_system && (funct3 == 3'b000) && (inst[31:20] == 12'h302);
  wire is_csr    = is_system && (funct3 != 3'b000);

  // 3. Register File
  wire [31:0] rs1_data;
  wire [31:0] rs2_data;
  reg  [31:0] rf_wdata;
  wire        rf_wen = (is_alu_r || is_alu_i || is_load || is_lui || is_auipc || is_jal || is_jalr || is_csr);

  ysyx_261018_regfile #(
    .NUM_REGS(32)
  ) u_regfile (
    .clk      (clock),
    .rst      (reset),
    .rs1_addr (rs1),
    .rs2_addr (rs2),
    .rs1_data (rs1_data),
    .rs2_data (rs2_data),
    .wen      (rf_wen),
    .rd_addr  (rd),
    .wdata    (rf_wdata)
  );

  // 4. Branch Evaluation
  reg branch_taken;
  always @(*) begin
    case (funct3)
      3'b000:  branch_taken = (rs1_data == rs2_data);                  // BEQ
      3'b001:  branch_taken = (rs1_data != rs2_data);                  // BNE
      3'b100:  branch_taken = ($signed(rs1_data) < $signed(rs2_data)); // BLT
      3'b101:  branch_taken = ($signed(rs1_data) >= $signed(rs2_data));// BGE
      3'b110:  branch_taken = (rs1_data < rs2_data);                   // BLTU
      3'b111:  branch_taken = (rs1_data >= rs2_data);                  // BGEU
      default: branch_taken = 1'b0;
    endcase
  end

  // 5. CSR Module
  wire [31:0] csr_rdata;
  wire [31:0] mtvec_out;
  wire [31:0] mepc_out;
  wire [31:0] csr_wdata_in = (funct3[2] == 1'b1) ? zimm : rs1_data;
  wire        csr_wen = is_csr && (funct3[1:0] == 2'b01 || rs1 != 5'b0);

  ysyx_261018_csr u_csr (
    .clk       (clock),
    .rst       (reset),
    .csr_addr  (inst[31:20]),
    .csr_op    (funct3),
    .csr_wdata (csr_wdata_in),
    .csr_wen   (csr_wen),
    .csr_rdata (csr_rdata),
    .is_ecall  (is_ecall),
    .is_mret   (is_mret),
    .pc        (pc),
    .mtvec_out (mtvec_out),
    .mepc_out  (mepc_out)
  );

  // 6. Next PC Logic
  wire [31:0] snpc = pc + 32'd4;
  reg  [31:0] dnpc;
  always @(*) begin
    if (is_jal)
      dnpc = pc + immJ;
    else if (is_jalr)
      dnpc = (rs1_data + immI) & ~32'h1;
    else if (is_branch && branch_taken)
      dnpc = pc + immB;
    else if (is_ecall)
      dnpc = mtvec_out;
    else if (is_mret)
      dnpc = mepc_out;
    else
      dnpc = snpc;
  end

  // 7. ALU Control and Execution
  reg [4:0] alu_op;
  always @(*) begin
    if (is_auipc || is_load || is_store || (is_alu_i && funct3 == 3'b000)) begin
      alu_op = 5'd0; // ADD
    end else if (is_alu_i) begin
      case (funct3)
        3'b010: alu_op = 5'd3; // SLTI
        3'b011: alu_op = 5'd4; // SLTIU
        3'b100: alu_op = 5'd5; // XORI
        3'b110: alu_op = 5'd8; // ORI
        3'b111: alu_op = 5'd9; // ANDI
        3'b001: alu_op = 5'd2; // SLLI
        3'b101: alu_op = inst[30] ? 5'd7 : 5'd6; // SRAI : SRLI
        default: alu_op = 5'd0;
      endcase
    end else if (is_alu_r) begin
      if (funct7 == 7'b0000001) begin
        // RV32M Extension
        case (funct3)
          3'b000: alu_op = 5'd10; // MUL
          3'b001: alu_op = 5'd11; // MULH
          3'b010: alu_op = 5'd13; // MULHSU
          3'b011: alu_op = 5'd12; // MULHU
          3'b100: alu_op = 5'd14; // DIV
          3'b101: alu_op = 5'd15; // DIVU
          3'b110: alu_op = 5'd16; // REM
          3'b111: alu_op = 5'd17; // REMU
          default: alu_op = 5'd0;
        endcase
      end else begin
        case (funct3)
          3'b000: alu_op = (funct7[5]) ? 5'd1 : 5'd0; // SUB : ADD
          3'b001: alu_op = 5'd2; // SLL
          3'b010: alu_op = 5'd3; // SLT
          3'b011: alu_op = 5'd4; // SLTU
          3'b100: alu_op = 5'd5; // XOR
          3'b101: alu_op = (funct7[5]) ? 5'd7 : 5'd6; // SRA : SRL
          3'b110: alu_op = 5'd8; // OR
          3'b111: alu_op = 5'd9; // AND
          default: alu_op = 5'd0;
        endcase
      end
    end else begin
      alu_op = 5'd0;
    end
  end

  wire [31:0] alu_src1 = is_auipc ? pc : rs1_data;
  wire [31:0] alu_src2 = (is_auipc)            ? immU :
                         (is_alu_i || is_load) ? immI :
                         (is_store)            ? immS : rs2_data;
  wire [31:0] alu_res;

  ysyx_261018_alu u_alu (
    .alu_op (alu_op),
    .src1   (alu_src1),
    .src2   (alu_src2),
    .res    (alu_res)
  );

  // 8. Memory Access (Load & Store)
  wire [1:0]  byte_offset = alu_res[1:0];
  wire [31:0] mem_rdata_raw = is_load ? pmem_read(alu_res & ~32'h3, 8'd4) : 32'b0;
  reg  [31:0] mem_rdata;

  always @(*) begin
    case (funct3)
      3'b000: begin // LB
        case (byte_offset)
          2'b00: mem_rdata = {{24{mem_rdata_raw[7]}},  mem_rdata_raw[7:0]};
          2'b01: mem_rdata = {{24{mem_rdata_raw[15]}}, mem_rdata_raw[15:8]};
          2'b10: mem_rdata = {{24{mem_rdata_raw[23]}}, mem_rdata_raw[23:16]};
          2'b11: mem_rdata = {{24{mem_rdata_raw[31]}}, mem_rdata_raw[31:24]};
        endcase
      end
      3'b001: begin // LH
        case (byte_offset[1])
          1'b0: mem_rdata = {{16{mem_rdata_raw[15]}}, mem_rdata_raw[15:0]};
          1'b1: mem_rdata = {{16{mem_rdata_raw[31]}}, mem_rdata_raw[31:16]};
        endcase
      end
      3'b010: mem_rdata = mem_rdata_raw; // LW
      3'b100: begin // LBU
        case (byte_offset)
          2'b00: mem_rdata = {24'b0, mem_rdata_raw[7:0]};
          2'b01: mem_rdata = {24'b0, mem_rdata_raw[15:8]};
          2'b10: mem_rdata = {24'b0, mem_rdata_raw[23:16]};
          2'b11: mem_rdata = {24'b0, mem_rdata_raw[31:24]};
        endcase
      end
      3'b101: begin // LHU
        case (byte_offset[1])
          1'b0: mem_rdata = {16'b0, mem_rdata_raw[15:0]};
          1'b1: mem_rdata = {16'b0, mem_rdata_raw[31:16]};
        endcase
      end
      default: mem_rdata = mem_rdata_raw;
    endcase
  end

  // Store data preparation
  reg [31:0] mem_wdata;
  reg [3:0]  mem_wmask;
  always @(*) begin
    case (funct3)
      3'b000: begin // SB
        mem_wdata = rs2_data << (8 * byte_offset);
        mem_wmask = 4'b0001 << byte_offset;
      end
      3'b001: begin // SH
        mem_wdata = rs2_data << (16 * byte_offset[1]);
        mem_wmask = 4'b0011 << (2 * byte_offset[1]);
      end
      3'b010: begin // SW
        mem_wdata = rs2_data;
        mem_wmask = 4'b1111;
      end
      default: begin
        mem_wdata = rs2_data;
        mem_wmask = 4'b0000;
      end
    endcase
  end

  // 9. Writeback to Register File
  always @(*) begin
    if (is_load)
      rf_wdata = mem_rdata;
    else if (is_jal || is_jalr)
      rf_wdata = snpc;
    else if (is_lui)
      rf_wdata = immU;
    else if (is_csr)
      rf_wdata = csr_rdata;
    else
      rf_wdata = alu_res;
  end

  // 10. Sequential State Updates
  always @(posedge clock) begin
    if (reset) begin
      pc <= 32'h80000000;
    end else begin
      if (is_store) begin
        pmem_write(alu_res & ~32'h3, mem_wdata, {4'b0, mem_wmask});
      end
      if (is_ebreak) begin
        npc_ebreak(pc, u_regfile.get_gpr_val(5'd10));
      end
      pc <= dnpc;
    end
  end

endmodule
