# DMA 

This workspace contains a completed Direct Memory Access assignment. The DMA is controlled through an APB slave interface and moves 32-bit words through an AXI4-Lite master interface. Independent read and write engines are connected by a four-entry FIFO so the two AXI transaction streams can overlap.

## Files

- `SPEC.md` - assignment specification.
- `dma.v` - completed DMA RTL with APB CSRs, overlap-safe address generation, independent AXI read/write engines, and FIFO buffering.
- `dma_top_tb.v` - original provided testbench skeleton with aligned 64-byte and 256-byte transfers.
- `dma_top_tb1.v` - extended self-checking testbench with 15 functional, boundary, status, overlap, and reset cases.
- `Makefile` - build, lint, run, and clean targets for Icarus Verilog.

## Register Map

| Address | Name | Description |
|---|---|---|
| `0x00` | Control | Bits `[31:16]` transfer size in bytes, bit `[0]` start |
| `0x04` | Status | Bit `[0]` busy, bit `[1]` done |
| `0x08` | Source address | 4-byte aligned source address |
| `0x0c` | Destination address | 4-byte aligned destination address |

## Common Commands

This workspace already has Icarus Verilog available on PATH.

PowerShell:

```powershell
.\run.ps1
```

If local PowerShell policy blocks scripts, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
```

GNU Make, if installed:

```sh
make lint
make run
make clean
```

Manual PowerShell equivalent:

```powershell
mkdir build
iverilog -g2012 -Wall -o build/dma_top_tb.vvp apb_master.v axi4_ram_slave.v fifo.v dma_fifo.v control_registers.v dma.v dma_top_tb.v
vvp build/dma_top_tb.vvp
```

Run the extended Verilog-2005-compatible testbench with:

```powershell
iverilog -g2005 -Wall -s dma_top_tb1 -o build/dma_top_tb1.vvp apb_master.v axi4_ram_slave.v fifo.v dma_fifo.v control_registers.v dma.v dma_top_tb1.v
vvp build/dma_top_tb1.vvp
```

## Implemented Regression

The original `dma_top_tb.v` checks:

1. Aligned 64-byte transfer.
2. Aligned 256-byte transfer.

The extended `dma_top_tb1.v` checks:

1. Aligned 64-byte transfer.
2. Aligned 256-byte transfer.
3. Complete overlap where source equals destination.
4. Higher partially overlapping destination requiring backward copying.
5. A new DMA command immediately after the previous command completes.
6. Minimum 4-byte transfer.
7. Small 16-byte transfer.
8. Lower partially overlapping destination where forward copying is safe.
9. Destination ending at the final valid word of the 64-KiB RAM.
10. Destination outside the RAM region. The DMA drives the full address, while the provided RAM BFM aliases `0x0001_0000` to `0x0000_0000` because it indexes memory with address bits `[15:2]`.
11. APB reset values and control/source/destination register readback. This check runs first so reset values are observed before another test programs the registers.
12. Zero-size command, which must complete without producing AXI traffic.
13. Maximum disjoint transfer inside the RAM: 32 KiB from `0x0000_0000` to `0x0000_8000`.
14. Near-maximum aligned transfer: 65,532 bytes from `0x0000_0000` to `0x0000_0004`, exercising a long backward copy.
15. Asynchronous reset during an active transfer, verifying that status, AXI outputs, FSM state, and FIFO occupancy return to reset values.
16. Non-word-aligned 5-byte transfer from `0x0000_1000` to `0x0000_2000`, verifying that the 32-bit datapath rounds the command up with `ceil(size / 4)` and transfers two AXI words.
17. Maximum 16-bit byte count (`16'hFFFF`) with source equal to destination, verifying the 16,384-word `total_words` limit and the special final-word counter behavior.
18. Source and destination regions that touch at the end boundary without overlapping, verifying that the DMA keeps `backward_copy` deasserted and copies forward.
19. Source and destination regions overlapping by exactly one 32-bit word, verifying that the DMA asserts `backward_copy` at the overlap boundary.
20. APB source, destination, and size registers reprogrammed while `BUSY` is asserted with `START=0`, verifying that the active transfer continues using its captured command while the new configuration remains available for readback.

The extended checker also polls APB `BUSY`/`DONE`, compares destination memory against a source snapshot, counts every AXI handshake, verifies the calculated word count and copy direction, checks concurrent read/write activity, and applies a timeout to stalled transfers. Its waveform is written to `dma_top_tb1.vcd`.
