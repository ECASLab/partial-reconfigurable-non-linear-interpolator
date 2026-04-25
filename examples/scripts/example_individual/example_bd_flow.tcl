# Vivado batch Tcl BD flow:
# - Create a new project
# - Package the selected AXI-wrapped DUT implementation as custom IP
# - Create a block design
# - Add IP and run automation
# - Validate BD and generate HDL wrapper

set supported_parts [list \
    "xcu250-figd2104-2L-e" \
    "xck26-sfvc784-2LV-c" \
]
set dut_impl "mul"
set part "xck26-sfvc784-2LV-c"
if {$argc >= 1} {
    set dut_impl [string tolower [lindex $argv 0]]
}
if {$argc >= 2} {
    set part [string trim [lindex $argv 1]]
}
if {$dut_impl ni {"mul" "xor"}} {
    error "Unsupported DUT '$dut_impl'. Supported DUTs: mul xor"
}
if {$part ni $supported_parts} {
    error "Unsupported part '$part'. Supported parts: [join $supported_parts {, }]"
}

set part_tag [string map {"-" "_" "." "_"} $part]
set proj_name "my_proj_${dut_impl}_${part_tag}"
set script_dir [file normalize [file dirname [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set build_dir [file normalize [file join $project_dir build vivado $dut_impl $part_tag]]
set proj_dir  [file normalize [file join $build_dir $proj_name]]
set dut_ip_script [file normalize [file join $project_dir scripts example_dut_ip_flow.tcl]]

puts "Using DUT implementation: $dut_impl"
puts "Using target part: $part"

if {![file exists $dut_ip_script]} {
    error "DUT IP Tcl helper not found: $dut_ip_script"
}

source $dut_ip_script
lassign [package_dut_ip $dut_impl $part $build_dir] \
    dut_ip_repo_dir \
    dut_ip_vlnv \
    dut_ip_name \
    dut_xci_file \
    dut_bd_wrapper_file \
    dut_bd_wrapper_module \
    dut_xci_module_name
set dut_cell_name "${dut_ip_name}_0"

# Create the main project and import custom IP catalog.
file mkdir $proj_dir
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property platform.name $proj_name [current_project]
set_property platform.board_id $part [current_project]

set_property ip_repo_paths [list $dut_ip_repo_dir] [current_project]
update_ip_catalog
if {$dut_ip_vlnv eq "" || [llength [get_ipdefs -all $dut_ip_vlnv]] == 0} {
    error "Custom DUT IP was not found in local IP catalog: $dut_ip_vlnv"
}
if {![file exists $dut_xci_file]} {
    error "Generated DUT XCI was not found: $dut_xci_file"
}
if {![file exists $dut_bd_wrapper_file]} {
    error "Generated DUT BD wrapper was not found: $dut_bd_wrapper_file"
}

import_ip $dut_xci_file
add_files -norecurse $dut_bd_wrapper_file
set imported_dut_ip [get_ips $dut_xci_module_name]
if {[llength $imported_dut_ip] == 0} {
    error "Imported DUT XCI was not found in the project: $dut_xci_module_name"
}
generate_target all $imported_dut_ip
export_ip_user_files -of_objects $imported_dut_ip -no_script -sync -force
update_compile_order -fileset sources_1

if {$part eq "xck26-sfvc784-2LV-c"} {
    puts "Building K26 platform block design"

    create_bd_design "design_1"

    create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* axi_dma_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:* axis_data_fifo_0
    create_bd_cell -type module -reference $dut_bd_wrapper_module $dut_cell_name

    set_property -dict [list \
        CONFIG.c_include_sg {0} \
        CONFIG.c_m_axis_mm2s_tdata_width {128} \
        CONFIG.c_s_axis_s2mm_tdata_width {128} \
    ] [get_bd_cells axi_dma_0]
    set_property -dict [list \
        CONFIG.TDATA_NUM_BYTES {16} \
    ] [get_bd_cells axis_data_fifo_0]

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
        if {[llength [get_bd_intf_pins -quiet zynq_ultra_ps_e_0/$if_name]] > 0} {
            set ps_ctrl_master "/zynq_ultra_ps_e_0/$if_name"
            break
        }
    }
    if {$ps_ctrl_master eq ""} {
        error "No usable PS AXI master interface found for DMA AXI-Lite control."
    }

    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
        -config [list Master $ps_ctrl_master Clk "/zynq_ultra_ps_e_0/pl_clk0"] \
        [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

    set ps_slave_candidates [list S_AXI_HPC0_FPD S_AXI_HPC1_FPD S_AXI_HP0_FPD S_AXI_HP1_FPD S_AXI_LPD]
    set ps_slave_ifs {}
    foreach if_name $ps_slave_candidates {
        if {[llength [get_bd_intf_pins -quiet zynq_ultra_ps_e_0/$if_name]] > 0} {
            lappend ps_slave_ifs "/zynq_ultra_ps_e_0/$if_name"
        }
    }
    if {[llength $ps_slave_ifs] == 0} {
        error "No usable PS slave AXI interface found for DMA memory-mapped ports."
    }
    set mm2s_slave_if [lindex $ps_slave_ifs 0]

    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_mem_smc_0
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_mem_smc_0]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_mem_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_mem_smc_0/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_mem_smc_0/M00_AXI] [get_bd_intf_pins [string trimleft $mm2s_slave_if "/"]]

    connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
        [get_bd_intf_pins axis_data_fifo_0/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_0/M_AXIS] \
        [get_bd_intf_pins ${dut_cell_name}/s_axis]
    connect_bd_intf_net [get_bd_intf_pins ${dut_cell_name}/m_axis] \
        [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

    foreach pin_name [list \
        axi_dma_0/s_axi_lite_aclk \
        axi_dma_0/m_axi_mm2s_aclk \
        axi_dma_0/m_axi_s2mm_aclk \
        axi_dma_0/m_axis_mm2s_aclk \
        axi_dma_0/s_axis_s2mm_aclk \
        axis_data_fifo_0/s_axis_aclk \
        axis_data_fifo_0/m_axis_aclk \
        ${dut_cell_name}/clk \
        axi_mem_smc_0/aclk \
        axi_mem_smc_0/s00_aclk \
        axi_mem_smc_0/s01_aclk \
        axi_mem_smc_0/m00_aclk \
    ] {
        set pin_obj [get_bd_pins -quiet $pin_name]
        if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
            connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $pin_obj
        }
    }

    set interconnect_resetn [get_bd_pins -quiet rst_ps8_0_96M/interconnect_aresetn]
    set peripheral_resetn [get_bd_pins -quiet rst_ps8_0_96M/peripheral_aresetn]
    if {[llength $interconnect_resetn] == 0 || [llength $peripheral_resetn] == 0} {
        error "Expected proc_sys_reset outputs were not created by automation."
    }

    foreach pin_name [list \
        axi_dma_0/axi_resetn \
        axis_data_fifo_0/s_axis_aresetn \
        axis_data_fifo_0/m_axis_aresetn \
        ${dut_cell_name}/rstn \
        axi_mem_smc_0/aresetn \
        axi_mem_smc_0/s00_aresetn \
        axi_mem_smc_0/s01_aresetn \
        axi_mem_smc_0/m00_aresetn \
    ] {
        set pin_obj [get_bd_pins -quiet $pin_name]
        if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
            if {$pin_name eq "axi_dma_0/axi_resetn" || $pin_name eq "${dut_cell_name}/rstn"} {
                connect_bd_net $peripheral_resetn $pin_obj
            } else {
                connect_bd_net $interconnect_resetn $pin_obj
            }
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

    set ocm_seg [get_bd_addr_segs -quiet /zynq_ultra_ps_e_0/SAXIGP2/HP0_LPS_OCM]
    if {[llength $ocm_seg] > 0} {
        foreach dma_space_name [list /axi_dma_0/Data_MM2S /axi_dma_0/Data_S2MM] {
            set dma_space [get_bd_addr_spaces -quiet $dma_space_name]
            if {[llength $dma_space] > 0} {
                exclude_bd_addr_seg -target_address_space $dma_space $ocm_seg
            }
        }
    }

    assign_bd_address
} else {
    puts "Building U250 accelerator subsystem block design"

    create_bd_design "design_1"
    create_bd_cell -type module -reference $dut_bd_wrapper_module $dut_cell_name

    make_bd_intf_pins_external [get_bd_intf_pins ${dut_cell_name}/s_axis]
    set_property name s_axis [get_bd_intf_ports s_axis_0]

    make_bd_intf_pins_external [get_bd_intf_pins ${dut_cell_name}/m_axis]
    set_property name m_axis [get_bd_intf_ports m_axis_0]

    make_bd_pins_external [get_bd_pins ${dut_cell_name}/clk]
    set_property name aclk [get_bd_ports clk_0]
    set_property CONFIG.FREQ_HZ {250000000} [get_bd_ports aclk]
    set_property CONFIG.ASSOCIATED_BUSIF {s_axis:m_axis} [get_bd_ports aclk]
    set_property CONFIG.ASSOCIATED_RESET {aresetn} [get_bd_ports aclk]

    make_bd_pins_external [get_bd_pins ${dut_cell_name}/rstn]
    set_property name aresetn [get_bd_ports rstn_0]
    set_property CONFIG.POLARITY {ACTIVE_LOW} [get_bd_ports aresetn]
}

validate_bd_design
save_bd_design

generate_target all [get_files design_1.bd]
set wrapper_file [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper_file
set wrapper_top [file rootname [file tail $wrapper_file]]
set_property top $wrapper_top [current_fileset]
update_compile_order -fileset sources_1

# Optional build steps:
# launch_runs synth_1 -jobs 8
# launch_runs impl_1 -to_step write_bitstream -jobs 8
