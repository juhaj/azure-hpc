#!/bin/bash

set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# != 5 ]; then
    echo "Usage: $0 <MasterHostname> <WorkerHostnamePrefix> <WorkerNodeCount> <HPCUserName> <TemplateBaseUrl>"
    exit 1
fi

# Set user args
MASTER_HOSTNAME=$1
WORKER_HOSTNAME_PREFIX=$2
WORKER_COUNT=$3
TEMPLATE_BASE_URL="$5"
LAST_WORKER_INDEX=$(($WORKER_COUNT - 1))

# Shares
SHARE_HOME=/share/home
SHARE_DATA=/share/data

# Munged
MUNGE_USER=munge
MUNGE_GROUP=munge
MUNGE_VERSION=0.5.11

# SLURM
SLURM_USER=slurm
SLURM_UID=6006
SLURM_GROUP=slurm
SLURM_GID=6006
SLURM_VERSION=15-08-1-1
SLURM_CONF_DIR=$SHARE_DATA/conf

# Hpc User
HPC_USER=$4
HPC_UID=7007
HPC_GROUP=users

# HPC software stuff
# Prep a suitable directory
SOFTWARE_BUILD_TREE=/software/src
SOFTWARE_INSTALL_TREE=/software

# Returns 0 if this node is the master node.
#
is_master()
{
    hostname | grep "$MASTER_HOSTNAME"
    return $?
}

# Add the SLES 12 SDK repository which includes all the
# packages for compilers and headers.
#
add_sdk_repo()
{
    repoFile="/etc/zypp/repos.d/SMT-http_smt-azure_susecloud_net:SLE-SDK12-SP3-Pool.repo"
	
    if [ -e "$repoFile" ]; then
        echo "SLES 12 SDK Repository already installed"
        return 0
    fi
	
	wget $TEMPLATE_BASE_URL/sles12sdk.repo
	
	cp sles12sdk.repo "$repoFile"

    # init new repo
    zypper -n search nfs > /dev/null 2>&1
}

# Add OpenSUSE repos for easier access to things like gcc7 and python3
add_opensuse_repos()
{
    repoFiles="opensuse-dist-non-oss.repo opensuse-dist-oss.repo opensuse-update.repo"
    for repoFile in ${repoFiles}
    do
        wget ${TEMPLATE_BASE_URL}/${repoFile} && \
            cp ${repoFile} /etc/zypp/repos.d/
    done && \
        zypper --gpg-auto-import-keys refresh
}

