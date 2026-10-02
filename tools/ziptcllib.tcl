package require chantricks

set path	[lindex $argv 0]
set prefix	[file dirname $path]
set tail	[file tail $path]

chantricks with_chan h {file tempfile tmpfn} {
	try {
		puts -nonewline $h [string map [list %tail% [list $tail]] {
			# zipfs mounts are process-wide: another thread may have mounted it
			# already, but this interp still needs the package ifneeded entries
			if {![dict exists [zipfs mount] [file join [zipfs root] %tail%]]} {
				zipfs mount [info script] %tail%
			}
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

