create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_clock -name avclk -period 30.303 [get_pins {av_pll/rpll_inst/CLKOUT}]
create_clock -name sdclk -period 12.346 [get_pins {card_pll/rpll_inst/CLKOUT}]

# The 33 MHz AV and 81 MHz SD clocks come from independent PLLs. The only
# transfers between these domains use a synchronized toggle plus stable held
# data, or the sector dual-port RAM. Treat paths across PLLs as asynchronous.
set_clock_groups -asynchronous -group [get_clocks {avclk}] -group [get_clocks {sdclk}]
