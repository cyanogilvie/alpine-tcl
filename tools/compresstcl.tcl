package require brotli

proc compress fn {
	if {[file size $fn] < 400} return
	set h	[open $fn rb]
	try {
		set bytes	[read $h]
	} finally {
		close $h
	}

	if {[string match *\x1A* $bytes]} return
	set h	[open $fn r]
	try {
		set script	[read $h]
	} finally {
		close $h
	}

	set h	[open $fn w]
	try {
		puts $h {apply {{} {set h [open [info script] rb]
set b [try {read $h} finally {close $h}]
set e [string first \x1A $b]
uplevel 1 [encoding convertfrom utf-8 [package require brotli;brotli::decompress [string range $b $e+1 end]]]}}
}
		puts -nonewline $h \x1A
		chan configure $h -translation binary
		puts -nonewline $h [package require brotli; brotli::compress -quality 11 [encoding convertto utf-8 $script]]
	} finally {
		close $h
	}
}

set queue	$argv
while {[llength $queue]} {
	set queue	[lassign $queue e]
	switch -exact -- [file type $e] {
		directory {
			lappend queue {*}[glob [file join $e *]]
		}
		file {
			if {[file extension $e] ni {.tcl .tm} || [file tail $e] eq "pkgIndex.tcl"} continue
			compress $e
		}
	}
}

# vim: ft=tcl ts=4 sw=4 foldmethod=marker foldmarker=<<<,>>> noexpandtab
