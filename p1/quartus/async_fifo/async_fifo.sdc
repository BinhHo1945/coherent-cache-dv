# Timing constraints for async_fifo: two independent 100 MHz clocks.
create_clock -name wclk -period 10.000 [get_ports wclk]
create_clock -name rclk -period 10.000 [get_ports rclk]

# The clocks are asynchronous: this FIFO is a clock-domain-crossing design. Every
# crossing is protected by design (gray-coded pointers through 2-FF synchronizers;
# the memory entry read across domains is stable while it is readable), so
# cross-domain paths are not timed against each other.
set_clock_groups -asynchronous -group {wclk} -group {rclk}
