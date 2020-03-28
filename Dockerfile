FROM centos:8

ENV export SNORT_INSTALL_PREFIX=/usr/local/snort
ENV export RULES_DIRECTORY=/usr/local/snort/rules
ENV export APPID_DIRECTORY=/usr/local/snort/appid
ENV export IP_REPUTATION_LISTS_DIRECTORY=/usr/local/snort/intel
ENV export LOGGING_DIRECTORY=/var/log/snort
ENV export SNORT_EXTRA_PLUGINS_DIRECTORY=/usr/local/snort/extra

# /snort3/build/src/snort: error while loading shared libraries: libtcmalloc.so.4: cannot open shared object file: No such file or directory
# RUN yum install gperftools-libs
# /snort3/build/src/snort: error while loading shared libraries: libdaq.so.3: cannot open shared object file: No such file or directory
ENV LD_LIBRARY_PATH=/usr/local/lib

# 1. Introduction
# Update system
RUN yum update -y
# Set locale
RUN source /etc/profile.d/lang.sh
# Install config-manager
RUN dnf install -y 'dnf-command(config-manager)'

# 2. Preparation
# With CentOS 8, several development packages and headers (for example, libpcap-devel) required for
# successfully compiling LibDAQ and Snort are not included in the default repositories – AppStream, Base, or Extras.
# Instead, they exist in the PowerTools repository, which is disabled by default.
RUN dnf config-manager --add-repo /etc/yum.repos.d/CentOS-PowerTools.repo
RUN dnf config-manager --set-enabled PowerTools

# Another change with CentOS 8 is that some packages were removed from the official repositories, such as
# gperftools and unwind [1].
# Some development packages such as LuaJIT and unwind exist in the EPEL repository. This streamlines the
# installation and future updates of these packages. If installing EPEL repository is not an option, the associated
# packages can be installed from source code.
RUN dnf install -y epel-release
# Now that all of the repositories enabled, it is time to ensure that the operating system and existing packages are
# up to date. This may require a reboot, especially if the updates included kernel upgrades.
RUN dnf upgrade -y
# Next, some helper packages are installed, which are not required by Snort and can be removed later.
RUN dnf install -y vim git \
  # Basic compilation tools required for building Snort are installed from the repository. These include: flex (flex),
  # bison (bison), gcc (gcc), c++ (gcc-c++), make (make), and cmake (cmake). Unlike CentOS 7, installing cmake from
  # source code is not required since the cmake version in CentOS 8 is compatible. Additionally, autoconf (autoconf)
  # and libtool (libtool) packages will be installed in order to successfully compile LibDAQ.
  flex bison gcc gcc-c++ make cmake autoconf libtool \
  # 3. Install Snort Dependencies
  # 3.1 Required Dependencies
  # The following packages are installed from CentOS repositories: pcap (libpcap-devel), pcre (pcre-devel), dnet
  # (libdnet-devel), hwloc (hwloc-devel), OpenSSL (openssl-devel), pkgconfig (pkgconfig), zlib (zlib-devel), and
  # LuaJIT (luajit-devel).
  libpcap-devel pcre-devel libdnet-devel hwloc-devel openssl-devel zlib-devel luajit-devel pkgconfig \
  # LibDAQ
  # Recent revisions of Snort 3 require the new LibDAQ (>=3.0.0). If building LibDAQ with NFQ module support, then
  # the following packages must be installed before configuration: libnfnetlink (libnfnetlink-devel),
  # libnetfilter_queue (libnetfilter_queue-devel), and libmnl (libmnl-devel).
  libnfnetlink-devel libnetfilter_queue-devel libmnl-devel \
  # LZMA and UUID
  # lzma is used for decompression of SWF and PDF files, while uuid is a library for generating/parsing Universally
  # Unique IDs for tagging/identifying objects across a network.
  xz-devel libuuid-devel \
  # Hyperscan
  # Prior to installing hyperscan, the following dependencies should be installed: Ragel, Boost, and sqlite3 (sqlitedevel). CentOS 8 does not come with Python preinstalled. Building hyperscan requires a python interpreter,
  # python3 (python3) available on the host. Both, python3 and sqlite will be installed from the repository.
  python3 sqlite-devel \
  # Tcmalloc
  # tcmalloc is a library created by Google (PerfTools) for improving memory handling in threaded programs. The use
  # of the library may lead to performance improvements and memory usage reduction. Neither CentOS 8 nor EPEL
  # repositories include the gperftools (gperftools-devel) package, therefore, gperftools will be built from sources.
  # Building gperftools from source requires unwind (libunwind-devel) package to be installed.
  libunwind-devel


