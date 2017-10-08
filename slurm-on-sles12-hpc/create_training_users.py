#!/usr/bin/python3

'''
TODO!!!

This creates on one host only: should fire up threads to create on all workers, too, as soon as password has
been generated.

'''

import passgen
import argparse
import subprocess
import pwd
import grp
import os
import posix
import threading

BASE_UID=10000

def on_master():
    return posix.uname().nodename.startswith("master")

def create_user(uname, num):
    if (on_master()):
        homedirflag="-m"
    else:
        homedirflag="-M"
    uid=BASE_UID+num
    gname=grp.getgrgid(pwd.getpwnam("hpc").pw_gid).gr_name
    homedir=os.path.join(os.path.split(pwd.getpwnam("hpc").pw_dir)[0],uname)
    subprocess.Popen(["/usr/sbin/useradd", "-c", "Training user {num}".format(num=num),
                      "-g", gname, "-d", homedir, "-s", "/bin/bash", homedirflag, "-u", str(uid),
                      uname]).wait()
    newpass = passgen.passgen()
    p=subprocess.Popen(["/usr/bin/passwd", uname], stdin=subprocess.PIPE)
    tmp = newpass+"\n"
    p.stdin.write(tmp.encode("utf-8"))
    p.stdin.write(tmp.encode("utf-8"))
    p.communicate()
    p.wait()
    if (on_master()):
        keyfile=os.path.join(homedir,".ssh","id_rsa")
        subprocess.Popen('sudo -u {uname} ssh-keygen -t rsa -f {keyfile} -q -P "" '.format(uname=uname, keyfile=keyfile),
                         shell=True).wait()
        with open(keyfile+".pub","r") as inf:
            with open(os.path.join(homedir,".ssh","authorized_keys"),"a") as ouf:
                for line in inf:
                    ouf.write(line)
        subprocess.Popen('mkdir /share/data/{uname}; chown {uname}.{gname} /share/data/{uname}'.format(
            uname=uname, gname=gname), shell=True).wait()
        subprocess.Popen('sudo --user {uname} --login python3 -m bash_kernel.install --user'.format(uname=uname),
                         shell=True).wait()
        subprocess.Popen('sudo --user {uname} --login jupyter notebook --generate-config'.format(uname=uname),
                         shell=True).wait()
        longcommand='''echo 'c.NotebookApp.contents_manager_class = "notedown.NotedownContentsManager"'
                            >> ${HOME}/.jupyter/jupyter_notebook_config.py &&
                       echo 'c.NotebookApp.server_extensions.append("ipyparallel.nbextension")'
                            >> ${HOME}/.jupyter/jupyter_notebook_config.py &&
                       ipython3 profile create --parallel --profile=mpi && 
                       echo 'c.IPClusterEngines.engine_launcher_class = "MPI"'
                            >> ${HOME}/.ipython/profile_mpi/ipcluster_config.py &&
                       echo 'c.BaseParallelApplication.cluster_id = "training_cluster_0"'
                            >> ${HOME}/.ipython/profile_mpi/ipcluster_config.py'''
        subprocess.Popen(["sudo", "--login", "--user", uname, "sh", "-c", longcommand]).wait()
    return newpass

if (__name__ == "__main__"):
    parser=argparse.ArgumentParser()
    parser.add_argument("--number-of-users", dest="numofus", type=int, default=1,
                        help="Create this many user-password-ssh-key triples")
    args=parser.parse_args()
    with open("passwords.txt","w") as f:
        for i in range(0,args.numofus):
            username="student{num:03d}".format(num=i)
            password = create_user(username, i)
            f.write("{user},{passwd}\n".format(user=username, passwd=password))

