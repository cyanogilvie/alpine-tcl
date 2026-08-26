# build_apk.tcl — produce a signed Alpine .apk from a staged payload tree.
#
# Designed to be invoked identically in two environments:
#
#   bld framework:
#     The Dockerfile package-apk stage's RUN body is just `tclsh
#     /var/task/build_apk.tcl`. stage_runner.tcl exports the ARG values as
#     env vars, so SIGNING_SECRET_ID etc. arrive as $SIGNING_SECRET_ID.
#     AWS credentials come from the build Lambda's execution role —
#     bld/sam/template.json grants secretsmanager:GetSecretValue on the
#     configured SigningSecretArn.
#
#   local docker:
#     The Makefile pkgrepo_apk target docker-runs the package-apk-prep
#     image with -v $HOME/.aws:/root/.aws:ro and -e VARS=..., calling
#     this script as the entrypoint. AWS credentials come from the
#     bind-mounted ~/.aws.
#
# In neither path is the signing keypair (or any AWS credential) passed
# through a Dockerfile ARG, a BuildKit secret, or a build event payload.
# Only the secret's *identifier* travels through args.
#
# Inputs (env):
#   REPO_BUCKET         S3 bucket to publish to, and
#   SIGNING_SECRET_ID   SecretsManager ARN/name of the signing keypair;
#                       either supply both directly (CodeBuild passes them
#                       from the stack's project env), or set
#   PKGREPO_STACK       Name of a CloudFormation stack to read BucketName /
#                       SigningSecretArn outputs from instead (local dev
#                       path; needs cloudformation:DescribeStacks).
#   VER                 (required) full version, optionally `v`-prefixed.
#   PKGREL              (default 0).
#   PKGNAME             (default cftcl).
#   TCLROOT             (default /usr/local) install prefix the payload
#                       tree was rooted at.
#   APK_PAYLOAD_ROOT    (default /tmp/apk-build/payload-root) directory
#                       containing the staged payload (the equivalent of
#                       tcl-copy's /out subtree).

package require aws
package require rl_json
package require chantricks
package require parse_args
package require common_sighandler

namespace import ::rl_json::json
namespace import ::parse_args::parse_args

set apkarch		[exec apk info --print-arch]

foreach v {
	VER
} {
	if {![info exists env($v)]} {
		puts stderr "$v unset"
		exit 1
	}
}

if {
	!([info exists env(REPO_BUCKET)] && [info exists env(SIGNING_SECRET_ID)]) &&
	![info exists env(PKGREPO_STACK)]
} {
	puts stderr "need REPO_BUCKET + SIGNING_SECRET_ID, or PKGREPO_STACK to discover them from"
	exit 1
}

foreach {v def} {
	PKGREL				0
	PKGNAME				cftcl
	TCLROOT				/usr/local
	APK_PAYLOAD_ROOT	/tmp/apk-build/payload-root
} {
	if {![info exists env($v)]} {set env($v) $def}
}

proc cfn_output key { #<<<
	global _cfn_output_cache env
	set cachekey	$env(PKGREPO_STACK)
	if {![info exists _cfn_output_cache] || ![dict exists $_cfn_output_cache $cachekey]} {
		set res	[aws cloudformation describe_stacks \
			-stack_name		$env(PKGREPO_STACK) \
		]
		dict set _cfn_output_cache $cachekey {}
		json foreach e [json extract $res Stacks 0 Outputs] {
			dict set _cfn_output_cache $cachekey [json get $e OutputKey] [json get $e OutputValue]
		}
	}
	dict get $_cfn_output_cache $cachekey $key
}

#>>>
proc repo_bucket {} { #<<<
	global env
	if {[info exists env(REPO_BUCKET)]} {return $env(REPO_BUCKET)}
	cfn_output BucketName
}

#>>>
proc signing_secret_id {} { #<<<
	global env
	if {[info exists env(SIGNING_SECRET_ID)]} {return $env(SIGNING_SECRET_ID)}
	cfn_output SigningSecretArn
}

