`timescale 1ns / 1ps

module axi_master (
  input             clock,
  input             reset,

  // Core internal interface
  input             req_valid,
  input             req_write,
  input      [31:0] req_addr,
  input      [2:0]  req_size,
  input      [7:0]  req_len,
  input      [31:0] req_wdata,
  input      [3:0]  req_wstrb,
  output            req_ack,
  output            write_beat_ack,
  output reg        resp_valid,
  output reg [31:0] resp_rdata,
  output reg        resp_rlast,

  // AXI4 Master Bus
  // AW
  input             io_master_awready,
  output reg        io_master_awvalid,
  output reg [31:0] io_master_awaddr,
  output     [3:0]  io_master_awid,
  output reg [7:0]  io_master_awlen,
  output reg [2:0]  io_master_awsize,
  output     [1:0]  io_master_awburst,
  // W
  input             io_master_wready,
  output reg        io_master_wvalid,
  output     [31:0] io_master_wdata,
  output     [3:0]  io_master_wstrb,
  output            io_master_wlast,
  // B
  output reg        io_master_bready,
  input             io_master_bvalid,
  input      [1:0]  io_master_bresp,
  input      [3:0]  io_master_bid,
  // AR
  input             io_master_arready,
  output reg        io_master_arvalid,
  output reg [31:0] io_master_araddr,
  output     [3:0]  io_master_arid,
  output reg [7:0]  io_master_arlen,
  output reg [2:0]  io_master_arsize,
  output     [1:0]  io_master_arburst,
  // R
  output reg        io_master_rready,
  input             io_master_rvalid,
  input      [1:0]  io_master_rresp,
  input      [31:0] io_master_rdata,
  input             io_master_rlast,
  input      [3:0]  io_master_rid
);

  assign io_master_awid    = 4'b0;
  assign io_master_awburst = 2'b01; // INCR
  assign io_master_arid    = 4'b0;
  assign io_master_arburst = 2'b01; // INCR

  assign req_ack        = (state == S_IDLE) && req_valid;
  assign write_beat_ack = (state == S_WRITE_AW_W) && io_master_wvalid && io_master_wready;

  assign io_master_wdata = req_wdata;
  assign io_master_wstrb = req_wstrb;
  assign io_master_wlast = (state == S_WRITE_AW_W) && (w_beat == saved_wlen);

  localparam S_IDLE       = 3'd0;
  localparam S_READ_AR    = 3'd1;
  localparam S_READ_R     = 3'd2;
  localparam S_WRITE_AW_W = 3'd3;
  localparam S_WRITE_B    = 3'd4;

  reg [2:0] state;
  reg aw_done;
  reg w_done;
  reg [7:0] w_beat;
  reg [7:0] saved_wlen;

  always @(posedge clock) begin
    if (reset) begin
      state             <= S_IDLE;
      io_master_arvalid <= 1'b0;
      io_master_rready  <= 1'b0;
      io_master_awvalid <= 1'b0;
      io_master_wvalid  <= 1'b0;
      io_master_bready  <= 1'b0;
      resp_valid        <= 1'b0;
      resp_rdata        <= 32'b0;
      resp_rlast        <= 1'b0;
      aw_done           <= 1'b0;
      w_done            <= 1'b0;
      w_beat            <= 8'b0;
      saved_wlen        <= 8'b0;
    end else begin
      resp_valid <= 1'b0;
      resp_rlast <= 1'b0;

      case (state)
        S_IDLE: begin
          if (req_valid) begin
            if (req_write) begin
              state             <= S_WRITE_AW_W;
              io_master_awvalid <= 1'b1;
              io_master_awaddr  <= req_addr;
              io_master_awlen   <= req_len;
              io_master_awsize  <= req_size;
              saved_wlen        <= req_len;
              w_beat            <= 8'd0;
              io_master_wvalid  <= 1'b1;
              aw_done           <= 1'b0;
              w_done            <= 1'b0;
            end else begin
              state             <= S_READ_AR;
              io_master_arvalid <= 1'b1;
              io_master_araddr  <= req_addr;
              io_master_arlen   <= req_len;
              io_master_arsize  <= req_size;
            end
          end
        end

        S_READ_AR: begin
          if (io_master_arvalid && io_master_arready) begin
            io_master_arvalid <= 1'b0;
            io_master_rready  <= 1'b1;
            state             <= S_READ_R;
          end
        end

        S_READ_R: begin
          if (io_master_rvalid && io_master_rready) begin
            resp_valid <= 1'b1;
            resp_rdata <= io_master_rdata;
            resp_rlast <= io_master_rlast;
            if (io_master_rlast) begin
              io_master_rready <= 1'b0;
              state            <= S_IDLE;
            end
          end
        end

        S_WRITE_AW_W: begin
          if (io_master_awvalid && io_master_awready) begin
            io_master_awvalid <= 1'b0;
            aw_done           <= 1'b1;
          end

          if (io_master_wvalid && io_master_wready) begin
            if (w_beat == saved_wlen) begin
              io_master_wvalid <= 1'b0;
              w_done           <= 1'b1;
            end else begin
              w_beat <= w_beat + 8'd1;
            end
          end

          if ((aw_done || (io_master_awvalid && io_master_awready)) &&
              (w_done  || (io_master_wvalid  && io_master_wready && (w_beat == saved_wlen)))) begin
            io_master_bready <= 1'b1;
            state            <= S_WRITE_B;
          end
        end

        S_WRITE_B: begin
          if (io_master_bvalid && io_master_bready) begin
            io_master_bready <= 1'b0;
            resp_valid       <= 1'b1;
            state            <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
