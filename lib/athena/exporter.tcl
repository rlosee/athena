#-----------------------------------------------------------------------
# TITLE:
#    exporter.tcl
#
# AUTHOR:
#    Will Duquette
#
# DESCRIPTION:
#    athena(n): Scenario Exporter
#
#    This object is responsible for exporting the scenario as an 
#    order script.  There are two flavors:
#
#    * Normal export, which is a snapshot of the current scenario.
#
#    * History export, which exports the orders in the cif table
#      (this is the classic export mode).
#
#-----------------------------------------------------------------------

snit::type ::athena::exporter {
    #-------------------------------------------------------------------
    # Components

    component adb ;# The athenadb(n) instance

    #-------------------------------------------------------------------
    # Constructor

    # constructor adb_
    #
    # adb_    - The athenadb(n) that owns this instance.
    #
    # Initializes instances of the type.

    constructor {adb_} {
        set adb $adb_
    }

    #-------------------------------------------------------------------
    # Export from CIF
    
    # fromcif scriptFile mapflag
    #
    # scriptFile    Absolute file name to receive script.
    # mapflag       If 0, no map image data is exported.
    #
    # Creates a script of "send" commands from the orders in the
    # CIF.  If the map flag is set to 0, MAP:IMPORT:* orders are changed to
    # MAP:GEOREF orders and only projection information is exported.

    method fromcif {scriptFile {mapflag 0}} {
        # FIRST, get a list of the order data.
        set orders [list]
        set projdict ""

        if {!$mapflag && [$adb exists {SELECT * FROM maps}]} {
            $adb eval {
                SELECT ulat, ulon, llat, llon
                FROM maps
            } row {}

            unset -nocomplain row(*)
            set projdict [array get row]
        }

        $adb eval {
            SELECT time,name,parmdict
            FROM cif
            ORDER BY id
        } {
            if {!$mapflag && [string first "MAP:IMPORT" $name 0] == 0} {
                lappend orders [list "MAP:GEOREF" $projdict]
                continue
            }

            # Save the current order.
            lappend orders [list $name $parmdict]
        }

        # NEXT, if there are no orders or scripts to save, do nothing.
        if {[llength $orders] == 0 && 
            [llength [$adb executive script names]] == 0
        } {
            error "nothing to export"
        }

        # NEXT, get file handle.  We'll throw an error if they
        # use a bad name; that's OK.

        set f [open $scriptFile w]

        # NEXT, write a header
        set adbfile [$adb adbfile]
        if {$adbfile eq ""} {
            set adbfile "unsaved scenario"
        }

        puts $f "# Exporting $adbfile from history"
        puts $f "# Exported @ [clock format [clock seconds]]"
        puts $f "# Written by Athena version [$adb version]"

        # NEXT, save all of the scripts in sequence order
        $self ExportScripts $f

        # NEXT, turn the orders into commands, and save them.
        foreach entry $orders {
            lassign $entry name parmdict

            # FIRST, build option list.  Include only parameters with
            # non-default values.
            set cmd [list send $name]

            set o [$adb order make $name]
            $o setdict $parmdict

            dict for {parm value} [$o prune] {
                lappend cmd -$parm $value
            }

            $o destroy

            puts $f $cmd
        }

        close $f

        return
    }

    # ExportScripts f
    #
    # f   - The output file handle
    #
    # Exports all executive scripts.

    method ExportScripts {f} {
        foreach name [$adb executive script names] {
            puts $f [list script save $name [$adb executive script get $name]]
            if {[$adb executive script auto $name]} {
                puts $f [list script auto $name 1]
            }
        }
    }

    #-------------------------------------------------------------------
    # Export from Current Data

    # fromdata scriptFile mapflag
    #
    # scriptFile  - Absolute file name to receive script
    # mapflag     - if 0, no map image data is exported 
    #
    # Creates a script that will recreate the current scenario.

    method fromdata {scriptFile {mapflag 0}} {
        # FIRST, open the file.  We'll throw an error on a bad file
        # name; that's OK.
        set f [open $scriptFile w]

        # NEXT, save the script, closing the file on error, which
        # will be rethrown automatically.
        try {
            $self ExportFromData $f $mapflag
        } finally {
            catch {close $f}
        }

        return
    }
    
    # ExportFromData f mapflag
    #
    # f        - Output channel on which to write script
    # mapflag  - If 0, only map projection is exported; no data
    #
    # Exports the current scenario to the given file.

    method ExportFromData {f mapflag} {
        # FIRST, write header.
        set adbfile [$adb adbfile]
        if {$adbfile eq ""} {
            set adbfile "unsaved scenario"
        }

        puts $f "# Exporting $adbfile from current data"
        puts $f "# Exported @ [clock format [clock seconds]]"
        puts $f "# Written by Athena version [$adb version]"
        puts $f "#"
        puts $f "# Note: if header has no commands following it, then"
        puts $f "# there was no data of that kind to export."

        # NEXT, Date and Time Parameters
        SectionHeader $f "Date and Time Parameters"
        MakeSend $f SIM:STARTDATE startdate [$adb clock cget -week0]
        MakeSend $f SIM:STARTTICK starttick [$adb clock cget -tick0]

        # NEXT, Model Parameters
        SectionHeader $f "Model Parameters"
        foreach parm [$adb parm nondefaults] {
            MakeSend $f PARM:SET parm $parm value [$adb parm get $parm]
        }

        # NEXT, Map Data and Projection
        if {$mapflag} {
            SectionHeader $f "Map and Projection"
            $self FromRDB $f MAP:IMPORT:DATA  {SELECT * FROM maps}
        } else {
            SectionHeader $f "Projection; No Map Exported"
            $self FromRDB $f MAP:GEOREF {SELECT * FROM maps} \
                {data width height}
        }

        # NEXT, Belief Systems
        SectionHeader $f "Belief Systems"
        FromParms $f BSYS:PLAYBOX:UPDATE gamma [$adb bsys playbox cget -gamma]

        foreach tid [$adb bsys topic ids] {
            FromParms $f BSYS:TOPIC:ADD tid $tid
            FromParms $f BSYS:TOPIC:UPDATE tid $tid \
                {*}[$adb bsys topic get $tid]
        }

        foreach sid [$adb bsys system ids] {
            if {$sid == 1} {
                continue
            }

            puts $f ""
            FromParms $f BSYS:SYSTEM:ADD sid $sid
            FromParms $f BSYS:SYSTEM:UPDATE sid $sid \
                {*}[$adb bsys system get $sid]

            foreach tid [$adb bsys topic ids] {
                if {[$adb bsys belief isdefault [list $sid $tid]]} {
                    continue
                } 

                FromParms $f BSYS:BELIEF:UPDATE bid [list $sid $tid] \
                    {*}[$adb bsys belief get $sid $tid]
            }
        }

        # NEXT, Actors.  Do supports separately, since this field can 
        # link back to actors not yet created.
        SectionHeader $f "Base Entities: Actors"

        $self FromRDB $f ACTOR:CREATE   {SELECT * FROM fmt_actors} supports
        $self FromRDB $f ACTOR:SUPPORTS {SELECT * FROM fmt_actors}

        # NEXT, Neighborhoods
        SectionHeader $f "Base Entities: Neighborhoods"

        $self FromRDB $f NBHOOD:CREATE {
            SELECT * FROM fmt_nbhoods ORDER BY stacking_order
        }

        $self FromRDB $f NBREL:UPDATE {SELECT * FROM fmt_nbrel_mn}

        # NEXT, Civilian Groups
        SectionHeader $f "Base Entities: Civilian Groups"
        $self FromRDB $f CIVGROUP:CREATE {SELECT * FROM fmt_civgroups}

        # NEXT, Force Groups
        SectionHeader $f "Base Entities: Force Groups"
        $self FromRDB $f FRCGROUP:CREATE {SELECT * FROM fmt_frcgroups}

        # NEXT, Organization Groups
        SectionHeader $f "Base Entities: Organization Groups"
        $self FromRDB $f ORGGROUP:CREATE {SELECT * FROM fmt_orggroups}

        # NEXT, Attitudes
        SectionHeader $f "Attitudes"
        $self FromRDB $f COOP:UPDATE   {SELECT * FROM fmt_coop_override}
        $self FromRDB $f HREL:OVERRIDE {SELECT * FROM fmt_hrel_override_view}
        $self FromRDB $f SAT:UPDATE    {SELECT * FROM fmt_sat_override_view}
        $self FromRDB $f VREL:OVERRIDE {SELECT * FROM fmt_vrel_override_view}

        # NEXT, Absits
        SectionHeader $f "Abstract Situations"
        $self FromRDB $f ABSIT:CREATE {SELECT * FROM fmt_absits}

        # NEXT, Economics
        SectionHeader $f "Economics: SAM Inputs"

        dict for {cell value} [$adb econ samparms] {
            MakeSend $f ECON:SAM:GLOBAL id $cell val $value
        }

        # NEXT, Plant Infrastructure
        SectionHeader $f "Plant Infrastructure:"

        $self FromRDB $f PLANT:SHARES:CREATE {SELECT * FROM plants_shares}

        # NEXT, CURSEs
        SectionHeader $f "CURSEs"
        $self FromRDB $f CURSE:CREATE {SELECT * FROM curses}
        $self FromRDB $f CURSE:STATE  {SELECT * FROM curses WHERE state != 'normal'}

        $self FromRDB $f INJECT:COOP:CREATE {
            SELECT * FROM curse_injects WHERE inject_type = 'COOP'
        } {longname ftype gtype}

        $self FromRDB $f INJECT:HREL:CREATE {
            SELECT * FROM curse_injects WHERE inject_type = 'HREL'
        } {longname ftype gtype}

        $self FromRDB $f INJECT:SAT:CREATE {
            SELECT * FROM curse_injects WHERE inject_type = 'SAT'
        } {longname gtype}

        $self FromRDB $f INJECT:VREL:CREATE {
            SELECT * FROM curse_injects WHERE inject_type = 'VREL'
        } {longname gtype atype}

        $self FromRDB $f INJECT:STATE {
            SELECT * FROM fmt_injects WHERE state != 'normal'
        }

        # NEXT, CAPs
        SectionHeader $f "Communication Asset Packages (CAPs)"
        $self FromRDB $f CAP:CREATE    {SELECT * FROM caps} {nlist glist}
        $self FromRDB $f CAP:NBCOV:SET {SELECT * FROM fmt_cap_kn_nonzero}
        $self FromRDB $f CAP:PEN:SET   {SELECT * FROM fmt_capcov_nonzero}
        
        # NEXT, Hooks
        SectionHeader $f "Semantic Hooks"
        $self FromRDB $f HOOK:CREATE       {SELECT * FROM hooks}
        $self FromRDB $f HOOK:TOPIC:CREATE {SELECT * FROM hook_topics} longname
        $self FromRDB $f HOOK:TOPIC:STATE  {
            SELECT * FROM gui_hook_topics WHERE state != 'normal'
        }

        # NEXT, IOMs
        SectionHeader $f "Information Operations Messages (IOMs)"
        $self FromRDB $f IOM:CREATE {SELECT * FROM ioms}
        $self FromRDB $f IOM:STATE  {SELECT * FROM ioms WHERE state != 'normal'}

        $self FromRDB $f PAYLOAD:COOP:CREATE {SELECT * FROM fmt_payloads_COOP} longname
        $self FromRDB $f PAYLOAD:HREL:CREATE {SELECT * FROM fmt_payloads_HREL} longname
        $self FromRDB $f PAYLOAD:SAT:CREATE  {SELECT * FROM fmt_payloads_SAT}  longname
        $self FromRDB $f PAYLOAD:VREL:CREATE {SELECT * FROM fmt_payloads_VREL} longname
        $self FromRDB $f PAYLOAD:STATE {
            SELECT * FROM fmt_payloads WHERE state != 'normal'
        }

        # NEXT, Strategies
        # TBD: Revise this code to use the normal orders with the 
        # "fullnames" instead of numeric ids.
        foreach agent [$adb agent names] {
            SectionHeader $f "Strategy: $agent"
            set s [$adb strategy getname $agent]

            foreach block [$s blocks] {
                Block $f $block
                Conditions $f [$block conditions]
                Tactics    $f [$block tactics]

                # Skip a line between blocks
                puts $f ""
            }
        }

        # NEXT, Scripts
        SectionHeader $f "Executive Scripts"
        $self ExportScripts $f

        # NEXT, end script
        puts $f "\n# *** End of Script ***"
    }

    #-------------------------------------------------------------------
    # Formatting Helper Procs
    
    # SectionHeader f text
    #
    # f       - File handle
    # text    - Header text
    #
    # Returns a section header string, leaving a black line before and
    # after it.

    proc SectionHeader {f text} {
        puts $f "\n#[string repeat - 65]"
        puts $f "# $text\n"
    }

    # MakeSend order parms...
    #
    # f       - File handle
    # order   - Name of an order
    # parms   - Parameter dictionary
    #
    # Given the parms, outputs a [send] command for the order.

    proc MakeSend {f order args} {
        # FIRST, build option list.  Include only parameters with
        # non-default values.
        set cmd [list send $order]

        dict for {parm value} $args {
            lappend cmd -$parm $value
        }

        puts $f $cmd
    }

    # FromParms f order parms...
    #
    # f       - File handle
    # order   - Name of an order
    # parms   - Parameter dictionary
    #
    # Given the parms, outputs a [send] command for the order,
    # removing any unwanted parms from the inputs.

    proc FromParms {f order args} {
        # FIRST, get the parameters we care about.
        set parms [::athena::orders parms $order]

        # NEXT, extract the available parameters from the args.
        dict for {parm value} $args {
            if {$parm ni $parms} {
                dict unset args $parm
            }
        }

        # NEXT, make the order
        MakeSend $f $order {*}$args
    }

    # FromBean order idvar bean
    #
    # order - Update order name
    # idvar - Bean ID parameter name
    # bean  - The bean
    #
    # Returns a dictionary of order parameter options.
    
    proc FromBean {order idvar bean} {
        set parms [::athena::orders parms $order]
        ldelete parms $idvar

        set view [$bean view]
        foreach parm $parms {
            dict set odict -$parm [dict get $view $parm]
        }

        if {[$bean state] eq "disabled"} {
            dict set odict -state disabled
        }

        return $odict
    }

    # Block f block
    #
    # f      - File handle
    # block  - The block to output

    proc Block {f block} {
        set odict [FromBean BLOCK:UPDATE block_id $block]

        puts $f "block add [$block agent] $odict"
    }

    # Conditions f conditions
    #
    # f           - File handle
    # conditions  - List of conditions
    #
    # Writes the conditions.

    proc Conditions {f conditions} {
        foreach c $conditions {
            set odict [FromBean CONDITION:[$c typename] condition_id $c]

            puts $f "condition add - [$c typename] $odict"
        }
    }

    # Tactics f tactics
    #
    # f        - File handle
    # tactics  - List of tactics
    #
    # Writes the tactics.

    proc Tactics {f tactics} {
        foreach t $tactics {
            set odict [FromBean TACTIC:[$t typename] tactic_id $t]

            puts $f "tactic add - [$t typename] $odict"
        }
    }

    #-------------------------------------------------------------------
    # Formatting Helper Methods
    

    # FromRDB f order query ?exceptions?
    #
    # f          - File handle
    # order      - An order name
    # query      - A query returning records matching the order
    # exceptions - A list of order parameters to exclude from the order.
    # 
    # Writes an order for each entry in the view, excluding parameters 
    # listed in exceptions.

    method FromRDB {f order query {exceptions ""}} {
        # FIRST, get the parameters we care about.
        set parms [::athena::orders parms $order]

        foreach exception $exceptions {
            ldelete parms $exception
        }

        # NEXT, output the send commands
        $adb eval $query data {
            unset -nocomplain $data(*)

            # FIRST, Get the parameter dictionary
            set parmdict [dict create]

            foreach parm $parms {
                dict set parmdict $parm $data($parm)
            }

            # NEXT, output the command.
            MakeSend $f $order {*}$parmdict
        }
    }
}

