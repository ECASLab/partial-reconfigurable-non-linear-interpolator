set ::pwl_dut_catalog_script_dir [file normalize [file dirname [info script]]]

proc pwl_dut_catalog {} {
    return [dict create \
        exp [dict create \
            id exp \
            function exp \
            precision float32 \
            precision_bits 32 \
            display_name "PWL Nonuniform Exponential Float32" \
            hls_core_name "pwl_pwl_nonuniform_pwl_function_exponential_use_float32" \
        ] \
        sigmoid [dict create \
            id sigmoid \
            function sigmoid \
            precision float32 \
            precision_bits 32 \
            display_name "PWL Nonuniform Sigmoid Float32" \
            hls_core_name "pwl_pwl_nonuniform_pwl_function_sigmoid_use_float32" \
        ] \
        exp_f16 [dict create \
            id exp_f16 \
            function exp \
            precision float16 \
            precision_bits 16 \
            display_name "PWL Nonuniform Exponential Float16" \
            hls_core_name "pwl_pwl_nonuniform_pwl_function_exponential_use_float16" \
        ] \
        sigmoid_f16 [dict create \
            id sigmoid_f16 \
            function sigmoid \
            precision float16 \
            precision_bits 16 \
            display_name "PWL Nonuniform Sigmoid Float16" \
            hls_core_name "pwl_pwl_nonuniform_pwl_function_sigmoid_use_float16" \
        ] \
    ]
}

proc pwl_supported_dut_ids {{slot ""}} {
    switch -- $slot {
        "" {
            return [list exp sigmoid exp_f16 sigmoid_f16]
        }
        exp {
            return [list exp exp_f16]
        }
        sigmoid {
            return [list sigmoid sigmoid_f16]
        }
        default {
            error "Unsupported DUT slot '$slot'. Supported slots: exp sigmoid"
        }
    }
}

proc pwl_default_dut_id {{slot ""}} {
    switch -- $slot {
        "" -
        exp {
            return exp
        }
        sigmoid {
            return sigmoid
        }
        default {
            error "Unsupported DUT slot '$slot'. Supported slots: exp sigmoid"
        }
    }
}

proc pwl_supported_dut_text {{slot ""}} {
    return [join [pwl_supported_dut_ids $slot] {, }]
}

proc pwl_normalize_dut_token {value} {
    set token [string tolower [string trim $value]]
    regsub -all {[^a-z0-9]+} $token "_" token
    regsub -all {_+} $token "_" token
    return [string trim $token "_"]
}

proc pwl_dut_alias_map {} {
    return [dict create \
        exp exp \
        exponential exp \
        pwl_exp exp \
        pwl_exponential exp \
        exp_f32 exp \
        exponential_f32 exp \
        exp_float32 exp \
        exponential_float32 exp \
        exp32 exp \
        sigmoid sigmoid \
        sig sigmoid \
        pwl_sigmoid sigmoid \
        sigmoid_f32 sigmoid \
        sig_f32 sigmoid \
        sigmoid_float32 sigmoid \
        sig32 sigmoid \
        exp_f16 exp_f16 \
        exponential_f16 exp_f16 \
        exp_float16 exp_f16 \
        exponential_float16 exp_f16 \
        exp16 exp_f16 \
        sigmoid_f16 sigmoid_f16 \
        sig_f16 sigmoid_f16 \
        sigmoid_float16 sigmoid_f16 \
        sig16 sigmoid_f16 \
    ]
}

proc pwl_resolve_dut_id {dut_impl {slot ""}} {
    set alias_map [pwl_dut_alias_map]
    set normalized [pwl_normalize_dut_token $dut_impl]
    if {![dict exists $alias_map $normalized]} {
        error "Unsupported DUT '$dut_impl'. Supported DUTs: [pwl_supported_dut_text $slot]"
    }

    set dut_id [dict get $alias_map $normalized]
    if {$slot ne ""} {
        set dut_info [dict get [pwl_dut_catalog] $dut_id]
        if {[dict get $dut_info function] ne $slot} {
            error "Unsupported DUT '$dut_impl' for slot '$slot'. Supported DUTs: [pwl_supported_dut_text $slot]"
        }
    }
    return $dut_id
}

proc pwl_get_dut_info {project_dir dut_impl {slot ""}} {
    set dut_id [pwl_resolve_dut_id $dut_impl $slot]
    set base_info [dict get [pwl_dut_catalog] $dut_id]
    set hls_core_name [dict get $base_info hls_core_name]
    set function_name [dict get $base_info function]
    set hls_ip_dir [file normalize [file join $project_dir HW build vitis_hls $hls_core_name solution impl ip]]
    set component_xml [file normalize [file join $hls_ip_dir component.xml]]
    if {![file exists $component_xml]} {
        error "Expected exported HLS IP was not found: $component_xml\nRun the matching HLS export under final-project/HW before launching this flow."
    }

    return [dict merge $base_info [dict create \
        hls_ip_dir $hls_ip_dir \
        ip_repo_dir $hls_ip_dir \
        component_xml $component_xml \
        dut_vlnv "xilinx.com:hls:${hls_core_name}:1.0" \
        slot_cell_name "pwl_${function_name}_0" \
        ip_name "pwl_${dut_id}" \
        wrapper_module_name "pwl_${dut_id}_axi_wrapper" \
        rp_module_name "pwl_rp_${dut_id}" \
        rm_name "rm_${dut_id}" \
        pr_config_name "config_${dut_id}" \
    ]]
}

proc pwl_multi_dut_project_suffix {exp_dut_id sigmoid_dut_id} {
    if {$exp_dut_id eq "exp" && $sigmoid_dut_id eq "sigmoid"} {
        return ""
    }
    return "_${exp_dut_id}_${sigmoid_dut_id}"
}

proc pwl_dfx_impl_run_name {dut_id} {
    if {$dut_id eq "exp"} {
        return "impl_1"
    }
    return "impl_config_${dut_id}"
}

proc pwl_companion_dut_id {dut_id} {
    set resolved_id [pwl_resolve_dut_id $dut_id]
    switch -- $resolved_id {
        exp {
            return sigmoid
        }
        sigmoid {
            return exp
        }
        exp_f16 {
            return sigmoid_f16
        }
        sigmoid_f16 {
            return exp_f16
        }
        default {
            error "Unsupported DUT '$dut_id'. Supported DUTs: [pwl_supported_dut_text]"
        }
    }
}
