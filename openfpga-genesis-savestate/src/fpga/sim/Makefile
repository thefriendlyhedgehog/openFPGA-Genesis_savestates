VERILATOR = verilator
VERILATOR_FLAGS = --cc --exe --build -Wall -Wno-fatal \
    -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-CASEINCOMPLETE \
    -Wno-UNSIGNED -Wno-IMPORTSTAR -Wno-MULTIDRIVEN \
    --trace

TOP_MODULE = tb_savestate_ctrl
SV_SOURCES = tb_savestate_ctrl.sv ../core/savestate_ctrl.sv
CPP_SOURCES = sim_savestate.cpp

.PHONY: all run clean

all: obj_dir/V$(TOP_MODULE)

obj_dir/V$(TOP_MODULE): $(SV_SOURCES) $(CPP_SOURCES)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(TOP_MODULE) \
		$(SV_SOURCES) $(CPP_SOURCES)

run: obj_dir/V$(TOP_MODULE)
	./obj_dir/V$(TOP_MODULE)

clean:
	rm -rf obj_dir
