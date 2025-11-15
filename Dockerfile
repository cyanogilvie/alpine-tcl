ARG DIST=alpine
ARG TCLVER=8.7

# Alpine linux <<<
#FROM alpine:3.20.3 AS src-alpine
FROM alpine:3.22.2 AS src-alpine
RUN apk add --no-cache --update musl-dev readline libjpeg-turbo libexif libpng libwebp tiff ncurses ncurses-libs libstdc++ libgcc brotli musl-obstack-dev && \
	rm /usr/lib/libc.a

FROM src-alpine AS src-dev-alpine
RUN apk add --no-cache --update build-base autoconf automake bsd-compat-headers bash ca-certificates docker-cli git libtool python3 pandoc pkgconfig musl-obstack-dev zip libstdc++ libgcc ncurses-libs ncurses-dev ncurses brotli-libs brotli-dev cmake boost-dev libjpeg-turbo-dev libpng-dev tiff-dev libjpeg-turbo-dev libexif-dev libpng-dev librsvg-dev libwebp-dev readline readline-dev
# Alpine linux >>>
# Amazon Linux 2023 <<<
FROM docker.io/library/amazonlinux:2023.9.20251027.0 AS src-al2023
ENV LANG=C.UTF-8
RUN echo LANG=C.UTF-8 > /etc/locale.conf
RUN echo /usr/local/lib > /etc/ld.so.conf.d/local.conf
RUN ldconfig
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
RUN echo -e "#!/bin/sh\ndnf install -q -y freetype libX11-xcb librsvg2 libwebp libexif libpng libtiff brotli ncurses brotli libjpeg-turbo glibc-devel" > /usr/local/bin/install-deps.sh && \
	chmod +x /usr/local/bin/install-deps.sh
RUN /usr/local/bin/install-deps.sh

FROM src-al2023 AS src-dev-al2023
RUN dnf install -q -y \
		autoconf \
		automake \
		cmake \
		gcc14 \
		gcc14-c++ \
		g++ \
		git \
		glibc-devel \
		libtool \
		wget \
		zip
ARG CC=gcc14
ARG CXX=gcc14-g++
RUN ln -s /usr/bin/gcc14-gcc /usr/local/bin/gcc
RUN ln -s /usr/bin/gcc14-gcc /usr/local/bin/cc
RUN ln -s /usr/bin/gcc14-g++ /usr/local/bin/g++
RUN ln -s /usr/bin/gcc14-g++ /usr/local/bin/c++
RUN ln -s /usr/bin/gcc14-cpp /usr/local/bin/cpp
# Amazon Linux 2023 >>>
# Ubuntu 24.04 <<<
FROM ubuntu:24.04@sha256:d22e4fb389065efa4a61bb36416768698ef6d955fe8a7e0cdb3cd6de80fa7eec AS src-ubuntu
RUN apt update
RUN DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends locales && apt clean
RUN locale-gen en_US.UTF-8 && echo LANG=en_US.UTF-8 > /etc/locale.conf
ENV LANG=en_US.UTF-8
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

FROM src-ubuntu AS src-dev-ubuntu
RUN DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
		autoconf \
		automake \
		build-essential \
		ca-certificates \
		cmake \
		curl \
		g++-14 \
		gcc-14 \
		git \
		libssl-dev \
		libtool \
		pkg-config \
		python-is-python3 \
		wget \
		zip \
	&& \
	apt clean
ARG CC=gcc-14
ARG CXX=g++-14
RUN ln -s /usr/bin/gcc-14 /usr/local/bin/gcc
RUN ln -s /usr/bin/g++-14 /usr/local/bin/g++
RUN ln -s /usr/bin/cpp-14 /usr/local/bin/cpp
RUN update-alternatives --install /usr/bin/cc  cc  /usr/bin/gcc-14 100
RUN update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-14 100
RUN update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100
RUN update-alternatives --set cc  /usr/bin/gcc-14
RUN update-alternatives --set c++ /usr/bin/g++-14
# Ubuntu 24.04 >>>

FROM src-$DIST AS src
FROM src-dev-$DIST AS src-dev

FROM src-dev AS base-amd64
# Since Nov 2020 Lambda has supported AVX2 (and haswell) in all regions except China
ARG CFLAGS_ARCH="-O3 -march=haswell -flto=auto -fPIC"
ARG CXXFLAGS_ARCH="-O3 -march=haswell -flto=auto -fPIC"
ARG LDFLAGS_ARCH="-O3 -march=haswell -flto=auto"
ARG CFLAGS="${CFLAGS_ARCH}"
ARG CXXFLAGS="${CXXFLAGS_ARCH}"
ARG LDFLAGS="${LDFLAGS_ARCH}"

FROM src-dev AS base-arm64
# Target graviton2
ARG CFLAGS_ARCH="-O3 -moutline-atomics -march=armv8.2-a -flto=auto -fPIC"
ARG CXXFLAGS_ARCH="-O3 -moutline-atomics -march=armv8.2-a -flto=auto -fPIC"
ARG LDFLAGS_ARCH="-O3 -moutline-atomics -march=armv8.2-a -flto=auto"
ARG CFLAGS="${CFLAGS_ARCH}"
ARG CXXFLAGS="${CXXFLAGS_ARCH}"
ARG LDFLAGS="${LDFLAGS_ARCH}"

ARG TARGETARCH

# Runtime library requirements (as static libs only) <<<
FROM base-$TARGETARCH AS base-build
ARG CFLAGS_ARCH

# ninja and meson <<<
FROM base-build AS base-build-ninja
RUN mkdir -p /out/usr/local/bin
WORKDIR /src/ninja
RUN wget -q https://github.com/ninja-build/ninja/archive/refs/tags/v1.13.1.tar.gz -O - | tar xz --strip-components=1
RUN ./configure.py --bootstrap
#RUN ./ninja all
RUN cp ninja /out/usr/local/bin/

