ARG BASE_IMAGE=python:3-slim-bookworm

FROM debian:bookworm-slim as librdkafka
SHELL [ "/bin/sh", "-ec" ]

ARG LIBRDKAFKA_REPO_URI=https://github.com/confluentinc/librdkafka
ARG LIBRDKAFKA_VERSION=2.2.0
ARG LIBRDKAFKA_GITREF=v${LIBRDKAFKA_VERSION}
ARG LIBRDKAFKA_URI=${LIBRDKAFKA_REPO_URI}/archive/${LIBRDKAFKA_GITREF}.tar.gz
ARG LIBRDKAFKA_SHA256=af9a820cbecbc64115629471df7c7cecd40403b6c34bfdbb9223152677a47226

ENV LIBRDKAFKA_TARBALL=/tmp/librdkafka.tar.gz

ENV BUILD_DEPS='build-essential libcurl4-openssl-dev libffi-dev liblz4-dev libsasl2-dev libssl-dev libzstd-dev zlib1g-dev' \
    DEB_BUILD_OPTIONS='hardening=+all,-pie,-stackprotectorstrong optimize=-lto' \
    DEB_LDFLAGS_APPEND='-s' \
    _CFLAGS_PREPEND='-g -O3 -fPIC -flto=2 -fuse-linker-plugin -ffat-lto-objects -flto-partition=none' \
    _CFLAGS_STRIP='-g -O2'

ADD "${LIBRDKAFKA_URI}"  "${LIBRDKAFKA_TARBALL}"
RUN ls -ldGg "${LIBRDKAFKA_TARBALL}" ; \
    [ -f "${LIBRDKAFKA_TARBALL}" ] ; \
    s=$(sha256sum -b "${LIBRDKAFKA_TARBALL}" | awk '{print $1}') ; \
    [ "$s" = "${LIBRDKAFKA_SHA256}" ] || { \
        echo "ERROR: tarball sha256 mismatch!" ; \
        echo "URI: ${LIBRDKAFKA_URI}" ; \
        echo "SHA256:" ; \
        echo "  Expected: ${LIBRDKAFKA_SHA256}" ; \
        echo "  Got:      $s" ; \
        exit 1 ; \
    }

## save initial package list
RUN dpkg-query --show --showformat='${Package}:${Architecture}|${db:Status-Abbrev}\n' \
    | sed -En '/^(.+)\|[hi]i $/{s//\1/;p}' | sort -V \
    > /tmp/apt.0

ENV DEBCONF_NONINTERACTIVE_SEEN=true \
    DEBIAN_FRONTEND=noninteractive \
    DEBIAN_PRIORITY=critical \
    TERM=linux
RUN apt-get update ; \
    apt-get -y install ${BUILD_DEPS} ; \
    apt-get -y clean

## propagate remaining variables to dpkg-buildflags
ENV DEB_CFLAGS_STRIP="${_CFLAGS_STRIP}" \
    DEB_CFLAGS_PREPEND="${_CFLAGS_PREPEND}" \
    DEB_CXXFLAGS_STRIP="${_CFLAGS_STRIP}" \
    DEB_CXXFLAGS_PREPEND="${_CFLAGS_PREPEND}"

COPY /patches/librdkafka.patch  /tmp/

## build librdkafka already!
RUN cd /tmp ; \
    mkdir librdkafka ; \
    cd librdkafka ; \
    eval "$(dpkg-buildflags --export=sh)" ; \
    tar --strip-components=1 -xf ${LIBRDKAFKA_TARBALL} ; \
    patch -p1 < /tmp/librdkafka.patch ; \
    ./configure \
      --prefix=/usr/local \
      --sysconfdir=/etc \
      --localstatedir=/var \
      --runstatedir=/run \
    ; \
    # make -j2 libs ; \
    make -j$(nproc) libs ; \
    make -j1 install-subdirs ; \
    ## remove unused things
    rm -rf /usr/local/share/doc /usr/local/lib/librdkafka*.a ; \
    ## cleanup
    cd /tmp ; \
    rm -rf librdkafka*

## determine runtime dependencies for librdkafka
RUN find /usr/local/lib/ -name '*.so*' -type f -exec \
      env -u LD_PRELOAD ldd '{}' '+' \
    | grep -F ' => /' | awk '{print $3}' \
    | grep -Ev '^(/usr/local/)' \
    ## quirk for merged-usr
    | sed -nE '/^.+$/{p;s,^/lib/,/usr/lib/,p}' \
    | sort -uV | xargs -r dpkg-query --search 2>/dev/null \
    | sed -E 's/^(\S+): .+$/\1/' | sort -uV \
    > /tmp/apt.rundeps

## minimize runtime dependencies
RUN set +e ; \
    grep -Fxv -f /tmp/apt.0 /tmp/apt.rundeps > /tmp/apt.manual ; \
    set -e ; \
    xargs -rt -a /tmp/apt.manual apt-mark manual ; \
    apt-get -y remove ${BUILD_DEPS} ; \
    apt-get -y autoremove ; \
    apt-get -y clean ; \
    rm /tmp/apt.rundeps /tmp/apt.manual

