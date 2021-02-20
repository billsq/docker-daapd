FROM ghcr.io/linuxserver/baseimage-alpine:3.12 as buildstage
############## build stage ##############

ARG DAAPD_RELEASE
ENV LIBSPOTIFY_VERSION 12.1.51
ENV ARCH x86_64

RUN \
 echo "**** install build packages ****" && \
 apk add --no-cache \
	alsa-lib-dev \
	autoconf \
	automake \
	avahi-dev \
	bash \
	bsd-compat-headers \
	confuse-dev \
	curl \
	curl-dev \
	ffmpeg-dev \
	file \
	flac-dev \
	g++ \
	gcc \
	gettext-dev \
	gnutls-dev \
	gperf \
	json-c-dev \
	libcurl \
	libevent-dev \
	libgcrypt-dev \
	libogg-dev \
	libplist-dev \
	libressl-dev \
	libsodium-dev \
	libtool \
	libunistring-dev \
	libwebsockets-dev \
	make \
	openjdk8-jre-base \
	protobuf-c-dev \
	sqlite-dev \
	taglib-dev \
	tar && \
 apk add --no-cache \
	--repository http://nl.alpinelinux.org/alpine/edge/community \
	mxml-dev && \
 echo "**** make antlr wrapper ****" && \
 mkdir -p \
	/tmp/source/forked-daapd && \
 echo \
	"#!/bin/bash" > /tmp/source/antlr3 && \
 echo \
	"exec java -cp /tmp/source/antlr-3.4-complete.jar org.antlr.Tool \"\$@\"" >> /tmp/source/antlr3 && \
 chmod a+x /tmp/source/antlr3 && \
 curl -o \
 /tmp/source/antlr-3.4-complete.jar -L \
	http://www.antlr3.org/download/antlr-3.4-complete.jar && \
 echo "**** compile and install antlr3c ****" && \
 curl -o \
 /tmp/libantlr3c-3.4.tar.gz -L \
	https://github.com/antlr/website-antlr3/raw/gh-pages/download/C/libantlr3c-3.4.tar.gz && \
 tar xf /tmp/libantlr3c-3.4.tar.gz  -C /tmp && \
 cd /tmp/libantlr3c-3.4 && \
 ./configure --enable-64bit --prefix=/usr && \
 make && \
 make DESTDIR=/tmp/antlr3c-build install && \
 export LDFLAGS="-L/tmp/antlr3c-build/usr/lib" && \
 export CFLAGS="-I/tmp/antlr3c-build/usr/include" && \
 echo "**** compile owntone-server ****" && \
 if [ -z ${DAAPD_RELEASE+x} ]; then \
	DAAPD_RELEASE=$(curl -sX GET "https://api.github.com/repos/owntone/owntone-server/releases/latest" \
	| awk '/tag_name/{print $4;exit}' FS='[""]'); \
 fi && \
 curl -L https://github.com/mopidy/libspotify-archive/blob/master/libspotify-${LIBSPOTIFY_VERSION}-Linux-${ARCH}-release.tar.gz?raw=true | tar -xzf- -C /tmp/source/ && \
 mv /tmp/source/libspotify* /tmp/source/libspotify && \
 sed -i 's/ldconfig//' /tmp/source/libspotify/Makefile && \
 make -C /tmp/source/libspotify prefix=/tmp/libspotify-build install && \
 rm -rf /tmp/source/libspotify && \
 export LIBSPOTIFY_CFLAGS="-I/tmp/libspotify-build/include" && \
 export LIBSPOTIFY_LIBS="/tmp/libspotify-build/lib/libspotify.so" && \
 curl -o \
 /tmp/source/forked.tar.gz -L \
	"https://github.com/owntone/owntone-server/archive/${DAAPD_RELEASE}.tar.gz" && \
 tar xf /tmp/source/forked.tar.gz -C \
	/tmp/source/forked-daapd --strip-components=1 && \
 export PATH="/tmp/source:$PATH" && \
 cd /tmp/source/forked-daapd && \
 autoreconf -i -v && \
 ./configure \
	--build=$CBUILD \
	--enable-chromecast \
	--enable-itunes \
	--enable-lastfm \
	--enable-mpd \
    --enable-spotify \
	--host=$CHOST \
	--infodir=/usr/share/info \
	--localstatedir=/var \
	--mandir=/usr/share/man \
	--prefix=/usr \
	--sysconfdir=/etc && \
 make && \
 make DESTDIR=/tmp/daapd-build install && \
 mv /tmp/daapd-build/etc/forked-daapd.conf /tmp/daapd-build/etc/forked-daapd.conf.orig

