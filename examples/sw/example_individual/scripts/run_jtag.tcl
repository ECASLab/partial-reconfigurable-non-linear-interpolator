# XSCT batch flow:
# - Connect to hw_server
# - Program PL with the generated bitstream
# - Initialize PS/DDR using psu_init.tcl
# - Download and run the baremetal ELF on A53 #0

if {$argc < 3} {
    error "Usage: run_jtag.tcl <bit> <psu_init_tcl> <elf>"
}

set bit_file [file normalize [lindex $argv 0]]
set psu_init [file normalize [lindex $argv 1]]
set elf_file [file normalize [lindex $argv 2]]

foreach path [list $bit_file $psu_init $elf_file] {
    if {![file exists $path]} {
        error "Required file not found: $path"
    }
}

puts "Connecting to local hw_server"
connect -url tcp:127.0.0.1:3121

puts "Programming PL with $bit_file"
fpga -file $bit_file

puts "Initializing PS/DDR"
targets -set -nocase -filter {name =~ "PSU"}
source $psu_init
psu_init
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
after 1000

puts "Downloading ELF to Cortex-A53 #0"
targets -set -nocase -filter {name =~ "Cortex-A53*#0"}
rst -processor
dow $elf_file
con