#>>>
proc mkpkg args { #<<<
	global apkarch default_meta work
	parse_args $args {
		-subpkg		{}
		-desc		{}
		-depends	{}
	}

	set meta	[dict merge $default_meta {
	}]
	if {[info exists subpkg]} {
		dict append meta name -$subpkg
	}
	if {[info exists desc]} {
		dict append meta description " ($desc)"
	}
	if {[info exists depends]} {
		dict set meta depends $depends
	}

	set extra	{}
	dict for {k v} $meta {
		lappend extra	--info $k:$v
	}
	set hold	[pwd]
	try {
		cd $work/packages/$apkarch
		puts "mkpkg [dict get $meta name] from $hold:\n[exec find $hold -ls]"
		exec apk --sign-key $work/.abuild/cftcl.rsa mkpkg --files $hold {*}$extra
	} finally {
		cd $hold
	}
}

#>>>
proc amove pat { #<<<
	global subpkgdir pkgdir
	if {![info exists subpkgdir]} {error "No subpkgdir set"}
	set olddir	[pwd]
	try {
		cd $pkgdir
		foreach e [glob $pat] {
			set dest	[file join $subpkgdir $e]
			file mkdir [file dirname $dest]
			puts "amove $e -> $dest"
			file rename $e $dest
			exec rmdir --ignore-fail-on-non-empty -p [file dirname $e]
		}
	} finally {
		cd $olddir
	}
}

#>>>
proc subpkg {name args} { #<<<
	global subpkgdir
	parse_args $args {
		-depends	{}
		-desc	{}
		script		{-required}
	}

	puts "Building subpackage $name"
	set extra	{}
	foreach v {depends desc} {
		if {[info exists $v]} {
			lappend extra -$v [set $v]
		}
	}

	set hold	[pwd]
	try {
		set subpkgdir	/tmp/pkgfiles/cftcl-$name
		file mkdir $subpkgdir
		cd $subpkgdir
		uplevel 1 $script
		mkpkg -subpkg $name {*}$extra
	} finally {
		unset -nocomplain subpkgdir
		cd $hold
	}
}

#>>>
proc elfend elf { # Return the end-of-file as far as the elf format is concerned <<<
	set raw	[exec readelf --file-header $elf]
	if {
		![regexp -line {^  Start of section headers:\s+([0-9]+)}  $raw - start] ||
		![regexp -line {^  Size of section headers:\s+([0-9]+)}   $raw - size] ||
		![regexp -line {^  Number of section headers:\s+([0-9]+)} $raw - num]
	} {
		error "Could not parse elf"
	}

	expr {$start + $size * $num}
}

#>>>


set work	/tmp/apk-build
cd $work

set prefix	[string trimleft $env(TCLROOT) /]

# Repack the staged tree (which has $TCLROOT under it) as the abuild
# source tarball. abuild's package() function then just untars it into
# $pkgdir — no rebuild, no relink.
if {![file isdirectory $env(APK_PAYLOAD_ROOT)$env(TCLROOT)]} {
	puts stderr "no payload under $env(APK_PAYLOAD_ROOT)$env(TCLROOT)"
	exit 1
}
#file mkdir $work/payload$env(TCLROOT)
#file copy -- {*}[glob $env(APK_PAYLOAD_ROOT)$env(TCLROOT)/*] $work/payload$env(TCLROOT)
#file mkdir $aports/src
#exec tar -czf $aports/src/payload.tar.gz -C $work/payload . >@ stdout 2>@ stderr
#file delete -force -- $work/payload

# Generate the APKBUILD. !check (no test harness), !strip (abuild's
# stripbin runs plain `strip`, which would discard the zipfs script-library
# image appended to libtcl9.0.so; our custom dbg() strips the binaries
# safely instead, preserving any appended archive), !tracedeps (we have no
# shared-lib deps the host resolver should track).
# Strip a leading "v" from $env(VER): apk-tools' version parser doesn't accept
# a non-numeric prefix and silently falls back to lexicographic comparison, so a
# repo carrying "v0.9.123-r0" and "v0.9.123-r1" would have apk pick r0.
regexp {^v?(.*)$} $env(VER) - apk_pkgver