WORKDIR /src/meson
RUN wget -q https://github.com/mesonbuild/meson/archive/refs/tags/1.9.1.tar.gz -O - | tar xz --strip-components=1
RUN ./packaging/create_zipapp.py --outfile /out/usr/local/bin/meson --interpreter '/usr/bin/env python3' .
# ninja and meson >>>
# boost <<<
FROM base-build AS base-build-boost
WORKDIR /src/boost
RUN git clone https://github.com/boostorg/boost.git -b boost-1.89.0 --depth 1 .
RUN git submodule update --depth 1 -q --init tools/boostdep
#RUN git submodule update --depth 1 -q --init libs/unordered
RUN python tools/boostdep/depinst/depinst.py -X test -g "--depth 1" unordered
RUN ./bootstrap.sh --prefix=/usr/local
RUN ./b2 -j 20 --build-type=minimal variant=release link=static threading=multi runtime-link=static
RUN ./b2 -j 20 install
RUN mkdir -p /out/usr && cp -a /usr/local /out/usr/
# boost >>>
# libexif <<<
FROM base-build AS base-build-libexif
WORKDIR /src/libexif
RUN wget -q https://github.com/libexif/libexif/releases/download/v0.6.25/libexif-0.6.25.tar.gz -O - | tar xz --strip-components=1
RUN ./configure --disable-shared --disable-docs --enable-year2038
RUN make -j
RUN make install DESTDIR=/out
# libexif >>>
# freetype <<<
FROM base-build AS base-build-freetype
WORKDIR /src/freetype
RUN wget -q https://download.savannah.gnu.org/releases/freetype/freetype-2.14.1.tar.gz -O - | tar xz --strip-components=1
RUN ./configure --disable-shared
RUN make -j
RUN make install DESTDIR=/out
# freetype >>>
# jpeg-turbo <<<
FROM base-build AS base-build-jpeg-turbo
WORKDIR /src/jpeg-turbo
RUN wget -q https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.2/libjpeg-turbo-3.1.2.tar.gz -O - | tar xz --strip-components=1
RUN CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" cmake -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DENABLE_SHARED=OFF -DWITH_TESTS=OFF -DWITH_TOOLS=OFF -DWITH_TURBOJPEG=OFF -DWITH_JPEG8=ON -DWITH_JPEG7=ON
RUN make -j
RUN make install DESTDIR=/out
# jpeg-turbo >>>
# ncurses <<<
FROM base-build AS base-build-ncurses
WORKDIR /src/ncurses
RUN wget -q https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.5.tar.gz -O - | tar xz --strip-components=1
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" \
		--prefix=/usr/local \
		--with-pkg-config-libdir=/usr/local/lib/pkgconfig \
		--disable-leaks \
		--without-shared \
		--with-normal \
		--without-debug \
		--without-ada \
		--without-cxx \
		--without-cxx-binding \
		--disable-db-install \
		--with-default-terminfo-dir=/usr/share/terminfo \
		--with-terminfo-dirs=/etc/terminfo:/usr/share/terminfo \
		--without-manpages \
		--without-progs \
		--without-tests \
		--disable-root-environ \
		--disable-root-access \
		--disable-setuid-environ \
		--disable-stripping \
		--enable-pc-files
RUN make -j
RUN make install DESTDIR=/out
# ncurses >>>
# zlib <<<
FROM base-build AS base-build-zlib
WORKDIR /src/zlib
RUN wget -q https://zlib.net/zlib-1.3.1.tar.gz -O - | tar xz --strip-components=1
#RUN set > /tmp/vars
RUN CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" ./configure --prefix=/usr/local --static
RUN make -j
RUN make install DESTDIR=/out
# zlib >>>
# libpng <<<
FROM base-build AS base-build-libpng
WORKDIR /src/libpng
RUN wget -q https://download.sourceforge.net/libpng/libpng-1.6.50.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-zlib /out /
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --disable-shared --enable-pic --disable-tests --disable-tools --enable-hardware-optimizations
RUN make -j
RUN make install DESTDIR=/out
# libpng >>>
# readline <<<
FROM base-build AS base-build-readline
WORKDIR /src/readline
RUN wget -q https://ftp.gnu.org/gnu/readline/readline-8.3.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-ncurses			/out /
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --disable-shared --disable-install-examples --enable-year2038 --with-curses
RUN make -j
RUN make install DESTDIR=/out
# readline >>>
# webp <<<
FROM base-build AS base-build-webp
WORKDIR /src/webp
RUN wget -q https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz -O - | tar xz --strip-components=1
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --disable-shared --enable-pic
RUN make -j
RUN make install DESTDIR=/out
# webp >>>
# libtiff <<<
FROM base-build AS base-build-libtiff
WORKDIR /src/libtiff
RUN wget -q https://gitlab.com/libtiff/libtiff/-/archive/v4.7.1/libtiff-v4.7.1.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-jpeg-turbo		/out /
COPY --link --from=base-build-libpng			/out /
COPY --link --from=base-build-webp				/out /
COPY --link --from=base-build-zlib				/out /
RUN ./autogen.sh
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --with-pic --disable-shared --enable-static --disable-dependency-tracking --disable-tools --disable-tests --disable-contrib --disable-docs
#RUN cmake -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -Dtiff-static=ON -Dtiff-shared=OFF -Dtiff-tests=OFF -Dtiff-tools=OFF -DBUILD_SHARED_LIBS=OFF -Dtiff-docs=OFF -Dtiff-contrib=OFF
RUN make -j
RUN make install DESTDIR=/out
# libtiff >>>
# lzo2 <<<
FROM base-build AS base-build-lzo2
WORKDIR /src/lzo2
RUN wget -q https://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz -O - | tar xz --strip-components=1
RUN ./configure --disable-shared --with-pic
RUN make -j
RUN make install DESTDIR=/out
# lzo2 >>>
# gperf <<<
FROM base-build AS base-build-gperf
WORKDIR /src/gperf
RUN wget -q http://ftp.gnu.org/pub/gnu/gperf/gperf-3.3.tar.gz -O - | tar xz --strip-components=1
RUN set > /tmp/vars
RUN ./configure
RUN make -j
RUN make install DESTDIR=/out
# gperf >>>
# gettext <<<
FROM base-build AS base-build-gettext
WORKDIR /src/gettext
RUN wget -q https://ftp.gnu.org/pub/gnu/gettext/gettext-0.26.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-ncurses			/out /
RUN ./configure --enable-pic --disable-shared --enable-static --enable-year2038
RUN make -j
RUN make install DESTDIR=/out && \
	rm -rf /out/usr/local/share/doc
# gettext >>>
# expat <<<
FROM base-build AS base-build-expat
WORKDIR /src/expat
RUN wget -q https://github.com/libexpat/libexpat/releases/download/R_2_7_3/expat-2.7.3.tar.gz -O - | tar xz --strip-components=1
RUN ./configure --disable-shared --enable-pic --without-examples --without-tests --without-docbook
RUN make -j
RUN make install DESTDIR=/out
# expat >>>
# fontconfig <<<
FROM base-build AS base-build-fontconfig
WORKDIR /src/fontconfig
RUN wget -q https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.17.1/fontconfig-2.17.1.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-gettext			/out /
COPY --link --from=base-build-gperf				/out /
COPY --link --from=base-build-freetype			/out /
COPY --link --from=base-build-expat				/out /
RUN ./autogen.sh --disable-shared --enable-static --with-pic --disable-docs --disable-dependency-tracking
RUN make -j
RUN make install DESTDIR=/out
# fontconfig >>>
# libffi <<<
FROM base-build AS base-build-libffi
WORKDIR /src/libffi
RUN wget -q https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz -O - | tar xz --strip-components=1
RUN ./configure --disable-shared --enable-pic --disable-docs --disable-dependency-tracking
RUN make -j
RUN make install DESTDIR=/out
# libffi >>>
# glib <<<
FROM base-build AS base-build-glib
WORKDIR /src/glib
RUN wget -q https://download.gnome.org/sources/glib/2.87/glib-2.87.0.tar.xz -O - | tar xJ --strip-components=1
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-gettext			/out /
COPY --link --from=base-build-zlib				/out /
COPY --link --from=base-build-libffi			/out /
RUN meson setup build/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D tests=false \
	-D man-pages=disabled \
	-D glib_debug=disabled
RUN meson install -C build --destdir /out
# glib >>>
# pixman <<<
FROM base-build AS base-build-pixman
WORKDIR /src/pixman
RUN wget -q https://cairographics.org/releases/pixman-0.46.4.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-glib				/out /
RUN meson setup build/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D gtk=disabled \
	-D libpng=disabled \
	-D tests=disabled \
	-D demos=disabled
RUN meson install -C build --destdir /out
# pixman >>>
# libxml2 <<<
FROM base-build AS base-build-libxml2
WORKDIR /src/libxml2
RUN wget -q https://gitlab.gnome.org/GNOME/libxml2/-/archive/v2.15.1/libxml2-v2.15.1.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-zlib				/out /
RUN meson setup builddir/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D debugging=disabled \
	-D docs=disabled \
	-D python=disabled \
	-D zlib=enabled