## save new package list
RUN dpkg-query --show --showformat='${Package}:${Architecture}|${db:Status-Abbrev}\n' \
    | sed -En '/^(.+)\|[hi]i $/{s//\1/;p}' | sort -V \
    > /tmp/apt.1

## compute package list diff
RUN set +e ; \
    grep -Fxv -f /tmp/apt.0 /tmp/apt.1 > /usr/local/etc/librdkafka.apt.list ; \
    set -e ; \
    rm /tmp/apt.0 /tmp/apt.1

## ---

FROM ${BASE_IMAGE} as aldente
SHELL [ "/bin/sh", "-ec" ]

ENV BUILD_DEPS='build-essential libffi-dev libkrb5-dev libsasl2-dev libssl-dev' \
    PIP_BUILD_FROM_SRC='cffi,confluent-kafka' \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY --from=librdkafka  /usr/local/  /usr/local/

## save initial package list
RUN dpkg-query --show --showformat='${Package}:${Architecture}|${db:Status-Abbrev}\n' \
    | sed -En '/^(.+)\|[hi]i $/{s//\1/;p}' | sort -V \
    > /tmp/apt.0

ENV DEBCONF_NONINTERACTIVE_SEEN=true \
    DEBIAN_FRONTEND=noninteractive \
    DEBIAN_PRIORITY=critical \
    TERM=linux
RUN apt-get update ; \
    xargs -rt -a /usr/local/etc/librdkafka.apt.list apt-get -y install ; \
    rm /usr/local/etc/librdkafka.apt.list ; \
    ldconfig ; \
    apt-get -y install ${BUILD_DEPS} ; \
    apt-get -y clean

## install required python packages
COPY /requirements.txt  /tmp/
ENV PIP_ARGS='--no-cache-dir --disable-pip-version-check --root-user-action=ignore'
RUN pip install ${PIP_ARGS} \
      --no-binary="${PIP_BUILD_FROM_SRC}" \
      -r /tmp/requirements.txt

## strip debug info from installed python packages
RUN find /usr/local/lib/python*/site-packages/ -name '*.cpython-*.so' -type f | sort -V > /tmp/shlib.list ; \
    xargs -r -a /tmp/shlib.list ls -lgG ; \
    echo ; \
    xargs -r -a /tmp/shlib.list strip --strip-debug ; \
    echo ; \
    xargs -r -a /tmp/shlib.list ls -lgG ; \
    rm /tmp/shlib.list

## determine runtime dependencies for installed python packages
RUN find /usr/local/lib/python*/site-packages/ -name '*.cpython-*.so' -type f -exec \
      env -u LD_PRELOAD ldd '{}' '+' \
    | grep -F ' => /' | awk '{print $3}' \
    | grep -Ev '^(/usr/local/)' \
    ## quirk for merged-usr
    | sed -nE '/^.+$/{p;s,^/lib/,/usr/lib/,p}' \
    | sort -uV | xargs -r dpkg-query --search 2>/dev/null \
    | sed -E 's/^(\S+): .+$/\1/' | sort -uV \
    > /tmp/apt.rundeps

## minimize runtime dependencies
RUN set +e ; \
    grep -Fxv -f /tmp/apt.0 /tmp/apt.rundeps > /tmp/apt.manual ; \
    set -e ; \
    xargs -rt -a /tmp/apt.manual apt-mark manual ; \
    apt-get -y remove ${BUILD_DEPS} ; \
    apt-get -y autoremove ; \
    apt-get -y clean ; \
    rm /tmp/apt.rundeps /tmp/apt.manual

## save new package list
RUN dpkg-query --show --showformat='${Package}:${Architecture}|${db:Status-Abbrev}\n' \
    | sed -En '/^(.+)\|[hi]i $/{s//\1/;p}' | sort -V \
    > /tmp/apt.1

## compute package list diff
RUN set +e ; \
    grep -Fxv -f /tmp/apt.0 /tmp/apt.1 > /usr/local/etc/librdkafka.apt.list ; \
    set -e ; \
    rm /tmp/apt.0 /tmp/apt.1

## ---

FROM ${BASE_IMAGE}

COPY --from=librdkafka  /usr/local/lib/  /usr/local/lib/
COPY --from=aldente     /usr/local/bin/  /usr/local/bin/
COPY --from=aldente     /usr/local/etc/  /usr/local/etc/
COPY --from=aldente     /usr/local/lib/  /usr/local/lib/

## Kafka + Kerberos/SASL
RUN export \
      DEBCONF_NONINTERACTIVE_SEEN=true \
      DEBIAN_FRONTEND=noninteractive \
      DEBIAN_PRIORITY=critical \
      TERM=linux \
    && \
    apt-get update && \
    xargs -rt -a /usr/local/etc/librdkafka.apt.list apt-get -y install && \
    apt-get install -y krb5-user \
                       libsasl2-modules-gssapi-mit \
    && \
    ldconfig && \
    apt-get -y clean
