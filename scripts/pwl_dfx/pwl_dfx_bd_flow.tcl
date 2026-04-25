# Vivado batch Tcl BD flow:
# - Package exported PWL HLS variants as reusable DUT wrappers
# - Build a K26 DFX static shell around AXI-Lite control and AXI master memory paths
# - Generate reconfigurable modules for the supported interpolator variants
# - Register the RP, RMs, and PR configurations

set supported_parts [list \
    "xck26-sfvc784-2LV-c" \
]
set supported_flow_aliases [list pwl_dfx dfx]

proc normalize_requested_rms {requested_value} {
    set requested_trimmed [string trim $requested_value]
    if {$requested_trimmed eq ""} {
        return [pwl_supported_dut_ids]
    }

    set requested_normalized [string tolower $requested_trimmed]
    if {$requested_normalized eq "all"} {
        return [pwl_supported_dut_ids]
    }

    # Accept common separators so callers can provide "a,b", "a b", or "a;b".
    set token_text [string map [list "," " " ";" " " ":" " "] $requested_trimmed]
    set selected_rms {}
    foreach token [split $token_text " "] {
        set token [string trim $token]
        if {$token eq ""} {
            continue
        }
        set dut_id [pwl_resolve_dut_id $token]
        if {$dut_id ni $selected_rms} {
            lappend selected_rms $dut_id
        }
    }

    if {[llength $selected_rms] == 0} {
        error "No valid RMs were selected from '$requested_value'. Supported RM DUT IDs: [pwl_supported_dut_text]"
    }
    return $selected_rms
}

set dut_impl "pwl_dfx"
set part "xck26-sfvc784-2LV-c"
set requested_rms_raw "all"
if {$argc >= 1} {
    set arg0 [string trim [lindex $argv 0]]
    if {$arg0 in $supported_parts} {
        set part $arg0
    } elseif {[lsearch -exact $supported_flow_aliases [string tolower $arg0]] < 0} {
        puts "Ignoring flow selector '$arg0'; this script always builds the PWL DFX hardware flow."
    }
}
if {$argc >= 2} {
    set part [string trim [lindex $argv 1]]
}

# Collect trailing arguments after flow/part and normalize for both direct
# invocation and wrapper invocation through impl_export_flow.tcl.
set trailing_args {}
for {set arg_idx 2} {$arg_idx < $argc} {incr arg_idx} {
    lappend trailing_args [string trim [lindex $argv $arg_idx]]
}

# Wrapper invocation format:
#   <flow> <part> <jobs> <bd_script> <rm_duts>
# Direct invocation format:
#   <flow> <part> <rm_duts>
if {[llength $trailing_args] >= 2} {
    set maybe_jobs [lindex $trailing_args 0]
    set maybe_bd_script [lindex $trailing_args 1]
    if {[string is integer -strict $maybe_jobs] && [string match "*.tcl" [file tail $maybe_bd_script]]} {
        set trailing_args [lrange $trailing_args 2 end]
    }
}

if {[llength $trailing_args] >= 1} {
    set requested_rms_raw [lindex $trailing_args 0]
}

if {$part ni $supported_parts} {
    error "Unsupported part '$part'. Supported parts: [join $supported_parts {, }]"
}