RUN meson install -C builddir --destdir /out
# libxml2 >>>
# shared-mime-info <<<
FROM base-build AS base-build-shared-mime-info
WORKDIR /src/shared-mime-info
RUN wget -q https://gitlab.freedesktop.org/xdg/shared-mime-info/-/archive/2.4/shared-mime-info-2.4.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-gettext			/out /
COPY --link --from=base-build-libxml2			/out /
COPY --link --from=base-build-ninja				/out /
RUN meson setup builddir/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D update-mimedb=false \
	-D build-tools=false \
	-D build-tests=false
RUN meson install -C builddir --destdir /out
# shared-mime-info >>>
# gdk-pixbuf2 <<<
FROM base-build AS base-build-gdk-pixbuf2
WORKDIR /src/gdk-pixbuf
RUN wget -q https://gitlab.gnome.org/GNOME/gdk-pixbuf/-/archive/2.44.4/gdk-pixbuf-2.44.4.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-glib				/out /
COPY --link --from=base-build-jpeg-turbo		/out /
COPY --link --from=base-build-libffi			/out /
COPY --link --from=base-build-libpng			/out /
COPY --link --from=base-build-libtiff			/out /
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-shared-mime-info	/out /
COPY --link --from=base-build-zlib				/out /
RUN meson setup builddir/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D documentation=false \
	-D man=false \
	-D tests=false \
	-D installed_tests=false \
	-D glycin=disabled
RUN meson install -C builddir --destdir /out
# gdk-pixbuf2 >>>
# libart2 <<<
# libart2 >>>
# harfbuzz <<<
FROM base-build AS base-build-harfbuzz
WORKDIR /src/harfbuzz
RUN wget -q https://github.com/harfbuzz/harfbuzz/releases/download/12.2.0/harfbuzz-12.2.0.tar.xz -O - | tar xJ --strip-components=1
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-freetype			/out /
COPY --link --from=base-build-glib				/out /
RUN meson setup builddir/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D tests=disabled \
	-D docs=disabled \
	-D doc_tests=false \
	-D utilities=disabled \
	-D cairo=disabled
RUN meson install -C builddir --destdir /out
# harfbuzz >>>
# freefidi <<<
FROM base-build AS base-build-freebidi
WORKDIR /src/freebidi
RUN wget -q https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz -O - | tar xJ --strip-components=1
COPY --link --from=base-build-ninja		/out /
RUN meson setup build/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D docs=false \
	-D bin=false \
	-D tests=false
RUN meson install -C build/ --destdir /out
# freefidi >>>
# cairo <<<
FROM base-build AS base-build-cairo
WORKDIR /src/cairo
RUN wget -q https://cairographics.org/releases/cairo-1.18.4.tar.xz -O - | tar xJ --strip-components=1
COPY --link --from=base-build-expat				/out /
COPY --link --from=base-build-fontconfig		/out /
COPY --link --from=base-build-freebidi			/out /
COPY --link --from=base-build-freetype			/out /
COPY --link --from=base-build-gdk-pixbuf2		/out /
COPY --link --from=base-build-gettext			/out /
COPY --link --from=base-build-glib				/out /
COPY --link --from=base-build-gperf				/out /
COPY --link --from=base-build-harfbuzz			/out /
COPY --link --from=base-build-jpeg-turbo		/out /
COPY --link --from=base-build-libffi			/out /
COPY --link --from=base-build-libpng			/out /
COPY --link --from=base-build-libtiff			/out /
COPY --link --from=base-build-libxml2			/out /
COPY --link --from=base-build-lzo2				/out /
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-pixman			/out /
COPY --link --from=base-build-shared-mime-info	/out /
COPY --link --from=base-build-zlib				/out /
RUN meson setup build/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D tests=disabled
RUN meson install -C build/ --destdir /out
# cairo >>>
# pangoft2 <<<
FROM base-build AS base-build-pangoft2
WORKDIR /src/pango
RUN wget -q https://gitlab.gnome.org/GNOME/pango/-/archive/1.57.0/pango-1.57.0.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-cairo				/out /
COPY --link --from=base-build-expat				/out /
COPY --link --from=base-build-fontconfig		/out /
COPY --link --from=base-build-freebidi			/out /
COPY --link --from=base-build-freetype			/out /
COPY --link --from=base-build-gdk-pixbuf2		/out /
COPY --link --from=base-build-gettext			/out /
COPY --link --from=base-build-glib				/out /
COPY --link --from=base-build-gperf				/out /
COPY --link --from=base-build-harfbuzz			/out /
COPY --link --from=base-build-jpeg-turbo		/out /
COPY --link --from=base-build-libffi			/out /
COPY --link --from=base-build-libpng			/out /
COPY --link --from=base-build-libtiff			/out /
COPY --link --from=base-build-libxml2			/out /
COPY --link --from=base-build-lzo2				/out /
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-pixman			/out /
COPY --link --from=base-build-shared-mime-info	/out /
COPY --link --from=base-build-zlib				/out /
RUN meson setup build/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D build-testsuite=false \
	-D build-examples=false
RUN meson install -C build/ --destdir /out
# pangoft2 >>>
# rust <<<
FROM base-build AS base-build-rust
WORKDIR /src/rust
RUN wget -q https://sh.rustup.rs -O install_rust.sh && chmod +x install_rust.sh
RUN ./install_rust.sh -y --profile minimal
ENV HOME=/root
ENV PATH=/root/.cargo/bin:${PATH}
# The default build CFLAGS break some cargo builds (probably -flto), blank it for the rust context
ENV CFLAGS=
ENV CXXFLAGS=
ENV LDFLAGS=
RUN cargo install cargo-c
RUN set > /tmp/vars
# rust >>>
# rsvg <<<
FROM base-build-rust AS base-build-rsvg
WORKDIR /src/rsvg
RUN wget -q https://gitlab.gnome.org/GNOME/librsvg/-/archive/2.61.3/librsvg-2.61.3.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-cairo				/out /
COPY --link --from=base-build-expat				/out /
COPY --link --from=base-build-fontconfig		/out /
COPY --link --from=base-build-freebidi			/out /
COPY --link --from=base-build-freetype			/out /
COPY --link --from=base-build-gdk-pixbuf2		/out /
COPY --link --from=base-build-gettext			/out /
COPY --link --from=base-build-glib				/out /
COPY --link --from=base-build-gperf				/out /
COPY --link --from=base-build-harfbuzz			/out /
COPY --link --from=base-build-jpeg-turbo		/out /
COPY --link --from=base-build-libffi			/out /
COPY --link --from=base-build-libpng			/out /
COPY --link --from=base-build-libtiff			/out /
COPY --link --from=base-build-libxml2			/out /
COPY --link --from=base-build-lzo2				/out /
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-pangoft2			/out /
COPY --link --from=base-build-pixman			/out /
COPY --link --from=base-build-shared-mime-info	/out /
COPY --link --from=base-build-zlib				/out /
RUN meson setup build/ --buildtype release --default-library static --optimization 2 --prefer-static \
	-D introspection=disabled \
	-D rsvg-convert=disabled \
	-D docs=disabled \
	-D vala=disabled \
	-D tests=false
