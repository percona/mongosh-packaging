#!/bin/sh

shell_quote_string() {
  echo "$1" | sed -e 's,\([^a-zA-Z0-9/_.=-]\),\\\1,g'
}

usage () {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given :
        --builddir=DIR      Absolute path to the dir where all actions will be performed
        --get_sources       Source will be downloaded from github
        --build_src_rpm     If it is set - src rpm will be built
        --build_src_deb  If it is set - source deb package will be built
        --build_mongosh     If it is set - mongosh will be built
        --build_variant     Varint to build(rpm-x64, deb-x64, linux-x64)
        --install_deps      Install build dependencies(root privilages are required)
        --branch            Branch for build
        --repo              Repo for build
        --version           Version to build

        --help) usage ;;
Example $0 --builddir=/tmp/percona-mongodb-mongosh --get_sources=1 --build_src_rpm=1
EOF
        exit 1
}

append_arg_to_args () {
  args="$args "$(shell_quote_string "$1")
}

parse_arguments() {
    pick_args=
    if test "$1" = PICK-ARGS-FROM-ARGV
    then
        pick_args=1
        shift
    fi

    for arg do
        val=$(echo "$arg" | sed -e 's;^--[^=]*=;;')
        case "$arg" in
            --builddir=*) WORKDIR="$val" ;;
            --build_src_rpm=*) SRPM="$val" ;;
            --build_src_deb=*) SDEB="$val" ;;
            --get_sources=*) SOURCE="$val" ;;
            --branch=*) BRANCH="$val" ;;
            --repo=*) REPO="$val" ;;
            --version=*) VERSION="$val" ;;
            --install_deps=*) INSTALL="$val" ;;
            --build_mongosh=*) MONGOSH="$val" ;;
            --build_variant=*) VARIANT="$val" ;;
            --help) usage ;;
            *)
              if test -n "$pick_args"
              then
                  append_arg_to_args "$arg"
              fi
              ;;
        esac
    done
}

check_workdir(){
    if [ "x$WORKDIR" = "x$CURDIR" ]
    then
        echo >&2 "Current directory cannot be used for building!"
        exit 1
    else
        if ! test -d "$WORKDIR"
        then
            echo >&2 "$WORKDIR is not a directory."
            exit 1
        fi
    fi
    return
}

get_sources(){
    cd "${WORKDIR}"
    if [ "${SOURCE}" = 0 ]
    then
        echo "Sources will not be downloaded"
        return 0
    fi
    PRODUCT=percona-mongodb-mongosh
    echo "PRODUCT=${PRODUCT}" > percona-mongodb-mongosh.properties
    echo "BUILD_NUMBER=${BUILD_NUMBER}" >> percona-mongodb-mongosh.properties
    echo "BUILD_ID=${BUILD_ID}" >> percona-mongodb-mongosh.properties
    echo "VERSION=${VERSION}" >> percona-mongodb-mongosh.properties
    echo "BRANCH=${BRANCH}" >> percona-mongodb-mongosh.properties
    rm -rf ${PRODUCT}
    git clone "$REPO" ${PRODUCT}
    retval=$?
    if [ $retval != 0 ]
    then
        echo "There were some issues during repo cloning from github. Please retry one more time"
        exit 1
    fi
    cd ${PRODUCT}
    if [ ! -z "$BRANCH" ]
    then
        git reset --hard
        git clean -xdf
        git checkout -b "$BRANCH" "$BRANCH"
    fi
    REVISION=$(git rev-parse --short HEAD)
    GITCOMMIT=$(git rev-parse HEAD 2>/dev/null)
    GITBRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    NODE_JS_VERSION=$(grep -e "const NODE_JS_VERSION_16" .evergreen/evergreen.yml.in | cut -d "'" -f 2)
    echo "VERSION=${VERSION}" > VERSION
    echo "REVISION=${REVISION}" >> VERSION
    echo "GITCOMMIT=${GITCOMMIT}" >> VERSION
    echo "GITBRANCH=${GITBRANCH}" >> VERSION
    echo "NODE_JS_VERSION=${NODE_JS_VERSION}" >> VERSION
    echo "REVISION=${REVISION}" >> ${WORKDIR}/percona-mongodb-mongosh.properties
    cd ${WORKDIR}
    rm -fr debian rpm ${PRODUCT}-${VERSION}

    mv ${PRODUCT} ${PRODUCT}-${VERSION}
    pushd ${PRODUCT}-${VERSION}
        cp ../../mongosh.patch .
        git apply ./mongosh.patch && rm ./mongosh.patch
        grep -r -l "0\.0\.0\-dev\.0" . | xargs sed -i "s:0.0.0-dev.0:${VERSION}:g"
    popd
    tar --owner=0 --group=0 --exclude=.* -czf ${PRODUCT}-${VERSION}.tar.gz ${PRODUCT}-${VERSION}
    echo "UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}/${PRODUCT}-${VERSION}/${BRANCH}/${REVISION}/${BUILD_ID}" >> percona-mongodb-mongosh.properties
    mkdir -p $WORKDIR/source_tarball
    mkdir -p $CURDIR/source_tarball
    cp ${PRODUCT}-${VERSION}.tar.gz $WORKDIR/source_tarball
    cp ${PRODUCT}-${VERSION}.tar.gz $CURDIR/source_tarball
    cd $CURDIR
    rm -rf ${PRODUCT}
    return
}

get_system(){
    if [ -f /etc/redhat-release ]; then
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        OS_NAME="el$RHEL"
        OS="rpm"
    else
        ARCH=$(uname -m)
        OS_NAME="$(lsb_release -sc)"
        OS="deb"
    fi
    return
}

