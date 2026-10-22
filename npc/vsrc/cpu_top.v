`timescale 1ns / 1ps

module cpu_top #(
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

`ifdef __ICARUS__
  // Icarus Verilog VPI functions/tasks for 4-state simulation
  function [31:0] pmem_read(input [31:0] raddr, input [7:0] rlen);
    pmem_read = $pmem_read_func(raddr, rlen);
  endfunction

  task pmem_write(input [31:0] waddr, input [31:0] wdata, input [7:0] wmask);
    $pmem_write_task(waddr, wdata, wmask);
  endtask

  task npc_ebreak(input [31:0] ebreak_pc, input [31:0] ebreak_a0);
    $npc_ebreak_task(ebreak_pc, ebreak_a0);
  endtask
`elsif SYNTHESIS
  // Stubs for ASIC logic synthesis
  function [31:0] pmem_read(input [31:0] raddr, input [7:0] rlen);
    pmem_read = 32'b0;
  endfunction

  task pmem_write(input [31:0] waddr, input [31:0] wdata, input [7:0] wmask);
  endtask

  task npc_ebreak(input [31:0] ebreak_pc, input [31:0] ebreak_a0);
  endtask
`else
  // Simulation DPI-C imports for memory access and trap detection
  import "DPI-C" context function int  pmem_read(input int raddr, input byte rlen);
  import "DPI-C" context function void pmem_write(input int waddr, input int wdata, input byte wmask);
  import "DPI-C" context function void npc_ebreak(input int pc, input int a0);