RUN meson install -C build/ --destdir /out
# rsvg >>>
# imlib2 <<<
FROM base-build AS base-build-imlib2
WORKDIR /src/imlib2
RUN wget -q https://downloads.sourceforge.net/enlightenment/imlib2-1.12.5.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=base-build-freetype			/out /
COPY --link --from=base-build-jpeg-turbo		/out /
COPY --link --from=base-build-libexif			/out /
COPY --link --from=base-build-libpng			/out /
COPY --link --from=base-build-libtiff			/out /
COPY --link --from=base-build-webp				/out /
COPY --link --from=base-build-zlib				/out /
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --disable-shared --disable-progs --disable-filters --without-x
RUN make -j all
RUN make DESTDIR=/out install
# imlib2 >>>
# Runtime library requirements (as static libs only) >>>

FROM base-build AS base
COPY --link --from=base-build-boost				/out /
COPY --link --from=base-build-cairo				/out /
COPY --link --from=base-build-expat				/out /
COPY --link --from=base-build-fontconfig		/out /
COPY --link --from=base-build-freebidi			/out /
COPY --link --from=base-build-freetype			/out /
COPY --link --from=base-build-gdk-pixbuf2		/out /
COPY --link --from=base-build-gettext			/out /
COPY --link --from=base-build-glib				/out /
COPY --link --from=base-build-gperf				/out /
COPY --link --from=base-build-harfbuzz			/out /
COPY --link --from=base-build-imlib2			/out /
COPY --link --from=base-build-jpeg-turbo		/out /
COPY --link --from=base-build-libexif			/out /
COPY --link --from=base-build-libffi			/out /
COPY --link --from=base-build-libpng			/out /
COPY --link --from=base-build-rsvg				/out /
COPY --link --from=base-build-libtiff			/out /
COPY --link --from=base-build-libxml2			/out /
COPY --link --from=base-build-lzo2				/out /
COPY --link --from=base-build-ncurses			/out /
COPY --link --from=base-build-ninja				/out /
COPY --link --from=base-build-pangoft2			/out /
COPY --link --from=base-build-pixman			/out /
COPY --link --from=base-build-readline			/out /
COPY --link --from=base-build-shared-mime-info	/out /
COPY --link --from=base-build-webp				/out /
COPY --link --from=base-build-zlib				/out /

# tcl-build <<<
# tcl-build-base <<<
FROM base AS tcl-build-base-common
RUN git config --global advice.detachedHead false

# tcl9.0 <<<
FROM tcl-build-base-common AS tcl-build-base-tcl9.0

# tcl: core-9-0-2 tag
WORKDIR /src/tcl
RUN wget -q https://core.tcl-lang.org/tcl/tarball/core-9-0-2/tcl.tar.gz -O - | tar xz --strip-components=1
WORKDIR /src/tcl/unix
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-64bit --enable-symbols
RUN make -j all CFLAGS="${CFLAGS_ARCH} -fprofile-generate=prof"
RUN make test CFLAGS="${CFLAGS_ARCH} -fprofile-generate=prof"
RUN make clean && make -j all CFLAGS="${CFLAGS_ARCH} -fprofile-use=prof -Wno-coverage-mismatch"
#RUN make -j all
RUN make install-binaries install-libraries install-tzdata install-packages install-headers install-private-headers
RUN make DESTDIR=/out install-binaries install-libraries install-tzdata install-packages install-headers install-private-headers
#RUN cp ../libtommath/tommath.h /usr/local/include/
RUN ln -s /usr/local/bin/tclsh9.0 /usr/local/bin/tclsh
RUN ln -s tclsh9.0 /out/usr/local/bin/tclsh
RUN mkdir /usr/local/lib/tcl9/site-tcl
RUN mkdir /out/usr/local/lib/tcl9/site-tcl
ARG SITETCL=/usr/local/lib/tcl9/site-tcl

# tclconfig: tip of main
WORKDIR /src/tclconfig
RUN wget -q https://core.tcl-lang.org/tclconfig/tarball/6e82b0097c/tclconfig.tar.gz -O - | tar xz --strip-components=1

# thread: tip of main
WORKDIR /src/thread
RUN wget -q https://core.tcl-lang.org/thread/tarball/thread-3-0-4/thread.tar.gz -O - | tar xz --strip-components=1
RUN ln -s ../tclconfig
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j
RUN make install-binaries install-libraries clean
RUN make DESTDIR=/out install-binaries install-libraries clean
# tcl9.0 >>>
# tcl8.7 <<<
FROM tcl-build-base-common AS tcl-build-base-tcl8.7

# tcl: tip of core-8-branch, now claimed to be defunct
WORKDIR /src/tcl
RUN wget -q https://core.tcl-lang.org/tcl/tarball/62ad42bba8/tcl.tar.gz -O - | tar xz --strip-components=1
WORKDIR /src/tcl/unix
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-64bit --enable-symbols
RUN make -j all CFLAGS="${CFLAGS_ARCH} -fprofile-generate=prof"
RUN make test CFLAGS="${CFLAGS_ARCH} -fprofile-generate=prof"
RUN make clean && make -j all CFLAGS="${CFLAGS_ARCH} -fprofile-use=prof -Wno-coverage-mismatch"
#RUN make -j
RUN make install-binaries install-libraries install-tzdata install-packages install-headers install-private-headers
RUN make DESTDIR=/out install-binaries install-libraries install-tzdata install-packages install-headers install-private-headers
#RUN cp ../libtommath/tommath.h /usr/local/include/
RUN ln -s /usr/local/bin/tclsh8.7 /usr/local/bin/tclsh
RUN ln -s tclsh8.7 /out/usr/local/bin/tclsh
RUN mkdir /usr/local/lib/tcl8/site-tcl
RUN mkdir /out/usr/local/lib/tcl8/site-tcl
ARG SITETCL=/usr/local/lib/tcl8/site-tcl

# tclconfig: tip of main
WORKDIR /src/tclconfig
RUN wget -q https://core.tcl-lang.org/tclconfig/tarball/6e82b0097c/tclconfig.tar.gz -O - | tar xz --strip-components=1

## thread: tip of thread3-for-tcl8
WORKDIR /src/thread
RUN wget -q https://core.tcl-lang.org/thread/tarball/thread-20250902124430-586530a607.tar.gz -O - | tar xz --strip-components=1
RUN ln -s ../tclconfig
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j
RUN make install-binaries install-libraries clean
RUN make DESTDIR=/out install-binaries install-libraries clean
# tcl8.7 >>>

FROM tcl-build-base-tcl${TCLVER} AS tcl-build-base
# tcl-build-base >>>

# package-jitc <<<
FROM tcl-build-base AS package-jitc
WORKDIR /src/jitc
RUN git clone -b v0.5.6 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/jitc .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make tcc tools
RUN make DESTDIR=/out install-binaries install-libraries
# package-jitc >>>
# package-tomcrypt <<<
FROM tcl-build-base AS package-tomcrypt
WORKDIR /src/tomcrypt
RUN wget -q https://github.com/cyanogilvie/tcl-tomcrypt/releases/download/v0.8.3/tomcrypt0.8.3.tar.gz -O - | tar xz --strip-components=1
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make DESTDIR=/out test install-binaries install-libraries
# package-tomcrypt >>>
# package-pgwire <<<
FROM tcl-build-base AS package-pgwire
WORKDIR /src/pgwire
RUN git clone -b v3.0.0b28 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/pgwire .
WORKDIR /src/pgwire/src
RUN make all && \
	mkdir -p /out/usr/local/lib/tcl8/site-tcl && \
    cp -a tm/* /out/usr/local/lib/tcl8/site-tcl
# package-pgwire >>>
# package-dedup <<<
FROM tcl-build-base AS package-dedup
WORKDIR /src/dedup
RUN git clone --recurse-submodules --shallow-submodules --branch v0.9.7 --single-branch --depth 1 https://github.com/cyanogilvie/dedup .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean && \
    cp /out/usr/local/lib/dedup*/dedupConfig.sh /out/usr/local/lib/
