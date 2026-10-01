`timescale 1ns/1ps

// Extended version of dma_top_tb.v.  The original APB/AXI skeleton and
// instances are retained, with additional self-checking and test cases.
module dma_top_tb1;
    reg clk   = 0;
    reg rst_n = 0;

    always #5 clk = ~clk;

    // --- APB Bus ---
    wire        psel;
    wire        penable;
    wire        pwrite;
    wire [7:0]  paddr;
    wire [31:0] pwdata;
    wire [31:0] prdata;
    wire        pready;

    reg         apb_start;
    reg         apb_rw;
    reg  [7:0]  apb_addr;
    reg  [31:0] apb_wdata;
    wire [31:0] apb_rdata;
    wire        apb_idle;
    wire        apb_busy;

    // AXI Write Address Channel
    wire        axi_awvalid;
    wire [31:0] axi_awaddr;
    wire        axi_awready;

    // AXI Write Data Channel
    wire        axi_wvalid;
    wire [31:0] axi_wdata;
    wire [3:0]  axi_wstrb;
    wire        axi_wready;

    // AXI Write Response Channel
    wire        axi_bvalid;
    wire        axi_bready;

    // AXI Read Address Channel
    wire        axi_arvalid;
    wire [31:0] axi_araddr;
    wire        axi_arready;

    // AXI Read Data Channel
    wire        axi_rvalid;
    wire [31:0] axi_rdata;
    wire        axi_rready;

    // The provided AXI RAM has no response-code ports.  It models successful
    // transactions, so the DMA response inputs are tied to OKAY.
    wire [1:0] axi_bresp = 2'b00;
    wire [1:0] axi_rresp = 2'b00;

    // Extended testbench bookkeeping.
    integer error_count;
    integer cycle_count;
    integer ar_count;
    integer r_count;
    integer aw_count;
    integer w_count;
    integer b_count;
    integer high_aw_count;
    integer summary_ar_count;
    integer summary_r_count;
    integer summary_aw_count;
    integer summary_w_count;
    integer summary_b_count;
    reg     transfer_overlap_seen;
    reg [31:0] expected_mem [0:16383];

    dma dma_inst (
        .clk(clk),
        .rst_n(rst_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .axi_awvalid(axi_awvalid),
        .axi_awaddr(axi_awaddr),
        .axi_awready(axi_awready),
        .axi_wvalid(axi_wvalid),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready),
        .axi_bresp(axi_bresp),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_arvalid(axi_arvalid),
        .axi_araddr(axi_araddr),
        .axi_arready(axi_arready),
        .axi_rdata(axi_rdata),
        .axi_rresp(axi_rresp),
        .axi_rvalid(axi_rvalid),
        .axi_rready(axi_rready)
    );

    apb_master apb_m (
        .clk(clk),
        .rst_n(rst_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .start(apb_start),
        .rw(apb_rw),
        .addr(apb_addr),
        .wdata(apb_wdata),
        .rdata(apb_rdata),
        .idle(apb_idle),
        .busy(apb_busy)
    );

    axi4_ram_slave mem (
        .clk(clk),
        .rst_n(rst_n),
        .awvalid(axi_awvalid),
        .awaddr(axi_awaddr),
        .awready(axi_awready),
        .wvalid(axi_wvalid),
        .wdata(axi_wdata),
        .wstrb(axi_wstrb),
        .wready(axi_wready),
        .bvalid(axi_bvalid),
        .bready(axi_bready),
        .arvalid(axi_arvalid),
        .araddr(axi_araddr),
        .arready(axi_arready),
        .rvalid(axi_rvalid),
        .rdata(axi_rdata),
        .rready(axi_rready)
    );

    // Count successful AXI transfers and detect simultaneous read/write work.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count           <= 0;
            ar_count              <= 0;
            r_count               <= 0;
            aw_count              <= 0;
            w_count               <= 0;
            b_count               <= 0;
            high_aw_count         <= 0;
            transfer_overlap_seen <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (axi_arvalid && axi_arready) ar_count <= ar_count + 1;
            if (axi_rvalid  && axi_rready)  r_count  <= r_count + 1;
            if (axi_awvalid && axi_awready) aw_count <= aw_count + 1;
            if (axi_wvalid  && axi_wready)  w_count  <= w_count + 1;
            if (axi_bvalid  && axi_bready)  b_count  <= b_count + 1;
            if (axi_awvalid && axi_awready && (axi_awaddr[31:16] != 16'd0))
                high_aw_count <= high_aw_count + 1;

            if (dma_inst.busy_reg &&
                (axi_arvalid || axi_rvalid || axi_rready) &&
                (axi_awvalid || axi_wvalid || axi_bvalid || axi_bready))
                transfer_overlap_seen <= 1'b1;
        end
    end

    task automatic apb_write(input [7:0] addr, input [31:0] data);
        begin
            // Falling-edge drive avoids a race with the provided APB master's
            // positive-edge state machine.
            @(negedge clk);
            while (!apb_idle) @(negedge clk);
            apb_addr  = addr;
            apb_wdata = data;
            apb_rw    = 1'b1;
            apb_start = 1'b1;

            @(negedge clk);
            apb_start = 1'b0;
            while (!apb_idle) @(negedge clk);
        end
    endtask

    task automatic apb_read(input [7:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            while (!apb_idle) @(negedge clk);
            apb_addr  = addr;
            apb_wdata = 32'd0;
            apb_rw    = 1'b0;
            apb_start = 1'b1;

            @(negedge clk);
            apb_start = 1'b0;
            while (!apb_idle) @(negedge clk);
            data = apb_rdata;
        end
    endtask

    task automatic wait_for_dma_done(
        output [31:0] final_status,
        output integer saw_busy
    );
        integer timeout;
        reg [31:0] status;
        begin
            timeout = 0;
            saw_busy = 0;
            status = 32'd0;

            // Large stress tests can require tens of thousands of cycles.
            while (!status[1] && timeout < 100000) begin
                apb_read(8'h04, status);
                if (status[0])
                    saw_busy = 1;
                timeout = timeout + 1;
            end

            if (!status[1]) begin
                $display("[ERROR] DMA timeout");
                error_count = error_count + 1;
            end
            if (status[0]) begin
                $display("[ERROR] BUSY remained asserted with DONE");
                error_count = error_count + 1;
            end
            final_status = status;
        end
    endtask

    // Test reset values and normal APB register readback before any DMA
    // command changes the status register.
    task automatic run_apb_register_test;
        reg [31:0] value;
        begin
            apb_read(8'h00, value);
            if (value !== 32'd0) begin
                $display("[ERROR] CONTROL reset value is %h", value);
                error_count = error_count + 1;
            end

            apb_read(8'h04, value);
            if (value !== 32'd0) begin
                $display("[ERROR] STATUS reset value is %h", value);
                error_count = error_count + 1;
            end

            apb_read(8'h08, value);
            if (value !== 32'd0) begin
                $display("[ERROR] SRC reset value is %h", value);
                error_count = error_count + 1;
            end

            apb_read(8'h0c, value);
            if (value !== 32'd0) begin
                $display("[ERROR] DST reset value is %h", value);
                error_count = error_count + 1;
            end

            apb_write(8'h08, 32'h0000_1234);
            apb_write(8'h0c, 32'h0000_5678);
            apb_write(8'h00, {16'd64, 16'h0000}); // START remains low.

            apb_read(8'h08, value);
            if (value !== 32'h0000_1234) begin
                $display("[ERROR] SRC APB readback is %h", value);
                error_count = error_count + 1;
            end

            apb_read(8'h0c, value);
            if (value !== 32'h0000_5678) begin
                $display("[ERROR] DST APB readback is %h", value);
                error_count = error_count + 1;
            end

            apb_read(8'h00, value);
            if (value !== {16'd64, 16'h0000}) begin
                $display("[ERROR] CONTROL APB readback is %h", value);
                error_count = error_count + 1;
            end

            if (dma_inst.busy_reg || dma_inst.done_reg) begin
                $display("[ERROR] Register writes without START launched DMA");
                error_count = error_count + 1;
            end

            $display("[PASS] APB reset values and register readback verified.");
        end
    endtask

    // A zero-byte command should complete immediately without any AXI work.
    task automatic run_zero_size_test;
        integer ar_before;
        integer r_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        reg [31:0] status;
        begin
            ar_before = ar_count;
            r_before  = r_count;
            aw_before = aw_count;
            w_before  = w_count;
            b_before  = b_count;

            apb_write(8'h08, 32'h0000_1000);
            apb_write(8'h0c, 32'h0000_2000);
            apb_write(8'h00, {16'd0, 16'h0001});
            repeat (3) @(posedge clk);
            apb_read(8'h04, status);

            if ((status[1:0] !== 2'b10) ||
                (dma_inst.total_words !== 15'd0)) begin
                $display("[ERROR] Zero-size command did not complete immediately");
                error_count = error_count + 1;
            end

            if ((ar_count != ar_before) || (r_count != r_before) ||
                (aw_count != aw_before) || (w_count != w_before) ||
                (b_count != b_before)) begin
                $display("[ERROR] Zero-size command generated AXI traffic");
                error_count = error_count + 1;
            end

            $display("[PASS] Zero-size command completed without AXI traffic.");
        end
    endtask

    // Assert asynchronous reset after a transfer has started.  The DMA must
    // abandon the command, remove all AXI requests and return to reset status.
    task automatic run_mid_transfer_reset_test;
        integer i;
        integer timeout;
        reg [31:0] status;
        begin
            for (i = 0; i < 1024; i = i + 1) begin
                mem.mem[(32'h0000_1000 >> 2) + i] = 32'hface_0000 + i;
                mem.mem[(32'h0000_9000 >> 2) + i] = 32'hdead_0000 + i;
            end

            apb_write(8'h08, 32'h0000_1000);
            apb_write(8'h0c, 32'h0000_9000);
            apb_write(8'h00, {16'd4096, 16'h0001});

            timeout = 0;
            while (!dma_inst.busy_reg && timeout < 100) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            repeat (10) @(posedge clk);

            if (!dma_inst.busy_reg) begin
                $display("[ERROR] DMA was not active before reset test");
                error_count = error_count + 1;
            end

            // Preserve cumulative handshake totals for the final report.  The
            // normal counters intentionally clear when rst_n is asserted.
            summary_ar_count = ar_count;
            summary_r_count  = r_count;
            summary_aw_count = aw_count;
            summary_w_count  = w_count;
            summary_b_count  = b_count;

            @(negedge clk);
            rst_n = 1'b0;
            repeat (2) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);

            apb_read(8'h04, status);
            if (status[1:0] !== 2'b00) begin
                $display("[ERROR] Status after mid-transfer reset is %h", status);
                error_count = error_count + 1;
            end

            if (axi_arvalid || axi_rready || axi_awvalid || axi_wvalid ||
                axi_bready || !dma_inst.fifo_empty) begin
                $display("[ERROR] AXI/FIFO state was not cleared by reset");
                error_count = error_count + 1;
            end

            $display("[PASS] Mid-transfer reset cleared DMA, AXI and FIFO state.");
        end
    endtask

    task automatic run_dma_test(
        input [31:0] src_addr,
        input [31:0] dst_addr,
        input [15:0] size
    );
        integer i;
        integer src_idx;
        integer dst_idx;
        integer words;
        integer saw_busy;
        integer start_cycle;
        integer ar_before;
        integer r_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        reg expected_backward;
        reg [32:0] copy_bytes_ext;
        reg [31:0] status;
        begin
            words = (size + 3) / 4;
            src_idx = src_addr >> 2;
            dst_idx = dst_addr >> 2;
            copy_bytes_ext = words * 4;
            expected_backward =
                (dst_addr > src_addr) &&
                ({1'b0, dst_addr} <
                 ({1'b0, src_addr} + copy_bytes_ext));

            if ((src_addr[1:0] != 2'b00) ||
                (dst_addr[1:0] != 2'b00) || (size == 0)) begin
                $display("[ERROR] Test requires nonzero size and 4-byte-aligned addresses");
                error_count = error_count + 1;
            end else if (((src_idx + words) > 16384) ||
                         ((dst_idx + words) > 16384)) begin
                $display("[ERROR] Normal test address exceeds the provided 64-KiB RAM");
                error_count = error_count + 1;
            end else begin
                // Initialize and snapshot the source before starting.  The
                // snapshot keeps the checker correct when regions overlap.
                for (i = 0; i < words; i = i + 1)
                    mem.mem[src_idx + i] =
                        32'hc000_0000 ^ src_addr ^ (32'h0101_0101 * i);
                for (i = 0; i < words; i = i + 1)
                    expected_mem[i] = mem.mem[src_idx + i];

                // Give a disjoint destination an obviously different value.
                if (((dst_idx + words) <= src_idx) ||
                    ((src_idx + words) <= dst_idx)) begin
                    for (i = 0; i < words; i = i + 1)
                        mem.mem[dst_idx + i] = 32'hdead_0000 + i;
                end

                ar_before = ar_count;
                r_before  = r_count;
                aw_before = aw_count;
                w_before  = w_count;
                b_before  = b_count;
                start_cycle = cycle_count;
                transfer_overlap_seen = 1'b0;

                apb_write(8'h08, src_addr);
                apb_write(8'h0c, dst_addr);
                apb_write(8'h00, {size, 16'h0001}); // Start = 1

                wait_for_dma_done(status, saw_busy);

                for (i = 0; i < words; i = i + 1) begin
                    if (mem.mem[dst_idx + i] !== expected_mem[i]) begin
                        $display("[ERROR] Mismatch at word %0d: expected=%h dst=%h",
                                 i, expected_mem[i], mem.mem[dst_idx + i]);
                        error_count = error_count + 1;
                    end
                end

                if (((ar_count - ar_before) != words) ||
                    ((r_count  - r_before)  != words) ||
                    ((aw_count - aw_before) != words) ||
                    ((w_count  - w_before)  != words) ||
                    ((b_count  - b_before)  != words)) begin
                    $display("[ERROR] AXI handshake count does not equal %0d words", words);
                    error_count = error_count + 1;
                end

                if (!saw_busy) begin
                    $display("[ERROR] BUSY was not observed");
                    error_count = error_count + 1;
                end
                if (dma_inst.total_words !== words[14:0]) begin
                    $display("[ERROR] total_words=%0d instead of ceil(%0d/4)=%0d",
                             dma_inst.total_words, size, words);
                    error_count = error_count + 1;
                end
                if (dma_inst.backward_copy !== expected_backward) begin
                    $display("[ERROR] backward_copy=%b instead of expected %b",
                             dma_inst.backward_copy, expected_backward);
                    error_count = error_count + 1;
                end
                if ((words > 1) && !transfer_overlap_seen) begin
                    $display("[ERROR] AXI read/write overlap was not observed");
                    error_count = error_count + 1;
                end

                if ((status[1:0] !== 2'b10)) begin
                    $display("[ERROR] Final status was %h instead of DONE=1, BUSY=0", status);
                    error_count = error_count + 1;
                end

                $display("[PASS] DMA transferred and verified %0d bytes from %08x to %08x (%0d cycles).",
                         size, src_addr, dst_addr, cycle_count - start_cycle);
            end
        end
    endtask

    // The provided RAM indexes memory with address bits [15:2].  It has no
    // error-response outputs, so a destination at 0x0001_0000 aliases address
    // 0x0000_0000.  This test documents that BFM behavior while also proving
    // that the DMA itself puts the full out-of-range address on AWADDR.
    task automatic run_out_of_range_destination_test(
        input [31:0] src_addr,
        input [31:0] dst_addr,
        input [15:0] size
    );
        integer i;
        integer src_idx;
        integer dst_alias_idx;
        integer words;
        integer saw_busy;
        integer high_aw_before;
        integer ar_before;
        integer r_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        reg [31:0] status;
        begin
            words = (size + 3) / 4;
            src_idx = src_addr >> 2;
            dst_alias_idx = (dst_addr & 32'h0000_ffff) >> 2;

            for (i = 0; i < words; i = i + 1) begin
                mem.mem[src_idx + i] =
                    32'he000_0000 ^ src_addr ^ (32'h0011_0011 * i);
                expected_mem[i] = mem.mem[src_idx + i];
                mem.mem[dst_alias_idx + i] = 32'hbad0_0000 + i;
            end

            ar_before = ar_count;
            r_before  = r_count;
            aw_before = aw_count;
            w_before  = w_count;
            b_before  = b_count;
            high_aw_before = high_aw_count;
            transfer_overlap_seen = 1'b0;

            apb_write(8'h08, src_addr);
            apb_write(8'h0c, dst_addr);
            apb_write(8'h00, {size, 16'h0001});

            wait_for_dma_done(status, saw_busy);

            for (i = 0; i < words; i = i + 1) begin
                if (mem.mem[dst_alias_idx + i] !== expected_mem[i]) begin
                    $display("[ERROR] Out-of-range alias mismatch at word %0d", i);
                    error_count = error_count + 1;
                end
            end

            if (((ar_count - ar_before) != words) ||
                ((r_count  - r_before)  != words) ||
                ((aw_count - aw_before) != words) ||
                ((w_count  - w_before)  != words) ||
                ((b_count  - b_before)  != words)) begin
                $display("[ERROR] Out-of-range test AXI count does not equal %0d words", words);
                error_count = error_count + 1;
            end

            if ((high_aw_count - high_aw_before) != words) begin
                $display("[ERROR] DMA did not drive all out-of-range AWADDR values");
                error_count = error_count + 1;
            end
            if (!saw_busy || (status[1:0] !== 2'b10)) begin
                $display("[ERROR] Bad status during out-of-range destination test");
                error_count = error_count + 1;
            end
            if ((words > 1) && !transfer_overlap_seen) begin
                $display("[ERROR] No read/write concurrency in out-of-range test");
                error_count = error_count + 1;
            end

            $display("[PASS] DMA drove destination %08x; RAM BFM aliased it to %08x.",
                     dst_addr, {16'd0, dst_addr[15:0]});
        end
    endtask

    // Rewrite the software-visible configuration while a long command is
    // active.  The current transfer must continue using the source,
    // destination and size that were captured when START was accepted.
    task automatic run_reprogram_while_busy_test;
        integer i;
        integer timeout;
        integer saw_busy;
        integer ar_before;
        integer r_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        reg [31:0] status;
        reg [31:0] value;
        begin
            // Active command: 4096 bytes = 1024 words.
            for (i = 0; i < 1024; i = i + 1) begin
                mem.mem[(32'h0000_6000 >> 2) + i] =
                    32'h5a00_0000 ^ (32'h0100_0001 * i);
                expected_mem[i] =
                    mem.mem[(32'h0000_6000 >> 2) + i];
                mem.mem[(32'h0000_8000 >> 2) + i] =
                    32'hdead_0000 + i;
            end

            // The newly programmed destination must remain untouched because
            // its CONTROL write keeps START low.
            for (i = 0; i < 16; i = i + 1)
                mem.mem[(32'h0000_3000 >> 2) + i] =
                    32'hbad0_0000 + i;

            ar_before = ar_count;
            r_before  = r_count;
            aw_before = aw_count;
            w_before  = w_count;
            b_before  = b_count;

            apb_write(8'h08, 32'h0000_6000);
            apb_write(8'h0c, 32'h0000_8000);
            apb_write(8'h00, {16'd4096, 16'h0001});

            timeout = 0;
            while (!dma_inst.busy_reg && timeout < 100) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!dma_inst.busy_reg) begin
                $display("[ERROR] DMA did not become BUSY before reprogramming");
                error_count = error_count + 1;
            end

            repeat (8) @(posedge clk);

            // Change all three configuration fields without issuing START.
            apb_write(8'h08, 32'h0000_1000);
            apb_write(8'h0c, 32'h0000_3000);
            apb_write(8'h00, {16'd64, 16'h0000});

            if (!dma_inst.busy_reg) begin
                $display("[ERROR] Active command ended during APB reprogramming");
                error_count = error_count + 1;
            end
            if (dma_inst.total_words !== 15'd1024) begin
                $display("[ERROR] Active total_words changed to %0d while BUSY",
                         dma_inst.total_words);
                error_count = error_count + 1;
            end

            wait_for_dma_done(status, saw_busy);

            for (i = 0; i < 1024; i = i + 1) begin
                if (mem.mem[(32'h0000_8000 >> 2) + i] !==
                    expected_mem[i]) begin
                    $display("[ERROR] Reprogram-while-BUSY mismatch at word %0d", i);
                    error_count = error_count + 1;
                end
            end

            for (i = 0; i < 16; i = i + 1) begin
                if (mem.mem[(32'h0000_3000 >> 2) + i] !==
                    (32'hbad0_0000 + i)) begin
                    $display("[ERROR] START=0 modified new destination word %0d", i);
                    error_count = error_count + 1;
                end
            end

            if (((ar_count - ar_before) != 1024) ||
                ((r_count  - r_before)  != 1024) ||
                ((aw_count - aw_before) != 1024) ||
                ((w_count  - w_before)  != 1024) ||
                ((b_count  - b_before)  != 1024)) begin
                $display("[ERROR] Reprogram-while-BUSY AXI count is not 1024 words");
                error_count = error_count + 1;
            end

            if (!saw_busy || (status[1:0] !== 2'b10)) begin
                $display("[ERROR] Bad status in reprogram-while-BUSY test");
                error_count = error_count + 1;
            end

            // APB readback should show the newly programmed values even though
            // the completed transfer used the original captured command.
            apb_read(8'h08, value);
            if (value !== 32'h0000_1000) begin
                $display("[ERROR] Reprogrammed SRC readback is %h", value);
                error_count = error_count + 1;
            end
            apb_read(8'h0c, value);
            if (value !== 32'h0000_3000) begin
                $display("[ERROR] Reprogrammed DST readback is %h", value);
                error_count = error_count + 1;
            end
            apb_read(8'h00, value);
            if (value !== {16'd64, 16'h0000}) begin
                $display("[ERROR] Reprogrammed CONTROL readback is %h", value);
                error_count = error_count + 1;
            end

            $display("[PASS] APB config changes while BUSY did not alter the active command.");
        end
    endtask

    initial begin
        $display("[TB1] Starting Extended DMA Test");
        $dumpfile("dma_top_tb1.vcd");
        $dumpvars(0, dma_top_tb1);

        apb_start = 1'b0;
        apb_rw    = 1'b0;
        apb_addr  = 8'd0;
        apb_wdata = 32'd0;
        error_count = 0;
        summary_ar_count = 0;
        summary_r_count  = 0;
        summary_aw_count = 0;
        summary_w_count  = 0;
        summary_b_count  = 0;

        rst_n = 0;
        #50;
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Extended Test Case 11 is intentionally run first because reset
        // values must be checked before another test programs the registers.
        run_apb_register_test;

        // Original Test Case 1: aligned, 64 bytes.
        run_dma_test(32'h0000_0000, 32'h0000_8000, 64);

        // Original Test Case 2: aligned, 256 bytes.
        run_dma_test(32'h0000_4000, 32'h0000_c000, 256);

        // Extended Test Case 3: complete overlap (source equals destination).
        run_dma_test(32'h0000_2000, 32'h0000_2000, 64);

        // Extended Test Case 4: partial overlap; DMA must copy backward.
        run_dma_test(32'h0000_3000, 32'h0000_3008, 64);

        // Extended Test Case 5: another command immediately after completion.
        run_dma_test(32'h0000_5000, 32'h0000_6000, 128);

        // Extended Test Case 6: minimum supported transfer, one 32-bit word.
        run_dma_test(32'h0000_6800, 32'h0000_6900, 4);

        // Extended Test Case 7: small four-word transfer.
        run_dma_test(32'h0000_6a00, 32'h0000_6b00, 16);

        // Extended Test Case 8: overlap with destination below source.  A
        // forward copy is safe in this direction.
        run_dma_test(32'h0000_7108, 32'h0000_7100, 64);

        // Extended Test Case 9: destination ends at the final RAM word.
        run_dma_test(32'h0000_7000, 32'h0000_fff0, 16);

        // Extended Test Case 10: destination is outside the 64-KiB RAM model.
        // The BFM aliases 0x0001_0000 to 0x0000_0000 instead of returning an
        // AXI error because it indexes memory using AWADDR[15:2].
        run_out_of_range_destination_test(
            32'h0000_7400, 32'h0001_0000, 16);

        // Extended Test Case 12: zero-byte command, no AXI traffic expected.
        run_zero_size_test;

        // Extended Test Case 13: largest disjoint transfer that fits entirely
        // in the provided 64-KiB RAM.
        run_dma_test(32'h0000_0000, 32'h0000_8000, 32768);

        // Extended Test Case 14: near-maximum aligned transfer.  The one-word
        // destination offset forces a long backward copy.
        run_dma_test(32'h0000_0000, 32'h0000_0004, 65532);

        // Extended Test Case 15: asynchronous reset during an active command.
        // The helper saves the pre-reset handshake totals; later tests add to
        // the counters that restart from zero after reset.
        run_mid_transfer_reset_test;

        // Extended Test Case 16: a 5-byte command must round up to two
        // complete 32-bit AXI words.
        run_dma_test(32'h0000_1000, 32'h0000_2000, 16'd5);

        // Extended Test Case 17: the largest 16-bit byte count rounds up to
        // 16384 words and exercises the maximum total_words counter value.
        run_dma_test(32'h0000_0000, 32'h0000_0000, 16'hffff);

        // Extended Test Case 18: the destination starts exactly at the source
        // end boundary, so the regions do not overlap and copy stays forward.
        run_dma_test(32'h0000_4000, 32'h0000_4040, 16'd64);

        // Extended Test Case 19: moving the destination back by one word makes
        // the regions overlap by exactly four bytes and requires backward copy.
        run_dma_test(32'h0000_5000, 32'h0000_503c, 16'd64);

        // Extended Test Case 20: APB configuration writes while BUSY must not
        // alter the command that was captured when START was accepted.
        run_reprogram_while_busy_test;

        if (error_count == 0) begin
            $display("[ALL PASS] All extended test cases passed.");
            $display("[TB1] AXI handshakes: AR=%0d R=%0d AW=%0d W=%0d B=%0d",
                     summary_ar_count + ar_count,
                     summary_r_count  + r_count,
                     summary_aw_count + aw_count,
                     summary_w_count  + w_count,
                     summary_b_count  + b_count);
        end else begin
            $display("[FAIL] %0d total error(s).", error_count);
            $fatal(1);
        end

        $finish;
    end
endmodule
