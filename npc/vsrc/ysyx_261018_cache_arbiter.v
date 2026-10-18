`timescale 1ns / 1ps

module ysyx_261018_cache_arbiter (
  input             clock,
  input             reset,

  // ICache Interface
  input             icache_mem_req_valid,
  input      [31:0] icache_mem_req_addr,
  input      [7:0]  icache_mem_req_len,
  output            icache_mem_resp_valid,
  output     [31:0] icache_mem_resp_rdata,
  output            icache_mem_resp_rlast,

  // DCache Interface
  input             dcache_mem_req_valid,
  input             dcache_mem_req_write,
  input      [31:0] dcache_mem_req_addr,
  input      [7:0]  dcache_mem_req_len,
  input      [31:0] dcache_mem_req_wdata,
  input      [3:0]  dcache_mem_req_wstrb,
  input             dcache_mem_req_wlast,
  output            dcache_mem_resp_valid,
  output     [31:0] dcache_mem_resp_rdata,
  output            dcache_mem_resp_rlast,

  // Downstream Memory Interface
  output reg        mem_req_valid,
  output reg        mem_req_write,
  output reg [31:0] mem_req_addr,
  output reg [7:0]  mem_req_len,
  output reg [31:0] mem_req_wdata,
  output reg [3:0]  mem_req_wstrb,
  output reg        mem_req_wlast,
  input             mem_resp_valid,
  input      [31:0] mem_resp_rdata,
  input             mem_resp_rlast
);

  localparam GRANT_NONE   = 2'd0;
  localparam GRANT_DCACHE = 2'd1;
  localparam GRANT_ICACHE = 2'd2;

  reg [1:0] grant;

  // Grant routing
  always @(*) begin
    case (grant)
      GRANT_DCACHE: begin
        mem_req_valid = dcache_mem_req_valid;
        mem_req_write = dcache_mem_req_write;
        mem_req_addr  = dcache_mem_req_addr;
        mem_req_len   = dcache_mem_req_len;
        mem_req_wdata = dcache_mem_req_wdata;
        mem_req_wstrb = dcache_mem_req_wstrb;
        mem_req_wlast = dcache_mem_req_wlast;
      end
      GRANT_ICACHE: begin
        mem_req_valid = icache_mem_req_valid;
        mem_req_write = 1'b0;
        mem_req_addr  = icache_mem_req_addr;
        mem_req_len   = icache_mem_req_len;
        mem_req_wdata = 32'b0;
        mem_req_wstrb = 4'b0;
        mem_req_wlast = 1'b0;
      end
      default: begin
        if (dcache_mem_req_valid) begin
          mem_req_valid = 1'b1;
          mem_req_write = dcache_mem_req_write;
          mem_req_addr  = dcache_mem_req_addr;
          mem_req_len   = dcache_mem_req_len;
          mem_req_wdata = dcache_mem_req_wdata;
          mem_req_wstrb = dcache_mem_req_wstrb;
          mem_req_wlast = dcache_mem_req_wlast;
        end else if (icache_mem_req_valid) begin
          mem_req_valid = 1'b1;
          mem_req_write = 1'b0;
          mem_req_addr  = icache_mem_req_addr;
          mem_req_len   = icache_mem_req_len;
          mem_req_wdata = 32'b0;
          mem_req_wstrb = 4'b0;
          mem_req_wlast = 1'b0;
        end else begin
          mem_req_valid = 1'b0;
          mem_req_write = 1'b0;
          mem_req_addr  = 32'b0;
          mem_req_len   = 8'b0;
          mem_req_wdata = 32'b0;
          mem_req_wstrb = 4'b0;
          mem_req_wlast = 1'b0;
        end
      end
    endcase
  end

  // Responses to masters
  assign dcache_mem_resp_valid = (grant == GRANT_DCACHE) ? mem_resp_valid : 1'b0;
  assign dcache_mem_resp_rdata = mem_resp_rdata;
  assign dcache_mem_resp_rlast = (grant == GRANT_DCACHE) ? mem_resp_rlast : 1'b0;

  assign icache_mem_resp_valid = (grant == GRANT_ICACHE) ? mem_resp_valid : 1'b0;
  assign icache_mem_resp_rdata = mem_resp_rdata;
  assign icache_mem_resp_rlast = (grant == GRANT_ICACHE) ? mem_resp_rlast : 1'b0;

  // Lock grant during transaction
  always @(posedge clock) begin
    if (reset) begin
      grant <= GRANT_NONE;
    end else begin
      case (grant)
        GRANT_NONE: begin
          if (dcache_mem_req_valid) begin
            grant <= GRANT_DCACHE;
          end else if (icache_mem_req_valid) begin
            grant <= GRANT_ICACHE;
          end
        end

        GRANT_DCACHE: begin
          if (dcache_mem_req_write) begin
            if (dcache_mem_req_wlast) begin
              grant <= GRANT_NONE;
            end
          end else begin
            if (mem_resp_valid && mem_resp_rlast) begin
              grant <= GRANT_NONE;
            end
          end
        end

        GRANT_ICACHE: begin
          if (mem_resp_valid && mem_resp_rlast) begin
            grant <= GRANT_NONE;
          end
        end
        default: grant <= GRANT_NONE;
      endcase
    end
  end

endmodule