# package-dedup >>>
# package-reuri <<<
FROM tcl-build-base AS package-reuri
WORKDIR /src/reuri
RUN wget -q https://github.com/cyanogilvie/reuri/releases/download/v0.14.3/reuri0.14.3.tar.gz -O - | tar xz --strip-components=1
COPY --link --from=package-dedup /out /
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make tools
#RUN make DESTDIR=/out pgo install-binaries install-libraries clean
RUN make DESTDIR=/out install-binaries install-libraries clean
# package-reuri >>>
# package-rl_http <<<
FROM tcl-build-base AS package-rl_http
WORKDIR /src/rl_http
RUN git clone -b 1.20 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/RubyLane/rl_http .
RUN make DESTDIR=/out install
# package-rl_http >>>
# libbrotli <<<
FROM base-build AS base-build-libbrotli
WORKDIR /src/libbrotli
RUN wget -q https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz -O - | tar xz --strip-components=1
WORKDIR /src/libbrotli/build
RUN cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBROTLI_BUILD_TOOLS=OFF ..
RUN DESTDIR=/out cmake --build . --config Release --target install
# libbrotli >>>
# package-brotli <<<
FROM tcl-build-base AS package-brotli
WORKDIR /src/brotli
RUN git clone -q -b v0.3.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/tcl-brotli .
COPY --link --from=base-build-libbrotli			/out /
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make DESTDIR=/out install-binaries install-libraries clean
# package-brotli >>>
# package-rltest <<<
FROM tcl-build-base AS package-rltest
WORKDIR /src/rltest
RUN git clone -b v1.5.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/RubyLane/rltest .
RUN make DESTDIR=/out install-tm
# pacakge-rltest >>>
# package-names <<<
FROM tcl-build-base AS package-names
WORKDIR /src/names
RUN git clone -b v0.1.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/names .
RUN make test && make DESTDIR=/out install-tm
# package-names >>>
# package-prng <<<
FROM tcl-build-base AS package-prng
WORKDIR /src/prng
RUN git clone -b v0.7.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/prng .
RUN make test && make DESTDIR=/out install-tm
# package-prng >>>
# package-sqlite3 <<<
FROM tcl-build-base AS package-sqlite3
WORKDIR /src/sqlite3
RUN wget -q https://sqlite.org/2023/sqlite-autoconf-3410200.tar.gz -O - | tar xz --strip-components=1
WORKDIR /src/sqlite3/tea
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" && \
    make DESTDIR=/out all install-binaries install-libraries clean
# package-sqlite3 >>>
# package-pixel <<<
# Pixel: tip of master
FROM tcl-build-base AS package-pixel-core
WORKDIR /src/pixel
RUN git clone -q -b v3.5.3.4 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/pixel .
WORKDIR /src/pixel/pixel_core
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j install-binaries install-libraries
RUN make DESTDIR=/out install-binaries install-libraries
RUN cp pixelConfig.sh /usr/local/lib
RUN cp pixelConfig.sh /out/usr/local/lib

FROM package-pixel-core AS package-pixel-jpeg
WORKDIR /src/pixel/pixel_jpeg
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j DESTDIR=/out install-binaries install-libraries

FROM package-pixel-core AS package-pixel-png
WORKDIR /src/pixel/pixel_png
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j DESTDIR=/out install-binaries install-libraries

FROM package-pixel-core AS package-pixel-svg_cairo
WORKDIR /src/pixel/pixel_svg_cairo
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j DESTDIR=/out install-binaries install-libraries

FROM package-pixel-core AS package-pixel-webp
WORKDIR /src/pixel/pixel_webp
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j DESTDIR=/out install-binaries install-libraries

FROM package-pixel-core AS package-pixel-imlib2
WORKDIR /src/pixel/pixel_imlib2
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j DESTDIR=/out install-binaries install-libraries

