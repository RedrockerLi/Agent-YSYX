`timescale 1ns / 1ps

module ysyx_261018 #(
  parameter RESET_VAL = 32'h80000000,
  parameter BUS_MODE  = 0
) (
  input         clock,
  input         reset,
  input         io_interrupt,

  // AXI4 Master Interface
  input         io_master_awready,
  output        io_master_awvalid,
  output [31:0] io_master_awaddr,
  output [3:0]  io_master_awid,
  output [7:0]  io_master_awlen,
  output [2:0]  io_master_awsize,
  output [1:0]  io_master_awburst,
  input         io_master_wready,
  output        io_master_wvalid,
  output [31:0] io_master_wdata,
  output [3:0]  io_master_wstrb,
  output        io_master_wlast,
  output        io_master_bready,
  input         io_master_bvalid,
  input  [1:0]  io_master_bresp,
  input  [3:0]  io_master_bid,
  input         io_master_arready,
  output        io_master_arvalid,
  output [31:0] io_master_araddr,
  output [3:0]  io_master_arid,
  output [7:0]  io_master_arlen,
  output [2:0]  io_master_arsize,
  output [1:0]  io_master_arburst,
  output        io_master_rready,
  input         io_master_rvalid,
  input  [1:0]  io_master_rresp,
  input  [31:0] io_master_rdata,
  input         io_master_rlast,
  input  [3:0]  io_master_rid,

  // AXI4 Slave Interface
  output        io_slave_awready,
  input         io_slave_awvalid,
  input  [31:0] io_slave_awaddr,
  input  [3:0]  io_slave_awid,
  input  [7:0]  io_slave_awlen,
  input  [2:0]  io_slave_awsize,
  input  [1:0]  io_slave_awburst,
  output        io_slave_wready,
  input         io_slave_wvalid,
  input  [31:0] io_slave_wdata,
  input  [3:0]  io_slave_wstrb,
  input         io_slave_wlast,
  input         io_slave_bready,
  output        io_slave_bvalid,
  output [1:0]  io_slave_bresp,
  output [3:0]  io_slave_bid,
  output        io_slave_arready,
  input         io_slave_arvalid,
  input  [31:0] io_slave_araddr,
  input  [3:0]  io_slave_arid,
  input  [7:0]  io_slave_arlen,
  input  [2:0]  io_slave_arsize,
  input  [1:0]  io_slave_arburst,
  input         io_slave_rready,
  output        io_slave_rvalid,
  output [1:0]  io_slave_rresp,
  output [31:0] io_slave_rdata,
  output        io_slave_rlast,
  output [3:0]  io_slave_rid,

  // SimpleBus Interface (for mini-SoC / Stage E/D)
  output [31:0] io_ifu_addr,
  output        io_ifu_reqValid,
  input  [31:0] io_ifu_rdata,
  input         io_ifu_respValid,
  output [31:0] io_lsu_addr,
  output        io_lsu_reqValid,
  input  [31:0] io_lsu_rdata,
  input         io_lsu_respValid,
  output [1:0]  io_lsu_size,
  output        io_lsu_wen,
  output [31:0] io_lsu_wdata,
  output [3:0]  io_lsu_wmask
);

  // DPI-C imports for simulation memory access and trap detection
  import "DPI-C" context function int  pmem_read(input int raddr, input byte rlen);
  import "DPI-C" context function void pmem_write(input int waddr, input int wdata, input byte wmask);
  import "DPI-C" context function void npc_ebreak(input int pc, input int a0);

  reg [31:0] pc;

  // SimpleBus State Machine definitions (for BUS_MODE == 1)
  localparam S_IF_WAIT  = 2'd0;
  localparam S_MEM_WAIT = 2'd1;

  reg [1:0]  state;
  reg [31:0] inst_reg;
  reg        io_ifu_reqValid_r;
  reg        io_lsu_reqValid_r;

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
  wire [31:0] inst = (BUS_MODE == 1) ? ((state == S_IF_WAIT) ? io_ifu_rdata : inst_reg) : pmem_read(pc, 8'd4);

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
  wire        rf_wen_normal = (is_alu_r || is_alu_i || is_load || is_lui || is_auipc || is_jal || is_jalr || is_csr);
  wire        rf_wen = (BUS_MODE == 0) ? rf_wen_normal :
                       (state == S_IF_WAIT)  ? (io_ifu_respValid && !is_load && !is_store && rf_wen_normal) :
                       (state == S_MEM_WAIT) ? (io_lsu_respValid && is_load) : 1'b0;

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
  wire        csr_wen_normal = is_csr && (funct3[1:0] == 2'b01 || rs1 != 5'b0);
  wire        csr_wen = (BUS_MODE == 0) ? csr_wen_normal :
                        (state == S_IF_WAIT && io_ifu_respValid) ? csr_wen_normal : 1'b0;

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
  wire [31:0] mem_rdata_raw = (BUS_MODE == 1) ? io_lsu_rdata :
                              (is_load ? pmem_read(alu_res & ~32'h3, 8'd4) : 32'b0);
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
      pc <= RESET_VAL;
      state <= S_IF_WAIT;
      io_ifu_reqValid_r <= 1'b1;
      io_lsu_reqValid_r <= 1'b0;
      inst_reg <= 32'b0;
    end else if (BUS_MODE == 0) begin
      if (is_store) begin
        pmem_write(alu_res & ~32'h3, mem_wdata, {4'b0, mem_wmask});
      end
      if (is_ebreak) begin
        npc_ebreak(pc, u_regfile.get_gpr_val(5'd10));
      end
      pc <= dnpc;
    end else begin
      case (state)
        S_IF_WAIT: begin
          if (io_ifu_respValid) begin
            if (is_load || is_store) begin
              inst_reg <= io_ifu_rdata;
              state <= S_MEM_WAIT;
              io_ifu_reqValid_r <= 1'b0;
              io_lsu_reqValid_r <= 1'b1;
            end else begin
              if (is_ebreak) begin
                npc_ebreak(pc, u_regfile.get_gpr_val(5'd10));
              end
              pc <= dnpc;
              io_ifu_reqValid_r <= 1'b1;
            end
          end
        end
        S_MEM_WAIT: begin
          if (io_lsu_respValid) begin
            pc <= dnpc;
            state <= S_IF_WAIT;
            io_lsu_reqValid_r <= 1'b0;
            io_ifu_reqValid_r <= 1'b1;
          end
        end
      endcase
    end
  end

  // 11. AXI4 Master Bridge instantiation
  wire        axi_req_valid = (is_load || is_store);
  wire        axi_req_write = is_store;
  wire [31:0] axi_req_addr  = alu_res & ~32'h3;
  wire [2:0]  axi_req_size  = (funct3[1:0] == 2'b00) ? 3'b000 :
                              (funct3[1:0] == 2'b01) ? 3'b001 : 3'b010;
  wire [7:0]  axi_req_len   = 8'd0;
  wire [31:0] axi_req_wdata = mem_wdata;
  wire [3:0]  axi_req_wstrb = mem_wmask;
  wire        axi_resp_valid;
  wire [31:0] axi_resp_rdata;
  wire        axi_resp_rlast;

  ysyx_261018_axi_master u_axi_master (
    .clock             (clock),
    .reset             (reset),
    .req_valid         (axi_req_valid),
    .req_write         (axi_req_write),
    .req_addr          (axi_req_addr),
    .req_size          (axi_req_size),
    .req_len           (axi_req_len),
    .req_wdata         (axi_req_wdata),
    .req_wstrb         (axi_req_wstrb),
    .resp_valid        (axi_resp_valid),
    .resp_rdata        (axi_resp_rdata),
    .resp_rlast        (axi_resp_rlast),

    .io_master_awready (io_master_awready),
    .io_master_awvalid (io_master_awvalid),
    .io_master_awaddr  (io_master_awaddr),
    .io_master_awid    (io_master_awid),
    .io_master_awlen   (io_master_awlen),
    .io_master_awsize  (io_master_awsize),
    .io_master_awburst (io_master_awburst),
    .io_master_wready  (io_master_wready),
    .io_master_wvalid  (io_master_wvalid),
    .io_master_wdata   (io_master_wdata),
    .io_master_wstrb   (io_master_wstrb),
    .io_master_wlast   (io_master_wlast),
    .io_master_bready  (io_master_bready),
    .io_master_bvalid  (io_master_bvalid),
    .io_master_bresp   (io_master_bresp),
    .io_master_bid     (io_master_bid),
    .io_master_arready (io_master_arready),
    .io_master_arvalid (io_master_arvalid),
    .io_master_araddr  (io_master_araddr),
    .io_master_arid    (io_master_arid),
    .io_master_arlen   (io_master_arlen),
    .io_master_arsize  (io_master_arsize),
    .io_master_arburst (io_master_arburst),
    .io_master_rready  (io_master_rready),
    .io_master_rvalid  (io_master_rvalid),
    .io_master_rresp   (io_master_rresp),
    .io_master_rdata   (io_master_rdata),
    .io_master_rlast   (io_master_rlast),
    .io_master_rid     (io_master_rid)
  );

  // 12. Tie off AXI Slave inputs/outputs
  assign io_slave_awready = 1'b0;
  assign io_slave_wready  = 1'b0;
  assign io_slave_bvalid  = 1'b0;
  assign io_slave_bresp   = 2'b00;
  assign io_slave_bid     = 4'b0;
  assign io_slave_arready = 1'b0;
  assign io_slave_rvalid  = 1'b0;
  assign io_slave_rresp   = 2'b00;
  assign io_slave_rdata   = 32'b0;
  assign io_slave_rlast   = 1'b0;
  assign io_slave_rid     = 4'b0;

  // 13. SimpleBus signal assignments
  assign io_ifu_addr      = pc;
  assign io_ifu_reqValid  = (BUS_MODE == 1) ? io_ifu_reqValid_r : 1'b0;
  assign io_lsu_addr      = alu_res;
  assign io_lsu_reqValid  = (BUS_MODE == 1) ? io_lsu_reqValid_r : 1'b0;
  assign io_lsu_size      = funct3[1:0];
  assign io_lsu_wen       = is_store;
  assign io_lsu_wdata     = mem_wdata;
  assign io_lsu_wmask     = mem_wmask;

endmodule