############## shairport-sync build stage ##############
FROM alpine AS shairport-sync-builder-base
# General Build System:
RUN apk -U add \
        git \
        build-base \
        autoconf \
        automake \
        libtool \
        dbus \
        su-exec \
        alsa-lib-dev \
        libdaemon-dev \
        popt-dev \
        mbedtls-dev \
        soxr-dev \
        avahi-dev \
        libconfig-dev \
        libsndfile-dev \
        mosquitto-dev \
        xmltoman

# ALAC Build System:
FROM shairport-sync-builder-base AS builder-alac

RUN git clone https://github.com/mikebrady/alac
WORKDIR alac
RUN autoreconf -fi
RUN ./configure
RUN make
RUN make install

# Shairport Sync Build System:
FROM shairport-sync-builder-base AS builder-sps

# This may be modified by the Github Action Workflow.
ENV SHAIRPORT_SYNC_BRANCH 3.3.7

COPY --from=builder-alac /usr/local/lib/libalac.* /usr/local/lib/
COPY --from=builder-alac /usr/local/lib/pkgconfig/alac.pc /usr/local/lib/pkgconfig/alac.pc
COPY --from=builder-alac /usr/local/include /usr/local/include

RUN git clone https://github.com/mikebrady/shairport-sync
WORKDIR shairport-sync
RUN git checkout "$SHAIRPORT_SYNC_BRANCH"
RUN autoreconf -fi
RUN ./configure \
              --with-alsa \
              --with-dummy \
              --with-pipe \
              --with-stdout \
              --with-avahi \
              --with-ssl=mbedtls \
              --with-soxr \
              --sysconfdir=/etc \
              --with-dbus-interface \
              --with-mpris-interface \
              --with-mqtt-client \
              --with-apple-alac \
              --with-convolution
RUN make -j $(nproc)
RUN make install

############## runtime stage ##############
FROM ghcr.io/linuxserver/baseimage-alpine:3.12

# set version label
ARG BUILD_DATE
ARG VERSION
LABEL build_version="Linuxserver.io version:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="BernsteinA"

RUN \
 echo "**** install runtime packages ****" && \
 apk add --no-cache \
	avahi \
	confuse \
	dbus \
	ffmpeg \
	json-c \
	libcurl \
	libevent \
	libgcrypt \
	libplist \
	libressl \
	libsodium \
	libunistring \
	libwebsockets \
	protobuf-c \
	sqlite \
	sqlite-libs \
	alsa-lib \
	popt \
	glib \
	mbedtls \
	soxr \
	libconfig \
	libsndfile \
	mosquitto-libs \
	su-exec \
	libgcc \
	libgc++ && \
 apk add --no-cache \
	--repository http://nl.alpinelinux.org/alpine/edge/community \
	mxml

# copy buildstage and local files
COPY --from=buildstage /tmp/daapd-build/ /
COPY --from=buildstage /tmp/antlr3c-build/ /
COPY --from=buildstage /tmp/libspotify-build/ /
COPY --from=builder-alac /usr/local/lib/libalac.* /usr/local/lib/
COPY --from=builder-sps /etc/shairport-sync* /etc/
COPY --from=builder-sps /etc/dbus-1/system.d/shairport-sync-dbus.conf /etc/dbus-1/system.d/
COPY --from=builder-sps /etc/dbus-1/system.d/shairport-sync-mpris.conf /etc/dbus-1/system.d/
COPY --from=builder-sps /usr/local/bin/shairport-sync /usr/local/bin/shairport-sync
COPY root/ /

RUN mkdir /pipe
RUN mkfifo /pipe/shairport-sync
RUN mkfifo /pipe/shairport-sync.metadata
RUN chmod 777 /pipe/shairport-sync*

# Add the abc user to the pre-existing audio group, which has ID 29, for access to the ALSA stuff
RUN addgroup -g 29 docker_audio && addgroup abc docker_audio

# ports and volumes
EXPOSE 3689
VOLUME /config /music
