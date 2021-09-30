if {![info exists standalone] || $standalone} {

  # Read liberty files
  foreach libFile $::env(LIB_FILES) {
    read_liberty $libFile
  }

  # Read lef
  read_lef $::env(TECH_LEF)
  read_lef $::env(SC_LEF)
  if {[info exist ::env(ADDITIONAL_LEFS)]} {
    foreach lef $::env(ADDITIONAL_LEFS) {
      read_lef $lef
    }
  }

  # Read def and sdc
  read_def $::env(RESULTS_DIR)/3_2_place_iop.def
  read_sdc $::env(RESULTS_DIR)/2_floorplan.sdc
  if [file exists $::env(PLATFORM_DIR)/derate.tcl] {
    source $::env(PLATFORM_DIR)/derate.tcl
  }
} else {
  puts "Starting resizer"
}

proc print_banner {header} {
  puts "\n=========================================================================="
  puts "$header"
  puts "--------------------------------------------------------------------------"
}

# Set res and cap
source $::env(PLATFORM_DIR)/setRC.tcl

estimate_parasitics -placement

source $::env(SCRIPTS_DIR)/report_metrics.tcl
report_metrics "resizer pre" false

print_banner "instance_count"
puts [sta::network_leaf_instance_count]

print_banner "pin_count"
puts [sta::network_leaf_pin_count]

puts ""

set_dont_use $::env(DONT_USE_CELLS)

# Do not buffer chip-level designs
if {![info exists ::env(FOOTPRINT)]} {
  puts "Perform port buffering..."
  buffer_ports
}

puts "Perform buffer insertion..."
repair_design



# check the lower boundary of the PLACE_DENSITY and add PLACE_DENSITY_LB_ADDON if it exists
if {[info exist ::env(PLACE_DENSITY_LB_ADDON)]} {
  set place_density_lb [gpl::get_global_placement_uniform_density \
  -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
  -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT)]
  set place_density [expr $place_density_lb + $::env(PLACE_DENSITY_LB_ADDON) + 0.01]
  if {$place_density > 1.0} {
    set place_density 1.0
  }
} else {
  set place_density $::env(PLACE_DENSITY)
}

#####################################################
#### Timing Re-Synthesis ############################
#####################################################
if { [info exist ::env(RESYNTH_TIMING_RECOVER_GLOBAL_PLACE)] && $::env(RESYNTH_TIMING_RECOVER_GLOBAL_PLACE) == 1 } {
  repair_timing
  # pre restructure area/timing report (ideal clocks)
  puts "Post global_place-opt area"
  report_design_area
  report_worst_slack -min -digits 3
  puts "Post global_place-opt wns"
  report_worst_slack -max -digits 3
  puts "Post global_place-opt tns"
  report_tns -digits 3

  set target_slack 0
  set num_tries 0
  set max_tries 5

  while { $num_tries < $max_tries } {

    set current_slack [sta::time_sta_ui [sta::worst_slack_cmd "max"]]

    if { $current_slack > $target_slack } {
      break
    }

    # Timing driven Remap
    # TODO: remove buffers in read blif or experiment with ABC buffering
    # TODO: Use multiple outputs than just one?
    # TODO: More Blob extraction strategies need to be tried - smaller cone, multiple independent blobs
    # TODO: Control blob size as an option to restructure command
    restructure -target timing -liberty_file $::env(DONT_USE_SC_LIB) \
                -work_dir $::env(RESULTS_DIR)

    # Incremental Placement
    # Andy: Have multiple choice nodes, generate cuts (small blobs) for each, have ABC generate multiple netlist for each cut
    #       Placer can then evaluate with multiple netlist options only for choice nodes.
    if { 0 != [llength [array get ::env GLOBAL_PLACEMENT_ARGS]] } {
      global_placement -routability_driven -density $place_density \
                       -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
                       -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
                       $::env(GLOBAL_PLACEMENT_ARGS) \
                       -incremental
    } else {
      global_placement -routability_driven -density $place_density \
                -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
                -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
                -incremental
    }

    # Incremental routing/extraction as applicable
    estimate_parasitics -placement

    # Incremental optimization
    repair_design
    repair_timing -setup

    puts "Post global_place_restructure-opt wns"
    report_worst_slack -max -digits 3
    puts "Post global_place_restructure-opt tns"
    report_tns -digits 3
    # TODO: Reject if timing does not improve
    #       There is a feature in OpenDB to journal the changes and import
    set num_tries [expr $num_tries+1]
  }

}


if { [info exists env(TIE_SEPARATION)] } {
  set tie_separation $env(TIE_SEPARATION)
} else {
  set tie_separation 0
}

# Repair tie lo fanout
puts "Repair tie lo fanout..."
set tielo_cell_name [lindex $env(TIELO_CELL_AND_PORT) 0]
set tielo_lib_name [get_name [get_property [get_lib_cell $tielo_cell_name] library]]
set tielo_pin $tielo_lib_name/$tielo_cell_name/[lindex $env(TIELO_CELL_AND_PORT) 1]
repair_tie_fanout -separation $tie_separation $tielo_pin

# Repair tie hi fanout
puts "Repair tie hi fanout..."
set tiehi_cell_name [lindex $env(TIEHI_CELL_AND_PORT) 0]
set tiehi_lib_name [get_name [get_property [get_lib_cell $tiehi_cell_name] library]]
set tiehi_pin $tiehi_lib_name/$tiehi_cell_name/[lindex $env(TIEHI_CELL_AND_PORT) 1]
repair_tie_fanout -separation $tie_separation $tiehi_pin

# hold violations are not repaired until after CTS

# post report

print_banner "report_floating_nets"
report_floating_nets

source $::env(SCRIPTS_DIR)/report_metrics.tcl
report_metrics "resizer"

print_banner "instance_count"
puts [sta::network_leaf_instance_count]

print_banner "pin_count"
puts [sta::network_leaf_pin_count]

puts ""

if {![info exists standalone] || $standalone} {
  write_def $::env(RESULTS_DIR)/3_3_place_resized.def
  exit
}
