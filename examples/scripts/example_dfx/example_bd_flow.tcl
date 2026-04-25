# Vivado batch Tcl BD flow:
# - Package AXI-wrapped mul/xor DUT implementations as custom IP
# - Build a K26 block design with a single reconfigurable partition boundary
# - Add DFX decouplers and GPIO based RP control/status
# - Create a generated top and reconfigurable module sources for mul/xor
# - Register the partition definition, reconfigurable modules, and PR configs

set supported_parts [list \
    "xck26-sfvc784-2LV-c" \
]

set dut_impl "dfx"
set part "xck26-sfvc784-2LV-c"
if {$argc >= 1} {
    set arg0 [string trim [lindex $argv 0]]
    if {$arg0 in $supported_parts} {
        set part $arg0
    } elseif {[string tolower $arg0] ne "dfx"} {
        puts "Ignoring flow selector '$arg0'; this script always builds the DFX hardware flow."
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
set build_dir [file normalize [file join $project_dir build vivado_dfx $part_tag]]
set proj_dir [file normalize [file join $build_dir $proj_name]]
set dut_ip_script [file normalize [file join $project_dir scripts example_dut_ip_flow.tcl]]

puts "Building DFX platform"
puts "Using target part: $part"

if {![file exists $dut_ip_script]} {
    error "DUT IP Tcl helper not found: $dut_ip_script"
}

source $dut_ip_script

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

proc configure_axis_dfx_decoupler {cell_name mode data_width tkeep_width} {
    if {$mode ni {"slave" "master"}} {
        error "Unsupported AXIS DFX decoupler mode '$mode'. Supported values: slave master"
    }

    set all_params [format {HAS_SIGNAL_CONTROL 1 HAS_SIGNAL_STATUS 1 HAS_AXI_LITE 0 INTF {intf_0 {ID 0 VLNV xilinx.com:interface:axis_rtl:1.0 MODE %s SIGNALS {TDATA {WIDTH %d PRESENT 1 DECOUPLED 1 DECOUPLED_VALUE 0x0} TVALID {WIDTH 1 PRESENT 1 DECOUPLED 1 DECOUPLED_VALUE 0x0} TREADY {WIDTH 1 PRESENT 1 DECOUPLED 1 DECOUPLED_VALUE 0x0} TLAST {WIDTH 1 PRESENT 1 DECOUPLED 1 DECOUPLED_VALUE 0x0} TKEEP {WIDTH %d PRESENT 1 DECOUPLED 1 DECOUPLED_VALUE 0x0} TSTRB {WIDTH %d PRESENT 0 DECOUPLED 0 DECOUPLED_VALUE 0x0} TUSER {WIDTH 1 PRESENT 0 DECOUPLED 0 DECOUPLED_VALUE 0x0} TID {WIDTH 1 PRESENT 0 DECOUPLED 0 DECOUPLED_VALUE 0x0} TDEST {WIDTH 1 PRESENT 0 DECOUPLED 0 DECOUPLED_VALUE 0x0}}}} IPI_PROP_COUNT 0} \
        $mode $data_width $tkeep_width $tkeep_width]
    set_property -dict [list CONFIG.ALL_PARAMS $all_params] [get_bd_cells $cell_name]
}

proc get_default_dfx_pblock_range {part} {
    switch -- $part {
        "xck26-sfvc784-2LV-c" {
            # Reserve two right-side clock regions for the RP to keep the static
            # PS-centric logic away from the reconfigurable region by default.
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

proc generate_dfx_rp_module {file_path module_name dut_wrapper_module} {
    set rp_template {
`timescale 1ns / 1ps

module ${module_name}(
    input  wire         clk,
    input  wire         rstn,
    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire [15:0]  s_axis_tkeep,
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire [15:0]  m_axis_tkeep
);

    ${dut_wrapper_module} u_dut (
        .clk           (clk),
        .rstn          (rstn),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tkeep  (s_axis_tkeep),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_tkeep  (m_axis_tkeep)
    );
endmodule
}

    write_text_file $file_path [subst $rp_template]
}

proc generate_dfx_top_module {file_path top_module_name static_wrapper_module rp_module_name} {
    set top_template {
`timescale 1ns / 1ps

module ${top_module_name};
    wire         rp_clk;
    wire         rp_rstn;
    wire [127:0] rp_s_axis_tdata;
    wire         rp_s_axis_tvalid;
    wire         rp_s_axis_tready;
    wire         rp_s_axis_tlast;
    wire [15:0]  rp_s_axis_tkeep;
    wire [127:0] rp_m_axis_tdata;
    wire         rp_m_axis_tvalid;
    wire         rp_m_axis_tready;
    wire         rp_m_axis_tlast;
    wire [15:0]  rp_m_axis_tkeep;

    ${static_wrapper_module} u_static (
        .rp_clk           (rp_clk),
        .rp_m_axis_tdata  (rp_m_axis_tdata),
        .rp_m_axis_tkeep  (rp_m_axis_tkeep),
        .rp_m_axis_tlast  (rp_m_axis_tlast),
        .rp_m_axis_tready (rp_m_axis_tready),
        .rp_m_axis_tvalid (rp_m_axis_tvalid),
        .rp_resetn        (rp_rstn),
        .rp_s_axis_tdata  (rp_s_axis_tdata),
        .rp_s_axis_tkeep  (rp_s_axis_tkeep),
        .rp_s_axis_tlast  (rp_s_axis_tlast),
        .rp_s_axis_tready (rp_s_axis_tready),
        .rp_s_axis_tvalid (rp_s_axis_tvalid)
    );

    (* keep_hierarchy = "yes" *)
    ${rp_module_name} u_rp (
        .clk           (rp_clk),
        .rstn          (rp_rstn),
        .s_axis_tdata  (rp_s_axis_tdata),
        .s_axis_tvalid (rp_s_axis_tvalid),
        .s_axis_tready (rp_s_axis_tready),
        .s_axis_tlast  (rp_s_axis_tlast),
        .s_axis_tkeep  (rp_s_axis_tkeep),
        .m_axis_tdata  (rp_m_axis_tdata),
        .m_axis_tvalid (rp_m_axis_tvalid),
        .m_axis_tready (rp_m_axis_tready),
        .m_axis_tlast  (rp_m_axis_tlast),
        .m_axis_tkeep  (rp_m_axis_tkeep)
    );
endmodule
}

    write_text_file $file_path [subst $top_template]
}

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
foreach generated_file [list $mul_xci_file $xor_xci_file $mul_bd_wrapper_file $xor_bd_wrapper_file] {
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
if {$mul_ip_vlnv eq "" || [llength [get_ipdefs -all $mul_ip_vlnv]] == 0} {
    error "Custom mul DUT IP was not found in local IP catalog: $mul_ip_vlnv"
}
if {$xor_ip_vlnv eq "" || [llength [get_ipdefs -all $xor_ip_vlnv]] == 0} {
    error "Custom xor DUT IP was not found in local IP catalog: $xor_ip_vlnv"
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

puts "Building K26 DFX block design"

create_bd_design "design_1"

create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* axi_dma_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:* axis_data_fifo_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* axi_gpio_decouple_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:* axi_gpio_reset_0
create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_decoupler:* dfx_decoupler_in_0
create_bd_cell -type ip -vlnv xilinx.com:ip:dfx_decoupler:* dfx_decoupler_out_0
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* decouple_status_and_0

set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
] [get_bd_cells axi_dma_0]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {16} \
] [get_bd_cells axis_data_fifo_0]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {1} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] [get_bd_cells axi_gpio_decouple_0]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
] [get_bd_cells axi_gpio_reset_0]
set_property -dict [list \
    CONFIG.C_OPERATION {and} \
    CONFIG.C_SIZE {1} \
] [get_bd_cells decouple_status_and_0]

configure_axis_dfx_decoupler dfx_decoupler_in_0 slave 128 16
configure_axis_dfx_decoupler dfx_decoupler_out_0 master 128 16

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
        set ps_ctrl_master "/zynq_ultra_ps_e_0/$if_name"
        break
    }
}
if {$ps_ctrl_master eq ""} {
    error "No usable PS AXI master interface found for AXI-Lite control."
}

foreach ctrl_if [list \
    axi_dma_0/S_AXI_LITE \
    axi_gpio_decouple_0/S_AXI \
    axi_gpio_reset_0/S_AXI \
] {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
        -config [list Master $ps_ctrl_master Clk "/zynq_ultra_ps_e_0/pl_clk0"] \
        [get_bd_intf_pins $ctrl_if]
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
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_mem_smc_0]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_mem_smc_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_mem_smc_0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_mem_smc_0/M00_AXI] [get_bd_intf_pins [string trimleft $mem_slave_if "/"]]

connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins axis_data_fifo_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_0/M_AXIS] \
    [get_bd_intf_pins dfx_decoupler_in_0/s_intf_0]
connect_bd_intf_net [get_bd_intf_pins dfx_decoupler_out_0/s_intf_0] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

externalize_bd_intf_port dfx_decoupler_in_0/rp_intf_0 rp_s_axis
externalize_bd_intf_port dfx_decoupler_out_0/rp_intf_0 rp_m_axis

create_bd_port -dir O -type clk rp_clk
create_bd_port -dir O -type rst rp_resetn
set_property CONFIG.POLARITY {ACTIVE_LOW} [get_bd_ports rp_resetn]

connect_bd_net [get_bd_ports rp_clk] [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
set rp_clk_freq [get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]]
if {$rp_clk_freq eq ""} {
    set rp_clk_freq 100000000
}
set_property CONFIG.FREQ_HZ $rp_clk_freq [get_bd_ports rp_clk]
set_property CONFIG.ASSOCIATED_BUSIF {rp_s_axis:rp_m_axis} [get_bd_ports rp_clk]
set_property CONFIG.ASSOCIATED_RESET {rp_resetn} [get_bd_ports rp_clk]

connect_bd_net [get_bd_ports rp_resetn] [get_bd_pins axi_gpio_reset_0/gpio_io_o]