`endif

  // Forward declarations of pipeline control signals
  wire mem_stall;
  wire id_stall;
  wire ex_redirect;
  wire [31:0] ex_redirect_target;
  wire        div_busy;
  wire        div_done;
  wire        div_start;
  wire        div_accept;
  wire        ex_mdu_stall;
  wire        ex_jalr_stall;
  wire [31:0] div_res;

  wire        mul_busy;
  wire        mul_done;
  wire        mul_start;
  wire        mul_accept;
  wire [31:0] mul_res;

  // Cache Wires
  wire        icache_resp_valid;
  wire        icache_req_ready;
  wire [127:0] icache_resp_line;
  wire [1:0]  icache_resp_word_sel;
  wire        icache_flush;
  wire        dcache_resp_valid;
  wire [31:0] dcache_resp_rdata;
  wire        dcache_fence_done;

  wire [31:0] icache_hit_cnt;
  wire [31:0] icache_miss_cnt;
  wire [31:0] dcache_hit_cnt;
  wire [31:0] dcache_miss_cnt;

  // =========================================================================
  // Stage 1: Fetch (synchronous ICache read + instruction FIFO)
  // =========================================================================
  reg  [31:0] fetch_pc;
  reg  [31:0] fetch_req_pc;
  reg  [31:0] fence_next_pc;
  reg         fetch_pending;
  reg  [3:0]  fq_count;
  reg  [2:0]  fq_head;
  reg  [2:0]  fq_tail;
  reg  [31:0] fq_pc   [0:7];
  reg  [31:0] fq_inst [0:7];

  wire [31:0] bpu_pred_target;
  wire        bpu_pred_taken;
  wire [31:0] bpu_total_pred_cnt;
  wire [31:0] bpu_correct_pred_cnt;
  wire        id_pred_redirect;
  wire        fence_flush;

  reg  [31:0] fq_head_pc;
  reg  [31:0] fq_head_inst;

  wire [1:0]  fetch_req_off   = fetch_req_pc[3:2];
  wire [31:0] fetch_word_base = {30'b0, fetch_req_off};
  wire [2:0]  fetch_req_words = 3'd4 - {1'b0, fetch_req_off};
  wire [31:0] fetch_next_line = {fetch_req_pc[31:4], 4'b0} + 32'd16;

  wire fetch_start = !fetch_pending && (fq_count <= 4'd2) &&
                     icache_req_ready && !icache_flush;
  wire fq_push     = icache_resp_valid && !icache_flush;
  wire fq_pop      = !id_stall && (fq_count != 4'd0) && !icache_flush;

  assign icache_flush = ex_redirect || id_pred_redirect || fence_flush;

  always @(posedge clock) begin
    if (reset) begin
      fetch_pc      <= RESET_VAL;
      fetch_req_pc  <= RESET_VAL;
      fence_next_pc <= RESET_VAL;
      fetch_pending <= 1'b0;
    end else if (fence_flush) begin
      fetch_pc      <= fence_next_pc;
      fetch_pending <= 1'b0;
    end else if (ex_redirect) begin
      fetch_pc      <= ex_redirect_target;
      fetch_pending <= 1'b0;
    end else if (id_pred_redirect) begin
      fetch_pc      <= if_id_pred_target;
      fetch_pending <= 1'b0;
    end else if (fetch_start) begin
      fetch_req_pc  <= fetch_pc;
      fetch_pending <= 1'b1;
    end else if (icache_resp_valid) begin
      fetch_pending <= 1'b0;
      fetch_pc      <= fetch_next_line;
    end
  end

  integer fqi;
  always @(posedge clock) begin
    if (reset) begin
      fq_count <= 4'd0;
      fq_head  <= 3'd0;
      fq_tail  <= 3'd0;
    end else if (icache_flush) begin
      fq_count <= 4'd0;
      fq_head  <= 3'd0;
      fq_tail  <= 3'd0;
    end else begin
      if (fq_push) begin
        for (fqi = 0; fqi < 4; fqi = fqi + 1) begin
          if (fqi < fetch_req_words) begin
            fq_pc[(fq_tail + fqi[2:0]) & 3'd7]   <= fetch_req_pc + (fqi << 2);
            fq_inst[(fq_tail + fqi[2:0]) & 3'd7] <=
                icache_resp_line[32*((fetch_word_base + fqi) & 32'd3) +: 32];
          end
        end
      end
      if (fq_pop)  fq_head <= fq_head + 3'd1;
      if (fq_push) fq_tail <= fq_tail + fetch_req_words;
      fq_count <= fq_count + (fq_push ? {1'b0, fetch_req_words} : 4'd0) -
                  (fq_pop ? 4'd1 : 4'd0);
    end
  end

  // Registered FIFO head: the BPU and IF/ID read a flop instead of the 8:1
  // array mux.
  always @(posedge clock) begin
    if (reset || icache_flush) begin
      fq_head_pc   <= 32'b0;
      fq_head_inst <= 32'h00000013;
    end else if (fq_pop) begin
      if (fq_count == 4'd1 && fq_push) begin
        fq_head_pc   <= fetch_req_pc;
        fq_head_inst <= icache_resp_line[32*fetch_req_off +: 32];
      end else if (fq_count > 4'd1) begin
        fq_head_pc   <= fq_pc[(fq_head + 3'd1) & 3'd7];
        fq_head_inst <= fq_inst[(fq_head + 3'd1) & 3'd7];
      end
    end else if (fq_push && fq_count == 4'd0) begin
      fq_head_pc   <= fetch_req_pc;
      fq_head_inst <= icache_resp_line[32*fetch_req_off +: 32];
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

  always @(posedge clock) begin
    if (reset || icache_flush) begin
      if_id_valid       <= 1'b0;
      if_id_pc          <= 32'b0;
      if_id_inst        <= 32'h00000013; // NOP
      if_id_pred_taken  <= 1'b0;
      if_id_pred_target <= 32'b0;
    end else if (!id_stall) begin
      if (fq_count != 4'd0) begin
        if_id_valid       <= 1'b1;
        if_id_pc          <= fq_head_pc;
        if_id_inst        <= fq_head_inst;
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

  // The BPU lookup result is captured with the instruction into IF/ID, so the
  // ID-stage redirect uses a flop instead of the BTB read path.
  assign id_pred_redirect = if_id_valid && !id_stall && !ex_redirect && !fence_flush &&
                            (id_is_branch || id_is_jal || id_is_jalr) &&
                            if_id_pred_taken;
  wire id_is_load    = (id_opcode == 7'b0000011);
  wire id_is_store   = (id_opcode == 7'b0100011);
  wire id_is_alu_i   = (id_opcode == 7'b0010011);
  wire id_is_alu_r   = (id_opcode == 7'b0110011);
  wire id_is_system  = (id_opcode == 7'b1110011);
  wire id_is_fence_i = (id_opcode == 7'b0001111);
  wire id_is_div     = id_is_alu_r && (id_funct7 == 7'b0000001) && id_funct3[2];
  wire id_is_mul     = id_is_alu_r && (id_funct7 == 7'b0000001) && !id_funct3[2];

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

  regfile #(
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

  assign id_stall = load_use_hazard || mem_stall || ex_mdu_stall || ex_jalr_stall;

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
  reg        id_ex_is_div;
  reg        id_ex_is_mul;
  reg        id_ex_pred_taken;
  reg [31:0] id_ex_pred_target;

  wire id_ex_flush = (!mem_stall && (ex_redirect || load_use_hazard)) || fence_flush;

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
      id_ex_is_div      <= 1'b0;
      id_ex_is_mul      <= 1'b0;
      id_ex_pred_taken  <= 1'b0;
      id_ex_pred_target <= 32'b0;
    end else if (mem_stall) begin
      if (wb_rf_wen && (wb_rd != 5'd0)) begin
        if (wb_rd == id_ex_rs1) id_ex_rs1_data <= wb_wdata;
        if (wb_rd == id_ex_rs2) id_ex_rs2_data <= wb_wdata;
      end
    end else if (ex_mdu_stall || ex_jalr_stall) begin
      // Hold the MDU instruction in EX; its operands were latched by the unit.
    end else begin
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
      id_ex_is_div      <= if_id_valid ? id_is_div : 1'b0;
      id_ex_is_mul      <= if_id_valid ? id_is_mul : 1'b0;
      id_ex_pred_taken  <= if_id_pred_taken;
      id_ex_pred_target <= if_id_pred_target;
    end
  end

  // Latch the fence.i restart PC when the fence leaves EX.  The MEM-stage
  // fence flush uses it to restart fetch after the I-cache invalidation.
  always @(posedge clock) begin
    if (reset)
      fence_next_pc <= RESET_VAL;
    else if (id_ex_valid && id_ex_is_fence_i && !mem_stall && !ex_mdu_stall)
      fence_next_pc <= id_ex_pc + 32'd4;
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
  alu u_alu (
    .alu_op (id_ex_alu_op),
    .src1   (alu_in1),
    .src2   (alu_in2),
    .res    (alu_res)
  );

  // Multi-cycle MDU.  DIV and MUL instructions occupy EX until their unit
  // raises done; the result is captured by EX/MEM on the accept cycle.
  assign div_start    = id_ex_valid && id_ex_is_div && !div_busy && !div_done &&
                        !ex_redirect_r;
  assign div_accept   = div_done && !mem_stall;
  assign mul_start    = id_ex_valid && id_ex_is_mul && !mul_busy && !mul_done &&
                        !ex_redirect_r;
  assign mul_accept   = mul_done && !mem_stall;
  assign ex_mdu_stall = !ex_redirect_r &&
                        ((id_ex_valid && id_ex_is_div && !div_accept) ||
                         (id_ex_valid && id_ex_is_mul && !mul_accept));

  div_unit #(
    .DIV_BITS_PER_CYCLE (1)
  ) u_div_unit (
    .clock  (clock),
    .reset  (reset),
    .start  (div_start),
    .accept (div_accept),
    .alu_op (id_ex_alu_op),
    .src1   (ex_src1),
    .src2   (ex_src2),
    .busy   (div_busy),
    .done   (div_done),
    .res    (div_res)
  );

  mul_unit #(
    .MUL_BITS_PER_CYCLE (4)
  ) u_mul_unit (
    .clock  (clock),
    .reset  (reset),
    .start  (mul_start),
    .accept (mul_accept),
    .alu_op (id_ex_alu_op),
    .src1   (ex_src1),
    .src2   (ex_src2),
    .busy   (mul_busy),
    .done   (mul_done),
    .res    (mul_res)
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

  // JALR target: the forwarded src1 is captured in the first EX cycle, and
  // the target adder runs from those flops in the second EX cycle.
  reg        jalr_phase;
  reg [31:0] jalr_src1_r;
  reg [31:0] jalr_imm_r;
  assign ex_jalr_stall = id_ex_valid && id_ex_is_jalr && !jalr_phase && !ex_redirect;
  wire [31:0] jalr_target  = (jalr_src1_r + jalr_imm_r) & ~32'h1;

  always @(posedge clock) begin
    if (reset) begin
      jalr_phase  <= 1'b0;
      jalr_src1_r <= 32'b0;
      jalr_imm_r  <= 32'b0;
    end else if (!mem_stall && !ex_mdu_stall) begin
      if (id_ex_valid && id_ex_is_jalr && !jalr_phase && !ex_redirect) begin
        jalr_src1_r <= ex_src1;
        jalr_imm_r  <= id_ex_imm;
        jalr_phase  <= 1'b1;
      end else begin
        jalr_phase  <= 1'b0;
      end
    end
  end

  wire ex_actual_taken = id_ex_is_branch ? branch_cond_met : (id_ex_is_jal || id_ex_is_jalr);

  wire [31:0] ex_actual_target = id_ex_is_branch ? (id_ex_pc + id_ex_imm) :
                                 id_ex_is_jal    ? (id_ex_pc + id_ex_imm) :
                                 (id_ex_is_jalr && jalr_phase) ? jalr_target :
                                                   (id_ex_pc + 32'd4);

  wire [31:0] ex_correct_next_pc = ex_actual_taken ? ex_actual_target : (id_ex_pc + 32'd4);

  wire ex_mispredict = !ex_jalr_stall && id_ex_valid && (id_ex_is_branch || id_ex_is_jal || id_ex_is_jalr) &&
                       ((ex_actual_taken != id_ex_pred_taken) ||
                        (ex_actual_taken && (ex_correct_next_pc != id_ex_pred_target)));

  // CSR Module
  wire [31:0] csr_rdata;
  wire [31:0] mtvec;
  wire [31:0] mepc;

  csr u_csr (
    .clk        (clock),
    .rst        (reset),
    .csr_addr   (id_ex_csr_addr),
    .csr_op     (id_ex_csr_op),
    .csr_wdata  (id_ex_funct3[2] ? id_ex_imm : ex_src1),
    .csr_wen    (id_ex_valid && id_ex_is_csr && !mem_stall && !ex_redirect_r),
    .csr_rdata  (csr_rdata),
    .is_ecall   (id_ex_valid && id_ex_is_ecall && !mem_stall),
    .is_mret    (id_ex_valid && id_ex_is_mret && !mem_stall),
    .pc         (id_ex_pc),
    .mtvec_out  (mtvec),
    .mepc_out   (mepc)
  );

  // Exception / Branch Redirection
  // Register the EX redirect before it enters the fetch unit.  The redirect
  // cycle's younger instruction is killed by ex_redirect_r on the next cycle.
  reg        ex_redirect_r;
  reg [31:0] ex_redirect_target_r;
  assign ex_redirect        = ex_redirect_r;
  assign ex_redirect_target = ex_redirect_target_r;

  wire ex_redirect_now = !mem_stall && !ex_mdu_stall && !ex_jalr_stall && !ex_redirect_r && !fence_flush &&
                         id_ex_valid &&
                         (id_ex_is_ecall || id_ex_is_mret || id_ex_is_fence_i || ex_mispredict);

  wire [31:0] ex_redirect_target_now = id_ex_is_ecall   ? mtvec :
                                       id_ex_is_mret    ? mepc :
                                       id_ex_is_fence_i ? (id_ex_pc + 32'd4) :
                                                          ex_correct_next_pc;

  always @(posedge clock) begin
    if (reset) begin
      ex_redirect_r        <= 1'b0;
      ex_redirect_target_r <= 32'b0;
    end else begin
      ex_redirect_r <= ex_redirect_now;
      if (ex_redirect_now)
        ex_redirect_target_r <= ex_redirect_target_now;
    end
  end

  // Register BPU training at the EX/MEM boundary so the BPU array write is
  // driven by flops instead of the forwarding/ALU cone.
  reg        bpu_train_valid;
  reg [31:0] bpu_train_pc;
  reg [31:0] bpu_train_target;
  reg        bpu_train_taken;
  reg        bpu_train_is_call;
  reg        bpu_train_is_ret;
  reg        bpu_train_mispred;

  wire bpu_capture = id_ex_valid && (id_ex_is_branch || id_ex_is_jal || id_ex_is_jalr) &&
                     !mem_stall && !ex_mdu_stall && !ex_jalr_stall && !ex_redirect_r;

  always @(posedge clock) begin
    if (reset) begin
      bpu_train_valid   <= 1'b0;
      bpu_train_pc      <= 32'b0;
      bpu_train_target  <= 32'b0;
      bpu_train_taken   <= 1'b0;
      bpu_train_is_call <= 1'b0;
      bpu_train_is_ret  <= 1'b0;
      bpu_train_mispred <= 1'b0;
    end else begin
      bpu_train_valid <= bpu_capture;
      if (bpu_capture) begin
        bpu_train_pc      <= id_ex_pc;
        bpu_train_target  <= ex_actual_target;
        bpu_train_taken   <= ex_actual_taken;
        bpu_train_is_call <= (id_ex_is_jal || id_ex_is_jalr) && (id_ex_rd == 5'd1);
        bpu_train_is_ret  <= id_ex_is_jalr && (id_ex_rs1 == 5'd1);
        bpu_train_mispred <= ex_mispredict;
      end
    end
  end

  // Branch Prediction Unit
  bpu #(
    .BTB_ENTRIES      (32),
    .INDEX_WIDTH      (5)
  ) u_bpu (
    .clock            (clock),
    .reset            (reset),
    .if_pc            (fq_head_pc),
    .pred_taken       (bpu_pred_taken),
    .pred_target      (bpu_pred_target),
    .train_valid      (bpu_train_valid),
    .train_pc         (bpu_train_pc),
    .train_taken      (bpu_train_taken),
    .train_target     (bpu_train_target),
    .train_is_call    (bpu_train_is_call),
    .train_is_ret     (bpu_train_is_ret),
    .train_mispred    (bpu_train_mispred),
    .total_pred_cnt   (bpu_total_pred_cnt),
    .correct_pred_cnt (bpu_correct_pred_cnt)
  );

  // =========================================================================
  // Pipeline Register: EX / MEM
  // =========================================================================
  reg [31:0] ex_mem_pc;
  reg [31:0] ex_mem_inst;
  reg [31:0] ex_mem_alu_res;
  reg [31:0] ex_mem_store_data;
  reg [31:0] ex_mem_next_pc;
  reg [2:0]  ex_mem_funct3;
  reg        ex_mem_is_load;
  reg        ex_mem_is_store;
  reg        ex_mem_is_ebreak;
  reg        ex_mem_is_fence_i;

  assign fence_flush = ex_mem_valid && ex_mem_is_fence_i;

  // Writeback value is selected in EX and registered with EX/MEM, so the
  // forwarding path starts from a flop instead of a combinational mux.
  wire [31:0] ex_val_next = id_ex_is_csr ? csr_rdata :
                            id_ex_is_lui ? id_ex_imm :
                            (id_ex_is_jal || id_ex_is_jalr) ? (id_ex_pc + 32'd4) :
                            id_ex_is_div ? div_res :
                            id_ex_is_mul ? mul_res :
                            alu_res;

  always @(posedge clock) begin
    if (reset) begin
      ex_mem_valid       <= 1'b0;
      ex_mem_pc          <= 32'b0;
      ex_mem_inst        <= 32'b0;
      ex_mem_rd          <= 5'b0;
      ex_mem_alu_res     <= 32'b0;
      ex_mem_val         <= 32'b0;
      ex_mem_store_data  <= 32'b0;
      ex_mem_next_pc     <= 32'b0;
      ex_mem_funct3      <= 3'b0;
      ex_mem_rf_wen      <= 1'b0;
      ex_mem_is_load     <= 1'b0;
      ex_mem_is_store    <= 1'b0;
      ex_mem_is_ebreak   <= 1'b0;
      ex_mem_is_fence_i  <= 1'b0;
    end else if (mem_stall) begin
      // Hold the older memory instruction in MEM.
    end else if (ex_redirect_r || ex_mdu_stall || ex_jalr_stall) begin
      // Kill the younger instruction in EX; the redirecting instruction
      // already in EX/MEM advances to MEM/WB on this edge.
      ex_mem_valid       <= 1'b0;
      ex_mem_rd          <= 5'd0;
      ex_mem_alu_res     <= 32'b0;
      ex_mem_val         <= 32'b0;
      ex_mem_store_data  <= 32'b0;
      ex_mem_funct3      <= 3'b0;
      ex_mem_rf_wen      <= 1'b0;
      ex_mem_is_load     <= 1'b0;
      ex_mem_is_store    <= 1'b0;
      ex_mem_is_ebreak   <= 1'b0;
      ex_mem_is_fence_i  <= 1'b0;
    end else begin
      ex_mem_valid       <= id_ex_valid;
      ex_mem_pc          <= id_ex_pc;
      ex_mem_inst        <= id_ex_inst;
      ex_mem_rd          <= id_ex_valid ? id_ex_rd : 5'd0;
      ex_mem_alu_res     <= alu_res;
      ex_mem_val         <= id_ex_valid ? ex_val_next : 32'b0;
      ex_mem_store_data  <= ex_src2;
      ex_mem_next_pc     <= ex_correct_next_pc;
      ex_mem_funct3      <= id_ex_funct3;
      ex_mem_rf_wen      <= id_ex_valid ? id_ex_rf_wen : 1'b0;
      ex_mem_is_load     <= id_ex_valid ? id_ex_is_load : 1'b0;
      ex_mem_is_store    <= id_ex_valid ? id_ex_is_store : 1'b0;
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

  // Store data formatting runs in MEM, off the EX forwarding/shift path.
  reg  [31:0] mem_store_data;
  reg  [3:0]  mem_store_mask;
  always @(*) begin
    case (ex_mem_funct3)
      3'b000: begin // SB
        mem_store_data = ex_mem_store_data << (8 * mem_byte_offset);
        mem_store_mask = 4'b0001 << mem_byte_offset;
      end
      3'b001: begin // SH
        mem_store_data = ex_mem_store_data << (16 * mem_byte_offset[1]);
        mem_store_mask = 4'b0011 << (2 * mem_byte_offset[1]);
      end
      3'b010: begin // SW
        mem_store_data = ex_mem_store_data;
        mem_store_mask = 4'b1111;
      end
      default: begin
        mem_store_data = ex_mem_store_data;
        mem_store_mask = 4'b0000;
      end
    endcase
  end

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

  wire [31:0] mem_final_wdata = ex_mem_is_load ? mem_rdata : ex_mem_val;

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

`ifndef SYNTHESIS
  // Trap handling
  always @(posedge clock) begin
    if (!reset && mem_wb_valid && mem_wb_is_ebreak) begin
      npc_ebreak(mem_wb_pc, u_regfile.get_gpr_val(5'd10));
    end
  end
`endif

`ifndef SYNTHESIS
`ifndef __ICARUS__
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
`endif
`endif

  // =========================================================================
  // Cache Instances & Arbiter
  // =========================================================================
  wire        icache_mem_req_valid;
  wire [31:0] icache_mem_req_addr;
  wire [7:0]  icache_mem_req_len;
  wire        icache_mem_grant;
  wire        icache_mem_req_ack;
  wire        icache_mem_resp_valid;
  wire [31:0] icache_mem_resp_rdata;
  wire        icache_mem_resp_rlast;

  icache #(
    .SET_WIDTH    (6),
    .OFFSET_WIDTH (4),
    .TAG_WIDTH    (22)
  ) u_icache (
    .clock          (clock),
    .reset          (reset),
    .req_valid      (fetch_start),
    .req_addr       (fetch_pc),
    .req_ready      (icache_req_ready),
    .resp_valid     (icache_resp_valid),
    .resp_line      (icache_resp_line),
    .resp_word_sel  (icache_resp_word_sel),
    .flush          (icache_flush),
    .fence_i        (ex_mem_valid && ex_mem_is_fence_i),
    .mem_req_ack    (icache_mem_req_ack),
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
  wire        dcache_mem_req_ack;
  wire        dcache_mem_write_ack;
  wire        dcache_mem_resp_valid;
  wire [31:0] dcache_mem_resp_rdata;
  wire        dcache_mem_resp_rlast;
  wire        dcache_req_ready;

  // The synchronous D-cache needs a one-shot request; the EX/MEM instruction
  // is held by mem_stall until the response is visible.
  reg         mem_req_accepted;
  wire        dcache_req_valid = !reset && ex_mem_valid &&
                                 (ex_mem_is_load || ex_mem_is_store) &&
                                 !mem_req_accepted;

  always @(posedge clock) begin
    if (reset)
      mem_req_accepted <= 1'b0;
    else if (dcache_resp_valid)
      mem_req_accepted <= 1'b0;
    else if (dcache_req_valid && dcache_req_ready)
      mem_req_accepted <= 1'b1;
  end

  dcache #(
    .SET_WIDTH    (6),
    .OFFSET_WIDTH (4),
    .TAG_WIDTH    (22)
  ) u_dcache (
    .clock          (clock),
    .reset          (reset),
    .req_valid      (dcache_req_valid),
    .req_write      (ex_mem_is_store),
    .req_addr       (ex_mem_alu_res),
    .req_wdata      (mem_store_data),
    .req_wmask      (mem_store_mask),
    .req_ready      (dcache_req_ready),
    .resp_valid     (dcache_resp_valid),
    .resp_rdata     (dcache_resp_rdata),
    .fence_i        (ex_mem_valid && ex_mem_is_fence_i),
    .fence_done     (dcache_fence_done),
    .mem_req_ack    (dcache_mem_req_ack),
    .mem_write_ack  (dcache_mem_write_ack),
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
  wire        arb_mem_req_ack;
  wire        arb_mem_write_beat_ack;
  wire        arb_mem_resp_valid;
  wire [31:0] arb_mem_resp_rdata;
  wire        arb_mem_resp_rlast;

  cache_arbiter u_arbiter (
    .clock                 (clock),
    .reset                 (reset),
    .icache_mem_req_valid  (icache_mem_req_valid),
    .icache_mem_req_addr   (icache_mem_req_addr),
    .icache_mem_req_len    (icache_mem_req_len),
    .icache_mem_grant      (icache_mem_grant),
    .icache_mem_req_ack    (icache_mem_req_ack),
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
    .dcache_mem_req_ack    (dcache_mem_req_ack),
    .dcache_mem_write_ack  (dcache_mem_write_ack),
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
    .mem_req_ack           (arb_mem_req_ack),
    .mem_write_beat_ack    (arb_mem_write_beat_ack),
    .mem_resp_valid        (arb_mem_resp_valid),
    .mem_resp_rdata        (arb_mem_resp_rdata),
    .mem_resp_rlast        (arb_mem_resp_rlast)
  );

  // =========================================================================
  // Simulation Burst Engine (CORE_BUS_MODE == 0)
  // =========================================================================
`ifdef SYNTHESIS
  localparam CORE_BUS_MODE = 1;
`else
  localparam CORE_BUS_MODE = BUS_MODE;
`endif

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
          if (CORE_BUS_MODE == 0 && arb_mem_req_valid) begin
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
  wire        axi_req_ack;
  wire        axi_write_beat_ack;

  axi_master u_axi_master (
    .clock             (clock),
    .reset             (reset),
    .req_valid         (CORE_BUS_MODE == 1 && arb_mem_req_valid),
    .req_write         (arb_mem_req_write),
    .req_addr          (arb_mem_req_addr),
    .req_size          (3'b010),
    .req_len           (arb_mem_req_len),
    .req_wdata         (arb_mem_req_wdata),
    .req_wstrb         (arb_mem_req_wstrb),
    .req_ack           (axi_req_ack),
    .write_beat_ack    (axi_write_beat_ack),
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

  assign arb_mem_req_ack        = (CORE_BUS_MODE == 1) ? axi_req_ack : (sim_mem_state == SIM_MEM_IDLE && arb_mem_req_valid);
  assign arb_mem_write_beat_ack = (CORE_BUS_MODE == 1) ? axi_write_beat_ack :
                                  ((sim_mem_state == SIM_MEM_IDLE && arb_mem_req_valid && arb_mem_req_write && (arb_mem_req_len > 8'd0)) ||
                                   (sim_mem_state == SIM_MEM_BURST && sim_write));
  assign arb_mem_resp_valid     = (CORE_BUS_MODE == 1) ? axi_resp_valid : sim_mem_resp_valid;
  assign arb_mem_resp_rdata     = (CORE_BUS_MODE == 1) ? axi_resp_rdata : sim_mem_resp_rdata;
  assign arb_mem_resp_rlast     = (CORE_BUS_MODE == 1) ? axi_resp_rlast : sim_mem_resp_rlast;

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
  assign io_ifu_addr      = fetch_pc;
  assign io_ifu_reqValid  = 1'b0;
  assign io_lsu_addr      = ex_mem_alu_res;
  assign io_lsu_reqValid  = 1'b0;
  assign io_lsu_size      = 2'b00;
  assign io_lsu_wen       = 1'b0;
  assign io_lsu_wdata     = 32'b0;
  assign io_lsu_wmask     = 4'b0;

endmodule