# Installs all required packages.
#
install_pkgs()
{
    pkgs="libbz2-1 libz1 openssl libopenssl-devel git lsb make mdadm nfs-client rpcbind"
    
    if is_master; then
        pkgs="$pkgs nfs-kernel-server"
    fi
    
    zypper -n install  --no-confirm --force --force-resolution $pkgs
    
    # also install IMPI; it will be found in
    rpm -i /opt/intelMPI/intel_mpi_packages/*.rpm
    # OR: {intel-mpi-intel64-5.0.3p-048.x86_64.rpm,intel-mpi-rt-intel64-5.0.3p-048.x86_64}.rpm
}

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
	createdPartitions=""

    # Loop through and partition disks until not found
    for disk in sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
	done

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/md10 --level 0 --raid-devices $devices $createdPartitions
	    mkfs -t ext4 /dev/md10
	    echo "/dev/md10 $mountPoint ext4 defaults,nofail 0 2" >> /etc/fstab
	    mount /dev/md10
    fi
}

# Creates and exports two shares on the master nodes:
#
# /share/home (for HPC user)
# /share/data
#
# These shares are mounted on all worker nodes.
#
setup_shares()
{
    mkdir -p $SHARE_HOME
    mkdir -p $SHARE_DATA

    if is_master; then
	    setup_data_disks $SHARE_DATA
        echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
        echo "$SHARE_DATA    *(rw,async)" >> /etc/exports
        service nfsserver status && service nfsserver reload || service nfsserver start
    else
        echo "master:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_DATA $SHARE_DATA    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        mount -a
        mount | grep "^master:$SHARE_HOME"
        mount | grep "^master:$SHARE_DATA"
    fi
}

# Downloads/builds/installs munged on the node.  
# The munge key is generated on the master node and placed 
# in the data share.  
# Worker nodes copy the existing key from the data share.
#
install_munge()
{
    groupadd $MUNGE_GROUP

    useradd -M -c "Munge service account" -g munge -s /usr/sbin/nologin munge

    wget https://github.com/dun/munge/archive/munge-${MUNGE_VERSION}.tar.gz

    tar xvfz munge-$MUNGE_VERSION.tar.gz

    cd munge-munge-$MUNGE_VERSION

    mkdir -m 700 /etc/munge
    mkdir -m 711 /var/lib/munge
    mkdir -m 700 /var/log/munge
    mkdir -m 755 /var/run/munge

    ./configure -libdir=/usr/lib64 --prefix=/usr --sysconfdir=/etc --localstatedir=/var && make && make install

    chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge /var/run/munge

    if is_master; then
        dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
		mkdir -p $SLURM_CONF_DIR
        cp /etc/munge/munge.key $SLURM_CONF_DIR
    else
        cp $SLURM_CONF_DIR/munge.key /etc/munge/munge.key
    fi

    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key

    systemctl enable munge
    systemctl start munge

    cd ..
}

# Installs and configures slurm.conf on the node.
# This is generated on the master node and placed in the data
# share.  All nodes create a sym link to the SLURM conf
# as all SLURM nodes must share a common config file.
#
install_slurm_config()
{
    if is_master; then

        mkdir -p $SLURM_CONF_DIR

	    wget "$TEMPLATE_BASE_URL/slurm.template.conf"

		cat slurm.template.conf |
		        sed 's/__MASTER__/'"$MASTER_HOSTNAME"'/g' |
				sed 's/__WORKER_HOSTNAME_PREFIX__/'"$WORKER_HOSTNAME_PREFIX"'/g' |
				sed 's/__LAST_WORKER_INDEX__/'"$LAST_WORKER_INDEX"'/g' > $SLURM_CONF_DIR/slurm.conf
    fi

    ln -s $SLURM_CONF_DIR/slurm.conf /etc/slurm/slurm.conf
}

# Downloads, builds and installs SLURM on the node.
# Starts the SLURM control daemon on the master node and
# the agent on worker nodes.
#
install_slurm()
{
    groupadd -g $SLURM_GID $SLURM_GROUP

    useradd -M -u $SLURM_UID -c "SLURM service account" -g $SLURM_GROUP -s /usr/sbin/nologin $SLURM_USER

    mkdir /etc/slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    chown -R slurm:slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    wget https://github.com/SchedMD/slurm/archive/slurm-$SLURM_VERSION.tar.gz

    tar xvfz slurm-$SLURM_VERSION.tar.gz

    cd slurm-slurm-$SLURM_VERSION
	
    ./configure -libdir=/usr/lib64 --prefix=/usr --sysconfdir=/etc/slurm --with-hdf5=no && make && make install

    install_slurm_config

    wget ${TEMPLATE_BASE_URL}/slurmd.service
    wget ${TEMPLATE_BASE_URL}/slurmctld.service
    
    if is_master; then
        echo 'd /var/run/slurmctld 0755 slurm slurm -' > /usr/lib/tmpfiles.d/slurmctld.conf
        mv slurmctld.service /usr/lib/systemd/system/
        systemctl enable slurmctld
        systemctl start slurmctld
    else
        echo 'd /var/run/slurmd 0755 root root -' > /usr/lib/tmpfiles.d/slurmd.conf
        mv slurmd.service /usr/lib/systemd/system/
        systemctl enable slurmd
        systemctl start slurmd
    fi

    cd ..
}

# Adds a common HPC user to the node and configures public key SSh auth.
# The HPC user has a shared home directory (NFS share on master) and access
# to the data share.
#
setup_hpc_user()
{
    if is_master; then
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -m -u $HPC_UID $HPC_USER

        # Configure public key auth for the HPC user
        sudo -u $HPC_USER ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""
        cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub > $SHARE_HOME/$HPC_USER/.ssh/authorized_keys

        echo "Host *" > $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$HPC_USER/.ssh/config
	echo "    PasswordAuthentication no" >> $SHARE_HOME/$HPC_USER/.ssh/config

        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER/.ssh/config
        chown $HPC_USER:$HPC_GROUP $SHARE_DATA
    else
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER
    fi

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
}

# Sets all common environment variables and system parameters.
#
setup_env()
{
    # Set unlimited mem lock
    echo "$HPC_USER hard memlock unlimited" >> /etc/security/limits.conf
    echo "$HPC_USER soft memlock unlimited" >> /etc/security/limits.conf

    # Intel MPI config for IB
    echo "# IB Config for MPI" > /etc/profile.d/hpc.sh
    echo "export I_MPI_FABRICS=shm:dapl" >> /etc/profile.d/hpc.sh
    echo "export I_MPI_DAPL_PROVIDER=ofa-v2-ib0" >> /etc/profile.d/hpc.sh
    echo "export I_MPI_DYNAMIC_CONNECTION=0" >> /etc/profile.d/hpc.sh
    echo "export I_MPI_PMI_LIBRARY=/usr/lib64/libpmi.so" >> /etc/profile.d/hpc.sh
    echo "export HDF5_HOME=/software/hdf5" >> /etc/profile.d/hpc.sh
    echo "export PETSC_DIR=/software/petsc" >> /etc/profile.d/hpc.sh
    # do we need LD_LIBRARY_PATH?
    echo "source /opt/intel/impi/5.0.3.048/bin64/mpivars.sh" >> /etc/profile.d/hpc.sh
    echo 'export PATH=/usr/lib64/gcc/x86_64-suse-linux/7:${HDF5_HOME}/bin:${PATH}' >> /etc/profile.d/hpc.sh
}

install_hdf5()
{
    # Go to our build tree dir
    pushd ${SOFTWARE_BUILD_TREE}
    # get HDF5 v1.8.15
    rm -rf hdf5-1.10.1 && \
        if ! [ -f hdf5-1.10.1.tar.bz2 ]
        then
            wget https://support.hdfgroup.org/ftp/HDF5/current/src/hdf5-1.10.1.tar.bz2
        fi && \
        tar jxf hdf5-1.10.1.tar.bz2 && \
        cd hdf5-1.10.1 && \
        ./configure --prefix=${SOFTWARE_INSTALL_TREE}/hdf5 --enable-parallel --enable-shared && \
        make && \
        make install && \
        echo DEBUG: hdf5 built successfully && popd && return 0 || \
            echo DEBUG: failed to build hdf5 && popd && return 1
}

install_petsc()
{
    # Go to our build tree dir
    pushd ${SOFTWARE_BUILD_TREE}
    # get PETSc v3.7.5
    git clone -b v3.7.5 https://bitbucket.org/petsc/petsc petsc
    
    # Build it
    cd petsc && \
        ./configure --prefix=${SOFTWARE_INSTALL_TREE}/petsc --with-shared-libraries --with-debugging=0 \
                    --useThreads=0 --with-clanguage=C++ --with-cxx-dialect=C++11 --with-c-support \
                    --with-fortran-interfaces=1 \
                    --with-mpi=1 --with-mpi-shared=1 \
                    --with-blas-lapack-include=/usr/include/openblas --with-blas-lib=/usr/lib64/libopenblas_openmp.so --with-lapack-lib=/usr/lib64/libopenblas_openmp.so \
                    --with-scalapack=0 \
                    --with-suitesparse=0 \
                    --with-spooles=0 \
                    --with-hypre=0 \
                    --with-ptscotch=0 \
                    --with-fftw=0 \
                    --with-hdf5=1 --with-hdf5-dir=${SOFTWARE_INSTALL_TREE}/hdf5 \
                    --with-memalign=64 --with-log=1 \
                    --with-valgrind=0 \
                    --with-mumps=0 \
                    --with-boost=0 \
                    --with-elemental=0 \
                    --with-netcdf=0 \
                    --with-triangle=0 \
                    --with-numpy=1 \
                    --with-hwloc=1 \
                    --with-parmetis=0 \
                    --with-metis=0 \
                    --with-tetgen=0 \
                    --with-scalar-type=real --with-pic=1 --with-gnu-compilers=1 --with-openmp=1 \
                    --with-64-bit-indices \
                    --download-sprng=yes \
                    --CXX_LINKER_FLAGS="-Wl,--no-as-needed" \
                    --COPTFLAGS="-Ofast -g" \
                    --FOPTFLAGS="-Ofast -g" \
                    --CXXOPTFLAGS="-Ofast -g" && \
        make PETSC_DIR=${SOFTWARE_BUILD_TREE}/petsc all && make PETSC_DIR=${SOFTWARE_BUILD_TREE}/petsc install && \
        export PETSC_DIR=${SOFTWARE_INSTALL_TREE}/petsc && \
        echo "Now installing mpi4py and petsc4py" && \
        pip3 install --no-binary :all: mpi4py && \
        pip3 install --no-binary :all: --no-deps petsc4py==3.7.0 && \
        echo DEBUG: petsc, mpi4py, petsc4py built successfully && popd && return 0 || \
            echo DEBUG: failed to build petsc, mpi4py, petsc4py && popd && return 1
}

# setup software needed for the Research Programming course
setup_hpc_software()
{
    zypper install --no-confirm --force --force-resolution cmake emacs gcc7 gcc7-c++ gcc7-fortran make git hwloc hwloc-devel hwloc-lstopo libopenblas_openmp-devel libopenblas_openmp0 libopenblaso0 openblas-devel python3-Cython python3-devel python3-matplotlib python3-numpy python3-numpy-devel python3-pip python3-scipy python3-virtualenv schedtool swig
    ln -s /usr/bin/gcc-7 /usr/local/bin/gcc
    ln -s /usr/bin/g++-7 /usr/local/bin/g++
    ln -s /usr/bin/gfortran-7 /usr/local/bin/gfortran
    pip3 install --user passgen

    # need to set up the environment for building stuff (with Intel MPI)
    # Intel's scripts do not work with "set -u" so
    set +u
    source /opt/intel/impi/5.0.3.048/bin64/mpivars.sh
    set -u
    export I_MPI_FABRICS=shm:dapl
    export I_MPI_DAPL_PROVIDER=ofa-v2-ib0
    export I_MPI_DYNAMIC_CONNECTION=0
    export I_MPI_PMI_LIBRARY=/usr/lib64/libpmi.so
    
    # create the out-of-rpm software installation tree
    mkdir -p ${SOFTWARE_BUILD_TREE}

    # install hdf5
    install_hdf5 || return 2 && \
            echo "export HDF5_HOME=/software/hdf5" >> /etc/profile.d/hpc.sh && \
            export HDF5_HOME=/software/hdf5 && \
            export PATH=${HDF5_HOME}/bin:${PATH}
            install_petsc || return 3 && \
                    echo "export PETSC_DIR=/software/petsc" >> /etc/profile.d/hpc.sh && \
                    export PETSC_DIR=/software/petsc && \
                    CC=/usr/bin/gcc-7 CXX=/usr/bin/g++-7 pip3 install --ignore-installed ipyparallel jupyter notedown bash_kernel nbextensions ipywidgets
}


setup_my_jupyter()
{
    wget ${TEMPLATE_BASE_URL}/my_jupyter
    mv my_jupyter /usr/local/bin/
    chmod 755 /usr/local/bin/my_jupyter
}


re_enable_ssh_password_auth()
{
    if is_master; then
        sed --in-place 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
        systemctl restart sshd
    fi
}

set -x
exec &> /root/install.log
echo "Starting"
date --iso-8601=seconds
add_sdk_repo
echo "DEBUG: add_sdk_repo done"
add_opensuse_repos
echo "DEBUG: add_opensuse_repos done"
install_pkgs
echo "DEBUG: install_pkgs done"
setup_shares
echo "DEBUG: setup_shares done"
setup_hpc_user
echo "DEBUG: setup_hpc_user done"
setup_env
echo "DEBUG: setup_env done"
setup_hpc_software
echo "DEBUG: hpc_software done"
install_munge
echo "DEBUG: install_munge done"
install_slurm
echo "DEBUG: install_slurm done"
wget ${TEMPLATE_BASE_URL}/create_training_users.py
mv create_training_users.py /root/
echo "DEBUG: wget got training user creation script"
setup_my_jupyter
echo "DEBUG: setup_my_jupyter done"
re_enable_ssh_password_auth
echo "DEBUG: re_enable_ssh_password_auth done"
echo "DEBUG: all done"
# add users, what else? persistent disc space? first lecture intro to ssh, log to azure, get it working on damtp
# glusterfs?
# singularity?
# worker reboot at the end of deployment (because IB does not always come up)?
