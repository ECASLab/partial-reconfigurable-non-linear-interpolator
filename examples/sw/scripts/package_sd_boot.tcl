# XSCT batch flow:
# - Reuse an existing standalone workspace/platform
# - Add the BSP libraries needed for ZynqMP FSBL
# - Create/build FSBL and PMUFW helper applications
# - Package BOOT.BIN for SD-card boot using bootgen

if {$argc < 8} {
    error "Usage: package_sd_boot.tcl <flow> <part> <workspace> <platform> <app> <bit> <output_dir> <bootgen>"
}

set flow_name     [string tolower [lindex $argv 0]]
set part          [string trim [lindex $argv 1]]
set workspace     [file normalize [lindex $argv 2]]
set platform_name [string trim [lindex $argv 3]]
set app_name      [string trim [lindex $argv 4]]
set bit_file      [file normalize [lindex $argv 5]]
set output_dir    [file normalize [lindex $argv 6]]
set bootgen_cmd   [string trim [lindex $argv 7]]

set domain_name     "standalone_domain"
set pmu_domain_name "pmu_domain"
set fsbl_app_name   "${app_name}_fsbl"
set pmufw_app_name  "${app_name}_pmufw"
set fsbl_sysproj    "${fsbl_app_name}_system"
set pmufw_sysproj   "${pmufw_app_name}_system"
set boot_bin_file   [file join $output_dir BOOT.BIN]
set boot_bif_file   [file join $output_dir boot.bif]
set readme_file     [file join $output_dir README.txt]

proc remove_app_if_exists {app_name sysproj_name} {
    set app_projects {}
    set sys_projects {}

    if {![catch {app list} app_projects] && [lsearch -exact $app_projects $app_name] >= 0} {
        puts "Removing existing application $app_name"
        app remove $app_name
    }
    if {![catch {sysproj list} sys_projects] && [lsearch -exact $sys_projects $sysproj_name] >= 0} {
        puts "Removing existing system project $sysproj_name"
        sysproj remove $sysproj_name
    }
}

if {$part ne "xck26-sfvc784-2LV-c"} {
    error "SD-card boot packaging is currently supported only for xck26-sfvc784-2LV-c"
}
if {![file isdirectory $workspace]} {
    error "Workspace not found: $workspace"
}
if {![file exists $bit_file]} {
    error "Bitstream not found: $bit_file"
}
if {$bootgen_cmd eq ""} {
    error "bootgen executable was not provided"
}

set app_elf [file normalize [file join $workspace $app_name Debug ${app_name}.elf]]
if {![file exists $app_elf]} {
    error "Application ELF not found: $app_elf. Run the software build first."
}

file delete -force $output_dir
file mkdir $output_dir

puts "Preparing SD-card boot artifacts for flow '$flow_name'"
puts "Workspace: $workspace"
puts "Platform:  $platform_name"
puts "App:       $app_name"
puts "Output:    $output_dir"

setws $workspace
platform active $platform_name

puts "Configuring BSP libraries needed by Zynq MP FSBL"
domain active $domain_name
foreach lib_name {xilffs xilsecure xilpm} {
    bsp setlib $lib_name
}
bsp write

if {[catch {domain active $pmu_domain_name}]} {
    puts "Creating PMU domain $pmu_domain_name"
    domain create -name $pmu_domain_name -os standalone -proc psu_pmu_0
}

puts "Generating platform after BSP/domain updates"
platform generate

puts "Rebuilding application $app_name after platform update"
app build -name $app_name
if {![file exists $app_elf]} {
    error "Application ELF not found after rebuild: $app_elf"
}

remove_app_if_exists $fsbl_app_name $fsbl_sysproj
remove_app_if_exists $pmufw_app_name $pmufw_sysproj

puts "Creating Zynq MP FSBL application $fsbl_app_name"
app create -name $fsbl_app_name \
    -platform $platform_name \
    -domain $domain_name \
    -template {Zynq MP FSBL}

puts "Creating PMU firmware application $pmufw_app_name"
app create -name $pmufw_app_name \
    -platform $platform_name \
    -domain $pmu_domain_name \
    -template {ZynqMP PMU Firmware}

puts "Building $fsbl_app_name"
app build -name $fsbl_app_name
puts "Building $pmufw_app_name"
app build -name $pmufw_app_name

set fsbl_elf   [file normalize [file join $workspace $fsbl_app_name Debug ${fsbl_app_name}.elf]]
set pmufw_elf  [file normalize [file join $workspace $pmufw_app_name Debug ${pmufw_app_name}.elf]]
set fsbl_copy  [file join $output_dir fsbl.elf]
set pmufw_copy [file join $output_dir pmufw.elf]
set bit_copy   [file join $output_dir [file tail $bit_file]]
set app_copy   [file join $output_dir [file tail $app_elf]]
set partial_copy_names {}

foreach required_file [list $fsbl_elf $pmufw_elf $app_elf $bit_file] {
    if {![file exists $required_file]} {
        error "Required boot component not found: $required_file"
    }
}

file copy -force $fsbl_elf $fsbl_copy
file copy -force $pmufw_elf $pmufw_copy
file copy -force $app_elf $app_copy
file copy -force $bit_file $bit_copy

foreach partial_file [glob -nocomplain -directory [file dirname $bit_file] *_partial.bit] {
    set partial_copy [file join $output_dir [file tail $partial_file]]
    file copy -force $partial_file $partial_copy
    lappend partial_copy_names [file tail $partial_copy]
}

set bif_fh [open $boot_bif_file w]
puts $bif_fh {the_ROM_image:}
puts $bif_fh "{"
puts $bif_fh {  [fsbl_config] a53_x64}
puts $bif_fh {  [bootloader] fsbl.elf}
puts $bif_fh {  [pmufw_image] pmufw.elf}
puts $bif_fh [format {  [destination_device=pl] %s} [file tail $bit_copy]]
puts $bif_fh [format {  [destination_cpu=a53-0, exception_level=el-3, trustzone] %s} [file tail $app_copy]]
puts $bif_fh "}"
close $bif_fh

set readme_fh [open $readme_file w]
puts $readme_fh "SD-card boot artifacts for $flow_name"
puts $readme_fh ""
puts $readme_fh "Copy BOOT.BIN to the FAT boot partition on the SD card."
puts $readme_fh "The other files are kept here to make the packaged image inspectable."
if {$flow_name eq "dfx"} {
    puts $readme_fh ""
    puts $readme_fh "For the DFX software flow, also copy any needed partial bitstreams to the FAT partition."
    if {[llength $partial_copy_names] > 0} {
        puts $readme_fh "This packaging run copied:"
        foreach partial_name $partial_copy_names {
            puts $readme_fh "  - $partial_name"
        }
    } else {
        puts $readme_fh "No *_partial.bit files were found next to the full bitstream, so add them manually if needed."
    }
}
close $readme_fh

set return_dir [pwd]
cd $output_dir
puts "Running bootgen to create $boot_bin_file"
exec -- $bootgen_cmd -arch zynqmp -image [file tail $boot_bif_file] -w -o i [file tail $boot_bin_file]
cd $return_dir

if {![file exists $boot_bin_file]} {
    error "BOOT.BIN was not created: $boot_bin_file"
}

puts "Created BOOT.BIN at $boot_bin_file"
