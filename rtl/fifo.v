`timescale 1ns/1ps

module fifo #(
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 4,
    parameter ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  push,
    input  wire [DATA_WIDTH-1:0] wdata,
    input  wire                  pop,
    output wire [DATA_WIDTH-1:0] rdata,
    output wire                  empty,
    output wire                  full
);
    // Circular storage with independent read and write pointers.  Memory does
    // not need reset because count=0 marks every entry invalid after reset.
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count;

    localparam [ADDR_WIDTH:0] DEPTH_COUNT = DEPTH;

    // Block underflow.  Overflow is blocked unless a same-cycle pop frees one
    // slot, in which case occupancy remains unchanged.
    wire pop_ok  = pop && !empty;
    // A simultaneous pop creates space for a push even when initially full.
    wire push_ok = push && (!full || pop_ok);

    assign empty = (count == {ADDR_WIDTH + 1{1'b0}});
    assign full  = (count == DEPTH_COUNT);
    // First-word fall-through output: the current FIFO head is always visible.
    assign rdata = mem[rd_ptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {ADDR_WIDTH + 1{1'b0}};
        end else begin
            if (push_ok) begin
                // Write the tail entry and wrap explicitly for non-power-of-2
                // DEPTH values as well as the default four-entry FIFO.
                mem[wr_ptr] <= wdata;
                if (wr_ptr == DEPTH - 1)
                    wr_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end
            if (pop_ok) begin
                // Advance the head only for a legal pop.
                if (rd_ptr == DEPTH - 1)
                    rd_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            // One-sided traffic changes occupancy; simultaneous push/pop does
            // not.  This also avoids competing assignments to count.
            case ({push_ok, pop_ok})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
