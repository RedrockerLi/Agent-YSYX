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

  // SimpleBus Interface (for backward compatibility if needed)
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

  // Forward declarations of pipeline control signals
  wire mem_stall;
  wire id_stall;
  wire pc_stall;
  wire ex_redirect;
  wire [31:0] ex_redirect_target;

  // Cache Wires
  wire        icache_resp_valid;
  wire [31:0] icache_resp_rdata;
  wire        dcache_resp_valid;
  wire [31:0] dcache_resp_rdata;
  wire        dcache_fence_done;

  wire [31:0] icache_hit_cnt;
  wire [31:0] icache_miss_cnt;
  wire [31:0] dcache_hit_cnt;
  wire [31:0] dcache_miss_cnt;

  // =========================================================================
  // Stage 1: IF (Instruction Fetch & Branch Prediction)
  // =========================================================================
  reg  [31:0] pc;
  wire [31:0] bpu_pred_target;
  wire        bpu_pred_taken;
  wire [31:0] bpu_total_pred_cnt;
  wire [31:0] bpu_correct_pred_cnt;

  wire [31:0] if_pc_next = ex_redirect ? ex_redirect_target :
                           pc_stall    ? pc :
                           bpu_pred_taken ? bpu_pred_target : (pc + 32'd4);

  always @(posedge clock) begin
    if (reset) begin
      pc <= RESET_VAL;
    end else begin
      pc <= if_pc_next;
    end
  end

  // =========================================================================
  // Pipeline Register: IF / ID
  // =========================================================================
  reg        if_id_valid;
  reg [31:0] if_id_pc;
  reg [31:0] if_id_inst;
  reg        if_id_pred_taken;
  reg [31:0] if_id_pred_target;

  wire if_id_flush = ex_redirect;
  wire if_stall    = !icache_resp_valid;
  assign pc_stall  = if_stall || id_stall || mem_stall;

  always @(posedge clock) begin
    if (reset || if_id_flush) begin
      if_id_valid       <= 1'b0;
      if_id_pc          <= 32'b0;
      if_id_inst        <= 32'h00000013; // NOP
      if_id_pred_taken  <= 1'b0;
      if_id_pred_target <= 32'b0;
    end else if (!id_stall) begin
      if (icache_resp_valid) begin
        if_id_valid       <= 1'b1;
        if_id_pc          <= pc;
        if_id_inst        <= icache_resp_rdata;
        if_id_pred_taken  <= bpu_pred_taken;
        if_id_pred_target <= bpu_pred_target;
      end else begin
        if_id_valid       <= 1'b0;
        if_id_pc          <= 32'b0;
        if_id_inst        <= 32'h00000013; // NOP
        if_id_pred_taken  <= 1'b0;
        if_id_pred_target <= 32'b0;
      end
    end
  end

  // =========================================================================
  // Stage 2: ID (Instruction Decode & Hazard Detection)
  // =========================================================================
  wire [31:0] id_inst = if_id_inst;
  wire [6:0]  id_opcode = id_inst[6:0];
  wire [4:0]  id_rd     = id_inst[11:7];
  wire [2:0]  id_funct3 = id_inst[14:12];
  wire [4:0]  id_rs1    = id_inst[19:15];
  wire [4:0]  id_rs2    = id_inst[24:20];
  wire [6:0]  id_funct7 = id_inst[31:25];

  // Immediates
  wire [31:0] id_immI = {{20{id_inst[31]}}, id_inst[31:20]};
  wire [31:0] id_immS = {{20{id_inst[31]}}, id_inst[31:25], id_inst[11:7]};
  wire [31:0] id_immB = {{19{id_inst[31]}}, id_inst[31], id_inst[7], id_inst[30:25], id_inst[11:8], 1'b0};
  wire [31:0] id_immU = {id_inst[31:12], 12'b0};
  wire [31:0] id_immJ = {{11{id_inst[31]}}, id_inst[31], id_inst[19:12], id_inst[20], id_inst[30:21], 1'b0};
  wire [31:0] id_zimm = {27'b0, id_inst[19:15]};

  // Instruction categories
  wire id_is_lui     = (id_opcode == 7'b0110111);
  wire id_is_auipc   = (id_opcode == 7'b0010111);
  wire id_is_jal     = (id_opcode == 7'b1101111);
  wire id_is_jalr    = (id_opcode == 7'b1100111 && id_funct3 == 3'b000);
  wire id_is_branch  = (id_opcode == 7'b1100011);
  wire id_is_load    = (id_opcode == 7'b0000011);
  wire id_is_store   = (id_opcode == 7'b0100011);
  wire id_is_alu_i   = (id_opcode == 7'b0010011);
  wire id_is_alu_r   = (id_opcode == 7'b0110011);
  wire id_is_system  = (id_opcode == 7'b1110011);
  wire id_is_fence_i = (id_opcode == 7'b0001111);

  wire id_is_ebreak  = id_is_system && (id_funct3 == 3'b000) && (id_inst[31:20] == 12'h001);
  wire id_is_ecall   = id_is_system && (id_funct3 == 3'b000) && (id_inst[31:20] == 12'h000);
  wire id_is_mret    = id_is_system && (id_funct3 == 3'b000) && (id_inst[31:20] == 12'h302);
  wire id_is_csr     = id_is_system && (id_funct3 != 3'b000);

  // Operand usage
  wire id_rs1_used = (id_is_alu_r || id_is_alu_i || id_is_load || id_is_store || id_is_branch || id_is_jalr || (id_is_csr && !id_funct3[2]));
  wire id_rs2_used = (id_is_alu_r || id_is_store || id_is_branch);

  wire id_rf_wen = (id_is_alu_r || id_is_alu_i || id_is_load || id_is_lui || id_is_auipc || id_is_jal || id_is_jalr || id_is_csr);

  // Immediate selection
  reg [31:0] id_imm;
  always @(*) begin
    if (id_is_lui || id_is_auipc)
      id_imm = id_immU;
    else if (id_is_jal)
      id_imm = id_immJ;
    else if (id_is_branch)
      id_imm = id_immB;
    else if (id_is_store)
      id_imm = id_immS;
    else if (id_is_csr && id_funct3[2])
      id_imm = id_zimm;
    else
      id_imm = id_immI;
  end

  // ALU Opcode generation
  reg [4:0] id_alu_op;
  always @(*) begin
    if (id_is_alu_r) begin
      case ({id_funct7, id_funct3})
        10'b0000000_000: id_alu_op = 5'd0;  // ADD
        10'b0100000_000: id_alu_op = 5'd1;  // SUB
        10'b0000000_001: id_alu_op = 5'd2;  // SLL
        10'b0000000_010: id_alu_op = 5'd3;  // SLT
        10'b0000000_011: id_alu_op = 5'd4;  // SLTU
        10'b0000000_100: id_alu_op = 5'd5;  // XOR
        10'b0000000_101: id_alu_op = 5'd6;  // SRL
        10'b0100000_101: id_alu_op = 5'd7;  // SRA
        10'b0000000_110: id_alu_op = 5'd8;  // OR
        10'b0000000_111: id_alu_op = 5'd9;  // AND
        10'b0000001_000: id_alu_op = 5'd10; // MUL
        10'b0000001_001: id_alu_op = 5'd11; // MULH
        10'b0000001_010: id_alu_op = 5'd13; // MULHSU
        10'b0000001_011: id_alu_op = 5'd12; // MULHU
        10'b0000001_100: id_alu_op = 5'd14; // DIV
        10'b0000001_101: id_alu_op = 5'd15; // DIVU
        10'b0000001_110: id_alu_op = 5'd16; // REM
        10'b0000001_111: id_alu_op = 5'd17; // REMU
        default:         id_alu_op = 5'd0;
      endcase
    end else if (id_is_alu_i) begin
      case (id_funct3)
        3'b000: id_alu_op = 5'd0; // ADDI
        3'b010: id_alu_op = 5'd3; // SLTI
        3'b011: id_alu_op = 5'd4; // SLTIU
        3'b100: id_alu_op = 5'd5; // XORI
        3'b110: id_alu_op = 5'd8; // ORI
        3'b111: id_alu_op = 5'd9; // ANDI
        3'b001: id_alu_op = 5'd2; // SLLI
        3'b101: id_alu_op = (id_funct7[5]) ? 5'd7 : 5'd6; // SRAI / SRLI
        default:id_alu_op = 5'd0;
      endcase
    end else begin
      id_alu_op = 5'd0; // ADD for address calc (load/store/auipc)
    end
  end

  // Register File
  wire [31:0] id_rs1_data;
  wire [31:0] id_rs2_data;
  wire        wb_rf_wen;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;

  ysyx_261018_regfile #(
    .NUM_REGS(32)
  ) u_regfile (
    .clk      (clock),
    .rst      (reset),
    .rs1_addr (id_rs1),
    .rs2_addr (id_rs2),
    .rs1_data (id_rs1_data),
    .rs2_data (id_rs2_data),
    .wen      (wb_rf_wen),
    .rd_addr  (wb_rd),
    .wdata    (wb_wdata)
  );

  // Load-Use Hazard Detection
  reg        id_ex_valid;
  reg [4:0]  id_ex_rd;
  reg        id_ex_is_load;

  wire load_use_hazard = id_ex_valid && id_ex_is_load && (id_ex_rd != 5'd0) &&
                         if_id_valid &&
                         ((id_rs1_used && (id_ex_rd == id_rs1)) ||
                          (id_rs2_used && (id_ex_rd == id_rs2)));

  assign id_stall = load_use_hazard || mem_stall;

  // =========================================================================
  // Pipeline Register: ID / EX
  // =========================================================================
  reg [31:0] id_ex_pc;
  reg [31:0] id_ex_inst;
  reg [4:0]  id_ex_rs1;
  reg [4:0]  id_ex_rs2;
  reg [31:0] id_ex_rs1_data;
  reg [31:0] id_ex_rs2_data;
  reg [31:0] id_ex_imm;
  reg [4:0]  id_ex_alu_op;
  reg [2:0]  id_ex_funct3;
  reg [11:0] id_ex_csr_addr;
  reg [2:0]  id_ex_csr_op;
  reg        id_ex_rf_wen;
  reg        id_ex_is_alu_r;
  reg        id_ex_is_alu_i;
  reg        id_ex_is_store;
  reg        id_ex_is_branch;
  reg        id_ex_is_jal;
  reg        id_ex_is_jalr;
  reg        id_ex_is_lui;
  reg        id_ex_is_auipc;
  reg        id_ex_is_csr;
  reg        id_ex_is_ecall;
  reg        id_ex_is_mret;
  reg        id_ex_is_ebreak;
  reg        id_ex_is_fence_i;
  reg        id_ex_pred_taken;
  reg [31:0] id_ex_pred_target;

  wire id_ex_flush = !mem_stall && (ex_redirect || load_use_hazard);

  always @(posedge clock) begin
    if (reset || id_ex_flush) begin
      id_ex_valid       <= 1'b0;
      id_ex_pc          <= 32'b0;
      id_ex_inst        <= 32'h00000013; // NOP
      id_ex_rd          <= 5'b0;
      id_ex_rs1         <= 5'b0;
      id_ex_rs2         <= 5'b0;
      id_ex_rs1_data    <= 32'b0;
      id_ex_rs2_data    <= 32'b0;
      id_ex_imm         <= 32'b0;
      id_ex_alu_op      <= 5'b0;
      id_ex_funct3      <= 3'b0;
      id_ex_csr_addr    <= 12'b0;
      id_ex_csr_op      <= 3'b0;
      id_ex_rf_wen      <= 1'b0;
      id_ex_is_alu_r    <= 1'b0;
      id_ex_is_alu_i    <= 1'b0;
      id_ex_is_load     <= 1'b0;
      id_ex_is_store    <= 1'b0;
      id_ex_is_branch   <= 1'b0;
      id_ex_is_jal      <= 1'b0;
      id_ex_is_jalr     <= 1'b0;
      id_ex_is_lui      <= 1'b0;
      id_ex_is_auipc    <= 1'b0;
      id_ex_is_csr      <= 1'b0;
      id_ex_is_ecall    <= 1'b0;
      id_ex_is_mret     <= 1'b0;
      id_ex_is_ebreak   <= 1'b0;
      id_ex_is_fence_i  <= 1'b0;
      id_ex_pred_taken  <= 1'b0;
      id_ex_pred_target <= 32'b0;
    end else if (!mem_stall) begin
      id_ex_valid       <= if_id_valid;
      id_ex_pc          <= if_id_pc;
      id_ex_inst        <= if_id_inst;
      id_ex_rd          <= if_id_valid ? id_rd : 5'd0;
      id_ex_rs1         <= if_id_valid ? id_rs1 : 5'd0;
      id_ex_rs2         <= if_id_valid ? id_rs2 : 5'd0;
      id_ex_rs1_data    <= id_rs1_data;
      id_ex_rs2_data    <= id_rs2_data;
      id_ex_imm         <= id_imm;
      id_ex_alu_op      <= id_alu_op;
      id_ex_funct3      <= id_funct3;
      id_ex_csr_addr    <= id_inst[31:20];
      id_ex_csr_op      <= id_funct3;
      id_ex_rf_wen      <= if_id_valid ? id_rf_wen : 1'b0;
      id_ex_is_alu_r    <= if_id_valid ? id_is_alu_r : 1'b0;
      id_ex_is_alu_i    <= if_id_valid ? id_is_alu_i : 1'b0;
      id_ex_is_load     <= if_id_valid ? id_is_load : 1'b0;
      id_ex_is_store    <= if_id_valid ? id_is_store : 1'b0;
      id_ex_is_branch   <= if_id_valid ? id_is_branch : 1'b0;
      id_ex_is_jal      <= if_id_valid ? id_is_jal : 1'b0;
      id_ex_is_jalr     <= if_id_valid ? id_is_jalr : 1'b0;
      id_ex_is_lui      <= if_id_valid ? id_is_lui : 1'b0;
      id_ex_is_auipc    <= if_id_valid ? id_is_auipc : 1'b0;
      id_ex_is_csr      <= if_id_valid ? id_is_csr : 1'b0;
      id_ex_is_ecall    <= if_id_valid ? id_is_ecall : 1'b0;
      id_ex_is_mret     <= if_id_valid ? id_is_mret : 1'b0;
      id_ex_is_ebreak   <= if_id_valid ? id_is_ebreak : 1'b0;
      id_ex_is_fence_i  <= if_id_valid ? id_is_fence_i : 1'b0;
      id_ex_pred_taken  <= if_id_pred_taken;
      id_ex_pred_target <= if_id_pred_target;
    end else begin
      if (wb_rf_wen && (wb_rd != 5'd0)) begin
        if (wb_rd == id_ex_rs1) id_ex_rs1_data <= wb_wdata;
        if (wb_rd == id_ex_rs2) id_ex_rs2_data <= wb_wdata;
      end
    end
  end

  // =========================================================================
  // Stage 3: EX (ALU, Forwarding Unit, Branch Resolution, CSRs)
  // =========================================================================
  reg        ex_mem_valid;
  reg [4:0]  ex_mem_rd;
  reg        ex_mem_rf_wen;
  reg [31:0] ex_mem_val;

  reg        mem_wb_valid;
  reg [4:0]  mem_wb_rd;
  reg        mem_wb_rf_wen;
  reg [31:0] mem_wb_wdata;

  // Forwarding Unit
  wire [31:0] ex_src1 = (ex_mem_valid && ex_mem_rf_wen && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1)) ? ex_mem_val :
                        (mem_wb_valid && mem_wb_rf_wen && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) ? mem_wb_wdata :
                        id_ex_rs1_data;

  wire [31:0] ex_src2 = (ex_mem_valid && ex_mem_rf_wen && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2)) ? ex_mem_val :
                        (mem_wb_valid && mem_wb_rf_wen && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) ? mem_wb_wdata :
                        id_ex_rs2_data;

  // ALU Input MUXes
  wire [31:0] alu_in1 = id_ex_is_auipc ? id_ex_pc : ex_src1;
  wire [31:0] alu_in2 = (id_ex_is_alu_i || id_ex_is_load || id_ex_is_store || id_ex_is_auipc) ? id_ex_imm : ex_src2;

  wire [31:0] alu_res;
  ysyx_261018_alu u_alu (
    .alu_op (id_ex_alu_op),
    .src1   (alu_in1),
    .src2   (alu_in2),
    .res    (alu_res)
  );

  // Branch Evaluation
  reg branch_cond_met;
  always @(*) begin
    case (id_ex_funct3)
      3'b000:  branch_cond_met = (ex_src1 == ex_src2);                  // BEQ
      3'b001:  branch_cond_met = (ex_src1 != ex_src2);                  // BNE
      3'b100:  branch_cond_met = ($signed(ex_src1) < $signed(ex_src2)); // BLT
      3'b101:  branch_cond_met = ($signed(ex_src1) >= $signed(ex_src2));// BGE
      3'b110:  branch_cond_met = (ex_src1 < ex_src2);                   // BLTU
      3'b111:  branch_cond_met = (ex_src1 >= ex_src2);                  // BGEU
      default: branch_cond_met = 1'b0;
    endcase
  end

  wire ex_actual_taken = id_ex_is_branch ? branch_cond_met : (id_ex_is_jal || id_ex_is_jalr);

  wire [31:0] ex_actual_target = id_ex_is_branch ? (id_ex_pc + id_ex_imm) :
                                 id_ex_is_jal    ? (id_ex_pc + id_ex_imm) :
                                 id_ex_is_jalr   ? ((ex_src1 + id_ex_imm) & ~32'h1) :
                                                   (id_ex_pc + 32'd4);

  wire [31:0] ex_correct_next_pc = ex_actual_taken ? ex_actual_target : (id_ex_pc + 32'd4);

  wire ex_mispredict = id_ex_valid && (id_ex_is_branch || id_ex_is_jal || id_ex_is_jalr) &&
                       ((ex_actual_taken != id_ex_pred_taken) ||
                        (ex_actual_taken && (ex_correct_next_pc != id_ex_pred_target)));

  // CSR Module
  wire [31:0] csr_rdata;
  wire [31:0] mtvec;
  wire [31:0] mepc;

  ysyx_261018_csr u_csr (
    .clk        (clock),
    .rst        (reset),
    .csr_addr   (id_ex_csr_addr),
    .csr_op     (id_ex_csr_op),
    .csr_wdata  (id_ex_funct3[2] ? id_ex_imm : ex_src1),
    .csr_wen    (id_ex_valid && id_ex_is_csr && !mem_stall),
    .csr_rdata  (csr_rdata),
    .is_ecall   (id_ex_valid && id_ex_is_ecall && !mem_stall),
    .is_mret    (id_ex_valid && id_ex_is_mret && !mem_stall),
    .pc         (id_ex_pc),
    .mtvec_out  (mtvec),
    .mepc_out   (mepc)
  );

  // Exception / Branch Redirection
  assign ex_redirect = !mem_stall && id_ex_valid && (id_ex_is_ecall || id_ex_is_mret || id_ex_is_fence_i || ex_mispredict);

  assign ex_redirect_target = id_ex_is_ecall   ? mtvec :
                              id_ex_is_mret    ? mepc :
                              id_ex_is_fence_i ? (id_ex_pc + 32'd4) :
                                                 ex_correct_next_pc;

  // Branch Prediction Unit
  ysyx_261018_bpu u_bpu (
    .clock            (clock),
    .reset            (reset),
    .if_pc            (pc),
    .pred_taken       (bpu_pred_taken),
    .pred_target      (bpu_pred_target),
    .train_valid      (id_ex_valid && (id_ex_is_branch || id_ex_is_jal || id_ex_is_jalr) && !mem_stall),
    .train_pc         (id_ex_pc),
    .train_taken      (ex_actual_taken),
    .train_target     (ex_actual_target),
    .train_is_call    ((id_ex_is_jal || id_ex_is_jalr) && (id_ex_rd == 5'd1)),
    .train_is_ret     (id_ex_is_jalr && (id_ex_rs1 == 5'd1)),
    .train_mispred    (ex_mispredict),
    .total_pred_cnt   (bpu_total_pred_cnt),
    .correct_pred_cnt (bpu_correct_pred_cnt)
  );

  // Store data preparation
  wire [1:0]  ex_byte_offset = alu_res[1:0];
  reg  [31:0] ex_mem_wdata;
  reg  [3:0]  ex_mem_wmask;
  always @(*) begin
    case (id_ex_funct3)
      3'b000: begin // SB
        ex_mem_wdata = ex_src2 << (8 * ex_byte_offset);
        ex_mem_wmask = 4'b0001 << ex_byte_offset;
      end
      3'b001: begin // SH
        ex_mem_wdata = ex_src2 << (16 * ex_byte_offset[1]);
        ex_mem_wmask = 4'b0011 << (2 * ex_byte_offset[1]);
      end
      3'b010: begin // SW
        ex_mem_wdata = ex_src2;
        ex_mem_wmask = 4'b1111;
      end
      default: begin
        ex_mem_wdata = ex_src2;
        ex_mem_wmask = 4'b0000;
      end
    endcase
  end

  // =========================================================================
  // Pipeline Register: EX / MEM
  // =========================================================================
  reg [31:0] ex_mem_pc;
  reg [31:0] ex_mem_inst;
  reg [31:0] ex_mem_alu_res;
  reg [31:0] ex_mem_store_data;
  reg [3:0]  ex_mem_store_mask;
  reg [31:0] ex_mem_csr_rdata;
  reg [31:0] ex_mem_imm;
  reg [31:0] ex_mem_snpc;
  reg [31:0] ex_mem_next_pc;
  reg [2:0]  ex_mem_funct3;
  reg        ex_mem_is_load;
  reg        ex_mem_is_store;
  reg        ex_mem_is_csr;
  reg        ex_mem_is_lui;
  reg        ex_mem_is_jal_jalr;
  reg        ex_mem_is_ebreak;
  reg        ex_mem_is_fence_i;

  always @(*) begin
    if (ex_mem_is_csr)
      ex_mem_val = ex_mem_csr_rdata;
    else if (ex_mem_is_lui)
      ex_mem_val = ex_mem_imm;
    else if (ex_mem_is_jal_jalr)
      ex_mem_val = ex_mem_snpc;
    else
      ex_mem_val = ex_mem_alu_res;
  end

  always @(posedge clock) begin
    if (reset) begin
      ex_mem_valid       <= 1'b0;
      ex_mem_pc          <= 32'b0;
      ex_mem_inst        <= 32'b0;
      ex_mem_rd          <= 5'b0;
      ex_mem_alu_res     <= 32'b0;
      ex_mem_store_data  <= 32'b0;
      ex_mem_store_mask  <= 4'b0;
      ex_mem_csr_rdata   <= 32'b0;
      ex_mem_imm         <= 32'b0;
      ex_mem_snpc        <= 32'b0;
      ex_mem_next_pc     <= 32'b0;
      ex_mem_funct3      <= 3'b0;
      ex_mem_rf_wen      <= 1'b0;
      ex_mem_is_load     <= 1'b0;
      ex_mem_is_store    <= 1'b0;
      ex_mem_is_csr      <= 1'b0;
      ex_mem_is_lui      <= 1'b0;
      ex_mem_is_jal_jalr <= 1'b0;
      ex_mem_is_ebreak   <= 1'b0;
      ex_mem_is_fence_i  <= 1'b0;
    end else if (!mem_stall) begin
      ex_mem_valid       <= id_ex_valid;
      ex_mem_pc          <= id_ex_pc;
      ex_mem_inst        <= id_ex_inst;
      ex_mem_rd          <= id_ex_valid ? id_ex_rd : 5'd0;
      ex_mem_alu_res     <= alu_res;
      ex_mem_store_data  <= ex_mem_wdata;
      ex_mem_store_mask  <= ex_mem_wmask;
      ex_mem_csr_rdata   <= csr_rdata;
      ex_mem_imm         <= id_ex_imm;
      ex_mem_snpc        <= id_ex_pc + 32'd4;
      ex_mem_next_pc     <= ex_correct_next_pc;
      ex_mem_funct3      <= id_ex_funct3;
      ex_mem_rf_wen      <= id_ex_valid ? id_ex_rf_wen : 1'b0;
      ex_mem_is_load     <= id_ex_valid ? id_ex_is_load : 1'b0;
      ex_mem_is_store    <= id_ex_valid ? id_ex_is_store : 1'b0;
      ex_mem_is_csr      <= id_ex_valid ? id_ex_is_csr : 1'b0;
      ex_mem_is_lui      <= id_ex_valid ? id_ex_is_lui : 1'b0;
      ex_mem_is_jal_jalr <= id_ex_valid ? (id_ex_is_jal || id_ex_is_jalr) : 1'b0;
      ex_mem_is_ebreak   <= id_ex_valid ? id_ex_is_ebreak : 1'b0;
      ex_mem_is_fence_i  <= id_ex_valid ? id_ex_is_fence_i : 1'b0;
    end
  end

  // =========================================================================
  // Stage 4: MEM (DCache & Load Formatting)
  // =========================================================================
  wire mem_wait_dcache = ex_mem_valid && (ex_mem_is_load || ex_mem_is_store) && !dcache_resp_valid;
  wire mem_wait_fence  = ex_mem_valid && ex_mem_is_fence_i && !dcache_fence_done;
  assign mem_stall     = mem_wait_dcache || mem_wait_fence;


  wire [1:0]  mem_byte_offset = ex_mem_alu_res[1:0];
  wire [31:0] mem_rdata_raw   = dcache_resp_rdata;
  reg  [31:0] mem_rdata;

  always @(*) begin
    case (ex_mem_funct3)
      3'b000: begin // LB
        case (mem_byte_offset)
          2'b00: mem_rdata = {{24{mem_rdata_raw[7]}},  mem_rdata_raw[7:0]};
          2'b01: mem_rdata = {{24{mem_rdata_raw[15]}}, mem_rdata_raw[15:8]};
          2'b10: mem_rdata = {{24{mem_rdata_raw[23]}}, mem_rdata_raw[23:16]};
          2'b11: mem_rdata = {{24{mem_rdata_raw[31]}}, mem_rdata_raw[31:24]};
        endcase
      end
      3'b001: begin // LH
        case (mem_byte_offset[1])
          1'b0: mem_rdata = {{16{mem_rdata_raw[15]}}, mem_rdata_raw[15:0]};
          1'b1: mem_rdata = {{16{mem_rdata_raw[31]}}, mem_rdata_raw[31:16]};
        endcase
      end
      3'b010: mem_rdata = mem_rdata_raw; // LW
      3'b100: begin // LBU
        case (mem_byte_offset)
          2'b00: mem_rdata = {24'b0, mem_rdata_raw[7:0]};
          2'b01: mem_rdata = {24'b0, mem_rdata_raw[15:8]};
          2'b10: mem_rdata = {24'b0, mem_rdata_raw[23:16]};
          2'b11: mem_rdata = {24'b0, mem_rdata_raw[31:24]};
        endcase
      end
      3'b101: begin // LHU
        case (mem_byte_offset[1])
          1'b0: mem_rdata = {16'b0, mem_rdata_raw[15:0]};
          1'b1: mem_rdata = {16'b0, mem_rdata_raw[31:16]};
        endcase
      end
      default: mem_rdata = mem_rdata_raw;
    endcase
  end

  wire [31:0] mem_final_wdata = ex_mem_is_load     ? mem_rdata :
                                ex_mem_is_csr      ? ex_mem_csr_rdata :
                                ex_mem_is_lui      ? ex_mem_imm :
                                ex_mem_is_jal_jalr ? ex_mem_snpc :
                                                     ex_mem_alu_res;

  // =========================================================================
  // Pipeline Register: MEM / WB
  // =========================================================================
  reg [31:0] mem_wb_pc;
  reg [31:0] mem_wb_inst;
  reg [31:0] mem_wb_next_pc;
  reg        mem_wb_is_ebreak;

  always @(posedge clock) begin
    if (reset) begin
      mem_wb_valid     <= 1'b0;
      mem_wb_pc        <= 32'b0;
      mem_wb_inst      <= 32'b0;
      mem_wb_rd        <= 5'b0;
      mem_wb_wdata     <= 32'b0;
      mem_wb_rf_wen    <= 1'b0;
      mem_wb_next_pc   <= 32'b0;
      mem_wb_is_ebreak <= 1'b0;
    end else if (mem_stall) begin
      mem_wb_valid     <= 1'b0; // bubble into WB when MEM stalls
      mem_wb_rf_wen    <= 1'b0;
      mem_wb_rd        <= 5'b0;
      mem_wb_is_ebreak <= 1'b0;
    end else begin
      mem_wb_valid     <= ex_mem_valid;
      mem_wb_pc        <= ex_mem_pc;
      mem_wb_inst      <= ex_mem_inst;
      mem_wb_rd        <= ex_mem_valid ? ex_mem_rd : 5'd0;
      mem_wb_wdata     <= mem_final_wdata;
      mem_wb_rf_wen    <= ex_mem_valid ? ex_mem_rf_wen : 1'b0;
      mem_wb_next_pc   <= ex_mem_next_pc;
      mem_wb_is_ebreak <= ex_mem_valid ? ex_mem_is_ebreak : 1'b0;
    end
  end

  // =========================================================================
  // Stage 5: WB (Writeback / Commit)
  // =========================================================================
  assign wb_rf_wen = mem_wb_valid && mem_wb_rf_wen && (mem_wb_rd != 5'd0);
  assign wb_rd     = mem_wb_rd;
  assign wb_wdata  = mem_wb_wdata;

  // Trap handling
  always @(posedge clock) begin
    if (!reset && mem_wb_valid && mem_wb_is_ebreak) begin
      npc_ebreak(mem_wb_pc, u_regfile.get_gpr_val(5'd10));
    end
  end

  // =========================================================================
  // DPI-C Exports for DiffTest and Testbench Inspection
  // =========================================================================
  export "DPI-C" function get_pc;
  function int get_pc();
    get_pc = mem_wb_next_pc;
  endfunction

  export "DPI-C" function get_commit_pc;
  function int get_commit_pc();
    get_commit_pc = mem_wb_pc;
  endfunction

  export "DPI-C" function get_commit_inst;
  function int get_commit_inst();
    get_commit_inst = mem_wb_inst;
  endfunction

  export "DPI-C" function get_gpr;
  function int get_gpr(input int idx);
    get_gpr = u_regfile.get_gpr_val(idx[4:0]);
  endfunction

  export "DPI-C" function is_inst_commit;
  function int is_inst_commit();
    is_inst_commit = mem_wb_valid ? 1 : 0;
  endfunction

  export "DPI-C" function get_icache_hits;
  function int get_icache_hits();
    get_icache_hits = icache_hit_cnt;
  endfunction

  export "DPI-C" function get_icache_misses;
  function int get_icache_misses();
    get_icache_misses = icache_miss_cnt;
  endfunction

  export "DPI-C" function get_dcache_hits;
  function int get_dcache_hits();
    get_dcache_hits = dcache_hit_cnt;
  endfunction

  export "DPI-C" function get_dcache_misses;
  function int get_dcache_misses();
    get_dcache_misses = dcache_miss_cnt;
  endfunction

  export "DPI-C" function get_bpu_total;
  function int get_bpu_total();
    get_bpu_total = bpu_total_pred_cnt;
  endfunction

  export "DPI-C" function get_bpu_correct;
  function int get_bpu_correct();
    get_bpu_correct = bpu_correct_pred_cnt;
  endfunction

  // =========================================================================
  // Cache Instances & Arbiter
  // =========================================================================
  wire        icache_mem_req_valid;
  wire [31:0] icache_mem_req_addr;
  wire [7:0]  icache_mem_req_len;
  wire        icache_mem_resp_valid;
  wire [31:0] icache_mem_resp_rdata;
  wire        icache_mem_resp_rlast;

  ysyx_261018_icache #(
    .SET_WIDTH    (6),
    .OFFSET_WIDTH (4),
    .TAG_WIDTH    (22)
  ) u_icache (
    .clock          (clock),
    .reset          (reset),
    .req_valid      (!reset),
    .req_addr       (pc),
    .resp_valid     (icache_resp_valid),
    .resp_rdata     (icache_resp_rdata),
    .flush          (ex_redirect),
    .fence_i        (ex_mem_valid && ex_mem_is_fence_i),
    .mem_req_valid  (icache_mem_req_valid),
    .mem_req_addr   (icache_mem_req_addr),
    .mem_req_len    (icache_mem_req_len),
    .mem_resp_valid (icache_mem_resp_valid),
    .mem_resp_rdata (icache_mem_resp_rdata),
    .mem_resp_rlast (icache_mem_resp_rlast),
    .hit_count      (icache_hit_cnt),
    .miss_count     (icache_miss_cnt)
  );

  wire        dcache_mem_req_valid;
  wire        dcache_mem_req_write;
  wire [31:0] dcache_mem_req_addr;
  wire [7:0]  dcache_mem_req_len;
  wire [31:0] dcache_mem_req_wdata;
  wire [3:0]  dcache_mem_req_wstrb;
  wire        dcache_mem_req_wlast;
  wire        dcache_mem_grant;
  wire        dcache_mem_resp_valid;
  wire [31:0] dcache_mem_resp_rdata;
  wire        dcache_mem_resp_rlast;

  ysyx_261018_dcache #(
    .SET_WIDTH    (6),
    .OFFSET_WIDTH (4),
    .TAG_WIDTH    (22)
  ) u_dcache (
    .clock          (clock),
    .reset          (reset),
    .req_valid      (!reset && ex_mem_valid && (ex_mem_is_load || ex_mem_is_store)),
    .req_write      (ex_mem_is_store),
    .req_addr       (ex_mem_alu_res),
    .req_wdata      (ex_mem_store_data),
    .req_wmask      (ex_mem_store_mask),
    .resp_valid     (dcache_resp_valid),
    .resp_rdata     (dcache_resp_rdata),
    .fence_i        (ex_mem_valid && ex_mem_is_fence_i),
    .fence_done     (dcache_fence_done),
    .mem_req_valid  (dcache_mem_req_valid),
    .mem_req_write  (dcache_mem_req_write),
    .mem_req_addr   (dcache_mem_req_addr),
    .mem_req_len    (dcache_mem_req_len),
    .mem_req_wdata  (dcache_mem_req_wdata),
    .mem_req_wstrb  (dcache_mem_req_wstrb),
    .mem_req_wlast  (dcache_mem_req_wlast),
    .mem_grant      (dcache_mem_grant),
    .mem_resp_valid (dcache_mem_resp_valid),
    .mem_resp_rdata (dcache_mem_resp_rdata),
    .mem_resp_rlast (dcache_mem_resp_rlast),
    .hit_count      (dcache_hit_cnt),
    .miss_count     (dcache_miss_cnt)
  );

  // Arbiter between ICache and DCache
  wire        arb_mem_req_valid;
  wire        arb_mem_req_write;
  wire [31:0] arb_mem_req_addr;
  wire [7:0]  arb_mem_req_len;
  wire [31:0] arb_mem_req_wdata;
  wire [3:0]  arb_mem_req_wstrb;
  wire        arb_mem_req_wlast;
  wire        arb_mem_resp_valid;
  wire [31:0] arb_mem_resp_rdata;
  wire        arb_mem_resp_rlast;

  ysyx_261018_cache_arbiter u_arbiter (
    .clock                 (clock),
    .reset                 (reset),
    .icache_mem_req_valid  (icache_mem_req_valid),
    .icache_mem_req_addr   (icache_mem_req_addr),
    .icache_mem_req_len    (icache_mem_req_len),
    .icache_mem_resp_valid (icache_mem_resp_valid),
    .icache_mem_resp_rdata (icache_mem_resp_rdata),
    .icache_mem_resp_rlast (icache_mem_resp_rlast),
    .dcache_mem_req_valid  (dcache_mem_req_valid),
    .dcache_mem_req_write  (dcache_mem_req_write),
    .dcache_mem_req_addr   (dcache_mem_req_addr),
    .dcache_mem_req_len    (dcache_mem_req_len),
    .dcache_mem_req_wdata  (dcache_mem_req_wdata),
    .dcache_mem_req_wstrb  (dcache_mem_req_wstrb),
    .dcache_mem_req_wlast  (dcache_mem_req_wlast),
    .dcache_mem_grant      (dcache_mem_grant),
    .dcache_mem_resp_valid (dcache_mem_resp_valid),
    .dcache_mem_resp_rdata (dcache_mem_resp_rdata),
    .dcache_mem_resp_rlast (dcache_mem_resp_rlast),
    .mem_req_valid         (arb_mem_req_valid),
    .mem_req_write         (arb_mem_req_write),
    .mem_req_addr          (arb_mem_req_addr),
    .mem_req_len           (arb_mem_req_len),
    .mem_req_wdata         (arb_mem_req_wdata),
    .mem_req_wstrb         (arb_mem_req_wstrb),
    .mem_req_wlast         (arb_mem_req_wlast),
    .mem_resp_valid        (arb_mem_resp_valid),
    .mem_resp_rdata        (arb_mem_resp_rdata),
    .mem_resp_rlast        (arb_mem_resp_rlast)
  );

  // =========================================================================
  // Simulation Burst Engine (BUS_MODE == 0)
  // =========================================================================
  reg        sim_mem_resp_valid;
  reg [31:0] sim_mem_resp_rdata;
  reg        sim_mem_resp_rlast;

  localparam SIM_MEM_IDLE      = 2'd0;
  localparam SIM_MEM_BURST     = 2'd1;
  localparam SIM_MEM_RESP_LAST = 2'd2;

  reg [1:0] sim_mem_state;
  reg [7:0] sim_beat;
  reg [31:0] sim_addr;
  reg [7:0] sim_len;
  reg       sim_write;

  always @(posedge clock) begin
    if (reset) begin
      sim_mem_state      <= SIM_MEM_IDLE;
      sim_beat           <= 8'b0;
      sim_addr           <= 32'b0;
      sim_len            <= 8'b0;
      sim_write          <= 1'b0;
      sim_mem_resp_valid <= 1'b0;
      sim_mem_resp_rdata <= 32'b0;
      sim_mem_resp_rlast <= 1'b0;
    end else begin
      sim_mem_resp_valid <= 1'b0;
      sim_mem_resp_rlast <= 1'b0;

      case (sim_mem_state)
        SIM_MEM_IDLE: begin
          if (BUS_MODE == 0 && arb_mem_req_valid) begin
            sim_addr  <= arb_mem_req_addr;
            sim_len   <= arb_mem_req_len;
            sim_write <= arb_mem_req_write;
            sim_beat  <= 8'd0;
            if (arb_mem_req_write) begin
              pmem_write(arb_mem_req_addr, arb_mem_req_wdata, {4'b0, arb_mem_req_wstrb});
              if (arb_mem_req_len == 8'd0) begin
                sim_mem_resp_valid <= 1'b1;
                sim_mem_resp_rlast <= 1'b1;
                sim_mem_state      <= SIM_MEM_RESP_LAST;
              end else begin
                sim_beat      <= 8'd1;
                sim_mem_state <= SIM_MEM_BURST;
              end
            end else begin
              // Read first beat
              sim_mem_resp_valid <= 1'b1;
              sim_mem_resp_rdata <= pmem_read(arb_mem_req_addr, 8'd4);
              sim_mem_resp_rlast <= (arb_mem_req_len == 8'd0);
              if (arb_mem_req_len > 8'd0) begin
                sim_beat      <= 8'd1;
                sim_mem_state <= SIM_MEM_BURST;
              end else begin
                sim_mem_state <= SIM_MEM_RESP_LAST;
              end
            end
          end
        end

        SIM_MEM_BURST: begin
          if (sim_write) begin
            pmem_write(sim_addr + {22'b0, sim_beat, 2'b00}, arb_mem_req_wdata, {4'b0, arb_mem_req_wstrb});
            if (sim_beat == sim_len) begin
              sim_mem_resp_valid <= 1'b1;
              sim_mem_resp_rlast <= 1'b1;
              sim_mem_state      <= SIM_MEM_RESP_LAST;
            end else begin
              sim_beat <= sim_beat + 8'd1;
            end
          end else begin
            sim_mem_resp_valid <= 1'b1;
            sim_mem_resp_rdata <= pmem_read(sim_addr + {22'b0, sim_beat, 2'b00}, 8'd4);
            sim_mem_resp_rlast <= (sim_beat == sim_len);
            if (sim_beat == sim_len) begin
              sim_mem_state <= SIM_MEM_RESP_LAST;
            end else begin
              sim_beat <= sim_beat + 8'd1;
            end
          end
        end

        SIM_MEM_RESP_LAST: begin
          sim_mem_resp_valid <= 1'b0;
          sim_mem_resp_rlast <= 1'b0;
          sim_mem_state      <= SIM_MEM_IDLE;
        end
        default: begin
          sim_mem_state <= SIM_MEM_IDLE;
        end
      endcase
    end
  end

  // =========================================================================
  // AXI4 Master Bridge instantiation (BUS_MODE == 1)
  // =========================================================================
  wire        axi_resp_valid;
  wire [31:0] axi_resp_rdata;
  wire        axi_resp_rlast;

  ysyx_261018_axi_master u_axi_master (
    .clock             (clock),
    .reset             (reset),
    .req_valid         (BUS_MODE == 1 && arb_mem_req_valid),
    .req_write         (arb_mem_req_write),
    .req_addr          (arb_mem_req_addr),
    .req_size          (3'b010),
    .req_len           (arb_mem_req_len),
    .req_wdata         (arb_mem_req_wdata),
    .req_wstrb         (arb_mem_req_wstrb),
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

  assign arb_mem_resp_valid = (BUS_MODE == 1) ? axi_resp_valid : sim_mem_resp_valid;
  assign arb_mem_resp_rdata = (BUS_MODE == 1) ? axi_resp_rdata : sim_mem_resp_rdata;
  assign arb_mem_resp_rlast = (BUS_MODE == 1) ? axi_resp_rlast : sim_mem_resp_rlast;

  // Tie off AXI Slave inputs/outputs
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

  // SimpleBus tie-offs
  assign io_ifu_addr      = pc;
  assign io_ifu_reqValid  = 1'b0;
  assign io_lsu_addr      = ex_mem_alu_res;
  assign io_lsu_reqValid  = 1'b0;
  assign io_lsu_size      = 2'b00;
  assign io_lsu_wen       = 1'b0;
  assign io_lsu_wdata     = 32'b0;
  assign io_lsu_wmask     = 4'b0;

endmodule
