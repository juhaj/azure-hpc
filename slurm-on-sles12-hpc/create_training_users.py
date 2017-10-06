#!/usr/bin/python3

import passgen
import argparse
import subprocess
import pwd
import grp
import os
import posix

def on_master():
    return posix.uname().nodename.startswith("master")

def create_user(uname, num):
    '''
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
    '''
    if (on_master()):
        homedirflag="-m"
    else:
        homedirflag="-M"
    uid=pwd.getpwnam("hpc").pw_uid+1+num
    gname=grp.getgrgid(pwd.getpwnam("hpc").pw_gid).gr_name
    homedir=os.path.join(os.path.split(pwd.getpwnam("hpc").pw_dir)[0],uname)
    subprocess.Popen(["/usr/sbin/useradd", "-c", "Training user {num}".format(num=num),
                      "-g", gname, "-d", homedir, "-s", "/bin/bash", homedirflag, "-u", str(uid), uname]).wait()
    if (on_master()):
        keyfile=os.path.join(homedir,".ssh","id_rsa")
        subprocess.Popen('sudo -u {uname} ssh-keygen -t rsa -f {keyfile} -q -P "" '.format(uname=uname, keyfile=keyfile),
                         shell=True).wait()
        with open(keyfile+".pub","r") as inf:
            with open(os.path.join(homedir,".ssh","authorized_keys"),"a") as ouf:
                for line in inf:
                    ouf.write(line)
        subprocess.Popen('mkdir /share/data/{uname}; chown {uname}.{gname} /share/data/{uname}'.format(
            uname=uname, gname=gname), shell=True)
        subprocess.Popen('python3 -m bash_kernel.install --user', shell=True)
        subprocess.Popen('jupyter notebook --generate-config', shell=True)
        subprocess.Popen('''echo 'c.NotebookApp.contents_manager_class = "notedown.NotedownContentsManager"' >> ${HOME}/.jupyter/jupyter_notebook_config.py &&     echo 'c.NotebookApp.server_extensions.append("ipyparallel.nbextension")' >> ${HOME}/.jupyter/jupyter_notebook_config.py &&     ipython3 profile create --parallel --profile=mpi &&     echo 'c.IPClusterEngines.engine_launcher_class = "MPI"' >> ${HOME}/.ipython/profile_mpi/ipcluster_config.py &&     echo 'c.BaseParallelApplication.cluster_id = "training_cluster_0"'>> ${HOME}/.ipython/profile_mpi/ipcluster_config.py''', shell=True)
    return

if (__name__ == "__main__"):
    parser=argparse.ArgumentParser()
    parser.add_argument("--number-of-users", dest="numofus", type=int, default=1,
                        help="Create this many user-password-ssh-key triples")
    args=parser.parse_args()
    for i in range(0,args.numofus):
        create_user("student{num:03d}".format(num=i), i)
