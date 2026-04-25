# XSCT batch flow:
# - Create a standalone platform from an exported XSA
# - Create an empty application
# - Copy repository sources into the app
# - Build the application

if {$argc < 6} {
    error "Usage: build_baremetal_app.tcl <action> <flow> <part> <xsa> <workspace> <app_src>"
}

set action    [string tolower [lindex $argv 0]]
set flow_name [string tolower [lindex $argv 1]]
set part      [string trim [lindex $argv 2]]
set xsa_file  [file normalize [lindex $argv 3]]
set workspace [file normalize [lindex $argv 4]]
set app_src   [file normalize [lindex $argv 5]]

set platform_name "dut64_dfx_platform"
set domain_name   "standalone_domain"
set app_name      "dut64_dfx_dma_cli"

proc find_host_tool {tool_name} {
    if {[auto_execok $tool_name] ne ""} {
        return $tool_name
    }
    if {[info exists ::env(XILINX_VITIS)]} {
        set tool_path [file join $::env(XILINX_VITIS) gnu aarch64 lin aarch64-none bin $tool_name]
        if {[file executable $tool_path]} {
            return $tool_path
        }
    }
    error "Required host tool not found in PATH or XILINX_VITIS: $tool_name"
}

proc run_logged {argv} {
    puts [join $argv " "]
    if {[catch {exec {*}$argv 2>@1} result options]} {
        if {$result ne ""} {
            puts $result
        }
        return -options $options $result
    }
    if {$result ne ""} {
        puts $result
    }
    return $result
}

if {$action ni {"platform" "app" "build"}} {
    error "Unsupported action '$action'. Supported actions: platform app build"
}
if {$flow_name ne "dfx"} {
    error "Unsupported flow '$flow_name'. Supported flow: dfx"
}
if {![file exists $xsa_file]} {
    error "XSA not found: $xsa_file"
}
if {![file exists $app_src]} {
    error "Application source not found: $app_src"
}

if {$action eq "platform"} {
    file delete -force $workspace
}

file mkdir $workspace
setws $workspace

if {$action eq "platform"} {
    puts "Creating standalone DFX platform in $workspace"
    platform create -name $platform_name \
        -hw $xsa_file \
        -proc psu_cortexa53_0 \
        -os standalone \
        -no-boot-bsp
    platform active $platform_name
    domain active $domain_name
    foreach lib_name {xilsecure xilfpga xilffs} {
        bsp setlib $lib_name
    }
    bsp config fs_interface 1
    bsp config use_lfn 2
    if {$part eq "xck26-sfvc784-2LV-c"} {
        bsp config stdin psu_uart_1
        bsp config stdout psu_uart_1
    }
    bsp write
    platform generate
    exit
}

platform active $platform_name

if {$action eq "app"} {
    puts "Creating DFX application in $workspace"
    set app_sysproj "${app_name}_system"
    set app_projects {}
    set sys_projects {}

    if {![catch {app list} app_projects] && [lsearch -exact $app_projects $app_name] >= 0} {
        app remove $app_name
    }
    if {![catch {sysproj list} sys_projects] && [lsearch -exact $sys_projects $app_sysproj] >= 0} {
        sysproj remove $app_sysproj
    }

    app create -name $app_name \
        -platform $platform_name \
        -domain $domain_name \
        -template {Empty Application(C)}

    set app_dst [file normalize [file join $workspace $app_name src main.c]]
    file copy -force $app_src $app_dst
    app config -name $app_name define-compiler-symbols APP_DUT_DFX
    exit
}

puts "Building DFX application in $workspace"
set gcc_tool [find_host_tool aarch64-none-elf-gcc]
set size_tool [find_host_tool aarch64-none-elf-size]
set app_dir [file normalize [file join $workspace $app_name]]
set platform_export_dir [file normalize [file join $workspace $platform_name export $platform_name sw $platform_name $domain_name]]
set include_dir [file normalize [file join $platform_export_dir bspinclude include]]
set lib_dir [file normalize [file join $platform_export_dir bsplib lib]]
set linker_script [file normalize [file join $app_dir src lscript.ld]]
set src_file [file normalize [file join $app_dir src main.c]]
set build_dir [file normalize [file join $app_dir Debug]]
set obj_dir [file normalize [file join $build_dir src]]
set obj_file [file normalize [file join $obj_dir main.o]]
set dep_file [file normalize [file join $obj_dir main.d]]
set elf_file [file normalize [file join $build_dir ${app_name}.elf]]

if {![file exists $include_dir]} {
    error "BSP include directory not found: $include_dir"
}
if {![file exists $lib_dir]} {
    error "BSP library directory not found: $lib_dir"
}
if {![file exists $linker_script]} {
    error "Linker script not found: $linker_script"
}

file mkdir $obj_dir

run_logged [list \
    $gcc_tool \
    -Wall \
    -O0 \
    -g3 \
    -c \
    -mcpu=cortex-a53 \
    -MMD \
    -MP \
    -DAPP_DUT_DFX \
    -I$include_dir \
    -ffunction-sections \
    -fdata-sections \
    -o $obj_file \
    $src_file]

run_logged [list \
    $gcc_tool \
    -mcpu=cortex-a53 \
    -Wl,-T,$linker_script \
    -L$lib_dir \
    -Wl,--gc-sections \
    -o $elf_file \
    $obj_file \
    -Wl,--start-group \
    -lxilfpga \
    -lxilsecure \
    -lxilffs \
    -lxil \
    -lgcc \
    -lc \
    -Wl,--end-group]

if {[file exists $dep_file]} {
    puts "Generated dependency file: $dep_file"
}
run_logged [list $size_tool $elf_file]