# Since some of the packages maybe built from source, a directory is created to house the source codes.
RUN mkdir /sources
WORKDIR /sources
# Clone LibDAQ from GitHub and generate the configuration script – since it is cloned from git.
RUN git clone https://github.com/snort3/libdaq.git
WORKDIR /sources/libdaq/
RUN ./bootstrap
# Otherwise, proceed to the configuration steps taking into account which modules to disable if not used. Now it’s
# time to configure LibDAQ.
RUN ./configure
RUN make
RUN make install
# 3.2 Optional Dependencies
# Installing newer versions (>=7.x) of Ragel requires installing colm first. Prior versions, for example version 6.10, do
# not require installing colm. The steps will proceed with installing colm (0.13.0.7 ) and ragel (7.0.0.12).
WORKDIR /sources
RUN curl -LO http://www.colm.net/files/colm/colm-0.13.0.7.tar.gz
RUN tar xf colm-0.13.0.7.tar.gz
WORKDIR /sources/colm-0.13.0.7
RUN ./configure
RUN make -j$(nproc)
RUN make -j$(nproc) install
RUN ldconfig
WORKDIR /sources
RUN curl -LO http://www.colm.net/files/ragel/ragel-7.0.0.12.tar.gz
RUN tar xf ragel-7.0.0.12.tar.gz
WORKDIR /sources/ragel-7.0.0.12
RUN ./configure
RUN make -j$(nproc)
RUN make -j$(nproc) install
RUN ldconfig
# The remaining dependency is boost, which will be downloaded and decompressed without building it.
WORKDIR /sources
RUN curl -LO https://dl.bintray.com/boostorg/release/1.71.0/source/boost_1_71_0.tar.gz
RUN tar xf boost_1_71_0.tar.gz
# Download and install Hyperscan (5.2.0):
RUN curl -Lo hyperscan-5.2.0.tar.gz https://github.com/intel/hyperscan/archive/v5.2.0.tar.gz
RUN tar xf hyperscan-5.2.0.tar.gz
RUN mkdir hs-build
WORKDIR /sources/hs-build
# There are two methods to make hyperscan aware of the Boost headers: 1) Symlink, or 2) Passing BOOST_ROOT
# pointing to the root directory of the Boost headers to cmake. Both methods are shown below.
# Method 1 – Symlink:
# RUN ln -s ~/sources/boost_1_71_0 /boost ~/sources/hyperscan-5.2.0/include/boost
# RUN cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local ../hyperscan-5.2.0
# Method 2 – BOOST_ROOT:
RUN cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DBOOST_ROOT=../boost_1_71_0 ../hyperscan-5.2.0
# Proceed with installing Hyperscan.
RUN make -j$(nproc)
RUN make -j$(nproc) install
# Flatbuffers
# Flatbuffers is a cross-platform serialization library for memory-constrained apps. It allows direct access of
# serialized data without unpacking/parsing it first.
WORKDIR /sources
RUN curl -Lo flatbuffers-1.11.tar.gz https://github.com/google/flatbuffers/archive/v1.11.0.tar.gz
RUN tar xf flatbuffers-1.11.tar.gz
RUN mkdir fb-build
WORKDIR /sources/fb-build
RUN cmake ../flatbuffers-1.11.0
RUN make -j$(nproc)
RUN make -j$(nproc) install
# Safec
# Safec is used for runtime bounds checks on certain legacy C-library calls.
WORKDIR /sources
RUN curl -LO https://github.com/rurban/safeclib/releases/download/v04062019/libsafec-04062019.0-ga99a05.tar.gz
RUN tar xf libsafec-04062019.0-ga99a05.tar.gz
WORKDIR /sources/libsafec-04062019.0-ga99a05
RUN ./configure
RUN make
RUN make install
# Proceed to building gperftools.
WORKDIR /sources
RUN curl -LO https://github.com/gperftools/gperftools/releases/download/gperftools-2.7/gperftools-2.7.tar.gz
RUN tar xf gperftools-2.7.tar.gz
WORKDIR /sources/gperftools-2.7
RUN ./configure
RUN make -j$(nproc)
RUN make -j$(nproc) install

