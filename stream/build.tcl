set script_dir [file dirname [file normalize [info script]]]
open_project [file join $script_dir stream.gprj]
set_option -verilog_std sysv2017
set_option -use_sspi_as_gpio 1
run all