# Build APKBUILD <<<
chantricks writefile APKBUILD [string map [list \
	%ver%		$apk_pkgver \
	%pkgrel%	$env(PKGREL) \
	%pkgname%	$env(PKGNAME) \
	%tclroot%	'[string trimleft $env(TCLROOT) /]' \
	%payload%	'$env(APK_PAYLOAD_ROOT)' \
] {# Maintainer: Cyan Ogilvie <cyan.ogilvie@gmail.com>
pkgname=%pkgname%
pkgver=%ver%
pkgrel=%pkgrel%
pkgdesc="Batteries-included Tcl runtime (rl_json, tomcrypt, aws, parsetcl, ...)"
url="https://github.com/cyanogilvie/alpine-tcl"
arch="all"
# musl-dev: jitc needs the libc headers (stdio.h, ...) and crt*.o on the host at runtime.
depends="musl-dev"
subpackages="$pkgname-dbg $pkgname-dev $pkgname-doc $pkgname-svg $pkgname-phash"
license="custom"
options="!check !strip !tracedeps !fhs"
source=""

TCLROOT=%tclroot%
APK_PAYLOAD_ROOT=%payload%

doc() {
	test -d "$subpkgdir/$TCLROOT" && rm -r "$subpkgdir/$TCLROOT"
	amove "$TCLROOT/share"
}

svg() {
	# Split out the large Pixel_svg_cairo package and its deps under $subpkgdir
	test -d "$subpkgdir/$TCLROOT" && rm -r "$subpkgdir/$TCLROOT"
	amove "$TCLROOT/lib/Pixel_svg_cairo-*"
}

phash() {
	# Split out the large Pixel_phash package and its deps under $subpkgdir
	test -d "$subpkgdir/$TCLROOT" && rm -r "$subpkgdir/$TCLROOT"
	amove "$TCLROOT/lib/Pixel_phash-*"
}

dev() {
	# Move sources, libraries and headers that aren't needed by runtime (jitc) under $subpkgdir
	test -d "$subpkgdir/$TCLROOT" && rm -r "$subpkgdir/$TCLROOT"
	#amove "$TCLROOT/include/readline"
	#amove "$TCLROOT/lib/libreadline.a"
	amove "$TCLROOT/lib/libtclstub.a"
	amove "$TCLROOT/lib/tclooConfig.sh"
	amove "$TCLROOT/lib/tclConfig.sh"
	amove "$TCLROOT/lib/tclsignalConfig.sh"
	amove "$TCLROOT/lib/libtommath.a"
	amove "$TCLROOT/lib/libz.a"
	amove "$TCLROOT/lib/cmake"
	amove "$TCLROOT/lib/pkgconfig"
}

# Read an unsigned little-endian integer of width $3 bytes at offset $2 of file $1.
_le_uint() {
	od -An -v -tu1 -j"$2" -N"$3" "$1" | awk -v m=1 '{for(i=1;i<=NF;i++){s=s+$i*m;m=m*256}} END{printf "%.0f", s}'
}

# If $1 has a zip archive appended (e.g. a Tcl zipfs image), print the byte
# offset at which the archive begins; otherwise print nothing. Finds the End Of
# Central Directory record, derives the archive start from it (offsets are
# archive-relative), and confirms a local-file-header signature lives there.
_appended_zip_offset() {
	local f="$1" sz n base eocd cd_size cd_off arc
	sz=$(stat -c %s "$f")
	n=65557; [ "$sz" -lt "$n" ] && n="$sz"; base=$((sz - n))
	eocd=$(tail -c "$n" "$f" | od -An -v -tu1 | awk -v base="$base" '
		{for(i=1;i<=NF;i++) b[k++]=$i}
		END{last=-1; for(j=0;j+3<k;j++) if(b[j]==80&&b[j+1]==75&&b[j+2]==5&&b[j+3]==6) last=j; if(last>=0) printf "%d", base+last}')
	[ -n "$eocd" ] || return 0
	cd_size=$(_le_uint "$f" $((eocd + 12)) 4)
	cd_off=$(_le_uint "$f" $((eocd + 16)) 4)
	arc=$((eocd - cd_size - cd_off))
	[ "$arc" -ge 0 ] && [ "$arc" -lt "$sz" ] || return 0
	# 0x04034b50 (PK\x03\x04) little-endian == 67324752
	[ "$(_le_uint "$f" "$arc" 4)" = 67324752 ] || return 0
	printf "%d" "$arc"
}

# Like abuild's default_dbg, but ELFs carrying an appended archive (Tcl zipfs:
# libtcl9.0.so holds the script library) get the archive detached, objcopy
# strips the ELF, then the archive is re-appended so the runtime still mounts.
dbg() {
	local type src dst ino tmp arc zip

	test -d "$subpkgdir/$TCLROOT" && rm -r "$subpkgdir/$TCLROOT"
	amove "$TCLROOT/src"

	depends=
	pkgdesc="$pkgdesc (debug symbols)"
	mkdir -p "$pkgbasedir/.dbg-tmp"
	scanelf -RyB -E ET_DYN "$pkgbasedir"/* | while read -r type src; do
		dst="$subpkgdir/usr/lib/debug/${src#"$pkgbasedir"/*/}.debug"
		mkdir -p "${dst%/*}"
		ino=$(stat -c %i "$src")
		[ -e "$pkgbasedir/.dbg-tmp/$ino" ] && continue
		tmp="$pkgbasedir/.dbg-tmp/${src##*/}"

		zip=
		arc=$(_appended_zip_offset "$src")
		if [ -n "$arc" ]; then
			zip="$pkgbasedir/.dbg-tmp/${src##*/}.appended"
			tail -c +"$((arc + 1))" "$src" > "$zip"
		fi

		objcopy --only-keep-debug "$src" "$dst"
		objcopy --add-gnu-debuglink="$dst" --strip-unneeded -R .comment "$src" "$tmp"

		if [ -n "$zip" ]; then
			cat "$zip" >> "$tmp"
			rm "$zip"
		fi

		# only replace content to preserve attributes
		cat "$tmp" > "$src"
		rm "$tmp"
		ln "$dst" "$pkgbasedir/.dbg-tmp/$ino"
	done
	rm -r "$pkgbasedir/.dbg-tmp"
	return 0
}

package() {
	mkdir -p "$pkgdir"
	cp -a "$APK_PAYLOAD_ROOT/*" "$pkgdir"
	rm "$pkgdir/$TCLROOT/include/pHash.h"
	rm "$pkgdir/$TCLROOT/lib/libpHash.a"
	rm "$pkgdir/$TCLROOT/lib/libgumbo.a"
	# TODO: move this to alpine-tcl Dockerfile to only copy these patterns
	#find "$pkgdir/$TCLROOT/src" -type f \! -name '*.c' \! -name '*.h' \! -name '*.cc' \! -name '*.cpp' -delete
}

# vim: ts=4 shiftwidth=4 noexpandtab
}]
# Build APKBUILD >>>


