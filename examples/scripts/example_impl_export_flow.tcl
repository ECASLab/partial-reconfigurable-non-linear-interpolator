# Vivado batch Tcl implementation/export flow:
# - Build the project and block design
# - Run synthesis and implementation through bitstream
# - Export hardware as XSA without embedding the bitstream

set jobs 4
if {$argc >= 3} {
    set jobs [string trim [lindex $argv 2]]
}
if {![string is integer -strict $jobs] || $jobs < 1} {
    error "Invalid jobs value '$jobs'. Expected a positive integer."
}

set shared_script_dir [file normalize [file dirname [info script]]]
set bd_flow_script [file normalize [file join $shared_script_dir example_individual example_bd_flow.tcl]]
if {$argc >= 4} {
    set bd_flow_script [file normalize [lindex $argv 3]]
}
if {![file exists $bd_flow_script]} {
    error "BD flow script not found: $bd_flow_script"
}

puts "Using BD flow script: $bd_flow_script"
source $bd_flow_script

set session_work_dir [file normalize [file join $build_dir vivado_session]]
file mkdir $session_work_dir
puts "Switching Vivado session working directory to $session_work_dir"
cd $session_work_dir

set export_dir [file normalize "$build_dir/export"]
file mkdir $export_dir
set xsa_file [file normalize "$export_dir/${proj_name}.xsa"]

puts "Running synthesis with $jobs jobs"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

puts "Running implementation through bitstream with $jobs jobs"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

set extra_impl_runs [lsort [get_runs -quiet impl_config_*]]

foreach run_name $extra_impl_runs {
    puts "Running additional implementation run $run_name through bitstream with $jobs jobs"
    launch_runs $run_name -to_step write_bitstream -jobs $jobs
    wait_on_run $run_name
}

open_run impl_1

set_property platform.name $proj_name [current_project]
set_property platform.board_id $part [current_project]
set_property platform.vendor user.org [current_project]
set_property platform.version 1.0 [current_project]
set_property platform.description "Generated hardware export for $dut_impl on $part" [current_project]
set_property platform.default_output_type "sd_card" [current_project]
if {$part eq "xck26-sfvc784-2LV-c"} {
    set_property platform.design_intent.embedded "true" [current_project]
    set_property platform.design_intent.external_host "false" [current_project]
    set_property platform.design_intent.datacenter "false" [current_project]
} else {
    set_property platform.design_intent.embedded "false" [current_project]
    set_property platform.design_intent.external_host "true" [current_project]
    set_property platform.design_intent.datacenter "true" [current_project]
}
set_property platform.design_intent.server_managed "false" [current_project]

puts "Exporting hardware platform without embedded bitstream: $xsa_file"
write_hw_platform -fixed -force -file $xsa_file
