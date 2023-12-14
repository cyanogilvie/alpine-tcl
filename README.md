ALPINE-TCL
==========

This container is intended to serve as a lightweight Tcl 8.7 runtime for
containerized services, building on the base of Alpine linux, and
including the set of packages I commonly use (mostly my own, but it's
easy to use this image as a base and bake in the ones you need).

Notably, it contains the necessary packages to easily implement AWS Lambda
functions in Tcl - rl_json for interacting with the JSON event descriptions,
and aws 2, which covers most of the AWS service API (though not ec2 yet -
it uses a different protocol that I haven't implemented yet).

It's in heavy production use at Ruby Lane, so I'm confident that the core
is pretty solid.

To architectures are provided x86_64 (with haswell optimization flags),
and arm64 (optimized for the Graviton ARM hardware AWS uses).

AWS-Tcl-Lambda
--------------

AWS Lambda now supports using a container as the function code.  This repo
provides a base image that supplies a Tcl runtime that is compatible with
this:

myfunc.tcl:
~~~tcl
proc handler {event context} {
    puts [json pretty $event]
    return "hello, world"
}
~~~

Dockerfile:
~~~dockerfile
FROM cyanogilvie/alpine-tcl:v0.9.80-stripped
ENV LAMBDA_TASK_ROOT=/foo
WORKDIR /foo
COPY myfunc.tcl /foo
ENTRYPOINT ["awslambdaric"]
CMD ["myfunc.handler"]
~~~

Build Flags
-----------

Since Nov 2020 AVX2 support is available to Lambda functions in all regions
other than China, so all the sources for this image are built with that
support.  If you need other hardware support, override the CFLAGS arg.

Included Packages
-----------------

Consult the Dockerfile for the versions and source URLs for these included
packages (most are from https://github.com/cyanogilvie or https://github.com/RubyLane):

- aio
- aws
- brotli
- cflib
- chantricks
- ck
- crypto
- datasource
- dedup
- docker
- dsl
- evlog
- flock
- gc_class
- hash
- inotify
- jitc
- logging
- m2
- names
- netdgram
- openapi
- parse_args
- parsetcl
- pgwire
- pixel
- prng
- resolve
- reuri
- rl_http
- rl_json
- rltest
- sockopt
- sop
- sqlite3
- tbuild
- tcllib
- tclreadline
- tclsignal
- tcltls
- tdbc
- tdom
- tty
- type
- unix_sockets

For Pixel_svg_cairo to be usable it needs librsvg, which isn't added by default because it more than doubles the image size.  To use it, derive a new image like so:

~~~dockerfile
FROM cyanogilvie/alpine-tcl
RUN apk add --no-cache librsvg
~~~

Similarly, Pixel_imlib2 requires imlib2:

~~~dockerfile
FROM cyanogilvie/alpine-tcl
RUN apk add --no-cache imlib2
~~~

License
-------
Licensed under the same terms as the Tcl core.
