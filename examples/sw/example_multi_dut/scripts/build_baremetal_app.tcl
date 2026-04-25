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

set platform_name "dut64_multi_platform"
set domain_name   "standalone_domain"
set app_name      "dut64_multi_dma_cli"

if {$action ni {"platform" "app" "build"}} {
    error "Unsupported action '$action'. Supported actions: platform app build"
}
if {$flow_name ne "multi_dut"} {
    error "Unsupported flow '$flow_name'. Supported flow: multi_dut"
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
    puts "Creating standalone multi-DUT platform in $workspace"
    platform create -name $platform_name \
        -hw $xsa_file \
        -proc psu_cortexa53_0 \
        -os standalone \
        -no-boot-bsp
    platform active $platform_name
    domain active $domain_name
    if {$part eq "xck26-sfvc784-2LV-c"} {
        bsp config stdin psu_uart_1
        bsp config stdout psu_uart_1
        bsp write
    }
    platform generate
    exit
}

platform active $platform_name

if {$action eq "app"} {
    puts "Creating multi-DUT application in $workspace"
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
    app config -name $app_name define-compiler-symbols APP_DUT_MULTI
    exit
}

puts "Building multi-DUT application in $workspace"
app build -name $app_name
