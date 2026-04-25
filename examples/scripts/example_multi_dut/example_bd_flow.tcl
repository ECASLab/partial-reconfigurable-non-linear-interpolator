# Vivado batch Tcl BD flow:
# - Create a new project
# - Package AXI-wrapped mul/xor DUT implementations as custom IP
# - Create a block design that includes both accelerators
# - Validate BD and generate HDL wrapper

set supported_parts [list \
    "xcu250-figd2104-2L-e" \
    "xck26-sfvc784-2LV-c" \
]

set dut_impl "multi_dut"
set part "xck26-sfvc784-2LV-c"
if {$argc >= 1} {
    set arg0 [string trim [lindex $argv 0]]
    if {$arg0 in $supported_parts} {
        set part $arg0
    } elseif {[string tolower $arg0] ne "multi_dut"} {
        puts "Ignoring flow selector '$arg0'; this script always instantiates both mul and xor."
    }
}
if {$argc >= 2} {
    set part [string trim [lindex $argv 1]]
}
if {$part ni $supported_parts} {
    error "Unsupported part '$part'. Supported parts: [join $supported_parts {, }]"
}

set part_tag [string map {"-" "_" "." "_"} $part]
set proj_name "my_proj_${dut_impl}_${part_tag}"
set script_dir [file normalize [file dirname [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set build_dir [file normalize [file join $project_dir build vivado_multi_dut $part_tag]]
set proj_dir [file normalize [file join $build_dir $proj_name]]
set dut_ip_script [file normalize [file join $project_dir scripts example_dut_ip_flow.tcl]]

puts "Building multi-DUT platform"
puts "Using target part: $part"

if {![file exists $dut_ip_script]} {
    error "DUT IP Tcl helper not found: $dut_ip_script"
}

source $dut_ip_script
lassign [package_dut_ip mul $part $build_dir] \
    mul_ip_repo_dir \
    mul_ip_vlnv \
    mul_ip_name \
    mul_xci_file \
    mul_bd_wrapper_file \
    mul_bd_wrapper_module \
    mul_xci_module_name
lassign [package_dut_ip xor $part $build_dir] \
    xor_ip_repo_dir \
    xor_ip_vlnv \
    xor_ip_name \
    xor_xci_file \
    xor_bd_wrapper_file \
    xor_bd_wrapper_module \
    xor_xci_module_name
set ip_repo_paths [lsort -unique [list $mul_ip_repo_dir $xor_ip_repo_dir]]
set mul_cell_name "${mul_ip_name}_0"
set xor_cell_name "${xor_ip_name}_0"

file mkdir $proj_dir
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property platform.name $proj_name [current_project]
set_property platform.board_id $part [current_project]

set_property ip_repo_paths $ip_repo_paths [current_project]
update_ip_catalog
if {$mul_ip_vlnv eq "" || [llength [get_ipdefs -all $mul_ip_vlnv]] == 0} {
    error "Custom mul DUT IP was not found in local IP catalog: $mul_ip_vlnv"
}
if {$xor_ip_vlnv eq "" || [llength [get_ipdefs -all $xor_ip_vlnv]] == 0} {
    error "Custom xor DUT IP was not found in local IP catalog: $xor_ip_vlnv"
}
foreach generated_file [list $mul_xci_file $xor_xci_file $mul_bd_wrapper_file $xor_bd_wrapper_file] {
    if {![file exists $generated_file]} {
        error "Generated multi-DUT dependency was not found: $generated_file"
    }
}

foreach xci_file [list $mul_xci_file $xor_xci_file] {
    import_ip $xci_file
}
add_files -norecurse $mul_bd_wrapper_file $xor_bd_wrapper_file
foreach xci_module_name [list $mul_xci_module_name $xor_xci_module_name] {
    set imported_dut_ip [get_ips $xci_module_name]
    if {[llength $imported_dut_ip] == 0} {
        error "Imported DUT XCI was not found in the project: $xci_module_name"
    }
    generate_target all $imported_dut_ip
    export_ip_user_files -of_objects $imported_dut_ip -no_script -sync -force
}
update_compile_order -fileset sources_1

if {$part eq "xck26-sfvc784-2LV-c"} {
    puts "Building K26 multi-accelerator block design"

    create_bd_design "design_1"

    create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* axi_dma_mul_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* axi_dma_xor_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:* axis_data_fifo_mul_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:* axis_data_fifo_xor_0
    create_bd_cell -type module -reference $mul_bd_wrapper_module $mul_cell_name
    create_bd_cell -type module -reference $xor_bd_wrapper_module $xor_cell_name

    foreach dma_cell [list axi_dma_mul_0 axi_dma_xor_0] {
        set_property -dict [list \
            CONFIG.c_include_sg {0} \
            CONFIG.c_m_axis_mm2s_tdata_width {128} \
            CONFIG.c_s_axis_s2mm_tdata_width {128} \
        ] [get_bd_cells $dma_cell]
    }
    foreach fifo_cell [list axis_data_fifo_mul_0 axis_data_fifo_xor_0] {
        set_property -dict [list \
            CONFIG.TDATA_NUM_BYTES {16} \
        ] [get_bd_cells $fifo_cell]
    }

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

    foreach dma_lite_if [list axi_dma_mul_0/S_AXI_LITE axi_dma_xor_0/S_AXI_LITE] {
        apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
            -config [list Master $ps_ctrl_master Clk "/zynq_ultra_ps_e_0/pl_clk0"] \
            [get_bd_intf_pins $dma_lite_if]
    }

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
    set mem_slave_if [lindex $ps_slave_ifs 0]

    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_mem_smc_0
    set_property -dict [list CONFIG.NUM_SI {4} CONFIG.NUM_MI {1}] [get_bd_cells axi_mem_smc_0]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_mul_0/M_AXI_MM2S] [get_bd_intf_pins axi_mem_smc_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_mul_0/M_AXI_S2MM] [get_bd_intf_pins axi_mem_smc_0/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_xor_0/M_AXI_MM2S] [get_bd_intf_pins axi_mem_smc_0/S02_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_dma_xor_0/M_AXI_S2MM] [get_bd_intf_pins axi_mem_smc_0/S03_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_mem_smc_0/M00_AXI] [get_bd_intf_pins [string trimleft $mem_slave_if "/"]]

    connect_bd_intf_net [get_bd_intf_pins axi_dma_mul_0/M_AXIS_MM2S] \
        [get_bd_intf_pins axis_data_fifo_mul_0/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_mul_0/M_AXIS] \
        [get_bd_intf_pins ${mul_cell_name}/s_axis]
    connect_bd_intf_net [get_bd_intf_pins ${mul_cell_name}/m_axis] \
        [get_bd_intf_pins axi_dma_mul_0/S_AXIS_S2MM]

    connect_bd_intf_net [get_bd_intf_pins axi_dma_xor_0/M_AXIS_MM2S] \
        [get_bd_intf_pins axis_data_fifo_xor_0/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_xor_0/M_AXIS] \
        [get_bd_intf_pins ${xor_cell_name}/s_axis]
    connect_bd_intf_net [get_bd_intf_pins ${xor_cell_name}/m_axis] \
        [get_bd_intf_pins axi_dma_xor_0/S_AXIS_S2MM]

    foreach pin_name [list \
        axi_dma_mul_0/s_axi_lite_aclk \
        axi_dma_mul_0/m_axi_mm2s_aclk \
        axi_dma_mul_0/m_axi_s2mm_aclk \
        axi_dma_mul_0/m_axis_mm2s_aclk \
        axi_dma_mul_0/s_axis_s2mm_aclk \
        axis_data_fifo_mul_0/s_axis_aclk \
        axis_data_fifo_mul_0/m_axis_aclk \
        ${mul_cell_name}/clk \
        axi_dma_xor_0/s_axi_lite_aclk \
        axi_dma_xor_0/m_axi_mm2s_aclk \
        axi_dma_xor_0/m_axi_s2mm_aclk \
        axi_dma_xor_0/m_axis_mm2s_aclk \
        axi_dma_xor_0/s_axis_s2mm_aclk \
        axis_data_fifo_xor_0/s_axis_aclk \
        axis_data_fifo_xor_0/m_axis_aclk \
        ${xor_cell_name}/clk \
        axi_mem_smc_0/aclk \
        axi_mem_smc_0/s00_aclk \
        axi_mem_smc_0/s01_aclk \
        axi_mem_smc_0/s02_aclk \
        axi_mem_smc_0/s03_aclk \
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
        axi_dma_mul_0/axi_resetn \
        axis_data_fifo_mul_0/s_axis_aresetn \
        axis_data_fifo_mul_0/m_axis_aresetn \
        ${mul_cell_name}/rstn \
        axi_dma_xor_0/axi_resetn \
        axis_data_fifo_xor_0/s_axis_aresetn \
        axis_data_fifo_xor_0/m_axis_aresetn \
        ${xor_cell_name}/rstn \
        axi_mem_smc_0/aresetn \
        axi_mem_smc_0/s00_aresetn \
        axi_mem_smc_0/s01_aresetn \
        axi_mem_smc_0/s02_aresetn \
        axi_mem_smc_0/s03_aresetn \
        axi_mem_smc_0/m00_aresetn \
    ] {
        set pin_obj [get_bd_pins -quiet $pin_name]
        if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
            if {$pin_name eq "axi_dma_mul_0/axi_resetn" || $pin_name eq "${mul_cell_name}/rstn" ||
                $pin_name eq "axi_dma_xor_0/axi_resetn" || $pin_name eq "${xor_cell_name}/rstn"} {
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
        foreach dma_space_name [list \
            /axi_dma_mul_0/Data_MM2S \
            /axi_dma_mul_0/Data_S2MM \
            /axi_dma_xor_0/Data_MM2S \
            /axi_dma_xor_0/Data_S2MM \
        ] {
            set dma_space [get_bd_addr_spaces -quiet $dma_space_name]
            if {[llength $dma_space] > 0} {
                exclude_bd_addr_seg -target_address_space $dma_space $ocm_seg
            }
        }
    }

    assign_bd_address
} else {
    puts "Building U250 multi-accelerator subsystem block design"

    create_bd_design "design_1"
    create_bd_cell -type module -reference $mul_bd_wrapper_module $mul_cell_name
    create_bd_cell -type module -reference $xor_bd_wrapper_module $xor_cell_name

    make_bd_intf_pins_external [get_bd_intf_pins ${mul_cell_name}/s_axis]
    set_property name mul_s_axis [get_bd_intf_ports s_axis_0]

    make_bd_intf_pins_external [get_bd_intf_pins ${mul_cell_name}/m_axis]
    set_property name mul_m_axis [get_bd_intf_ports m_axis_0]

    make_bd_intf_pins_external [get_bd_intf_pins ${xor_cell_name}/s_axis]
    set_property name xor_s_axis [get_bd_intf_ports s_axis_1]

    make_bd_intf_pins_external [get_bd_intf_pins ${xor_cell_name}/m_axis]
    set_property name xor_m_axis [get_bd_intf_ports m_axis_1]

    make_bd_pins_external [get_bd_pins ${mul_cell_name}/clk]
    set_property name aclk [get_bd_ports clk_0]
    set_property CONFIG.FREQ_HZ {250000000} [get_bd_ports aclk]
    set_property CONFIG.ASSOCIATED_BUSIF {mul_s_axis:mul_m_axis:xor_s_axis:xor_m_axis} [get_bd_ports aclk]
    set_property CONFIG.ASSOCIATED_RESET {aresetn} [get_bd_ports aclk]
    connect_bd_net [get_bd_ports aclk] [get_bd_pins ${xor_cell_name}/clk]

    make_bd_pins_external [get_bd_pins ${mul_cell_name}/rstn]
    set_property name aresetn [get_bd_ports rstn_0]
    set_property CONFIG.POLARITY {ACTIVE_LOW} [get_bd_ports aresetn]
    connect_bd_net [get_bd_ports aresetn] [get_bd_pins ${xor_cell_name}/rstn]
}

validate_bd_design
save_bd_design

generate_target all [get_files design_1.bd]
set wrapper_file [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper_file
set wrapper_top [file rootname [file tail $wrapper_file]]
set_property top $wrapper_top [current_fileset]
update_compile_order -fileset sources_1