# ENV LD_LIBRARY_PATH=/usr/local/lib
# 4. Installing Snort 3
# Now that all of the dependencies are installed, clone Snort 3 repository from GitHub.
WORKDIR /sources
RUN git clone https://github.com/snort3/snort3.git
WORKDIR /sources/snort3
# Before running the configuration step, export the PKG_CONFIG_PATH to include the LibDAQ pkgconfig path, as well
# as other packages’ pkgconfig paths, otherwise, the build process may fail or Snort 3 will not be able to locate the
# associated libraries at compile or runtime.
# ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
# ENV export PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig:$PKG_CONFIG_PATH
# Note: If LibDAQ or other packages were installed to a custom, non-system path, then that path should be
# exported to PKG_CONFIG_PATH, for example:
# export PKG_CONFIG_PATH=/opt/libdaq/lib/pkgconfig:$PKG_CONFIG_PATH
# Proceed to building Snort 3 while enabling tcmalloc support.
RUN ./configure_cmake.sh --prefix=/usr/local/snort --enable-tcmalloc
# Proceed to installing Snort 3.
WORKDIR /sources/snort3/build/
RUN make -j$(nproc)
RUN make -j$(nproc) install
# Once the installation is complete, verify that Snort 3 reports the expected version and library names
RUN ln -s /usr/local/snort/bin/snort /usr/bin/snort
# /usr/local/snort/bin/snort -V

# 6.1Global Paths for Rules, AppID, and IP Reputation Lists
# Snort rules, appid, and reputation lists will be stored in their respective directory.The rules/directory will contain Snort rules files, 
# the appid/directory will contain the AppID detectors, and the intel/ directory will contain IP blacklists and whitelists.
RUN mkdir -p /usr/local/snort/{builtin_rules,rules,appid,intel} 

WORKDIR /sources
# Snort Rules Snort rules consist of text-based rules, and Shared Object (SO) rules and their associated text-based stubs. At the time of writing this guide, the Shared Object rules are not available yet [3].The rules tarball also contains Snort configuration files. The configuration files from the rules tarball will be copied to the etc/snort/directory, and will be used in favor of the configuration files in from Snort 3 source tarball. To proceed with the configurations, download the rules tarball from Snort.org (PulledPork is not tested yet), replacing the oinkcode placeholder in the below command with the official and dedicated oinkcode.
# https://www.snort.org/downloads/community/snort3-community-rules.tar.gz
RUN curl -Lo snortrules-snapshot-3000.tar.gz https://www.snort.org/rules/snortrules-snapshot-3000.tar.gz?oinkcode=2afcbc2407852ce0c2dbbfbcf6aca313919c7c6b
# Extract the rules tarball and copy the rules to therules/directory created earlier.
RUN tar xf snortrules-snapshot-3000.tar.gz 
RUN cp rules/*.rules /usr/local/snort/rules/ 
RUN cp builtins/builtins.rules /usr/local/snort/builtin_rules/ 
# Copy Snort configuration files from the extracted rules tarball /etc directory to Snort etc/snort/ directory. 
RUN cp etc/snort_defaults.lua etc/snort.lua /usr/local/snort/etc/snort/

# OpenAppID (Optional)
# Download and extract the OpenAppID package, and move the extractedodp/directory to theappid/directory.
RUN curl -Lo snort-openappid-12159.tar.gz https://www.snort.org/downloads/openappid/12159
RUN tar xf snort-openappid-12159.tar.gz
RUN mv odp/ /usr/local/snort/appid/

# IP Reputation (Optional)
# Download the IP Blacklist generated by Talos and move it to the intel/ directory created earlier. 
# Enabling the Reputation inspector while in IDS mode will generate blacklist hit alert when a match occurs, and traffic may not be inspected further.
RUN curl -LO https://www.talosintelligence.com/documents/ip-blacklist
RUN mv ip-blacklist /usr/local/snort/intel/ 
# Create an empty file for the IP whitelist, which will be configured along with the blacklist in the following section.
RUN touch /usr/local/snort/intel/ip-whitelist 
# Edit thesnort_defaults.luafile. The below snapshots of the configurations show the before and after states of the configuration. 
# The paths shown below follow the conventions mentioned at the beginning of this guide.


CMD [ "snort", "-i", "wlan0", "--daq-dir=/usr/local/lib/daq" ]

# /usr/local/snort/bin/snort -c /usr/local/snort/etc/snort/snort.lua -r test.pcap -l /var/log/snort --plugin-path /usr/local/snort/extra -k none
# /usr/local/snort/bin/snort -c /usr/local/snort/etc/snort/snort.lua --pcap-dir pcaps/ --pcap-filter '*.pcap' -l /var/log/snort --plugin-path /usr/local/snort/extra -k none
# /usr/local/snort/bin/snort -c /usr/local/snort/etc/snort/snort.lua -i eth0 -l /var/log/snort -k none

snort -i eth0 \
      --daq-dir=/usr/local/lib/daq \
      -c /usr/local/snort/etc/snort/snort.lua \
      -l /var/log/snort \
      -k none

snort --daq-dir=/usr/local/lib/daq -i wlan0 

# sudo snort --rule-path ~/snort3/etc/rules \
#       --plugin-path ~/snort3/lib -i eht0 \
#       -A json \
#       -q \
#       -y > alerts.json