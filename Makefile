IVERILOG ?= iverilog
VVP      ?= vvp

BUILD_DIR := build
SIMV      := $(BUILD_DIR)/dma_top_tb.vvp
SOURCES   := apb_master.v axi4_ram_slave.v fifo.v dma_fifo.v control_registers.v dma.v dma_top_tb.v

.PHONY: all lint sim run clean

all: sim

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

lint: $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -tnull $(SOURCES)

sim: $(BUILD_DIR) $(SOURCES)
	$(IVERILOG) -g2012 -Wall -o $(SIMV) $(SOURCES)

run: sim
	$(VVP) $(SIMV)

clean:
	rm -rf $(BUILD_DIR) *.vcd *.fst *.lxt *.lxt2