FROM package-pixel-core AS package-pixel-phash
## pHash
WORKDIR /src/phash
RUN wget -q https://github.com/aetilius/pHash/archive/dea9ffc.tar.gz -O - | tar xz --strip-components=1
RUN CFLAGS="${CFLAGS} `pkg-config libtiff-4 --static --cflags`" LIBS="${LIBS} `pkg-config libtiff-4 --static --libs`" cmake -DPHASH_DYNAMIC=OFF -DPHASH_STATIC=ON .
RUN make install
#RUN DESTDIR=/out make install
RUN cp -a third-party/CImg/* /usr/local/include

WORKDIR /src/pixel/pixel_phash
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make -j DESTDIR=/out install-binaries install-libraries
# package-pixel >>>
# package-tdom <<<
FROM tcl-build-base AS package-tdom
# gumbo (not a tcl package, needed for tdom)
WORKDIR /src/gumbo
RUN wget -q https://github.com/google/gumbo-parser/archive/v0.10.1.tar.gz -O - | tar xz --strip-components=1
RUN ./autogen.sh && \
	./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-static=no && \
	make -j all && \
	make install && \
	make DESTDIR=/out install

# tdom - fork with RL changes and extra stubs exports and misc
WORKDIR /src/tdom
RUN git clone -b cyan-0.9.3.2 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/RubyLane/tdom .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols --enable-html5 && \
    make -j all && \
    make DESTDIR=/out install-binaries install-libraries
# package-tdom >>>
# package-parse_args <<<
FROM tcl-build-base AS package-parse_args
WORKDIR /src/parse_args
RUN git clone --recurse-submodules --shallow-submodules --branch v0.5.1 --single-branch --depth 1 https://github.com/RubyLane/parse_args .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-parse_args >>>
# package-rl_json <<<
FROM tcl-build-base AS package-rl_json
WORKDIR /src/rl_json
RUN git clone --recurse-submodules --shallow-submodules --branch 0.15.7 --single-branch --depth 1 https://github.com/RubyLane/rl_json .
RUN autoconf
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols --enable-cbor
RUN make -j
RUN make DESTDIR=/out install-binaries install-libraries
# package-rl_json >>>
# package-hash <<<
FROM tcl-build-base AS package-hash
WORKDIR /src/hash
RUN git clone -b v0.3.2 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/hash .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
    make -j all && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-hash >>>
# package-unix_sockets <<<
FROM tcl-build-base AS package-unix_sockets
WORKDIR /src/unix_sockets
RUN wget -q https://github.com/cyanogilvie/unix_sockets/releases/download/v0.5.2/unix_sockets0.5.tar.gz -O - | tar xz --strip-components=1
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make DESTDIR=/out install-binaries install-libraries clean
# package-unix_sockets >>>
# package-tclreadline <<<
FROM tcl-build-base AS package-tclreadline
WORKDIR /src/tclreadline
#RUN git clone -b v2.4.1.cyan1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/tclreadline .
RUN wget -q https://github.com/cyanogilvie/tclreadline/releases/download/v2.4.1.cyan11/tclreadline2.4.1.tar.gz -O - | tar xz --strip-components=1
RUN ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}"
RUN make DESTDIR=/out install-binaries install-libraries clean
COPY tcl/tclshrc /out/root/.tclshrc
# package-tclreadline >>>
# package-tclsignal <<<
FROM tcl-build-base AS package-tclsignal
WORKDIR /src/tclsignal
RUN git clone -b v1.4.4.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/tclsignal .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
	make -j all && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-tclsignal >>>
# package-type <<<
FROM tcl-build-base AS package-type
WORKDIR /src/type
RUN git clone -q -b v0.2.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/type .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-type >>>
# package-inotify <<<
FROM tcl-build-base AS package-inotify
WORKDIR /src/inotify
RUN git clone -q -b v2.2.1 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/inotify .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-inotify >>>
# package-parsetcl <<<
FROM tcl-build-base AS package-parsetcl
COPY --link --from=package-tdom /out /
WORKDIR /src/parsetcl
RUN git clone -q -b v0.1.2 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/parsetcl .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
	make DESTDIR=/out install-binaries install-libraries clean
# package-parsetcl >>>
# package-ck <<<
FROM tcl-build-base AS package-ck
WORKDIR /src/ck
RUN git clone -q -b cyan3 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/tcltk-depot/ck .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols
RUN make all -j
RUN make DESTDIR=/out install-binaries install-libraries
# package-ck >>>
# package-chantricks <<<
FROM tcl-build-base AS package-chantricks
WORKDIR /src/chantricks
RUN git clone --recurse-submodules --shallow-submodules --branch v1.0.7 --single-branch --depth 1 https://github.com/cyanogilvie/chantricks .
RUN make DESTDIR=/out install-tm
# package-chantricks >>>
# package-openapi <<<
FROM tcl-build-base AS package-openapi
WORKDIR /src/openapi
RUN git clone --recurse-submodules --shallow-submodules --branch v0.4.12 --single-branch --depth 1 https://github.com/cyanogilvie/tcl-openapi .
RUN mkdir -p /out/usr/local/lib/tcl8/site-tcl && \
	cp *.tm /out/usr/local/lib/tcl8/site-tcl
# package-openapi >>>
# package-resolve <<<
FROM tcl-build-base AS package-resolve
WORKDIR /src/resolve
RUN git clone --recurse-submodules --shallow-submodules --branch v0.10 --single-branch --depth 1 https://github.com/cyanogilvie/resolve .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-resolve >>>
# package-tcllib <<<
FROM tcl-build-base AS package-tcllib
WORKDIR /src/tcllib
RUN git clone -b cyan-1-21-3 --recurse-submodules --shallow-submodules --single-branch --depth 1 https://github.com/cyanogilvie/tcllib .
RUN ./configure && make DESTDIR=/out install-libraries install-applications clean
# package-tcllib >>>
# package-docker <<<
FROM tcl-build-base AS package-docker
COPY --link --from=package-chantricks	/out /
COPY --link --from=package-openapi		/out /
COPY --link --from=package-rl_json		/out /
COPY --link --from=package-parse_args	/out /
COPY --link --from=package-tcllib		/out /
WORKDIR /src/docker
RUN git clone --recurse-submodules --shallow-submodules --branch v0.9.3 --single-branch --depth 1 https://github.com/cyanogilvie/tcl-docker-client .
RUN make DESTDIR=/out TM_MODE=-ziplet install-tm
# package-docker >>>
# package-gc_class <<<
FROM tcl-build-base AS package-gc_class
WORKDIR /src/gc_class
RUN git clone --recurse-submodules --shallow-submodules --branch v1.0 --single-branch --depth 1 https://github.com/RubyLane/gc_class .
RUN mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp gc_class*.tm /out/usr/local/lib/tcl8/site-tcl
# package-gc_class >>>
# package-tbuild <<<
FROM tcl-build-base AS package-tbuild
WORKDIR /src/tbuild
RUN git clone --recurse-submodules --shallow-submodules --branch v0.5 --single-branch --depth 1 https://github.com/cyanogilvie/tbuild .
RUN mkdir -p /out/usr/local/bin && \
	cp tbuild-lite.tcl /out/usr/local/bin/tbuild-lite && \
	chmod +x /out/usr/local/bin/tbuild-lite
# package-tbuild >>>
# tbuild-base <<<
FROM tcl-build-base AS tbuild-base
COPY --from=package-tbuild /out /
# tbuild-base >>>
# package-cflib <<<
FROM tbuild-base AS package-cflib
WORKDIR /src/cflib
RUN git clone --recurse-submodules --shallow-submodules --branch 1.16.1 --single-branch --depth 1 https://github.com/cyanogilvie/cflib .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-cflib >>>
# package-sop <<<
FROM tbuild-base AS package-sop
WORKDIR /src/sop
RUN git clone --recurse-submodules --shallow-submodules --branch 1.7.2 --single-branch --depth 1 https://github.com/cyanogilvie/sop .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-sop >>>
# package-netdgram <<<
FROM tbuild-base AS package-netdgram
WORKDIR /src/netdgram
RUN git clone --recurse-submodules --shallow-submodules --branch v0.9.12 --single-branch --depth 1 https://github.com/cyanogilvie/netdgram .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp -a tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-netdgram >>>
# package-evlog <<<
FROM tbuild-base AS package-evlog
WORKDIR /src/evlog
RUN git clone --recurse-submodules --shallow-submodules --branch v0.3.1 --single-branch --depth 1 https://github.com/cyanogilvie/evlog .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-evlog >>>
# package-dsl <<<
FROM tbuild-base AS package-dsl
WORKDIR /src/dsl
RUN git clone --recurse-submodules --shallow-submodules --branch v0.5 --single-branch --depth 1 https://github.com/cyanogilvie/dsl .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-dsl >>>
# package-logging <<<
FROM tbuild-base AS package-logging
WORKDIR /src/logging
RUN git clone --recurse-submodules --shallow-submodules --branch v0.3 --single-branch --depth 1 https://github.com/cyanogilvie/logging .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-logging >>>
# package-crypto <<<
FROM tbuild-base AS package-crypto
WORKDIR /src/crypto
RUN git clone --recurse-submodules --shallow-submodules --branch 0.6 --single-branch --depth 1 https://github.com/cyanogilvie/crypto .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-crypto >>>
# package-datasource <<<
FROM tbuild-base AS package-datasource
WORKDIR /src/datasource
RUN git clone --recurse-submodules --shallow-submodules --branch v0.2.4 --single-branch --depth 1 https://github.com/cyanogilvie/datasource .
RUN tbuild-lite && mkdir -p /out/usr/local/lib/tcl8/site-tcl && cp tm/tcl/* /out/usr/local/lib/tcl8/site-tcl/
# package-datasource >>>
# package-m2 <<<
FROM tbuild-base AS package-m2
WORKDIR /src/m2
#RUN git clone --recurse-submodules --shallow-submodules --branch v0.43.15 --single-branch --depth 1 https://github.com/cyanogilvie/m2 .
RUN git clone --branch v0.43.15 --single-branch --depth 1 https://github.com/cyanogilvie/m2 .
RUN mkdir -p /out/usr/local/lib/tcl8/site-tcl && \
	tbuild-lite build_tm m2 && \
	cp -r tm/tcl/*			/out/usr/local/lib/tcl8/site-tcl/ && \
	mkdir -p				/out/usr/local/opt/m2 && \
	cp -r m2_node			/out/usr/local/opt/m2/ && \
	cp -r tools				/out/usr/local/opt/m2/ && \
	cp -r authenticator		/out/usr/local/opt/m2/ && \
	cp -r admin_console		/out/usr/local/opt/m2/ && \
	mkdir -p				/out/etc/codeforge/authenticator && \
	cp -r plugins			/out/etc/codeforge/authenticator/
COPY m2/m2_node				/out/usr/local/bin/
COPY m2/authenticator		/out/usr/local/bin/
COPY m2/m2_keys				/out/usr/local/bin/
COPY m2/m2_admin_console	/out/usr/local/bin/
# package-m2 >>>
# package-tdbc <<<
# tip of connection-pool-git branch
FROM tcl-build-base AS package-tdbc
WORKDIR /src/tdbc
RUN wget -q https://github.com/cyanogilvie/tdbc/archive/1f8b684.tar.gz -O - | tar xz --strip-components=1
RUN ln -s ../tclconfig && \
    autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
    make -j all && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-tdbc >>>
# package-s2n <<<
FROM tcl-build-base AS package-s2n
WORKDIR /src/tcl-s2n
RUN wget -q https://github.com/cyanogilvie/tcl-s2n/releases/download/v0.5.1/tcl-s2n-0.5.1.tar.gz -O - | tar xz --strip-components=1
RUN ./configure CFLAGS="-O3" --enable-symbols
#RUN make deps AR_ECHO="echo -e"
RUN make deps -j
RUN test -e local/lib64/libs2n.a && cp local/lib64/libs2n.a local/lib/ || true
RUN make DESTDIR=/out install-binaries install-libraries
# package-s2n >>>
# package-sockopt <<<
FROM tcl-build-base AS package-sockopt
COPY --link --from=package-rl_json /out /
WORKDIR /src/sockopt
RUN git clone --recurse-submodules --shallow-submodules --branch v0.2.1 --single-branch --depth 1 https://github.com/cyanogilvie/sockopt .
RUN autoconf && ./configure CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" --enable-symbols && \
    make DESTDIR=/out install-binaries install-libraries clean
# package-sockopt >>>
# package-tty <<<
FROM tcl-build-base AS package-tty
WORKDIR /src/tty
RUN git clone --recurse-submodules --shallow-submodules --branch v0.6.1 --single-branch --depth 1 https://github.com/cyanogilvie/tcl-tty .
RUN make DESTDIR=/out install-tm
# package-tty >>>
# package-flock <<<
FROM tcl-build-base AS package-flock
WORKDIR /src/flock
RUN git clone --recurse-submodules --shallow-submodules --branch v0.6.1 --single-branch --depth 1 https://github.com/cyanogilvie/flock .
RUN make DESTDIR=/out install
# package-flock >>>
# package-aio <<<
FROM tcl-build-base AS package-aio
WORKDIR /src/aio
RUN git clone --recurse-submodules --shallow-submodules --branch v1.7.1 --single-branch --depth 1 https://github.com/cyanogilvie/aio .
RUN make test && \
	make DESTDIR=/out install-tm
# package-aio >>>
# package-aws <<<
FROM tcl-build-base AS package-aws
WORKDIR /src/aws-tcl
COPY --link --from=package-tdom			/out /
COPY --link --from=package-parse_args	/out /
COPY --link --from=package-rl_json		/out /
COPY --link --from=package-hash			/out /
COPY --link --from=package-dedup		/out /
COPY --link --from=package-reuri		/out /
COPY --link --from=package-resolve		/out /
COPY --link --from=package-gc_class		/out /
COPY --link --from=package-rl_http		/out /
COPY --link --from=package-tcllib		/out /
COPY --link --from=package-chantricks	/out /
RUN git clone --recurse-submodules --shallow-submodules --branch v2.0a17 --single-branch --depth 1 https://github.com/cyanogilvie/aws-tcl .
RUN ldconfig || true
RUN make DESTDIR=/out install
# package-aws >>>
# aklomp/base64 <<<
FROM tcl-build-base AS aklomp-base64
WORKDIR /src/aklomp_base64
RUN wget -q https://github.com/aklomp/base64/archive/e77bd70bdd860c52c561568cffb251d88bba064c.tar.gz -O - | tar xz --strip-components=1
#RUN	if [ "${TARGETARCH}" = "arm64" ]; \
#	then \
#		dnf install -q -y clang; \
#	fi
#RUN make CC=clang CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" NEON64_CFLAGS=" "
#RUN mkdir -p /out/usr/local/lib; clang -shared -o /out/usr/local/lib/libaklompbase64.so lib/libbase64.o
RUN mkdir -p /out/usr/local/lib /out/usr/local/include
RUN	if [ "${TARGETARCH}" = "arm64" ]; \
	then \
		CC=gcc CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" NEON64_CFLAGS=" " make lib/config.h lib/libbase64.o && \
		gcc -shared -o /out/usr/local/lib/libaklompbase64.so lib/libbase64.o; \
	else \
		CFLAGS="${CFLAGS_ARCH}" LDFLAGS="${LDFLAGS_ARCH}" AVX2_CFLAGS=-mavx2 SSSE3_CFLAGS=-mssse3 SSE41_CFLAGS=-msse4.1 SSE42_CFLAGS=-msse4.2 AVX_CFLAGS=-mavx make lib/config.h lib/libbase64.o && \
		gcc -shared -o /out/usr/local/lib/libaklompbase64.so lib/libbase64.o; \
	fi
RUN cp lib/libbase64.o /out/usr/local/lib
RUN cp include/libbase64.h /out/usr/local/include
# aklomp/base64 >>>
# package-mtag_stack <<<
#FROM tcl-build-base AS package-mtag_stack
#WORKDIR /src/mtag_stack
#RUN wget -q https://github.com/cyanogilvie/mtag_stack/releases/download/v2.0/mtag_stack2.0.tar.gz -O - | tar xz --strip-components=1
#RUN make CFLAGS_OPTIMIZE="${CFLAGS_ARCH}" DESTDIR=/out clean pgo install clean
# package-mtag_stack >>>
# package-ip <<<
FROM tcl-build-base AS package-ip
WORKDIR /src/ip
RUN git clone --recurse-submodules --shallow-submodules --branch v1.2 --single-branch --depth 1 https://github.com/cyanogilvie/tcl-ip .
RUN make DESTDIR=/out install-tm
# package-ip >>>

#FROM tcl-build-base AS tcl-build
FROM src AS tcl-build
COPY --link --from=tcl-build-base			/out /
COPY --link --from=package-rl_http			/out /
COPY --link --from=package-dedup			/out /
COPY --link --from=package-jitc				/out /
COPY --link --from=package-tomcrypt			/out /
COPY --link --from=package-pgwire			/out /
COPY --link --from=package-reuri			/out /
COPY --link --from=package-brotli			/out /
COPY --link --from=package-rltest			/out /
COPY --link --from=package-names			/out /
COPY --link --from=package-prng				/out /
COPY --link --from=package-sqlite3			/out /

COPY --link --from=package-pixel-core		/out /
COPY --link --from=package-pixel-jpeg		/out /
COPY --link --from=package-pixel-png		/out /
COPY --link --from=package-pixel-svg_cairo	/out /
COPY --link --from=package-pixel-webp		/out /
COPY --link --from=package-pixel-imlib2		/out /
COPY --link --from=package-pixel-phash		/out /

COPY --link --from=package-tdom				/out /
COPY --link --from=package-parse_args		/out /
COPY --link --from=package-rl_json			/out /
COPY --link --from=package-hash				/out /
COPY --link --from=package-unix_sockets		/out /
COPY --link --from=package-tclreadline		/out /
COPY --link --from=package-tclsignal		/out /
COPY --link --from=package-type				/out /
COPY --link --from=package-inotify			/out /
COPY --link --from=package-parsetcl			/out /
COPY --link --from=package-ck				/out /
COPY --link --from=package-resolve			/out /
COPY --link --from=package-tcllib			/out /
COPY --link --from=package-tdbc				/out /
COPY --link --from=package-s2n				/out /
COPY --link --from=package-sockopt			/out /
COPY --link --from=package-chantricks		/out /
COPY --link --from=package-openapi			/out /
COPY --link --from=package-docker			/out /
COPY --link --from=package-gc_class			/out /
COPY --link --from=package-tbuild			/out /
COPY --link --from=package-cflib			/out /
COPY --link --from=package-sop				/out /
COPY --link --from=package-netdgram			/out /
COPY --link --from=package-evlog			/out /
COPY --link --from=package-dsl				/out /
COPY --link --from=package-logging			/out /
COPY --link --from=package-crypto			/out /
COPY --link --from=package-datasource		/out /
COPY --link --from=package-m2				/out /
COPY --link --from=package-tty				/out /
COPY --link --from=package-flock			/out /
COPY --link --from=package-aio				/out /
COPY --link --from=package-aws				/out /
COPY --link --from=aklomp-base64			/out /
COPY --link --from=package-ip				/out /

#COPY --link --from=package-mtag_stack		/out /
RUN ldconfig || true

# misc local bits
COPY tcl/tm /usr/local/lib/tcl8/site-tcl
COPY tools/* /usr/local/bin/

# common_sighandler
COPY common_sighandler-*.tm /usr/local/lib/tcl8/site-tcl/

# meta
#RUN /usr/local/bin/package_report
# tcl-build >>>

# tcl-gdb <<<
FROM tcl-build AS tcl-gdb
RUN dnf install -q -y gdb vim
COPY --link --from=tcl-build-base		/src /src
COPY --link --from=package-rl_http		/src /src
COPY --link --from=package-dedup		/src /src
COPY --link --from=package-jitc			/src /src
COPY --link --from=package-pgwire		/src /src
COPY --link --from=package-reuri		/src /src
COPY --link --from=package-brotli		/src /src
COPY --link --from=package-rltest		/src /src
COPY --link --from=package-names		/src /src
COPY --link --from=package-prng			/src /src
COPY --link --from=package-sqlite3		/src /src
COPY --link --from=package-pixel		/src /src
COPY --link --from=package-tdom			/src /src
COPY --link --from=package-parse_args	/src /src
COPY --link --from=package-rl_json		/src /src
COPY --link --from=package-hash			/src /src
COPY --link --from=package-unix_sockets	/src /src
COPY --link --from=package-tclreadline	/src /src
COPY --link --from=package-tclsignal	/src /src
COPY --link --from=package-type			/src /src
COPY --link --from=package-inotify		/src /src
COPY --link --from=package-parsetcl		/src /src
COPY --link --from=package-ck			/src /src
COPY --link --from=package-resolve		/src /src
COPY --link --from=package-tcllib		/src /src
COPY --link --from=package-tdbc			/src /src
COPY --link --from=package-s2n			/src /src
COPY --link --from=package-sockopt		/src /src
COPY --link --from=package-chantricks	/src /src
COPY --link --from=package-openapi		/src /src
COPY --link --from=package-docker		/src /src
COPY --link --from=package-gc_class		/src /src
COPY --link --from=package-tbuild		/src /src
COPY --link --from=package-cflib		/src /src
COPY --link --from=package-sop			/src /src
COPY --link --from=package-netdgram		/src /src
COPY --link --from=package-evlog		/src /src
COPY --link --from=package-dsl			/src /src
COPY --link --from=package-logging		/src /src
COPY --link --from=package-crypto		/src /src
COPY --link --from=package-datasource	/src /src
COPY --link --from=package-m2			/src /src
COPY --link --from=package-tty			/src /src
COPY --link --from=package-flock		/src /src
COPY --link --from=package-aio			/src /src
COPY --link --from=package-aws			/src /src
COPY --link --from=aklomp-base64		/src /src
#COPY --link --from=package-mtag_stack	/src /src
COPY --link --from=package-ip			/src /src
WORKDIR /here
# tcl-gdb >>>

# tcl-build-stripped <<<
FROM src-dev AS tcl-build-stripped
RUN rm -rf /usr/local
COPY --link --from=tcl-build			/usr/local /usr/local
RUN find /usr/local -name "*.so" -print0 | xargs -0 strip
# tcl-build-stripped >>>

# tcl <<<
FROM src AS tcl
COPY --link --from=tcl-build			/usr/local /usr/local
COPY --link --from=tcl-build			/root/.tclshrc /root/
RUN ldconfig || true
WORKDIR /here
VOLUME /here
ENTRYPOINT ["tclsh"]
# tcl >>>

# tcl-stripped <<<
FROM src AS tcl-stripped
COPY --link --from=tcl-build-stripped	/usr/local /usr/local
COPY --link --from=tcl-build			/root/.tclshrc /root/
RUN ldconfig || true
WORKDIR /here
VOLUME /here
ENTRYPOINT ["tclsh"]
# tcl-stripped >>>

# m2 <<<
FROM tcl AS m2
RUN mkdir -p /etc/codeforge/authenticator/keys/env && \
	mkdir -p /etc/codeforge/authenticator/svc_keys && \
	mkdir -p /etc/codeforge/authenticator/plugins && \
	mkdir -p /var/lib/codeforge/authenticator
COPY config/authenticator.conf /etc/codeforge
COPY m2/m2_entrypoint /usr/local/bin/
COPY m2/m2_node /usr/local/bin/
COPY m2/authenticator /usr/local/bin/
COPY --from=tcl-build /etc/codeforge/authenticator/plugins /etc/codeforge/authenticator/plugins
EXPOSE 5300
EXPOSE 5301
EXPOSE 5350
#VOLUME /etc/codeforge
#VOLUME /var/lib/codeforge
VOLUME /tmp/m2
ENTRYPOINT ["m2_entrypoint"]
# m2 >>>

# m2-stripped <<<
FROM tcl-stripped AS m2-stripped
RUN mkdir -p /etc/codeforge/authenticator/keys/env && \
	mkdir -p /etc/codeforge/authenticator/svc_keys && \
	mkdir -p /etc/codeforge/authenticator/plugins && \
	mkdir -p /var/lib/codeforge/authenticator
COPY config/authenticator.conf /etc/codeforge
COPY m2/m2_entrypoint /usr/local/bin/
COPY m2/m2_node /usr/local/bin/
COPY m2/authenticator /usr/local/bin/
COPY --from=tcl-build /etc/codeforge/authenticator/plugins /etc/codeforge/authenticator/plugins
EXPOSE 5300
EXPOSE 5301
EXPOSE 5350
#VOLUME /etc/codeforge
#VOLUME /var/lib/codeforge
VOLUME /tmp/m2
ENTRYPOINT ["m2_entrypoint"]
# m2-stripped >>>

# vim: foldmethod=marker foldmarker=<<<,>>>
