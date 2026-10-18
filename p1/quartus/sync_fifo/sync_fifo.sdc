# Timing constraints for sync_fifo: single clock, 100 MHz target.
create_clock -name clk -period 10.000 [get_ports clk]
