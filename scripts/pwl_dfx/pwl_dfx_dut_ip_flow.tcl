# Vivado Tcl helper:
# - Locate exported PWL HLS IP variants built under HW/build/vitis_hls
# - Generate an XCI instance for the selected interpolator
# - Generate a wrapper module with a standard DFX-friendly AXI boundary

set ::pwl_dfx_dut_ip_flow_script_dir [file normalize [file dirname [info script]]]
set ::pwl_dut_catalog_script [file normalize [file join $::pwl_dfx_dut_ip_flow_script_dir .. pwl_dut_catalog.tcl]]

if {![file exists $::pwl_dut_catalog_script]} {
    error "Shared DUT catalog helper not found: $::pwl_dut_catalog_script"
}
source $::pwl_dut_catalog_script

proc write_text_file {file_path content} {
    set fh [open $file_path w]
    puts -nonewline $fh $content
    close $fh
}

proc get_repo_root {} {
    return [file normalize [file join $::pwl_dfx_dut_ip_flow_script_dir .. ..]]
}

proc pwl_port_specs {} {
    return [list \
        [dict create dir input  width ""     name ap_clk] \
        [dict create dir input  width ""     name ap_rst_n] \
        [dict create dir input  width "5:0"  name s_axi_control_AWADDR] \
        [dict create dir input  width "2:0"  name s_axi_control_AWPROT] \
        [dict create dir input  width ""     name s_axi_control_AWVALID] \
        [dict create dir output width ""     name s_axi_control_AWREADY] \
        [dict create dir input  width "31:0" name s_axi_control_WDATA] \
        [dict create dir input  width "3:0"  name s_axi_control_WSTRB] \
        [dict create dir input  width ""     name s_axi_control_WVALID] \
        [dict create dir output width ""     name s_axi_control_WREADY] \
        [dict create dir output width "1:0"  name s_axi_control_BRESP] \
        [dict create dir output width ""     name s_axi_control_BVALID] \
        [dict create dir input  width ""     name s_axi_control_BREADY] \
        [dict create dir input  width "5:0"  name s_axi_control_ARADDR] \
        [dict create dir input  width "2:0"  name s_axi_control_ARPROT] \
        [dict create dir input  width ""     name s_axi_control_ARVALID] \
        [dict create dir output width ""     name s_axi_control_ARREADY] \
        [dict create dir output width "31:0" name s_axi_control_RDATA] \
        [dict create dir output width "1:0"  name s_axi_control_RRESP] \
        [dict create dir output width ""     name s_axi_control_RVALID] \
        [dict create dir input  width ""     name s_axi_control_RREADY] \
        [dict create dir output width ""     name interrupt] \
        [dict create dir output width ""     name m_axi_gmem0_AWVALID] \
        [dict create dir input  width ""     name m_axi_gmem0_AWREADY] \
        [dict create dir output width "63:0" name m_axi_gmem0_AWADDR] \
        [dict create dir output width "0:0"  name m_axi_gmem0_AWID] \
        [dict create dir output width "7:0"  name m_axi_gmem0_AWLEN] \
        [dict create dir output width "2:0"  name m_axi_gmem0_AWSIZE] \
        [dict create dir output width "1:0"  name m_axi_gmem0_AWBURST] \
        [dict create dir output width ""     name m_axi_gmem0_AWLOCK] \
        [dict create dir output width "3:0"  name m_axi_gmem0_AWCACHE] \
        [dict create dir output width "2:0"  name m_axi_gmem0_AWPROT] \
        [dict create dir output width "3:0"  name m_axi_gmem0_AWQOS] \
        [dict create dir output width "3:0"  name m_axi_gmem0_AWREGION] \
        [dict create dir output width ""     name m_axi_gmem0_WVALID] \
        [dict create dir input  width ""     name m_axi_gmem0_WREADY] \
        [dict create dir output width "31:0" name m_axi_gmem0_WDATA] \
        [dict create dir output width "3:0"  name m_axi_gmem0_WSTRB] \
        [dict create dir output width ""     name m_axi_gmem0_WLAST] \
        [dict create dir output width ""     name m_axi_gmem0_ARVALID] \
        [dict create dir input  width ""     name m_axi_gmem0_ARREADY] \
        [dict create dir output width "63:0" name m_axi_gmem0_ARADDR] \
        [dict create dir output width "0:0"  name m_axi_gmem0_ARID] \
        [dict create dir output width "7:0"  name m_axi_gmem0_ARLEN] \
        [dict create dir output width "2:0"  name m_axi_gmem0_ARSIZE] \
        [dict create dir output width "1:0"  name m_axi_gmem0_ARBURST] \
        [dict create dir output width ""     name m_axi_gmem0_ARLOCK] \
        [dict create dir output width "3:0"  name m_axi_gmem0_ARCACHE] \
        [dict create dir output width "2:0"  name m_axi_gmem0_ARPROT] \
        [dict create dir output width "3:0"  name m_axi_gmem0_ARQOS] \
        [dict create dir output width "3:0"  name m_axi_gmem0_ARREGION] \
        [dict create dir input  width ""     name m_axi_gmem0_RVALID] \
        [dict create dir output width ""     name m_axi_gmem0_RREADY] \
        [dict create dir input  width "31:0" name m_axi_gmem0_RDATA] \
        [dict create dir input  width ""     name m_axi_gmem0_RLAST] \
        [dict create dir input  width "0:0"  name m_axi_gmem0_RID] \
        [dict create dir input  width "1:0"  name m_axi_gmem0_RRESP] \
        [dict create dir input  width ""     name m_axi_gmem0_BVALID] \
        [dict create dir output width ""     name m_axi_gmem0_BREADY] \
        [dict create dir input  width "1:0"  name m_axi_gmem0_BRESP] \
        [dict create dir input  width "0:0"  name m_axi_gmem0_BID] \
        [dict create dir output width ""     name m_axi_gmem1_AWVALID] \
        [dict create dir input  width ""     name m_axi_gmem1_AWREADY] \
        [dict create dir output width "63:0" name m_axi_gmem1_AWADDR] \
        [dict create dir output width "0:0"  name m_axi_gmem1_AWID] \
        [dict create dir output width "7:0"  name m_axi_gmem1_AWLEN] \
        [dict create dir output width "2:0"  name m_axi_gmem1_AWSIZE] \
        [dict create dir output width "1:0"  name m_axi_gmem1_AWBURST] \
        [dict create dir output width ""     name m_axi_gmem1_AWLOCK] \
        [dict create dir output width "3:0"  name m_axi_gmem1_AWCACHE] \
        [dict create dir output width "2:0"  name m_axi_gmem1_AWPROT] \
        [dict create dir output width "3:0"  name m_axi_gmem1_AWQOS] \
        [dict create dir output width "3:0"  name m_axi_gmem1_AWREGION] \
        [dict create dir output width ""     name m_axi_gmem1_WVALID] \
        [dict create dir input  width ""     name m_axi_gmem1_WREADY] \
        [dict create dir output width "31:0" name m_axi_gmem1_WDATA] \
        [dict create dir output width "3:0"  name m_axi_gmem1_WSTRB] \
        [dict create dir output width ""     name m_axi_gmem1_WLAST] \
        [dict create dir output width ""     name m_axi_gmem1_ARVALID] \
        [dict create dir input  width ""     name m_axi_gmem1_ARREADY] \
        [dict create dir output width "63:0" name m_axi_gmem1_ARADDR] \
        [dict create dir output width "0:0"  name m_axi_gmem1_ARID] \
        [dict create dir output width "7:0"  name m_axi_gmem1_ARLEN] \
        [dict create dir output width "2:0"  name m_axi_gmem1_ARSIZE] \
        [dict create dir output width "1:0"  name m_axi_gmem1_ARBURST] \
        [dict create dir output width ""     name m_axi_gmem1_ARLOCK] \
        [dict create dir output width "3:0"  name m_axi_gmem1_ARCACHE] \
        [dict create dir output width "2:0"  name m_axi_gmem1_ARPROT] \
        [dict create dir output width "3:0"  name m_axi_gmem1_ARQOS] \
        [dict create dir output width "3:0"  name m_axi_gmem1_ARREGION] \
        [dict create dir input  width ""     name m_axi_gmem1_RVALID] \
        [dict create dir output width ""     name m_axi_gmem1_RREADY] \
        [dict create dir input  width "31:0" name m_axi_gmem1_RDATA] \
        [dict create dir input  width ""     name m_axi_gmem1_RLAST] \
        [dict create dir input  width "0:0"  name m_axi_gmem1_RID] \
        [dict create dir input  width "1:0"  name m_axi_gmem1_RRESP] \
        [dict create dir input  width ""     name m_axi_gmem1_BVALID] \
        [dict create dir output width ""     name m_axi_gmem1_BREADY] \
        [dict create dir input  width "1:0"  name m_axi_gmem1_BRESP] \
        [dict create dir input  width "0:0"  name m_axi_gmem1_BID] \
    ]
}

