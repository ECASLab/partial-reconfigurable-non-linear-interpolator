# Vivado batch Tcl multi-DUT BD flow:
# - Resolve the exported exponential and sigmoid PWL HLS IPs
# - Build a K26 block design that instantiates one exponential-slot DUT and one
#   sigmoid-slot DUT at once
# - Validate the design and generate the HDL wrapper for downstream implementation

proc connect_bd_net_if_unconnected {src_pin_name dst_pin_name} {
    set dst_pin [get_bd_pins -quiet $dst_pin_name]
    if {[llength $dst_pin] == 0} {
        return
    }
    if {[llength [get_bd_nets -quiet -of_objects $dst_pin]] == 0} {
        connect_bd_net [get_bd_pins $src_pin_name] $dst_pin
    }
}

set supported_parts [list \
    "xck26-sfvc784-2LV-c" \
]

set dut_impl "multi_dut"
set script_dir [file normalize [file dirname [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set dut_catalog_script [file normalize [file join $project_dir scripts pwl_dut_catalog.tcl]]

if {![file exists $dut_catalog_script]} {
    error "Shared DUT catalog helper not found: $dut_catalog_script"
}
source $dut_catalog_script

set part "xck26-sfvc784-2LV-c"
set exp_requested [pwl_default_dut_id exp]
set sigmoid_requested [pwl_default_dut_id sigmoid]
if {$argc >= 1} {
    set arg0 [string trim [lindex $argv 0]]
    if {$arg0 in $supported_parts} {
        set part $arg0
    } elseif {[string tolower $arg0] ne "multi_dut"} {
        puts "Ignoring flow selector '$arg0'; this script always instantiates both exp and sigmoid."
    }
}
if {$argc >= 2} {
    set part [string trim [lindex $argv 1]]
}
# Collect trailing arguments after flow/part and normalize the expected
# shape for both direct invocation and wrapper invocation through
# impl_export_flow.tcl.
set trailing_args {}
for {set arg_idx 2} {$arg_idx < $argc} {incr arg_idx} {
    lappend trailing_args [string trim [lindex $argv $arg_idx]]
}

# Wrapper invocation format:
#   <flow> <part> <jobs> <bd_script> <exp_dut> <sigmoid_dut>
# Direct invocation format:
#   <flow> <part> <exp_dut> <sigmoid_dut>
if {[llength $trailing_args] >= 2} {
    set maybe_jobs [lindex $trailing_args 0]
    set maybe_bd_script [lindex $trailing_args 1]
    if {[string is integer -strict $maybe_jobs] && [string match "*.tcl" [file tail $maybe_bd_script]]} {
        set trailing_args [lrange $trailing_args 2 end]
    }
}

if {[llength $trailing_args] >= 1} {
    set exp_requested [lindex $trailing_args 0]
}
if {[llength $trailing_args] >= 2} {
    set sigmoid_requested [lindex $trailing_args 1]
}
if {$part ni $supported_parts} {
    error "Unsupported part '$part'. Supported parts: [join $supported_parts {, }]"
}

set exp_info [pwl_get_dut_info $project_dir $exp_requested exp]
set exp_dut_id [dict get $exp_info id]
set exp_ip_repo_dir [dict get $exp_info ip_repo_dir]
set exp_ip_vlnv [dict get $exp_info dut_vlnv]
set exp_cell_name [dict get $exp_info slot_cell_name]

set sigmoid_info [pwl_get_dut_info $project_dir $sigmoid_requested sigmoid]
set sigmoid_dut_id [dict get $sigmoid_info id]
set sigmoid_ip_repo_dir [dict get $sigmoid_info ip_repo_dir]
set sigmoid_ip_vlnv [dict get $sigmoid_info dut_vlnv]
set sigmoid_cell_name [dict get $sigmoid_info slot_cell_name]

set dut_display_name "[dict get $exp_info display_name] + [dict get $sigmoid_info display_name]"

set part_tag [string map {"-" "_" "." "_"} $part]
set proj_suffix [pwl_multi_dut_project_suffix $exp_dut_id $sigmoid_dut_id]
set proj_name "my_proj_${dut_impl}${proj_suffix}_${part_tag}"
set build_dir [file normalize [file join $project_dir build vivado_multi_dut $part_tag]]
set proj_dir [file normalize [file join $build_dir $proj_name]]

puts "Building PWL multi-DUT platform"
puts "Using target part: $part"
puts "Using exponential-slot DUT: $exp_dut_id ([dict get $exp_info display_name])"
puts "Using sigmoid-slot DUT: $sigmoid_dut_id ([dict get $sigmoid_info display_name])"
puts "Using exponential-slot HLS IP repository: $exp_ip_repo_dir"
puts "Using sigmoid-slot HLS IP repository: $sigmoid_ip_repo_dir"

file mkdir $proj_dir
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property platform.name $proj_name [current_project]
set_property platform.board_id $part [current_project]
set_property ip_repo_paths [lsort -unique [list $exp_ip_repo_dir $sigmoid_ip_repo_dir]] [current_project]
update_ip_catalog

if {[llength [get_ipdefs -all $exp_ip_vlnv]] == 0} {
    error "Selected exponential PWL HLS IP was not found in the local IP catalog: $exp_ip_vlnv"
}
if {[llength [get_ipdefs -all $sigmoid_ip_vlnv]] == 0} {
    error "Selected sigmoid PWL HLS IP was not found in the local IP catalog: $sigmoid_ip_vlnv"
}

puts "Building K26 multi-DUT PWL block design"

create_bd_design "design_1"

create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_ps8_0_pl0
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_ctrl_smc_0
create_bd_cell -type ip -vlnv $exp_ip_vlnv $exp_cell_name
create_bd_cell -type ip -vlnv $sigmoid_ip_vlnv $sigmoid_cell_name

set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells axi_ctrl_smc_0]
set_property -dict [list \
    CONFIG.C_NUM_INTERCONNECT_ARESETN {1} \
    CONFIG.C_EXT_RST_WIDTH {1} \
] [get_bd_cells rst_ps8_0_pl0]

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
set_property -dict [list \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
] [get_bd_cells zynq_ultra_ps_e_0]

set ps_ctrl_master ""
foreach if_name [list M_AXI_HPM0_FPD M_AXI_HPM0_LPD] {
    set if_obj [get_bd_intf_pins -quiet zynq_ultra_ps_e_0/$if_name]
    if {[llength $if_obj] > 0} {
        set ps_ctrl_master $if_obj
        break
    }
}
if {$ps_ctrl_master eq ""} {
    error "No usable PS AXI master interface found for DUT AXI-Lite control."
}

connect_bd_intf_net $ps_ctrl_master [get_bd_intf_pins axi_ctrl_smc_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_smc_0/M00_AXI] [get_bd_intf_pins ${exp_cell_name}/s_axi_control]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_smc_0/M01_AXI] [get_bd_intf_pins ${sigmoid_cell_name}/s_axi_control]

set ps_slave_candidates [list S_AXI_HPC0_FPD S_AXI_HPC1_FPD S_AXI_HP0_FPD S_AXI_HP1_FPD S_AXI_LPD]
set ps_slave_ifs {}
foreach if_name $ps_slave_candidates {
    set if_obj [get_bd_intf_pins -quiet zynq_ultra_ps_e_0/$if_name]
    if {[llength $if_obj] > 0} {
        lappend ps_slave_ifs $if_obj
    }
}
if {[llength $ps_slave_ifs] == 0} {
    error "No usable PS slave AXI interface found for DUT memory master ports."
}

if {[llength $ps_slave_ifs] >= 2} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_exp_mem_smc_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_sigmoid_mem_smc_0
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_exp_mem_smc_0]
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_sigmoid_mem_smc_0]

    connect_bd_intf_net [get_bd_intf_pins ${exp_cell_name}/m_axi_gmem0] [get_bd_intf_pins axi_exp_mem_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins ${exp_cell_name}/m_axi_gmem1] [get_bd_intf_pins axi_exp_mem_smc_0/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_exp_mem_smc_0/M00_AXI] [lindex $ps_slave_ifs 0]

    connect_bd_intf_net [get_bd_intf_pins ${sigmoid_cell_name}/m_axi_gmem0] [get_bd_intf_pins axi_sigmoid_mem_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins ${sigmoid_cell_name}/m_axi_gmem1] [get_bd_intf_pins axi_sigmoid_mem_smc_0/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_sigmoid_mem_smc_0/M00_AXI] [lindex $ps_slave_ifs 1]

    set mem_clock_pins [list \
        axi_exp_mem_smc_0/aclk \
        axi_exp_mem_smc_0/s00_aclk \
        axi_exp_mem_smc_0/s01_aclk \
        axi_exp_mem_smc_0/m00_aclk \
        axi_sigmoid_mem_smc_0/aclk \
        axi_sigmoid_mem_smc_0/s00_aclk \
        axi_sigmoid_mem_smc_0/s01_aclk \
        axi_sigmoid_mem_smc_0/m00_aclk \
    ]
    set mem_reset_pins [list \
        axi_exp_mem_smc_0/aresetn \
        axi_exp_mem_smc_0/s00_aresetn \
        axi_exp_mem_smc_0/s01_aresetn \
        axi_exp_mem_smc_0/m00_aresetn \
        axi_sigmoid_mem_smc_0/aresetn \
        axi_sigmoid_mem_smc_0/s00_aresetn \
        axi_sigmoid_mem_smc_0/s01_aresetn \
        axi_sigmoid_mem_smc_0/m00_aresetn \
    ]
} else {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_mem_smc_0
    set_property -dict [list CONFIG.NUM_SI {4} CONFIG.NUM_MI {1}] [get_bd_cells axi_mem_smc_0]

    connect_bd_intf_net [get_bd_intf_pins ${exp_cell_name}/m_axi_gmem0] [get_bd_intf_pins axi_mem_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins ${exp_cell_name}/m_axi_gmem1] [get_bd_intf_pins axi_mem_smc_0/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins ${sigmoid_cell_name}/m_axi_gmem0] [get_bd_intf_pins axi_mem_smc_0/S02_AXI]
    connect_bd_intf_net [get_bd_intf_pins ${sigmoid_cell_name}/m_axi_gmem1] [get_bd_intf_pins axi_mem_smc_0/S03_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_mem_smc_0/M00_AXI] [lindex $ps_slave_ifs 0]

    set mem_clock_pins [list \
        axi_mem_smc_0/aclk \
        axi_mem_smc_0/s00_aclk \
        axi_mem_smc_0/s01_aclk \
        axi_mem_smc_0/s02_aclk \
        axi_mem_smc_0/s03_aclk \
        axi_mem_smc_0/m00_aclk \
    ]
    set mem_reset_pins [list \
        axi_mem_smc_0/aresetn \
        axi_mem_smc_0/s00_aresetn \
        axi_mem_smc_0/s01_aresetn \
        axi_mem_smc_0/s02_aresetn \
        axi_mem_smc_0/s03_aresetn \
        axi_mem_smc_0/m00_aresetn \
    ]
}

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins rst_ps8_0_pl0/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_ps8_0_pl0/ext_reset_in]