set part_tag [string map {"-" "_" "." "_"} $part]
set proj_name "my_proj_${dut_impl}_${part_tag}"
set script_dir [file normalize [file dirname [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set build_dir [file normalize [file join $project_dir build vivado_pwl_dfx $part_tag]]
set proj_dir [file normalize [file join $build_dir $proj_name]]
set dut_ip_script [file normalize [file join $script_dir pwl_dfx_dut_ip_flow.tcl]]
set dfx_latency_module_file [file normalize [file join $project_dir HW srcs dfx_programming_latency_gpio.v]]

puts "Building PWL DFX platform"
puts "Using target part: $part"

if {![file exists $dut_ip_script]} {
    error "DUT IP Tcl helper not found: $dut_ip_script"
}
if {![file exists $dfx_latency_module_file]} {
    error "DFX latency RTL helper not found: $dfx_latency_module_file"
}

source $dut_ip_script

set supported_rms [normalize_requested_rms $requested_rms_raw]
set default_rm_id exp
if {$default_rm_id ni $supported_rms} {
    set default_rm_id [lindex $supported_rms 0]
}
set rm_display_names {}
foreach dut_id $supported_rms {
    lappend rm_display_names [dict get [resolve_pwl_dut $dut_id] display_name]
}
set dut_display_name [join $rm_display_names {, }]

proc externalize_bd_intf_port {intf_pin_name new_name} {
    set before_ports [get_bd_intf_ports -quiet]
    make_bd_intf_pins_external [get_bd_intf_pins $intf_pin_name]
    set created_ports {}
    foreach port_obj [get_bd_intf_ports -quiet] {
        if {$port_obj ni $before_ports} {
            lappend created_ports $port_obj
        }
    }
    if {[llength $created_ports] != 1} {
        error "Expected exactly one new BD interface port while externalizing '$intf_pin_name', found [llength $created_ports]."
    }
    set created_port [lindex $created_ports 0]
    set_property name $new_name $created_port
    return [get_bd_intf_ports -quiet $new_name]
}

proc configure_axi_lite_shutdown_manager {cell_name addr_width data_width} {
    set_property -dict [list \
        CONFIG.DP_PROTOCOL {AXI4LITE} \
        CONFIG.RP_IS_MASTER {false} \
        CONFIG.DP_AXI_ADDR_WIDTH $addr_width \
        CONFIG.DP_AXI_DATA_WIDTH $data_width \
        CONFIG.DP_AXI_ID_WIDTH {0} \
        CONFIG.DP_AXI_AWUSER_WIDTH {0} \
        CONFIG.DP_AXI_ARUSER_WIDTH {0} \
        CONFIG.DP_AXI_WUSER_WIDTH {0} \
        CONFIG.DP_AXI_RUSER_WIDTH {0} \
        CONFIG.DP_AXI_BUSER_WIDTH {0} \
    ] [get_bd_cells $cell_name]
}

proc configure_axi_mm_shutdown_manager {cell_name addr_width data_width id_width user_width} {
    set_property -dict [list \
        CONFIG.DP_PROTOCOL {AXI4MM} \
        CONFIG.RP_IS_MASTER {true} \
        CONFIG.DP_AXI_ADDR_WIDTH $addr_width \
        CONFIG.DP_AXI_DATA_WIDTH $data_width \
        CONFIG.DP_AXI_ID_WIDTH $id_width \
        CONFIG.DP_AXI_AWUSER_WIDTH $user_width \
        CONFIG.DP_AXI_ARUSER_WIDTH $user_width \
        CONFIG.DP_AXI_WUSER_WIDTH $user_width \
        CONFIG.DP_AXI_RUSER_WIDTH $user_width \
        CONFIG.DP_AXI_BUSER_WIDTH $user_width \
    ] [get_bd_cells $cell_name]
}

proc get_default_dfx_pblock_range {part} {
    switch -- $part {
        "xck26-sfvc784-2LV-c" {
            return "CLOCKREGION_X2Y1:CLOCKREGION_X2Y2"
        }
        default {
            error "No default DFX PBLOCK range is defined for part '$part'."
        }
    }
}

proc generate_dfx_pblock_xdc {file_path pblock_name rp_cell_name pblock_range} {
    set xdc_template {set rp_cells [get_cells -quiet -hier -filter {NAME == @@RP_CELL_NAME@@ || NAME =~ @@RP_CELL_NAME@@/*}]
create_pblock @@PBLOCK_NAME@@
resize_pblock [get_pblocks @@PBLOCK_NAME@@] -add {@@PBLOCK_RANGE@@}
add_cells_to_pblock [get_pblocks @@PBLOCK_NAME@@] $rp_cells
set_property SNAPPING_MODE ON [get_pblocks @@PBLOCK_NAME@@]
}

    write_text_file $file_path [string map [list \
        @@RP_CELL_NAME@@ $rp_cell_name \
        @@PBLOCK_NAME@@ $pblock_name \
        @@PBLOCK_RANGE@@ $pblock_range \
    ] $xdc_template]
}

proc connect_bd_net_if_unconnected {src_pin_name dst_pin_name} {
    set dst_pin [get_bd_pins -quiet $dst_pin_name]
    if {[llength $dst_pin] == 0} {
        return
    }
    if {[llength [get_bd_nets -quiet -of_objects $dst_pin]] == 0} {
        connect_bd_net [get_bd_pins $src_pin_name] $dst_pin
    }
}

set dut_build_info {}
set ip_repo_paths {}
set xci_files {}
set wrapper_files {}
set xci_module_names {}
foreach dut_id $supported_rms {
    lassign [package_dut_ip $dut_id $part $build_dir] \
        ip_repo_dir \
        dut_vlnv \
        ip_name \
        xci_file \
        wrapper_file \
        wrapper_module \
        xci_module_name

    set dut_info [resolve_pwl_dut $dut_id]
    set dut_info [dict merge $dut_info [dict create \
        ip_repo_dir $ip_repo_dir \
        dut_vlnv $dut_vlnv \
        ip_name $ip_name \
        xci_file $xci_file \
        wrapper_file $wrapper_file \
        wrapper_module_name $wrapper_module \
        xci_module_name $xci_module_name \
    ]]
    lappend dut_build_info $dut_info
    lappend ip_repo_paths $ip_repo_dir
    lappend xci_files $xci_file
    lappend wrapper_files $wrapper_file
    lappend xci_module_names $xci_module_name
}

set ip_repo_paths [lsort -unique $ip_repo_paths]
foreach generated_file [concat $xci_files $wrapper_files] {
    if {![file exists $generated_file]} {
        error "Generated DFX dependency was not found: $generated_file"
    }
}

file mkdir $proj_dir
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property platform.name $proj_name [current_project]
set_property platform.board_id $part [current_project]
set_property PR_FLOW 1 [current_project]

set_property ip_repo_paths $ip_repo_paths [current_project]
update_ip_catalog
foreach dut_info $dut_build_info {
    set dut_id [dict get $dut_info id]
    set dut_vlnv [dict get $dut_info dut_vlnv]
    if {$dut_vlnv eq "" || [llength [get_ipdefs -all $dut_vlnv]] == 0} {
        error "Custom PWL IP '$dut_id' was not found in the local IP catalog: $dut_vlnv"
    }
}

foreach xci_file $xci_files {
    import_ip $xci_file
}
set project_source_files $wrapper_files
lappend project_source_files $dfx_latency_module_file
add_files -norecurse {*}$project_source_files
foreach xci_module_name $xci_module_names {
    set imported_dut_ip [get_ips $xci_module_name]
    if {[llength $imported_dut_ip] == 0} {
        error "Imported DUT XCI was not found in the project: $xci_module_name"
    }
    generate_target all $imported_dut_ip
    export_ip_user_files -of_objects $imported_dut_ip -no_script -sync -force
}
update_compile_order -fileset sources_1

puts "Building K26 DFX block design"

create_bd_design "design_1"

create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_ps8_0_pl0
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_ctrl_smc_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* axi_gpio_shutdown_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* axi_gpio_reset_0
create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_axi_shutdown_manager:* dfx_axi_shutdown_ctrl_0
create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_axi_shutdown_manager:* dfx_axi_shutdown_gmem0_0
create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_axi_shutdown_manager:* dfx_axi_shutdown_gmem1_0
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* shutdown_status_and_0
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* shutdown_status_and_1
create_bd_cell -type module -reference dfx_programming_latency_gpio dfx_programming_latency_gpio_0

set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] [get_bd_cells axi_ctrl_smc_0]
set_property -dict [list \
    CONFIG.C_NUM_INTERCONNECT_ARESETN {1} \
    CONFIG.C_EXT_RST_WIDTH {1} \
] [get_bd_cells rst_ps8_0_pl0]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] [get_bd_cells axi_gpio_shutdown_0]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
] [get_bd_cells axi_gpio_reset_0]
set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {1}] [get_bd_cells shutdown_status_and_0]
set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {1}] [get_bd_cells shutdown_status_and_1]

configure_axi_lite_shutdown_manager dfx_axi_shutdown_ctrl_0 6 32
configure_axi_mm_shutdown_manager dfx_axi_shutdown_gmem0_0 64 32 1 0
configure_axi_mm_shutdown_manager dfx_axi_shutdown_gmem1_0 64 32 1 0

apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "0"} \
    [get_bd_cells zynq_ultra_ps_e_0]

startgroup
set_property CONFIG.PSU__FPGA_PL1_ENABLE {0} [get_bd_cells zynq_ultra_ps_e_0]
endgroup
startgroup
set_property CONFIG.PSU__USE__M_AXI_GP1 {0} [get_bd_cells zynq_ultra_ps_e_0]
endgroup
startgroup
set_property -dict [list \
    CONFIG.PSU__UART1__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__UART1__PERIPHERAL__IO {MIO 36 .. 37} \
    CONFIG.PSU__CRL_APB__UART1_REF_CTRL__SRCSEL {IOPLL} \
    CONFIG.PSU__CRL_APB__UART1_REF_CTRL__FREQMHZ {100} \
] [get_bd_cells zynq_ultra_ps_e_0]
endgroup
startgroup
set_property -dict [list \
    CONFIG.PSU__SD1__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__SD1__PERIPHERAL__IO {MIO 46 .. 51} \
    CONFIG.PSU__SD1__SLOT_TYPE {SD 2.0} \
    CONFIG.PSU__SD1__DATA_TRANSFER_MODE {4Bit} \
    CONFIG.PSU__SD1__GRP_CD__ENABLE {0} \
    CONFIG.PSU__SD1__GRP_WP__ENABLE {0} \
    CONFIG.PSU__SD1__GRP_POW__ENABLE {0} \
] [get_bd_cells zynq_ultra_ps_e_0]
endgroup
set_property -dict [list \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
] [get_bd_cells zynq_ultra_ps_e_0]

set ps_ctrl_master ""
foreach if_name [list M_AXI_HPM0_FPD M_AXI_HPM0_LPD] {
    if {[llength [get_bd_intf_pins -quiet zynq_ultra_ps_e_0/$if_name]] > 0} {
        set ps_ctrl_master [get_bd_intf_pins zynq_ultra_ps_e_0/$if_name]
        break
    }
}
if {$ps_ctrl_master eq ""} {
    error "No usable PS AXI master interface found for AXI-Lite control."
}

connect_bd_intf_net $ps_ctrl_master [get_bd_intf_pins axi_ctrl_smc_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_smc_0/M00_AXI] [get_bd_intf_pins dfx_axi_shutdown_ctrl_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_smc_0/M01_AXI] [get_bd_intf_pins axi_gpio_shutdown_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_smc_0/M02_AXI] [get_bd_intf_pins axi_gpio_reset_0/S_AXI]

set ps_slave_candidates [list S_AXI_HPC0_FPD S_AXI_HPC1_FPD S_AXI_HP0_FPD S_AXI_HP1_FPD S_AXI_LPD]
set ps_slave_ifs {}
foreach if_name $ps_slave_candidates {
    if {[llength [get_bd_intf_pins -quiet zynq_ultra_ps_e_0/$if_name]] > 0} {
        lappend ps_slave_ifs [get_bd_intf_pins zynq_ultra_ps_e_0/$if_name]
    }
}
if {[llength $ps_slave_ifs] == 0} {
    error "No usable PS slave AXI interface found for RP master memory ports."
}

if {[llength $ps_slave_ifs] >= 2} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_gmem0_smc_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_gmem1_smc_0
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_gmem0_smc_0]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_gmem1_smc_0]
    connect_bd_intf_net [get_bd_intf_pins dfx_axi_shutdown_gmem0_0/M_AXI] [get_bd_intf_pins axi_gmem0_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_gmem0_smc_0/M00_AXI] [lindex $ps_slave_ifs 0]
    connect_bd_intf_net [get_bd_intf_pins dfx_axi_shutdown_gmem1_0/M_AXI] [get_bd_intf_pins axi_gmem1_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_gmem1_smc_0/M00_AXI] [lindex $ps_slave_ifs 1]
    set mem_clock_pins [list \
        axi_gmem0_smc_0/aclk \
        axi_gmem0_smc_0/s00_aclk \
        axi_gmem0_smc_0/m00_aclk \
        axi_gmem1_smc_0/aclk \
        axi_gmem1_smc_0/s00_aclk \
        axi_gmem1_smc_0/m00_aclk \
    ]
    set mem_reset_pins [list \
        axi_gmem0_smc_0/aresetn \
        axi_gmem0_smc_0/s00_aresetn \
        axi_gmem0_smc_0/m00_aresetn \
        axi_gmem1_smc_0/aresetn \
        axi_gmem1_smc_0/s00_aresetn \
        axi_gmem1_smc_0/m00_aresetn \
    ]
} else {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_mem_smc_0
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_mem_smc_0]
    connect_bd_intf_net [get_bd_intf_pins dfx_axi_shutdown_gmem0_0/M_AXI] [get_bd_intf_pins axi_mem_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins dfx_axi_shutdown_gmem1_0/M_AXI] [get_bd_intf_pins axi_mem_smc_0/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_mem_smc_0/M00_AXI] [lindex $ps_slave_ifs 0]
    set mem_clock_pins [list \
        axi_mem_smc_0/aclk \
        axi_mem_smc_0/s00_aclk \
        axi_mem_smc_0/s01_aclk \
        axi_mem_smc_0/m00_aclk \
    ]
    set mem_reset_pins [list \
        axi_mem_smc_0/aresetn \
        axi_mem_smc_0/s00_aresetn \
        axi_mem_smc_0/s01_aresetn \
        axi_mem_smc_0/m00_aresetn \
    ]
}

externalize_bd_intf_port dfx_axi_shutdown_ctrl_0/M_AXI rp_s_axi_control
externalize_bd_intf_port dfx_axi_shutdown_gmem0_0/S_AXI rp_m_axi_gmem0
externalize_bd_intf_port dfx_axi_shutdown_gmem1_0/S_AXI rp_m_axi_gmem1

create_bd_port -dir O -type clk rp_clk
create_bd_port -dir O -type rst rp_resetn
set_property CONFIG.POLARITY {ACTIVE_LOW} [get_bd_ports rp_resetn]

connect_bd_net [get_bd_ports rp_clk] [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins rst_ps8_0_pl0/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_ps8_0_pl0/ext_reset_in]
set rp_clk_freq [get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]]
if {$rp_clk_freq eq ""} {
    set rp_clk_freq 100000000
}
set_property CONFIG.FREQ_HZ $rp_clk_freq [get_bd_ports rp_clk]
set_property CONFIG.ASSOCIATED_BUSIF {rp_s_axi_control:rp_m_axi_gmem0:rp_m_axi_gmem1} [get_bd_ports rp_clk]
set_property CONFIG.ASSOCIATED_RESET {rp_resetn} [get_bd_ports rp_clk]

connect_bd_net [get_bd_ports rp_resetn] [get_bd_pins axi_gpio_reset_0/gpio_io_o]

connect_bd_net [get_bd_pins axi_gpio_shutdown_0/gpio_io_o] [get_bd_pins dfx_axi_shutdown_ctrl_0/request_shutdown]
connect_bd_net [get_bd_pins axi_gpio_shutdown_0/gpio_io_o] [get_bd_pins dfx_axi_shutdown_gmem0_0/request_shutdown]
connect_bd_net [get_bd_pins axi_gpio_shutdown_0/gpio_io_o] [get_bd_pins dfx_axi_shutdown_gmem1_0/request_shutdown]

connect_bd_net [get_bd_pins dfx_axi_shutdown_ctrl_0/in_shutdown] [get_bd_pins shutdown_status_and_0/Op1]
connect_bd_net [get_bd_pins dfx_axi_shutdown_gmem0_0/in_shutdown] [get_bd_pins shutdown_status_and_0/Op2]
connect_bd_net [get_bd_pins shutdown_status_and_0/Res] [get_bd_pins shutdown_status_and_1/Op1]
connect_bd_net [get_bd_pins dfx_axi_shutdown_gmem1_0/in_shutdown] [get_bd_pins shutdown_status_and_1/Op2]
connect_bd_net [get_bd_pins shutdown_status_and_1/Res] [get_bd_pins dfx_programming_latency_gpio_0/shutdown_status]
connect_bd_net [get_bd_pins axi_gpio_reset_0/gpio_io_o] [get_bd_pins dfx_programming_latency_gpio_0/rp_resetn]
connect_bd_net [get_bd_pins dfx_programming_latency_gpio_0/gpio_value] [get_bd_pins axi_gpio_shutdown_0/gpio2_io_i]

foreach pin_name [concat [list \
    axi_ctrl_smc_0/aclk \
    axi_ctrl_smc_0/s00_aclk \
    axi_ctrl_smc_0/m00_aclk \
    axi_ctrl_smc_0/m01_aclk \
    axi_ctrl_smc_0/m02_aclk \
    axi_gpio_shutdown_0/s_axi_aclk \
    axi_gpio_reset_0/s_axi_aclk \
    dfx_axi_shutdown_ctrl_0/clk \
    dfx_axi_shutdown_gmem0_0/clk \
    dfx_axi_shutdown_gmem1_0/clk \
    dfx_programming_latency_gpio_0/clk \
] $mem_clock_pins] {
    connect_bd_net_if_unconnected zynq_ultra_ps_e_0/pl_clk0 $pin_name
}

set interconnect_resetn [get_bd_pins -quiet rst_ps8_0_pl0/interconnect_aresetn]
set peripheral_resetn [get_bd_pins -quiet rst_ps8_0_pl0/peripheral_aresetn]
if {[llength $interconnect_resetn] == 0 || [llength $peripheral_resetn] == 0} {
    error "Expected proc_sys_reset outputs were not created for the static shell."
}

foreach pin_name [concat [list \
    axi_ctrl_smc_0/aresetn \
    axi_ctrl_smc_0/s00_aresetn \
    axi_ctrl_smc_0/m00_aresetn \
    axi_ctrl_smc_0/m01_aresetn \
    axi_ctrl_smc_0/m02_aresetn \
] $mem_reset_pins] {
    set pin_obj [get_bd_pins -quiet $pin_name]
    if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
        connect_bd_net $interconnect_resetn $pin_obj
    }
}

foreach pin_name [list \
    axi_gpio_shutdown_0/s_axi_aresetn \
    axi_gpio_reset_0/s_axi_aresetn \
    dfx_axi_shutdown_ctrl_0/resetn \
    dfx_axi_shutdown_gmem0_0/resetn \
    dfx_axi_shutdown_gmem1_0/resetn \
    dfx_programming_latency_gpio_0/resetn \
] {
    set pin_obj [get_bd_pins -quiet $pin_name]
    if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
        connect_bd_net $peripheral_resetn $pin_obj
    }
}

foreach aclk_pin [get_bd_pins -quiet zynq_ultra_ps_e_0/maxihpm*_fpd_aclk] {
    if {[llength [get_bd_nets -quiet -of_objects $aclk_pin]] == 0} {
        connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $aclk_pin
    }
}
foreach aclk_pin [get_bd_pins -quiet zynq_ultra_ps_e_0/maxihpm*_lpd_aclk] {
    if {[llength [get_bd_nets -quiet -of_objects $aclk_pin]] == 0} {
        connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $aclk_pin
    }
}
foreach aclk_pin [get_bd_pins -quiet zynq_ultra_ps_e_0/saxihp*_fpd_aclk] {
    if {[llength [get_bd_nets -quiet -of_objects $aclk_pin]] == 0} {
        connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $aclk_pin
    }
}

assign_bd_address

set ocm_seg [get_bd_addr_segs -quiet /zynq_ultra_ps_e_0/SAXIGP2/HP0_LPS_OCM]
if {[llength $ocm_seg] > 0} {
    foreach master_space_name [list /rp_m_axi_gmem0 /rp_m_axi_gmem1] {
        set master_space [get_bd_addr_spaces -quiet $master_space_name]
        if {[llength $master_space] > 0} {
            exclude_bd_addr_seg -target_address_space $master_space $ocm_seg
        }
    }
}

validate_bd_design
save_bd_design

generate_target all [get_files design_1.bd]
set wrapper_file [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper_file
set wrapper_top [file rootname [file tail $wrapper_file]]

set generated_dfx_src_dir [file normalize [file join $build_dir generated_dfx_src]]
set generated_dfx_constraints_dir [file normalize [file join $build_dir generated_dfx_constraints]]
set top_module "pwl_dfx_top"
set top_file [file normalize [file join $generated_dfx_src_dir ${top_module}.v]]
set pblock_name "pblock_u_rp"
set rp_instance_name "u_rp"
set pblock_range [get_default_dfx_pblock_range $part]
set pblock_xdc_file [file normalize [file join $generated_dfx_constraints_dir ${pblock_name}.xdc]]

file mkdir $generated_dfx_src_dir
file mkdir $generated_dfx_constraints_dir
set dut_build_info_with_rp {}
set generated_rp_files {}
set default_rp_module ""
set default_rm_name ""
set default_pr_config ""
foreach dut_info $dut_build_info {
    set dut_id [dict get $dut_info id]
    set rp_module_name [dict get $dut_info rp_module_name]
    set wrapper_module_name [dict get $dut_info wrapper_module_name]
    set rp_file [file normalize [file join $generated_dfx_src_dir ${rp_module_name}.v]]
    generate_pwl_rp_module $rp_file $rp_module_name $wrapper_module_name
    lappend generated_rp_files $rp_file
    set dut_info [dict merge $dut_info [dict create rp_file $rp_file]]
    lappend dut_build_info_with_rp $dut_info
    if {$dut_id eq $default_rm_id} {
        set default_rp_module $rp_module_name
        set default_rm_name [dict get $dut_info rm_name]
        set default_pr_config [dict get $dut_info pr_config_name]
    }
}
if {$default_rp_module eq "" || $default_rm_name eq "" || $default_pr_config eq ""} {
    error "Default DFX RM '$default_rm_id' was not packaged correctly."
}
generate_pwl_dfx_top_module $top_file $top_module $wrapper_top $default_rp_module
generate_dfx_pblock_xdc $pblock_xdc_file $pblock_name $rp_instance_name $pblock_range

set generated_design_sources $generated_rp_files
lappend generated_design_sources $top_file
add_files -norecurse {*}$generated_design_sources
add_files -fileset constrs_1 -norecurse $pblock_xdc_file
set pblock_xdc_obj [get_files $pblock_xdc_file]
set_property used_in_synthesis false $pblock_xdc_obj
set_property used_in_implementation true $pblock_xdc_obj
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

set partition_def [create_partition_def -name rp_partition -module $default_rp_module]
foreach dut_info $dut_build_info {
    create_reconfig_module \
        -name [dict get $dut_info rm_name] \
        -partition_def $partition_def \
        -define_from [dict get $dut_info rp_module_name]
}
set_property default_rm $default_rm_name $partition_def

foreach dut_info $dut_build_info {
    create_pr_configuration \
        -name [dict get $dut_info pr_config_name] \
        -partitions [list u_rp:[dict get $dut_info rm_name]]
}
current_pr_configuration $default_pr_config
set_property pr_configuration $default_pr_config [get_runs impl_1]

set impl_flow [get_property FLOW [get_runs impl_1]]
if {$impl_flow eq ""} {
    set impl_flow {Vivado Implementation 2023}
}
foreach dut_info $dut_build_info {
    set dut_id [dict get $dut_info id]
    if {$dut_id eq $default_rm_id} {
        continue
    }
    set impl_run_name [pwl_dfx_impl_run_name $dut_id]
    set pr_config_name [dict get $dut_info pr_config_name]
    if {[llength [get_runs -quiet $impl_run_name]] == 0} {
        create_run $impl_run_name -parent_run impl_1 -flow $impl_flow -pr_config $pr_config_name
    }
    set_property pr_configuration $pr_config_name [get_runs $impl_run_name]
}

puts "Generated DFX top module: $top_file"
foreach dut_info $dut_build_info_with_rp {
    puts "Generated RP module for [dict get $dut_info id]: [dict get $dut_info rp_file]"
}
puts "Generated DFX PBLOCK constraints: $pblock_xdc_file"
puts "Default DFX PBLOCK range: $pblock_range"
puts "Selected DFX RMs: [join $supported_rms {, }]"
puts "Active PR configuration: [current_pr_configuration]"
