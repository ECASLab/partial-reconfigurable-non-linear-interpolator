# Vivado Tcl helper:
# - Package the selected DUT implementation together with the shared AXI wrapper
#   as a custom IP with a DUT-specific top/module name.

set ::example_dut_ip_flow_script_dir [file dirname [info script]]

proc write_text_file {file_path content} {
    set fh [open $file_path w]
    puts -nonewline $fh $content
    close $fh
}

proc generate_bd_wrapper_module {wrapper_file wrapper_module_name xci_module_name} {
    set wrapper_template {
`timescale 1ns / 1ps

module ${wrapper_module_name}(
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET rstn" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    input  wire         clk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rstn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rstn RST" *)
    input  wire         rstn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [127:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire         s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire         s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *)
    input  wire [15:0]  s_axis_tkeep,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [127:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire         m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output wire         m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)
    output wire [15:0]  m_axis_tkeep
);

    ${xci_module_name} u_ip (
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

    write_text_file $wrapper_file [subst $wrapper_template]
}

proc generate_dut_xci {ip_name dut_vlnv ip_repo_dir part build_dir} {
    set xci_module_name "${ip_name}_xci"
    set xci_proj_name "ip_xci_proj_${ip_name}"
    set xci_proj_dir [file normalize [file join $build_dir $xci_proj_name]]
    set xci_output_dir [file normalize [file join $build_dir generated_xci]]

    file mkdir $xci_proj_dir
    file mkdir $xci_output_dir

    create_project $xci_proj_name $xci_proj_dir -part $part -force
    set_property ip_repo_paths [list $ip_repo_dir] [current_project]
    update_ip_catalog

    if {[llength [get_ipdefs -all $dut_vlnv]] == 0} {
        error "Custom DUT IP was not found in local IP catalog while generating XCI: $dut_vlnv"
    }

    create_ip -vlnv $dut_vlnv -module_name $xci_module_name -dir $xci_output_dir -force
    set ip_obj [get_ips $xci_module_name]
    if {[llength $ip_obj] == 0} {
        error "Failed to create IP instance for $dut_vlnv"
    }

    generate_target all $ip_obj
    export_ip_user_files -of_objects $ip_obj -no_script -sync -force

    set xci_file [file normalize [get_property IP_FILE $ip_obj]]
    if {![file exists $xci_file]} {
        error "Expected generated XCI file was not created: $xci_file"
    }

    close_project

    return [list $xci_file $xci_module_name]
}

proc package_dut_ip {dut_impl part build_dir} {
    set script_dir $::example_dut_ip_flow_script_dir
    set project_dir [file normalize [file join $script_dir ..]]
    set build_dir [file normalize $build_dir]

    if {$dut_impl ni {"mul" "xor"}} {
        error "Unsupported DUT '$dut_impl'. Supported DUTs: mul xor"
    }

    set axis_wrapper_template [file normalize [file join $project_dir srcs/dut_64x64_axis_wrapper.v]]
    if {![file exists $axis_wrapper_template]} {
        error "AXI wrapper source not found: $axis_wrapper_template"
    }

    set core_wrapper_template ""
    set rtl_rel_files {}
    if {$dut_impl eq "mul"} {
        set core_wrapper_template [file normalize [file join $project_dir srcs/dut_64x64_mul_wrapper.v]]
        set rtl_rel_files [list \
            srcs/mul8x8.v \
            srcs/mul64x64_segmented_8x8.v \
        ]
    } else {
        set core_wrapper_template [file normalize [file join $project_dir srcs/dut_64x64_xor_wrapper.v]]
        set rtl_rel_files [list \
            srcs/xor64x64_pipelined.v \
        ]
    }
    if {![file exists $core_wrapper_template]} {
        error "DUT wrapper source not found: $core_wrapper_template"
    }

    set rtl_files {}
    foreach rel_path $rtl_rel_files {
        set abs_path [file normalize [file join $project_dir $rel_path]]
        if {![file exists $abs_path]} {
            error "RTL file not found: $abs_path"
        }
        lappend rtl_files $abs_path
    }

    set ip_name "dut_64x64_axis_${dut_impl}"
    set core_module_name "dut_64x64_core_${dut_impl}"
    set xci_module_name "${ip_name}_xci"
    set bd_wrapper_module_name "${ip_name}_bd_wrapper"
    set ip_repo_dir [file normalize [file join $build_dir ip_repo]]
    set ip_root [file normalize [file join $ip_repo_dir ${ip_name}_1_0]]
    set ip_pack_dir [file normalize [file join $build_dir ip_pack_proj_${ip_name}]]
    set generated_src_dir [file normalize [file join $build_dir generated_ip_src]]
    set generated_axis_wrapper [file normalize [file join $generated_src_dir ${ip_name}.v]]
    set generated_core_wrapper [file normalize [file join $generated_src_dir ${core_module_name}.v]]
    set generated_bd_wrapper [file normalize [file join $generated_src_dir ${bd_wrapper_module_name}.v]]

    file mkdir $ip_repo_dir
    file mkdir $ip_root
    file mkdir $ip_pack_dir
    file mkdir $generated_src_dir

    set fh [open $axis_wrapper_template r]
    set axis_wrapper_data [read $fh]
    close $fh
    set axis_wrapper_data [string map [list \
        "module dut_64x64_axis_wrapper #(" "module ${ip_name} #(" \
        "dut_64x64 u_core (" "${core_module_name} u_core (" \
    ] $axis_wrapper_data]
    write_text_file $generated_axis_wrapper $axis_wrapper_data

    set fh [open $core_wrapper_template r]
    set core_wrapper_data [read $fh]
    close $fh
    set core_wrapper_data [string map [list \
        "module dut_64x64(" "module ${core_module_name}(" \
    ] $core_wrapper_data]
    write_text_file $generated_core_wrapper $core_wrapper_data

    create_project $ip_name $ip_pack_dir -part $part -force
    set_property source_mgmt_mode None [current_project]
    add_files -norecurse $generated_axis_wrapper $generated_core_wrapper $rtl_files
    set_property top $ip_name [current_fileset]
    update_compile_order -fileset sources_1

    ipx::package_project -root_dir $ip_root \
        -vendor user.org \
        -library user \
        -taxonomy /UserIP \
        -import_files \
        -force

    set core [ipx::current_core]
    set_property name $ip_name $core
    set_property display_name [string toupper $ip_name] $core
    set_property description "AXI4-Stream wrapped ${dut_impl} DUT" $core
    ipx::save_core $core

    set dut_vlnv [get_property vlnv $core]
    close_project

    lassign [generate_dut_xci $ip_name $dut_vlnv $ip_repo_dir $part $build_dir] xci_file generated_xci_module_name
    generate_bd_wrapper_module $generated_bd_wrapper $bd_wrapper_module_name $generated_xci_module_name

    return [list \
        $ip_repo_dir \
        $dut_vlnv \
        $ip_name \
        $xci_file \
        $generated_bd_wrapper \
        $bd_wrapper_module_name \
        $generated_xci_module_name \
    ]
}

if {[file tail [info script]] eq [file tail $argv0]} {
    if {$argc < 3} {
        error "Usage: example_dut_ip_flow.tcl <dut> <part> <build_dir>"
    }

    set dut_impl [string tolower [lindex $argv 0]]
    set part [string trim [lindex $argv 1]]
    set build_dir [lindex $argv 2]

    lassign [package_dut_ip $dut_impl $part $build_dir] \
        ip_repo_dir \
        dut_vlnv \
        ip_name \
        xci_file \
        bd_wrapper_file \
        bd_wrapper_module_name \
        xci_module_name
    puts "Packaged DUT IP: $dut_vlnv"
    puts "IP name: $ip_name"
    puts "IP repository: $ip_repo_dir"
    puts "Generated XCI: $xci_file"
    puts "Generated XCI module: $xci_module_name"
    puts "Generated BD wrapper: $bd_wrapper_file"
    puts "Generated BD wrapper module: $bd_wrapper_module_name"
}
