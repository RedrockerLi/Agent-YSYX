`timescale 1ns / 1ps

module sim_top;
  reg clock;
  reg reset;
  reg [1023:0] img_path;

  initial begin
    clock = 0;
    reset = 1;
    if ($value$plusargs("img=%s", img_path)) begin
      $pmem_init_task(img_path);
    end else begin
      $display("[sim_top] Warning: +img=<path> not provided!");
    end
    # 20 reset = 0;
  end

  always # 10 clock = ~clock;


  // AXI Master wires from DUT
  wire        io_master_awready;
  wire        io_master_awvalid;
  wire [31:0] io_master_awaddr;
  wire [3:0]  io_master_awid;
  wire [7:0]  io_master_awlen;
  wire [2:0]  io_master_awsize;
  wire [1:0]  io_master_awburst;
  wire        io_master_wready;
  wire        io_master_wvalid;
  wire [31:0] io_master_wdata;
  wire [3:0]  io_master_wstrb;
  wire        io_master_wlast;
  wire        io_master_bready;
  wire        io_master_bvalid;
  wire [1:0]  io_master_bresp;
  wire [3:0]  io_master_bid;
  wire        io_master_arready;
  wire        io_master_arvalid;
  wire [31:0] io_master_araddr;
  wire [3:0]  io_master_arid;
  wire [7:0]  io_master_arlen;
  wire [2:0]  io_master_arsize;
  wire [1:0]  io_master_arburst;
  wire        io_master_rready;
  wire        io_master_rvalid;
  wire [1:0]  io_master_rresp;
  wire [31:0] io_master_rdata;
  wire        io_master_rlast;
  wire [3:0]  io_master_rid;

  // Slave outputs from DUT (ebreak trap status)
  wire        io_slave_bvalid;
  wire [1:0]  io_slave_bresp;
  wire [31:0] io_slave_rdata;

  // Instantiate NPC Core (works for both RTL and Gate-Level Netlist)
  cpu_top u_dut (
    .clock             (clock),
    .reset             (reset),
    .io_interrupt      (1'b0),

    // AXI Master ports
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
    .io_master_rid     (io_master_rid),

    // Slave ports
    .io_slave_awready  (),
    .io_slave_awvalid  (1'b0),
    .io_slave_awaddr   (32'b0),
    .io_slave_awid     (4'b0),
    .io_slave_awlen    (8'b0),
    .io_slave_awsize   (3'b0),
    .io_slave_awburst  (2'b0),
    .io_slave_wready   (),
    .io_slave_wvalid   (1'b0),
    .io_slave_wdata    (32'b0),
    .io_slave_wstrb    (4'b0),
    .io_slave_wlast    (1'b0),
    .io_slave_bready   (1'b1),
    .io_slave_bvalid   (io_slave_bvalid),
    .io_slave_bresp    (io_slave_bresp),
    .io_slave_bid      (),
    .io_slave_arready  (),
    .io_slave_arvalid  (1'b0),
    .io_slave_araddr   (32'b0),
    .io_slave_arid     (4'b0),
    .io_slave_arlen    (8'b0),
    .io_slave_arsize   (3'b0),
    .io_slave_arburst  (2'b0),
    .io_slave_rready   (1'b1),
    .io_slave_rvalid   (),
    .io_slave_rresp    (),
    .io_slave_rdata    (io_slave_rdata),
    .io_slave_rlast    (),
    .io_slave_rid      (),

    // SimpleBus ports
    .io_ifu_addr       (),
    .io_ifu_reqValid   (),
    .io_ifu_rdata      (32'b0),
    .io_ifu_respValid  (1'b0),
    .io_lsu_addr       (),
    .io_lsu_reqValid   (),
    .io_lsu_rdata      (32'b0),
    .io_lsu_respValid  (1'b0),
    .io_lsu_size       (),
    .io_lsu_wen        (),
    .io_lsu_wdata      (),
    .io_lsu_wmask      ()
  );

  // =========================================================================
  // AXI4 Read Channel Memory Responder
  // =========================================================================
  reg         r_arready;
  reg  [31:0] r_rdata;
  reg  [1:0]  r_rresp;
  reg         r_rlast;
  reg  [3:0]  r_rid;
  reg         r_rvalid;

  assign io_master_arready = r_arready;
  assign io_master_rdata   = r_rdata;
  assign io_master_rresp   = r_rresp;
  assign io_master_rlast   = r_rlast;
  assign io_master_rid     = r_rid;
  assign io_master_rvalid  = r_rvalid;

  reg [31:0] r_cur_addr;
  reg [7:0]  r_rem_len;
  reg [1:0]  r_state;

  localparam R_IDLE  = 2'd0;
  localparam R_BURST = 2'd1;

  always @(posedge clock) begin
    if (reset) begin
      r_state   <= R_IDLE;
      r_arready <= 1'b1;
      r_rvalid  <= 1'b0;
      r_rlast   <= 1'b0;
      r_rdata   <= 32'b0;
      r_rresp   <= 2'b00;
      r_rid     <= 4'b0;
      r_cur_addr<= 32'b0;
      r_rem_len <= 8'b0;
    end else begin
      case (r_state)
        R_IDLE: begin
          if (io_master_arvalid && r_arready) begin
            r_arready  <= 1'b0;
            r_rvalid   <= 1'b1;
            r_rdata    <= $pmem_read_func(io_master_araddr, 8'd4);
            r_rlast    <= (io_master_arlen == 8'd0);
            r_rresp    <= 2'b00;
            r_rid      <= io_master_arid;
            r_cur_addr <= io_master_araddr + 32'd4;
            r_rem_len  <= io_master_arlen;
            if (io_master_arlen > 8'd0) begin
              r_state <= R_BURST;
            end
          end else begin
            r_arready <= 1'b1;
            if (r_rvalid && io_master_rready) begin
              r_rvalid <= 1'b0;
              r_rlast  <= 1'b0;
            end
          end
        end

        R_BURST: begin
          if (r_rvalid && io_master_rready) begin
            if (r_rem_len == 8'd1) begin
              r_rdata    <= $pmem_read_func(r_cur_addr, 8'd4);
              r_rlast    <= 1'b1;
              r_rem_len  <= 8'd0;
              r_state    <= R_IDLE;
            end else if (r_rem_len > 8'd1) begin
              r_rdata    <= $pmem_read_func(r_cur_addr, 8'd4);
              r_rlast    <= 1'b0;
              r_cur_addr <= r_cur_addr + 32'd4;
              r_rem_len  <= r_rem_len - 8'd1;
            end
          end
        end
      endcase
    end
  end

  // =========================================================================
  // AXI4 Write Channel Memory Responder
  // =========================================================================
  reg        w_awready;
  reg        w_wready;
  reg [1:0]  w_bresp;
  reg [3:0]  w_bid;
  reg        w_bvalid;

  assign io_master_awready = w_awready;
  assign io_master_wready  = w_wready;
  assign io_master_bresp   = w_bresp;
  assign io_master_bid     = w_bid;
  assign io_master_bvalid  = w_bvalid;

  reg [31:0] w_cur_addr;
  reg [3:0]  w_cur_id;
  reg [1:0]  w_state;

  localparam W_IDLE = 2'd0;
  localparam W_DATA = 2'd1;
  localparam W_RESP = 2'd2;

  always @(posedge clock) begin
    if (reset) begin
      w_state   <= W_IDLE;
      w_awready <= 1'b1;
      w_wready  <= 1'b0;
      w_bvalid  <= 1'b0;
      w_bresp   <= 2'b00;
      w_bid     <= 4'b0;
      w_cur_addr<= 32'b0;
      w_cur_id  <= 4'b0;
    end else begin
      case (w_state)
        W_IDLE: begin
          if (io_master_awvalid && w_awready) begin
            w_awready  <= 1'b0;
            w_wready   <= 1'b1;
            w_cur_addr <= io_master_awaddr;
            w_cur_id   <= io_master_awid;
            w_state    <= W_DATA;
          end else begin
            w_awready <= 1'b1;
          end
        end

        W_DATA: begin
          if (io_master_wvalid && w_wready) begin
            $pmem_write_task(w_cur_addr, io_master_wdata, {4'b0, io_master_wstrb});
            w_cur_addr <= w_cur_addr + 32'd4;
            if (io_master_wlast) begin
              w_wready <= 1'b0;
              w_bvalid <= 1'b1;
              w_bresp  <= 2'b00;
              w_bid    <= w_cur_id;
              w_state  <= W_RESP;
            end
          end
        end

        W_RESP: begin
          if (w_bvalid && io_master_bready) begin
            w_bvalid  <= 1'b0;
            w_awready <= 1'b1;
            w_state   <= W_IDLE;
          end
        end
      endcase
    end
  end

  // =========================================================================
  // Simulation Tick & Trap Detection
  // =========================================================================
  always @(posedge clock) begin
    if (!reset) begin
      $sim_tick_task();
    end
  end

endmodule
