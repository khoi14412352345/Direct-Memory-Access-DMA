`timescale 1ns/1ps

module dma_fifo #(
    parameter DEPTH = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        push,
    input  wire [31:0] wdata,
    input  wire        pop,
    output wire [31:0] rdata,
    output wire        empty,
    output wire        full
);
    fifo #(
        .DATA_WIDTH(32),
        .DEPTH(DEPTH),
        .ADDR_WIDTH((DEPTH <= 1) ? 1 : $clog2(DEPTH))
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .push(push),
        .wdata(wdata),
        .pop(pop),
        .rdata(rdata),
        .empty(empty),
        .full(full)
    );
endmodule
