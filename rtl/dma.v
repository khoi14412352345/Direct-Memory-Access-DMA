`timescale 1ns/1ps

module dma (
    input  wire        clk,
    input  wire        rst_n,

    // APB slave interface
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [7:0]  paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,

    // AXI4-Lite master write address channel
    output reg  [31:0] axi_awaddr,
    output reg         axi_awvalid,
    input  wire        axi_awready,

    // AXI4-Lite master write data channel
    output reg  [31:0] axi_wdata,
    output reg  [3:0]  axi_wstrb,
    output reg         axi_wvalid,
    input  wire        axi_wready,

    // AXI4-Lite master write response channel
    input  wire [1:0]  axi_bresp,
    input  wire        axi_bvalid,
    output reg         axi_bready,

    // AXI4-Lite master read address channel
    output reg  [31:0] axi_araddr,
    output reg         axi_arvalid,
    input  wire        axi_arready,

    // AXI4-Lite master read data channel
    input  wire [31:0] axi_rdata,
    input  wire [1:0]  axi_rresp,
    input  wire        axi_rvalid,
    output reg         axi_rready
);

    localparam FIFO_DEPTH = 4;

    // The read and write sides use independent FSMs so AXI reads can continue
    // while an earlier FIFO entry is being written to the destination.
    localparam [1:0] R_IDLE = 2'd0;
    localparam [1:0] R_ADDR = 2'd1;
    localparam [1:0] R_DATA = 2'd2;

    localparam [1:0] W_IDLE = 2'd0;
    localparam [1:0] W_SEND = 2'd1;
    localparam [1:0] W_RESP = 2'd2;

    // An APB access completes in the ACCESS phase when PSEL, PENABLE and
    // PREADY are all asserted.  The register block receives one-cycle enables.
    wire apb_transfer = psel && penable && pready;
    wire reg_wr_en = apb_transfer && pwrite;
    wire reg_rd_en = apb_transfer && !pwrite;

    wire        start_pulse;
    wire [15:0] configured_size_bytes;
    wire [31:0] configured_src;
    wire [31:0] configured_dst;

    reg         busy_reg;
    reg         done_reg;

    // A 16-bit byte count needs at most ceil(65535 / 4) = 16384
    // 32-bit words. total_words/read_issued must represent 16384, while
    // write_completed is tested before its final increment and tops at 16383.
    reg [14:0]  total_words;
    reg [14:0]  read_issued;
    reg [13:0]  write_completed;
    reg [31:0]  read_addr_work;
    reg [31:0]  write_addr_work;
    reg         backward_copy;

    reg [1:0]   read_state;
    reg [1:0]   write_state;

    wire [31:0] fifo_rdata;
    wire        fifo_empty;
    wire        fifo_full;

    // Each AXI channel transfers information only on a VALID/READY handshake.
    wire ar_hs = axi_arvalid && axi_arready;
    wire r_hs  = axi_rvalid  && axi_rready;
    wire aw_hs = axi_awvalid && axi_awready;
    wire w_hs  = axi_wvalid  && axi_wready;
    wire b_hs  = axi_bvalid  && axi_bready;

    // Read data enters the FIFO at R handshake.  The FIFO head is retired only
    // after the matching write response, so its data stays valid through AW/W.
    wire fifo_push = r_hs;
    wire fifo_pop  = b_hs;

    // write_completed stores the index of the write being completed.  Taking
    // total_words[13:0] also handles 16384 words: 0 - 1 wraps to 14'h3fff.
    wire final_write =
        (write_completed == (total_words[13:0] - 14'd1));

    // The supplied dma_top_tb skeleton defines bits [31:16] as a byte count.
    // The 32-bit datapath therefore performs ceil(size_bytes / 4) AXI words.
    wire configured_partial_word = |configured_size_bytes[1:0];
    wire [14:0] configured_word_count =
        {1'b0, configured_size_bytes[15:2]} +
        {{14{1'b0}}, configured_partial_word};
    wire [13:0] configured_last_word_index =
        configured_word_count[13:0] - 14'd1;
    wire [32:0] configured_copy_bytes =
        {16'd0, configured_word_count, 2'b00};
    wire [31:0] configured_last_offset =
        (configured_word_count == 15'd0) ? 32'd0 :
        {16'd0, configured_last_word_index, 2'b00};

    // memmove-style direction selection prevents a higher overlapping
    // destination from overwriting source words that have not been read yet.
    wire configured_backward =
        (configured_dst > configured_src) &&
        ({1'b0, configured_dst} <
         ({1'b0, configured_src} + configured_copy_bytes));

    // This slave never inserts APB wait states.
    assign pready = 1'b1;

    // Software-visible configuration and status registers.
    control_registers u_control_registers (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(reg_wr_en),
        .rd_en(reg_rd_en),
        .addr(paddr),
        .wdata(pwdata),
        .rdata(prdata),
        .busy(busy_reg),
        .done(done_reg),
        .start_pulse(start_pulse),
        .transfer_size(configured_size_bytes),
        .src_addr(configured_src),
        .dst_addr(configured_dst)
    );

    // Four entries decouple the latency of the AXI read and write channels.
    dma_fifo #(
        .DEPTH(FIFO_DEPTH)
    ) u_dma_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .push(fifo_push),
        .wdata(axi_rdata),
        .pop(fifo_pop),
        .rdata(fifo_rdata),
        .empty(fifo_empty),
        .full(fifo_full)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Asynchronous active-low reset returns both engines to idle and
            // removes every outstanding AXI request.
            busy_reg        <= 1'b0;
            done_reg        <= 1'b0;
            total_words     <= 15'd0;
            read_issued     <= 15'd0;
            write_completed <= 14'd0;
            read_addr_work  <= 32'd0;
            write_addr_work <= 32'd0;
            backward_copy   <= 1'b0;

            read_state      <= R_IDLE;
            write_state     <= W_IDLE;

            axi_awaddr      <= 32'd0;
            axi_awvalid     <= 1'b0;
            axi_wdata       <= 32'd0;
            axi_wstrb       <= 4'd0;
            axi_wvalid      <= 1'b0;
            axi_bready      <= 1'b0;
            axi_araddr      <= 32'd0;
            axi_arvalid     <= 1'b0;
            axi_rready      <= 1'b0;
        end else begin
            // A command is accepted only while idle.  Starting while busy is
            // intentionally unspecified by the assignment.
            if (start_pulse && !busy_reg) begin
                // Snapshot the programmed command.  Later APB writes cannot
                // change the addresses or direction of this active transfer.
                total_words     <= configured_word_count;
                read_issued     <= 15'd0;
                write_completed <= 14'd0;
                backward_copy   <= configured_backward;

                read_addr_work  <= configured_src +
                    (configured_backward ? configured_last_offset : 32'd0);
                write_addr_work <= configured_dst +
                    (configured_backward ? configured_last_offset : 32'd0);

                read_state      <= R_IDLE;
                write_state     <= W_IDLE;
                axi_arvalid     <= 1'b0;
                axi_rready      <= 1'b0;
                axi_awvalid     <= 1'b0;
                axi_wvalid      <= 1'b0;
                axi_bready      <= 1'b0;
                axi_wstrb       <= 4'hf;

                if (configured_word_count == 15'd0) begin
                    // A zero-length command completes without issuing AXI.
                    busy_reg <= 1'b0;
                    done_reg <= 1'b1;
                end else begin
                    busy_reg <= 1'b1;
                    done_reg <= 1'b0;
                end
            end else begin
                // Read engine: one read transaction may be outstanding.  It
                // runs independently from the write engine while FIFO space
                // is available.
                case (read_state)
                    R_IDLE: begin
                        // Do not issue an address unless the returning word has
                        // guaranteed FIFO space.
                        axi_rready <= 1'b0;
                        if (busy_reg && (read_issued != total_words) && !fifo_full) begin
                            axi_araddr  <= read_addr_work;
                            axi_arvalid <= 1'b1;
                            read_state  <= R_ADDR;
                        end
                    end

                    R_ADDR: begin
                        // Hold ARVALID and ARADDR until the slave accepts them.
                        if (ar_hs) begin
                            axi_arvalid <= 1'b0;
                            axi_rready  <= 1'b1;
                            read_issued <= read_issued + 15'd1;
                            read_state  <= R_DATA;
                        end
                    end

                    R_DATA: begin
                        // The R handshake writes AXI data directly into FIFO.
                        if (r_hs) begin
                            axi_rready <= 1'b0;

                            if (backward_copy)
                                read_addr_work <= read_addr_work - 32'd4;
                            else
                                read_addr_work <= read_addr_work + 32'd4;

                            read_state <= R_IDLE;
                        end
                    end

                    default: begin
                        read_state  <= R_IDLE;
                        axi_arvalid <= 1'b0;
                        axi_rready  <= 1'b0;
                    end
                endcase

                // Write engine: AW and W are deliberately tracked as
                // independent channels.  Completion is counted only at the B
                // response handshake, not at the W data handshake.
                case (write_state)
                    W_IDLE: begin
                        // Snapshot the FIFO head and destination before either
                        // independent AXI write channel starts handshaking.
                        axi_bready <= 1'b0;
                        if (busy_reg && !fifo_empty) begin
                            axi_awaddr  <= write_addr_work;
                            axi_wdata   <= fifo_rdata;
                            axi_wstrb   <= 4'hf;
                            axi_awvalid <= 1'b1;
                            axi_wvalid  <= 1'b1;
                            write_state <= W_SEND;
                        end
                    end

                    W_SEND: begin
                        // AW and W may complete in different cycles.  Clear
                        // each VALID separately and wait until both are done.
                        if (aw_hs)
                            axi_awvalid <= 1'b0;
                        if (w_hs)
                            axi_wvalid <= 1'b0;

                        if ((!axi_awvalid || aw_hs) &&
                            (!axi_wvalid  || w_hs)) begin
                            axi_bready <= 1'b1;
                            write_state <= W_RESP;
                        end
                    end

                    W_RESP: begin
                        // A write counts as complete only when its B response
                        // is accepted; this handshake also pops the FIFO.
                        if (b_hs) begin
                            axi_bready <= 1'b0;
                            write_completed <= write_completed + 14'd1;

                            if (backward_copy)
                                write_addr_work <= write_addr_work - 32'd4;
                            else
                                write_addr_work <= write_addr_work + 32'd4;

                            if (final_write) begin
                                busy_reg   <= 1'b0;
                                done_reg   <= 1'b1;
                                write_state <= W_IDLE;
                            end else begin
                                write_state <= W_IDLE;
                            end
                        end
                    end

                    default: begin
                        write_state <= W_IDLE;
                        axi_awvalid <= 1'b0;
                        axi_wvalid  <= 1'b0;
                        axi_bready  <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
