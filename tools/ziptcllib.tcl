package require chantricks

set path	[lindex $argv 0]
set prefix	[file dirname $path]
set tail	[file tail $path]

chantricks with_chan h {file tempfile tmpfn} {
	try {
		puts -nonewline $h [string map [list %tail% [list $tail]] {
			if {[lsearch -exact -stride 2 -index 1 [zipfs mount] [info script]] >= 0} return
			zipfs mount [info script] %tail%
			set dir	[file join [zipfs root] %tail%]
			source [file join $dir pkgIndex.tcl]
		}]
		puts -nonewline $h \x1A
		flush $h
		chan configure $h -translation binary
		close $h
		set wrap_fn	[file join $prefix pkgIndex.tcl.wrapped]
		zipfs mkimg $wrap_fn $path $path {} $tmpfn
		file delete -force {*}[glob -directory $path *]
		file rename $wrap_fn [file join $path pkgIndex.tcl]
	} finally {
		file delete $tmpfn
	}
}

