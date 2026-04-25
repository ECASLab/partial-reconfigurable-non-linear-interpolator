# Vivado batch Tcl BD flow:
# - Resolve a selected HLS-exported PWL DUT from HW/build/vitis_hls
# - Build a K26 block design around the DUT AXI-Lite control and AXI master ports
# - Validate the design and generate the HDL wrapper for downstream implementation

proc resolve_pwl_dut {project_dir dut_impl} {
    set normalized [string tolower [string trim $dut_impl]]

    switch -- $normalized {
        exp -
        exponential -
        pwl_exp -
        pwl_exponential {
            set alias exp
            set hls_core_name "pwl_pwl_nonuniform_pwl_function_exponential_use_float32"
            set display_name "PWL Nonuniform Exponential Float32"
        }
        sig -
        sigmoid -
        pwl_sigmoid {
            set alias sigmoid
            set hls_core_name "pwl_pwl_nonuniform_pwl_function_sigmoid_use_float32"
            set display_name "PWL Nonuniform Sigmoid Float32"
        }
        default {
            error "Unsupported DUT '$dut_impl'. Supported DUTs: exp sigmoid"
        }
    }

    set hls_ip_dir [file normalize [file join $project_dir HW build vitis_hls $hls_core_name solution impl ip]]
    set component_xml [file normalize [file join $hls_ip_dir component.xml]]
    if {![file exists $component_xml]} {
        error "Expected exported HLS IP was not found: $component_xml\nRun the matching HLS export under final-project/HW before launching this Vivado flow."
    }

    return [dict create \
        alias $alias \
        display_name $display_name \
        hls_core_name $hls_core_name \
        ip_repo_dir $hls_ip_dir \
        dut_vlnv "xilinx.com:hls:${hls_core_name}:1.0" \
        cell_name "pwl_${alias}_0" \
    ]
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

set supported_parts [list \
    "xck26-sfvc784-2LV-c" \
]

set dut_impl "exp"
set part "xck26-sfvc784-2LV-c"
if {$argc >= 1} {
    set dut_impl [string trim [lindex $argv 0]]
}
if {$argc >= 2} {
    set part [string trim [lindex $argv 1]]
}
if {$part ni $supported_parts} {
    error "Unsupported part '$part'. Supported parts: [join $supported_parts {, }]"
}

set script_dir [file normalize [file dirname [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set dut_info [resolve_pwl_dut $project_dir $dut_impl]
set dut_impl [dict get $dut_info alias]
set dut_display_name [dict get $dut_info display_name]
set dut_ip_repo_dir [dict get $dut_info ip_repo_dir]
set dut_ip_vlnv [dict get $dut_info dut_vlnv]
set dut_cell_name [dict get $dut_info cell_name]

set part_tag [string map {"-" "_" "." "_"} $part]
set proj_name "my_proj_${dut_impl}_${part_tag}"
set build_dir [file normalize [file join $project_dir build vivado $dut_impl $part_tag]]
set proj_dir [file normalize [file join $build_dir $proj_name]]

puts "Using DUT implementation: $dut_impl"
puts "Using DUT variant: $dut_display_name"
puts "Using target part: $part"
puts "Using HLS IP repository: $dut_ip_repo_dir"

file mkdir $proj_dir
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property platform.name $proj_name [current_project]
set_property platform.board_id $part [current_project]
set_property ip_repo_paths [list $dut_ip_repo_dir] [current_project]
update_ip_catalog

if {[llength [get_ipdefs -all $dut_ip_vlnv]] == 0} {
    error "Selected PWL HLS IP was not found in the local IP catalog: $dut_ip_vlnv"
}

puts "Building K26 individual PWL block design"

create_bd_design "design_1"

create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_ps8_0_pl0
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_ctrl_smc_0
create_bd_cell -type ip -vlnv $dut_ip_vlnv $dut_cell_name

set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_ctrl_smc_0]
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
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_smc_0/M00_AXI] [get_bd_intf_pins ${dut_cell_name}/s_axi_control]

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
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_gmem0_smc_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_gmem1_smc_0
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_gmem0_smc_0]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_gmem1_smc_0]

    connect_bd_intf_net [get_bd_intf_pins ${dut_cell_name}/m_axi_gmem0] [get_bd_intf_pins axi_gmem0_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_gmem0_smc_0/M00_AXI] [lindex $ps_slave_ifs 0]
    connect_bd_intf_net [get_bd_intf_pins ${dut_cell_name}/m_axi_gmem1] [get_bd_intf_pins axi_gmem1_smc_0/S00_AXI]
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

    connect_bd_intf_net [get_bd_intf_pins ${dut_cell_name}/m_axi_gmem0] [get_bd_intf_pins axi_mem_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins ${dut_cell_name}/m_axi_gmem1] [get_bd_intf_pins axi_mem_smc_0/S01_AXI]
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

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins rst_ps8_0_pl0/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_ps8_0_pl0/ext_reset_in]

foreach pin_name [concat [list \
    axi_ctrl_smc_0/aclk \
    axi_ctrl_smc_0/s00_aclk \
    axi_ctrl_smc_0/m00_aclk \
    ${dut_cell_name}/ap_clk \
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
] $mem_reset_pins] {
    set pin_obj [get_bd_pins -quiet $pin_name]
    if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
        connect_bd_net $interconnect_resetn $pin_obj
    }
}

foreach pin_name [list \
    ${dut_cell_name}/ap_rst_n \
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