install_npm_modules() {
    npm install -g npm@latest
    npm install -g n
    n stable
    hash -r
    npm install -g lerna
    npm install -g typescript
}

install_deps() {
    if [ $INSTALL = 0 ]
    then
        echo "Dependencies will not be installed"
        return;
    fi
    if [ ! $( id -u ) -eq 0 ]
    then
        echo "It is not possible to instal dependencies. Please run as root"
        exit 1
    fi
    CURPLACE=$(pwd)

    if [ "x$OS" = "xrpm" ]; then
      RHEL=$(rpm --eval %rhel)
      yum -y install wget git rpm-build rpmdevtools python3 krb5-devel cmake bzip2

      if [ "x${RHEL}" = "x7" ]; then
          until yum -y install epel-release centos-release-scl; do
              echo "waiting"
              sleep 1
          done
          yum -y install npm cmake3 devtoolset-11
          ln -sf /usr/bin/cmake3 /usr/bin/cmake
          source /opt/rh/devtoolset-11/enable
      fi
      if [ "x${RHEL}" = "x8" ]; then
          yum -y install npm gcc-toolset-11
          source /opt/rh/gcc-toolset-11/enable
      fi
      if [ "x${RHEL}" = "x9" ]; then
          yum -y install npm gcc g++
      fi
      yum clean all
    else
      until apt-get -y update; do
        sleep 1
        echo "waiting"
      done
      DEBIAN_FRONTEND=noninteractive apt-get -y install lsb-release gpg wget
      export DEBIAN=$(lsb_release -sc)
      if [ x"${DEBIAN}" = xbionic ]; then
          wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null
          echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ bionic main' | tee /etc/apt/sources.list.d/kitware.list >/dev/null
          apt-get -y update
      fi
      INSTALL_LIST="wget git devscripts debhelper debconf pkg-config npm libkrb5-dev cmake bzip2 gcc g++"
      until DEBIAN_FRONTEND=noninteractive apt-get -y install ${INSTALL_LIST}; do
        sleep 1
        echo "waiting"
      done
    fi
    return;
}

get_tar(){
    TARBALL=$1
    TARFILE=$(basename $(find $WORKDIR/$TARBALL -name 'percona-mongodb-mongosh*.tar.gz' | sort | tail -n1))
    if [ -z $TARFILE ]
    then
        TARFILE=$(basename $(find $CURDIR/$TARBALL -name 'percona-mongodb-mongosh*.tar.gz' | sort | tail -n1))
        if [ -z $TARFILE ]
        then
            echo "There is no $TARBALL for build"
            exit 1
        else
            cp $CURDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
        fi
    else
        cp $WORKDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
    fi
    return
}

build_mongosh(){
    if [ $MONGOSH = 0 ]
    then
        echo "mongosh will not be built"
        return;
    fi
    echo $PATH
    if [ "x$OS" = "xrpm" ]; then
      RHEL=$(rpm --eval %rhel)
      if [ "x${RHEL}" = "x7" ]; then
          source /opt/rh/devtoolset-11/enable
      fi
      if [ "x${RHEL}" = "x8" ]; then
          source /opt/rh/gcc-toolset-11/enable
      fi
    fi
    get_tar "source_tarball"
    cd $WORKDIR
    rm -rf ${PRODUCT}-${VERSION}
    TARFILE=$(basename $(find . -name 'percona-mongodb-mongosh*.tar.gz' | sort | tail -n1))
    tar xzf ${TARFILE}
    cd ${PRODUCT}-${VERSION}
    source VERSION
    install_npm_modules
    pwd
    ls -la
    npm run bootstrap
    NODE_JS_VERSION=${NODE_JS_VERSION} SEGMENT_API_KEY="dummy" BOXEDNODE_MAKE_ARGS="-j${NCPU}" REVISION=${REVISION} BUILD_FLE_FROM_SOURCE=true npm run compile-exec;
    NODE_JS_VERSION=${NODE_JS_VERSION} SEGMENT_API_KEY="dummy" BOXEDNODE_MAKE_ARGS="-j${NCPU}" REVISION=${REVISION} BUILD_FLE_FROM_SOURCE=true npm run evergreen-release package -- --build-variant=${VARIANT}
    echo ${VARIANT}

    if [[ ${VARIANT} =~ 'rpm' ]]; then
        PKGDIR="rpm"
        EXT="rpm"
    elif [[ ${VARIANT} =~ 'deb' ]]; then
        PKGDIR="deb"
        EXT="deb"
    elif [[ ${VARIANT} =~ 'linux' ]]; then
        PKGDIR="tarball"
        EXT="tar.gz"
    fi
    mkdir -p ${WORKDIR}/${PKGDIR}
    mkdir -p ${CURDIR}/${PKGDIR}
    cp dist/*.${EXT} ${WORKDIR}/${PKGDIR}
    cp dist/*.${EXT} ${CURDIR}/${PKGDIR}
}

#main

CURDIR=$(pwd)
VERSION_FILE=$CURDIR/percona-mongodb-mongosh.properties
args=
WORKDIR=
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
TARBALL=0
MONGOSH=0
OS_NAME=
ARCH=
OS=
INSTALL=0
RPM_RELEASE=1
DEB_RELEASE=1
VERSION="1.6.0"
RELEASE="1"
REVISION=0
BRANCH="nocoord"
REPO="https://github.com/mongodb-js/mongosh.git"
PRODUCT=percona-mongodb-mongosh
parse_arguments PICK-ARGS-FROM-ARGV "$@"
PSM_BRANCH=${BRANCH}
if test -e "/proc/cpuinfo"
then
    NCPU="$(grep -c ^processor /proc/cpuinfo)"
else
    NCPU=4
fi

check_workdir
get_system
install_deps
get_sources
build_mongosh
