set source_name "pwl"

set build_mode "PWL_UNIFORM"
if {[info exists ::env(PWL_MODE)]} {
  set build_mode $::env(PWL_MODE)
}
set build_function "PWL_FUNCTION_EXPONENTIAL"
if {[info exists ::env(PWL_FUNCTION)]} {
  set build_function $::env(PWL_FUNCTION)
}
set build_precision "USE_FLOAT32"
if {[info exists ::env(PWL_PRECISION)]} {
  set build_precision $::env(PWL_PRECISION)
}
set build_bus ""
if {[info exists ::env(PWL_BUS)]} {
  set build_bus $::env(PWL_BUS)
}

set top_name [string tolower "${source_name}_${build_mode}_${build_function}_${build_precision}"]
set project_dir "./build/vitis_hls/${top_name}"
set design_dir "."
set tb_dir "tb"

set cflags "-I${design_dir} -I${design_dir}/common -I${design_dir}/coefficients"
if {[info exists ::env(PWL_MODE)]} {
  append cflags " -D$::env(PWL_MODE)"
} else {
  append cflags " -DPWL_UNIFORM"
}
if {[info exists ::env(PWL_FUNCTION)]} {
  append cflags " -D$::env(PWL_FUNCTION)"
} else {
  append cflags " -DPWL_FUNCTION_EXPONENTIAL"
}
if {[info exists ::env(PWL_PRECISION)]} {
  append cflags " -D$::env(PWL_PRECISION)"
} else {
  append cflags " -DUSE_FLOAT32"
}
if {$build_bus ne ""} {
  append cflags " -DBUS=$build_bus"
}
append cflags " -DPWL_TOP=${top_name}"

open_project $project_dir
set_top ${top_name}

add_files "${design_dir}/${source_name}.cpp" -cflags $cflags
add_files -tb "${tb_dir}/${source_name}_tb.cpp" -cflags $cflags

open_solution -flow_target vitis solution
set_part xck26-sfvc784-2LV-c
create_clock -period 300MHz -name default

config_dataflow -strict_mode warning
config_rtl -deadlock_detection sim
config_interface -m_axi_conservative_mode=1
config_interface -m_axi_auto_max_ports=0
config_export -format xo -ipname ${top_name}

csim_design -clean -ldflags "-fuse-ld=gold"
csynth_design
cosim_design
export_design

close_project
puts "HLS for ${top_name} completed successfully"
exit