# Fetch the signing keypair from SecretsManager. AWS credentials come
# from whatever the environment provides (lambda role under bld, mounted
# ~/.aws under local docker) — never from args we control.
file mkdir $work/.abuild
set secret	[json get [aws secretsmanager get_secret_value -secret_id [signing_secret_id]] SecretString]
chantricks writefile $work/.abuild/cftcl.rsa.pub	[json get $secret public_key]
chantricks with_chan h {open $work/.abuild/cftcl.rsa w 0o600} {
	puts -nonewline $h [json get $secret private_key]
}
chantricks writefile $work/.abuild/abuild.conf PACKAGER_PRIVKEY=$work/.abuild/cftcl.rsa\n
file copy $work/.abuild/cftcl.rsa.pub /etc/apk/keys/
set env(HOME)	$work

file mkdir	$work/packages/$apkarch
#exec tar czf payload.tar.gz -C $work/payload-root opt
#exec abuild -F checksum >@ stdout 2>@ stderr
# rootpkg builds and signs the .apk; skip fetch/deps/check because the
# source is already local, there are no build deps, and package() is
# pure cp -a. -F lets abuild run as uid 0; -K keeps work files for
# debugging if needed (cheap on Lambda's /tmp).
#exec abuild -F -K -P $work/packages rootpkg >@ stdout 2>@ stderr

set default_meta [dict create {*}{
	name		cftcl
	description	{Batteries-included Tcl runtime (rl_json, parse_args, tomcrypt, aws, jitc, ...)}
	origin		cftcl
	maintainer	{Cyan Ogilvie}
	url			https://github.com/cyanogilvie/cftcl
}	version		$apk_pkgver \
	arch		$apkarch \
	build-time	[clock seconds] \
]


set pkgdir	$env(APK_PAYLOAD_ROOT)
cd $pkgdir

# Trim out files that none of the packages contain
file delete $prefix/include/pHash.h
file delete $prefix/lib/libpHash.a
file delete $prefix/lib/libgumbo.a
file delete $prefix/lib/libz.a