foreach pin_name [concat [list \
    axi_ctrl_smc_0/aclk \
    axi_ctrl_smc_0/s00_aclk \
    axi_ctrl_smc_0/m00_aclk \
    axi_ctrl_smc_0/m01_aclk \
    ${exp_cell_name}/ap_clk \
    ${sigmoid_cell_name}/ap_clk \
] $mem_clock_pins] {
    connect_bd_net_if_unconnected zynq_ultra_ps_e_0/pl_clk0 $pin_name
}

set interconnect_resetn [get_bd_pins -quiet rst_ps8_0_pl0/interconnect_aresetn]
set peripheral_resetn [get_bd_pins -quiet rst_ps8_0_pl0/peripheral_aresetn]
if {[llength $interconnect_resetn] == 0 || [llength $peripheral_resetn] == 0} {
    error "Expected proc_sys_reset outputs were not created."
}

foreach pin_name [concat [list \
    axi_ctrl_smc_0/aresetn \
    axi_ctrl_smc_0/s00_aresetn \
    axi_ctrl_smc_0/m00_aresetn \
    axi_ctrl_smc_0/m01_aresetn \
] $mem_reset_pins] {
    set pin_obj [get_bd_pins -quiet $pin_name]
    if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
        connect_bd_net $interconnect_resetn $pin_obj
    }
}

foreach pin_name [list \
    ${exp_cell_name}/ap_rst_n \
    ${sigmoid_cell_name}/ap_rst_n \
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

validate_bd_design
save_bd_design

generate_target all [get_files design_1.bd]
set wrapper_file [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper_file
set wrapper_top [file rootname [file tail $wrapper_file]]
set_property top $wrapper_top [current_fileset]
update_compile_order -fileset sources_1
