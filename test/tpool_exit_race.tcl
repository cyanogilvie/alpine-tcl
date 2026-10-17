# Reproduces the Thread package's tpool exit race (patches/thread/tpool-worker-exit.patch).
#
#	tclsh tpool_exit_race.tcl ?-runs n? ?-thread /path/to/libtcl9thread3.0.x.so?
#
# Runs n child processes (default 50) that each start a 4 worker tpool and
# exit, and reports how many of them crashed.  Exits 1 if any did.  -thread
# loads that build of Thread instead of the installed one.
#
# Without the patch, TpoolRelease (called by Thread's exit handler) returns
# while the workers are still deleting their interps.  Tcl_Exit's later
# exit handlers then run concurrently with the workers' teardown:
# ClockFinalize finalizes ClockFmtMutex while a worker's clock command
# delete proc holds it, and the worker segfaults unlocking it.  The child
# keeps many clock format storages alive, so ClockFinalize holds the mutex
# long enough to hit the race in most runs (cftcl 0.10.24 on arm64: about 3
# in 4 runs crash unpatched, none patched).
#
# Each crash dumps core: on a devinstance the core handler keeps at most 5 an
# hour of one program, and logs the rest as discarded.

proc child {thread_lib} {
	if {$thread_lib ne ""} {
		load $thread_lib Thread
	}
	package require Thread

	set keep {}
	for {set i 0} {$i < 100000} {incr i} {
		set f "%Y $i"
		clock format 0 -format $f -gmt 1
		lappend keep $f
	}

	tpool::create -minworkers 4 -maxworkers 4
	exit 0
}

proc main {argv} {
	set runs		50
	set thread_lib	""
	foreach {opt val} $argv {
		switch -- $opt {
			-runs	{set runs $val}
			-thread	{set thread_lib [file normalize $val]}
			default	{error "usage: [file tail [info script]] ?-runs n? ?-thread lib?"}
		}
	}

	set results	{}
	for {set i 0} {$i < $runs} {incr i} {
		try {
			exec [info nameofexecutable] [info script] -child $thread_lib 2>@1
		} trap {CHILDKILLED} {- options} {
			dict incr results "killed by [lindex [dict get $options -errorcode] 2]"
		} trap {CHILDSTATUS} {- options} {
			dict incr results "exit status [lindex [dict get $options -errorcode] 2]"
		} on ok {} {
			dict incr results ok
		}
	}

	puts "Thread [expr {$thread_lib eq "" ? "(installed)" : $thread_lib}], $runs runs:"
	dict for {result count} $results {
		puts [format {  %-20s %d} $result $count]
	}
	exit [expr {[dict size $results] == 1 && [dict exists $results ok] ? 0 : 1}]
}

if {[lindex $argv 0] eq "-child"} {
	child [lindex $argv 1]
} else {
	main $argv
}

# vim: ft=tcl ts=4 shiftwidth=4 noexpandtab