connect_bd_net [get_bd_pins axi_gpio_decouple_0/gpio_io_o] [get_bd_pins dfx_decoupler_in_0/decouple]
connect_bd_net [get_bd_pins axi_gpio_decouple_0/gpio_io_o] [get_bd_pins dfx_decoupler_out_0/decouple]
connect_bd_net [get_bd_pins dfx_decoupler_in_0/decouple_status] [get_bd_pins decouple_status_and_0/Op1]
connect_bd_net [get_bd_pins dfx_decoupler_out_0/decouple_status] [get_bd_pins decouple_status_and_0/Op2]
connect_bd_net [get_bd_pins decouple_status_and_0/Res] [get_bd_pins axi_gpio_decouple_0/gpio2_io_i]

foreach pin_name [list \
    axi_dma_0/s_axi_lite_aclk \
    axi_dma_0/m_axi_mm2s_aclk \
    axi_dma_0/m_axi_s2mm_aclk \
    axi_dma_0/m_axis_mm2s_aclk \
    axi_dma_0/s_axis_s2mm_aclk \
    axis_data_fifo_0/s_axis_aclk \
    axis_data_fifo_0/m_axis_aclk \
    axi_mem_smc_0/aclk \
    axi_mem_smc_0/s00_aclk \
    axi_mem_smc_0/s01_aclk \
    axi_mem_smc_0/m00_aclk \
    axi_gpio_decouple_0/s_axi_aclk \
    axi_gpio_reset_0/s_axi_aclk \
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
    axi_mem_smc_0/aresetn \
    axi_mem_smc_0/s00_aresetn \
    axi_mem_smc_0/s01_aresetn \
    axi_mem_smc_0/m00_aresetn \
    axi_gpio_decouple_0/s_axi_aresetn \
    axi_gpio_reset_0/s_axi_aresetn \
] {
    set pin_obj [get_bd_pins -quiet $pin_name]
    if {[llength $pin_obj] > 0 && [llength [get_bd_nets -quiet -of_objects $pin_obj]] == 0} {
        if {$pin_name eq "axi_dma_0/axi_resetn" ||
            $pin_name eq "axi_gpio_decouple_0/s_axi_aresetn" ||
            $pin_name eq "axi_gpio_reset_0/s_axi_aresetn"} {
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
validate_bd_design
save_bd_design

generate_target all [get_files design_1.bd]
set wrapper_file [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper_file
set wrapper_top [file rootname [file tail $wrapper_file]]

set generated_dfx_src_dir [file normalize [file join $build_dir generated_dfx_src]]
set generated_dfx_constraints_dir [file normalize [file join $build_dir generated_dfx_constraints]]
set rp_default_module "dut_64x64_axis_rp"
set rp_xor_module "dut_64x64_axis_rp_xor"
set top_module "dut_64x64_axis_dfx_top"
set rp_default_file [file normalize [file join $generated_dfx_src_dir ${rp_default_module}.v]]
set rp_xor_file [file normalize [file join $generated_dfx_src_dir ${rp_xor_module}.v]]
set top_file [file normalize [file join $generated_dfx_src_dir ${top_module}.v]]
set pblock_name "pblock_u_rp"
set rp_instance_name "u_rp"
set pblock_range [get_default_dfx_pblock_range $part]
set pblock_xdc_file [file normalize [file join $generated_dfx_constraints_dir ${pblock_name}.xdc]]

file mkdir $generated_dfx_src_dir
file mkdir $generated_dfx_constraints_dir
generate_dfx_rp_module $rp_default_file $rp_default_module $mul_bd_wrapper_module
generate_dfx_rp_module $rp_xor_file $rp_xor_module $xor_bd_wrapper_module
generate_dfx_top_module $top_file $top_module $wrapper_top $rp_default_module
generate_dfx_pblock_xdc $pblock_xdc_file $pblock_name $rp_instance_name $pblock_range

add_files -norecurse $rp_default_file $rp_xor_file $top_file
add_files -fileset constrs_1 -norecurse $pblock_xdc_file
set pblock_xdc_obj [get_files $pblock_xdc_file]
set_property used_in_synthesis false $pblock_xdc_obj
set_property used_in_implementation true $pblock_xdc_obj
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

set partition_def [create_partition_def -name rp_partition -module $rp_default_module]
create_reconfig_module -name rp_mul -partition_def $partition_def -define_from $rp_default_module
create_reconfig_module -name rp_xor -partition_def $partition_def -define_from $rp_xor_module
set_property default_rm rp_mul $partition_def

create_pr_configuration -name config_mul -partitions [list u_rp:rp_mul]
create_pr_configuration -name config_xor -partitions [list u_rp:rp_xor]
current_pr_configuration config_mul
set_property pr_configuration config_mul [get_runs impl_1]

set impl_flow [get_property FLOW [get_runs impl_1]]
if {$impl_flow eq ""} {
    set impl_flow {Vivado Implementation 2023}
}
if {[llength [get_runs -quiet impl_config_xor]] == 0} {
    create_run impl_config_xor -parent_run impl_1 -flow $impl_flow -pr_config config_xor
}
set_property pr_configuration config_xor [get_runs impl_config_xor]

puts "Generated DFX top module: $top_file"
puts "Generated default RP module: $rp_default_file"
puts "Generated XOR RM module: $rp_xor_file"
puts "Generated DFX PBLOCK constraints: $pblock_xdc_file"
puts "Default DFX PBLOCK range: $pblock_range"
puts "Active PR configuration: [current_pr_configuration]"
