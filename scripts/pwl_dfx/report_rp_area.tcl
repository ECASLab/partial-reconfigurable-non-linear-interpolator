#!/usr/bin/env vivado -mode tcl
# Vivado batch Tcl flow:
# - Open each available routed DFX implementation checkpoint
# - Generate a hierarchical utilization report for the reconfigurable partition
# - Write reports into build/reports/area/rp_partition for downstream parsing

set supported_parts [list \
    "xck26-sfvc784-2LV-c" \
]
set supported_flow_aliases [list pwl_dfx dfx]

set part "xck26-sfvc784-2LV-c"
if {$argc >= 1} {
    set arg0 [string trim [lindex $argv 0]]
    if {$arg0 in $supported_parts} {
        set part $arg0
    } elseif {[lsearch -exact $supported_flow_aliases [string tolower $arg0]] < 0} {
        puts "Ignoring flow selector '$arg0'; this script always generates DFX RP area reports."
    }
}
if {$argc >= 2} {
    set part [string trim [lindex $argv 1]]
}

if {$part ni $supported_parts} {
    error "Unsupported part '$part'. Supported parts: [join $supported_parts {, }]"
}

set script_dir [file normalize [file dirname [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set part_tag [string map {"-" "_" "." "_"} $part]
set proj_name "my_proj_pwl_dfx_${part_tag}"
set build_dir [file normalize [file join $project_dir build]]
set proj_dir [file normalize [file join $build_dir vivado_pwl_dfx $part_tag $proj_name]]
set runs_dir [file normalize [file join $proj_dir "${proj_name}.runs"]]
set report_dir [file normalize [file join $build_dir reports area rp_partition]]

if {![file isdirectory $runs_dir]} {
    error "DFX implementation runs directory not found: $runs_dir"
}

file mkdir $report_dir

set routed_dcps [lsort [glob -nocomplain -directory $runs_dir -types f */pwl_dfx_top_routed.dcp]]
if {[llength $routed_dcps] == 0} {
    error "No routed DFX checkpoints were found under $runs_dir"
}

puts "Generating RP utilization reports for part: $part"
puts "Using DFX runs directory: $runs_dir"
puts "Writing RP reports under: $report_dir"

foreach routed_dcp $routed_dcps {
    set run_dir [file dirname $routed_dcp]
    set run_name [file tail $run_dir]
    set report_file [file normalize [file join $report_dir "${run_name}_u_rp_utilization_hierarchical.rpt"]]

    catch {close_design}
    puts "Opening routed checkpoint for run $run_name"
    open_checkpoint $routed_dcp

    set rp_cells [get_cells -hier -quiet u_rp]
    if {[llength $rp_cells] == 0} {
        error "Could not find reconfigurable partition cell 'u_rp' in checkpoint: $routed_dcp"
    }

    puts "Writing hierarchical RP utilization report: $report_file"
    report_utilization -hierarchical -file $report_file
}

catch {close_design}
puts "Generated [llength $routed_dcps] RP utilization report(s)."