proc emit_module_ports {port_specs indent} {
    set lines {}
    set count [llength $port_specs]
    set idx 0
    foreach spec $port_specs {
        incr idx
        set dir [dict get $spec dir]
        set width [dict get $spec width]
        set name [dict get $spec name]
        set width_text ""
        if {$width ne ""} {
            set width_text [format { [%s]} $width]
        }
        set comma ","
        if {$idx == $count} {
            set comma ""
        }
        lappend lines [format "%s%s wire%s %s%s" $indent $dir $width_text $name $comma]
    }
    return [join $lines "\n"]
}

proc emit_wire_decls {wire_specs indent} {
    set lines {}
    foreach spec $wire_specs {
        lassign $spec width name
        set width_text ""
        if {$width ne ""} {
            set width_text [format { [%s]} $width]
        }
        lappend lines [format "%swire%s %s;" $indent $width_text $name]
    }
    return [join $lines "\n"]
}

proc resolve_pwl_dut {dut_impl} {
    set repo_root [get_repo_root]
    return [pwl_get_dut_info $repo_root $dut_impl]
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
        error "Selected PWL HLS IP was not found in the local IP catalog: $dut_vlnv"
    }

    create_ip -vlnv $dut_vlnv -module_name $xci_module_name -dir $xci_output_dir -force
    set ip_obj [get_ips $xci_module_name]
    if {[llength $ip_obj] == 0} {
        error "Failed to create an IP instance for $dut_vlnv"
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

proc generate_pwl_wrapper_module {wrapper_file wrapper_module_name xci_module_name} {
    set port_specs [pwl_port_specs]
    set module_ports [emit_module_ports $port_specs "    "]
    set internal_wires [emit_wire_decls [list \
        [list "1:0" m_axi_gmem0_AWLOCK_int] \
        [list "1:0" m_axi_gmem0_ARLOCK_int] \
        [list "0:0" m_axi_gmem0_WID_unused] \
        [list "1:0" m_axi_gmem1_AWLOCK_int] \
        [list "1:0" m_axi_gmem1_ARLOCK_int] \
        [list "0:0" m_axi_gmem1_WID_unused] \
    ] "    "]

    set connection_lines {}
    foreach spec $port_specs {
        set name [dict get $spec name]
        if {$name eq "s_axi_control_AWPROT" || $name eq "s_axi_control_ARPROT"} {
            continue
        }
        switch -- $name {
            m_axi_gmem0_AWLOCK {
                lappend connection_lines "        .m_axi_gmem0_AWLOCK (m_axi_gmem0_AWLOCK_int),"
            }
            m_axi_gmem0_ARLOCK {
                lappend connection_lines "        .m_axi_gmem0_ARLOCK (m_axi_gmem0_ARLOCK_int),"
            }
            m_axi_gmem1_AWLOCK {
                lappend connection_lines "        .m_axi_gmem1_AWLOCK (m_axi_gmem1_AWLOCK_int),"
            }
            m_axi_gmem1_ARLOCK {
                lappend connection_lines "        .m_axi_gmem1_ARLOCK (m_axi_gmem1_ARLOCK_int),"
            }
            default {
                lappend connection_lines [format "        .%s (%s)," $name $name]
            }
        }
    }
    lappend connection_lines "        .m_axi_gmem0_WID    (m_axi_gmem0_WID_unused),"
    lappend connection_lines "        .m_axi_gmem1_WID    (m_axi_gmem1_WID_unused)"
    set connection_text [join $connection_lines "\n"]

    set wrapper_template [format {`timescale 1ns / 1ps

module %s(
%s
);

%s

    assign m_axi_gmem0_AWLOCK = m_axi_gmem0_AWLOCK_int[0];
    assign m_axi_gmem0_ARLOCK = m_axi_gmem0_ARLOCK_int[0];
    assign m_axi_gmem1_AWLOCK = m_axi_gmem1_AWLOCK_int[0];
    assign m_axi_gmem1_ARLOCK = m_axi_gmem1_ARLOCK_int[0];

    %s u_ip (
%s
    );
endmodule
} $wrapper_module_name $module_ports $internal_wires $xci_module_name $connection_text]

    write_text_file $wrapper_file $wrapper_template
}

proc pwl_top_wire_name {port_name} {
    switch -- $port_name {
        ap_clk {
            return "rp_clk"
        }
        ap_rst_n {
            return "rp_resetn"
        }
        interrupt {
            return "rp_interrupt"
        }
        default {
            return "rp_[string tolower $port_name]"
        }
    }
}

proc pwl_static_wrapper_port_name {port_name} {
    switch -- $port_name {
        ap_clk {
            return "rp_clk"
        }
        ap_rst_n {
            return "rp_resetn"
        }
        default {
            return "rp_[string tolower $port_name]"
        }
    }
}

proc generate_pwl_rp_module {file_path module_name dut_wrapper_module} {
    set port_specs [pwl_port_specs]
    set module_ports [emit_module_ports $port_specs "    "]

    set connection_lines {}
    set count [llength $port_specs]
    set idx 0
    foreach spec $port_specs {
        incr idx
        set name [dict get $spec name]
        set comma ","
        if {$idx == $count} {
            set comma ""
        }
        lappend connection_lines [format "        .%s (%s)%s" $name $name $comma]
    }
    set connection_text [join $connection_lines "\n"]

    set rp_template [format {`timescale 1ns / 1ps

module %s(
%s
);

    %s u_dut (
%s
    );
endmodule
} $module_name $module_ports $dut_wrapper_module $connection_text]

    write_text_file $file_path $rp_template
}

proc generate_pwl_dfx_top_module {file_path top_module_name static_wrapper_module rp_module_name} {
    set port_specs [pwl_port_specs]

    set wire_specs {}
    foreach spec $port_specs {
        set width [dict get $spec width]
        set name [dict get $spec name]
        lappend wire_specs [list $width [pwl_top_wire_name $name]]
    }
    set wire_text [emit_wire_decls $wire_specs "    "]

    set static_port_specs {}
    foreach spec $port_specs {
        if {[dict get $spec name] ne "interrupt"} {
            lappend static_port_specs $spec
        }
    }

    set static_connection_lines {}
    set static_count [llength $static_port_specs]
    set static_idx 0
    foreach spec $static_port_specs {
        incr static_idx
        set port_name [dict get $spec name]
        set wire_name [pwl_top_wire_name $port_name]
        set comma ","
        if {$static_idx == $static_count} {
            set comma ""
        }
        lappend static_connection_lines [format "        .%s (%s)%s" [pwl_static_wrapper_port_name $port_name] $wire_name $comma]
    }

    set rp_connection_lines {}
    set rp_count [llength $port_specs]
    set rp_idx 0
    foreach spec $port_specs {
        incr rp_idx
        set port_name [dict get $spec name]
        set wire_name [pwl_top_wire_name $port_name]

        set comma ","
        if {$rp_idx == $rp_count} {
            set comma ""
        }
        lappend rp_connection_lines [format "        .%s (%s)%s" $port_name $wire_name $comma]
    }

    set static_connection_text [join $static_connection_lines "\n"]
    set rp_connection_text [join $rp_connection_lines "\n"]

    set top_template [format {`timescale 1ns / 1ps

module %s;
%s

    %s u_static (
%s
    );

    (* keep_hierarchy = "yes" *)
    %s u_rp (
%s
    );
endmodule
} $top_module_name $wire_text $static_wrapper_module $static_connection_text $rp_module_name $rp_connection_text]

    write_text_file $file_path $top_template
}

proc package_dut_ip {dut_impl part build_dir} {
    set build_dir [file normalize $build_dir]
    set dut_info [resolve_pwl_dut $dut_impl]

    set ip_repo_dir [dict get $dut_info hls_ip_dir]
    set dut_vlnv [dict get $dut_info dut_vlnv]
    set ip_name [dict get $dut_info ip_name]
    set wrapper_module_name [dict get $dut_info wrapper_module_name]

    set generated_src_dir [file normalize [file join $build_dir generated_ip_src]]
    set generated_wrapper_file [file normalize [file join $generated_src_dir ${wrapper_module_name}.v]]
    file mkdir $generated_src_dir

    lassign [generate_dut_xci $ip_name $dut_vlnv $ip_repo_dir $part $build_dir] xci_file xci_module_name
    generate_pwl_wrapper_module $generated_wrapper_file $wrapper_module_name $xci_module_name

    return [list \
        $ip_repo_dir \
        $dut_vlnv \
        $ip_name \
        $xci_file \
        $generated_wrapper_file \
        $wrapper_module_name \
        $xci_module_name \
    ]
}

if {[file tail [info script]] eq [file tail $argv0]} {
    if {$argc < 3} {
        error "Usage: pwl_dfx_dut_ip_flow.tcl <dut> <part> <build_dir>"
    }

    set dut_impl [string tolower [lindex $argv 0]]
    set part [string trim [lindex $argv 1]]
    set build_dir [lindex $argv 2]

    lassign [package_dut_ip $dut_impl $part $build_dir] \
        ip_repo_dir \
        dut_vlnv \
        ip_name \
        xci_file \
        wrapper_file \
        wrapper_module_name \
        xci_module_name
    puts "Packaged DUT IP: $dut_vlnv"
    puts "IP name: $ip_name"
    puts "IP repository: $ip_repo_dir"
    puts "Generated XCI: $xci_file"
    puts "Generated XCI module: $xci_module_name"
    puts "Generated wrapper: $wrapper_file"
    puts "Generated wrapper module: $wrapper_module_name"
}