subpkg dev -desc {development files} {
	#amove $prefix/include/readline
	#amove $prefix/lib/libreadline.a
	amove $prefix/lib/libtclstub.a
	amove $prefix/lib/*Config.sh
	amove $prefix/lib/libtommath.a
	amove $prefix/lib/cmake
	amove $prefix/lib/pkgconfig
}

subpkg doc -desc documentation -depends mandoc {
	amove $prefix/share
}

subpkg dbg -desc {debug symbols} {
	amove $prefix/src

	# Like abuild's default_dbg, but ELFs carrying an appended archive (Tcl zipfs:
	# libtcl9.0.so holds the script library) get the archive detached, objcopy
	# strips the ELF, then the archive is re-appended so the runtime still mounts.
	cd $pkgdir
	set elves	[split [string trim [exec scanelf --recursive --symlink --etype ET_DYN --nobanner --format %p $prefix/]] \n]
	foreach relelf $elves {
		set elf		[file join $prefix $relelf]
		set elfend	[elfend $elf]
		set dst		[file join $subpkgdir usr/lib/debug/$prefix/$relelf.debug]
		file mkdir [file dirname $dst]
		if {[file size $elf] != $elfend} {
			chantricks with_file h $elf rb {
				seek $h $elfend
				set tail	[read $h]
				if {[string range $tail 0 3] eq "PK\x03\x04"} {
					puts "Found appended zip: $relelf [expr {[file size $elf] - $elfend}]"
				} else {
					puts "Found unknown appended bytes: $relelf [expr {[file size $elf] - $elfend}]"
				}
			}
		} else {
			unset -nocomplain tail
		}
		exec objcopy --only-keep-debug $elf $dst
		exec objcopy --add-gnu-debuglink=$dst --strip-unneeded --remove-section=.comment $elf
		if {[info exists tail]} {
			chantricks with_file h $elf ab {
				puts -nonewline $h $tail
			}
		}
	}
}

subpkg svg -desc {Pixel_svg_cairo} {
	amove $prefix/lib/Pixel_svg_cairo-*
}

subpkg phash -desc {Pixel_phash} {
	amove $prefix/lib/Pixel_phash-*
}

# base package:
cd $pkgdir
mkpkg -depends musl-dev

# Upload the freshly-built .apks
cd $work/packages/$apkarch
foreach fn [glob -types f *.apk] {
	puts "uploading $fn: [file size $fn]"
	aws s3 put_object \
		-bucket			[repo_bucket] \
		-key			alpine/v1/$apkarch/$fn \
		-body			[chantricks readbin $fn] \
		-content_type	application/octet-stream
}

if 0 {
	# Fetch existing index
	aws s3 get_object \
		-bucket			[repo_bucket] \
		-key			alpine/v1/$apkarch/APKINDEX.tar.gz \
		-payload		index
	chantricks writebin APKINDEX.prev.tar.gz $index

	exec apk index --output APKINDEX.tar.gz --index APKINDEX.prev.tar.gz *.apk >@ stdout 2>@ stderr
	exec abuild-sign -t RSA256 \
		-k $work/abuild/cftcl.rsa \
		-p $work/abuild/cftcl.rsa.pub \
		APKINDEX.tar.gz

	aws s3 put_object \
		-bucket			[repo_bucket] \
		-key			alpine/v1/$apkarch/APKINDEX.tar.gz \
		-body			[chantricks readbin APKINDEX.tar.gz] \
		-content_type	application/octet-stream \
		-cache_control	"public, max-age=60"
} else {
	set apks	[glob -types f *.apk]
	puts "mkndx on:\n\t[join $apks \n\t]"
	set ndx		Packages.adb
	exec apk --sign-key $work/.abuild/cftcl.rsa mkndx --output $ndx {*}$apks >@ stdout 2>@ stderr
	#exec apk --sign-key $work/.abuild/cftcl.rsa adbsign $ndx

	puts "Uploading index: [file size $ndx]"
	aws s3 put_object \
		-bucket			[repo_bucket] \
		-key			alpine/v1/$apkarch/$ndx \
		-body			[chantricks readbin $ndx] \
		-content_type	application/octet-stream \
		-cache_control	"public, max-age=60"
}


# vim: foldmethod=marker foldmarker=<<<,>>> ts=4 sw=4 noexpandtab
