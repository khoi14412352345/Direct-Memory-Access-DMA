`timescale 1ns/1ps

module control_registers (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        wr_en,
    input  wire        rd_en,
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    input  wire        busy,
    input  wire        done,

    output reg         start_pulse,
    output reg  [15:0] transfer_size,
    output reg  [31:0] src_addr,
    output reg  [31:0] dst_addr
);
    // APB control/status register map from the lab specification.
    localparam [7:0] ADDR_CONTROL = 8'h00;
    localparam [7:0] ADDR_STATUS  = 8'h04;
    localparam [7:0] ADDR_SRC     = 8'h08;
    localparam [7:0] ADDR_DST     = 8'h0c;

    // Full control value is retained for APB readback.  The DMA receives the
    // size field and a one-cycle start pulse as separate outputs.
    reg [31:0] control_reg;

    // Configuration registers are written synchronously after a completed
    // APB write.  Source and destination remain stable until software rewrites
    // them; the DMA snapshots them when it accepts START.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            control_reg <= 32'b0;
            start_pulse <= 1'b0;
            transfer_size <= 16'b0;
            src_addr <=32'b0;
            dst_addr <= 32'b0;
        end else begin
            // Default-low assignment turns a written START bit into a pulse
            // rather than a level that could repeatedly launch transfers.
            start_pulse <= 1'b0;
            if (wr_en) begin
                case (addr)
                    ADDR_CONTROL: begin
                        // CONTROL[31:16] = byte count, CONTROL[0] = START.
                        control_reg <= wdata;
                        transfer_size <= wdata[31:16];
                        start_pulse <= wdata[0];
                    end
                    ADDR_SRC: src_addr <= wdata;
                    ADDR_DST: dst_addr <= wdata;
                    default: begin
                    end
                endcase
            end
        end
    end

    // Combinational APB read mux.  STATUS[0] is BUSY and STATUS[1] is DONE.
    // Returning zero outside a read keeps PRDATA deterministic.
    always @(*) begin
        if (rd_en) begin
            case (addr)
                ADDR_CONTROL: rdata = control_reg;
                ADDR_STATUS:  rdata = {30'b0, done, busy};
                ADDR_SRC:     rdata = src_addr; 
                ADDR_DST:     rdata = dst_addr;
                default:     rdata = 32'b0;
            endcase
        end else begin
            rdata = 32'b0;
        end
    end
endmodule
