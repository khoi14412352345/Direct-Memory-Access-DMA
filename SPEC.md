# VNCHIP RISCV Computer Structure

# Lab 5: Direct Memory Access (DMA) Design

## Objective

The purpose of this lab exercise is to design a simple DMA controller to move data from one address to another address. You need to design and test this DMA, which is controlled by an APB bus and interfaced with memory connected by an AXI4-Lite interface.

## Tasks

In this lab, you will perform the following tasks:

- Design a DMA controller based on the specification.
- Understand the provided `apb_master` and `axi4_ram_slave` behavior functional models (BFM).
- Build the test plan for DMA based on the specification.
- Build the top-level testbench with tasks to read and write to `apb_master` to trigger the DMA commands.
- Write tests in the test plan, run, and debug tests until all of your tests pass.
- Make sure the performance target is achieved.
- Check and submit your design with the TA of the class.

---

Debugging hardware designs described in HDL requires a disciplined approach that relies on clear, guaranteed cause-effect relationships within the design. Due to the inherently parallel and interactive nature of hardware, speculative debugging techniques often lead to wasted time, increased effort, and frustration.

## 1. Lab Setup

Copy the content from:

```text
/VNCHIP/TP2025/1_RTL/0_COMMON/0707_RTL_LAB/Lab5
```

to your working directory. Follow the guidelines provided by your TA.

The RTL directory only has the provided `apb_master.v` and `axi4_ram_slave.v`. Your task is to develop all necessary design and testbench files from scratch.

Use the provided Makefile to build and simulate your design, ensuring all filenames and module interfaces match those described in this manual. If you encounter any setup issues, consult your TA.

---

## 3. DMA Controller `dma.v`

The DMA (Direct Memory Access) controller IP enables efficient data movement between memory-mapped peripherals or memory blocks without CPU intervention. It is used to move a block of memory from one location to another location. It has two interfaces:

- **APB Slave interface:**
  - Used by a host processor to configure and control the DMA.
  - Access CSRs (Control and Status Registers).
- **AXI4-Lite Master Interface:**
  - Perform read/write transfers to memory-mapped regions.
  - Supports 32-bit addressing and 32-bit data.

No block diagrams are provided for the internal of `dma.v`. It is up to you to partition it into smaller modules and design them. Include your detailed diagrams in your submission.

---

## 3.1. Inputs and Outputs of `dma.v`

| Port name | Direction | Description |
|---|---|---|
| `clk` | input | The system clock |
| `rst_n` | input | Asynchronous reset active low |
| **APB interface** |  |  |
| `psel` | input | APB select |
| `penable` | input | APB enable |
| `pwrite` | input | APB write: `1` is write, `0` is read |
| `paddr[7:0]` | input | Address of control and status registers |
| `pwdata[31:0]` | input | Write data to registers |
| `prdata[31:0]` | output | Read data from registers |
| `pready` | output | APB ready |
| **AXI interface** |  |  |
| `axi_awaddr[31:0]` | output | AXI write address |
| `axi_awvalid` | output | AXI write address valid |
| `axi_awready` | input | AXI write address ready |
| `axi_wdata[31:0]` | output | AXI write data value |
| `axi_wstrb[3:0]` | output | AXI write data strobe (byte enable) |
| `axi_wvalid` | output | AXI write data valid |
| `axi_wready` | input | AXI write data ready |
| `axi_bresp[1:0]` | input | AXI write response value |
| `axi_bvalid` | input | AXI write response valid |
| `axi_bready` | output | AXI write response ready |
| `axi_araddr[31:0]` | output | AXI read address |
| `axi_arvalid` | output | AXI read address valid |
| `axi_arready` | input | AXI read address ready |
| `axi_rdata[31:0]` | input | AXI read data value |
| `axi_rresp[1:0]` | input | AXI read response value |
| `axi_rvalid` | input | AXI read data valid |
| `axi_rready` | output | AXI read data ready |

---

## 4. Theory of Operation

In order to start a new DMA, the CPU will need to program the source address of the transfer to the register at address `0x08` and the destination address of the transfer to the register at address `0x0C`. These addresses have to be 4-byte aligned.

Then the CPU will program the control register at address `0x0` with two components. A size up to 64 KB is from bits `[31:16]`, and bit `0` needs to be set to `1`.

The DMA controller should master an AXI read transaction from the address pointed by the source address register into the DMA controller, then master an AXI write transaction to the address pointed by the destination address register. It needs to keep a counter that is clear at the beginning of the DMA transfer and increased by each pair of read and write transactions until it gets to the size of the transfer in the control register.

The DMA controller needs to maximize the throughput of the transfer as much as possible while maintaining the correct operation of the AXI4-Lite bus. Be aware that the slave device can insert delays in any phase of a transaction.

The CPU will periodically read the value of the status register. If the busy bit is still set, then the CPU will continue to wait. If the busy bit is clear and the done bit is set, the CPU knows the DMA transfer is complete and the destination memory blocks can be used by a program or by an IO device.

The CPU can program the next DMA transfer by programming the source, destination, and control register again.

If the CPU starts a new DMA transfer when the busy bit is still asserted, then the behavior of the DMA controller is indeterministic.

---

## 5. Test Plan and Design Verification Environment

### 5.1. Test Plan

Write a test plan that covers different sizes of transfers and different sets of source and destination addresses.

Usually, DMA is used to move a block of memory to a completely unconnected address. But if the source and destination addresses are overlapped, then the destination address has to be larger than the source address. If the source address and destination address are the same and the transfer is completely overlapped, the DMA controller must not corrupt data pointed by the source and must complete the transfer correctly.

---

### 5.2. Verification Environments

The top-level testbench should be implemented with tasks that program and get information from `apb_master` to check for operation correctness.

An example of a task to program a write to register is below.

```verilog
task automatic apb_write(input [7:0] addr, input [31:0] data);
    @(posedge clk);
    while (!apb_idle) @(posedge clk);
    apb_addr  = addr;
    apb_wdata = data;
    apb_rw    = 1;
    apb_start = 1;

    @(posedge clk);
    apb_start = 0;
    while (!apb_idle) @(posedge clk);
endtask
```

---

### 5.3. Performance Expectation

An implementation that can correctly move the data from source address to the destination address only gets half of the credit. The expected performance of the DMA controller is to get both read transactions and write transactions happen in parallel, and throughput of the DMA is only limited by the slower transactions.

---

©2026 VNCHIP Institute of Research and Development
