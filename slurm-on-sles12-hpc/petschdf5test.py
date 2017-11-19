#!/usr/bin/env python3                                                                                                  

import sys
import numpy
import petsc4py
petsc4py.init(sys.argv)
from petsc4py import PETSc

def initialise(dm, field):
    field_ = dm.getVecArray(field)
    (zs, ze), (ys, ye), (xs, xe) = dm.getRanges()
    sizes = dm.getSizes()
    for z in range(zs,ze):
        for y in range(ys,ye):
            start = (xs + (y)*sizes[2] +
                     (z)*sizes[1]*sizes[2])
            stop = start + (xe-xs)
        field_[z,y,:] = numpy.arange(start, stop, step=1)**2
    return

OptDB = PETSc.Options()

stype = PETSc.DMDA.StencilType.BOX
ssize = 1

bx    = PETSc.DMDA.BoundaryType.PERIODIC
by    = PETSc.DMDA.BoundaryType.PERIODIC
bz    = PETSc.DMDA.BoundaryType.PERIODIC

m = OptDB.getInt('m', PETSc.DECIDE)
n = OptDB.getInt('n', PETSc.DECIDE)
p = OptDB.getInt('p', PETSc.DECIDE)

comm = PETSc.COMM_WORLD

dm = PETSc.DMDA().create(dim=3, sizes = (-6,-8,-5), proc_sizes=(m,n,p),
                         boundary_type=(bx,by,bz), stencil_type=stype,
                         stencil_width = ssize, dof = 1, comm = comm,
                         setup = False)
dm.setFromOptions()
dm.setUp()
data1 = dm.createGlobalVector()
data1.name = "data"
data2 = data1.duplicate()
data2.name = "data"
initialise(dm, data1)

FILENAME="/share/data/juhaj/test.h5"
vwr=PETSc.Viewer().createHDF5(FILENAME, mode=PETSc.Viewer.Mode.WRITE)
data1.view(vwr)
vwr.destroy()

vwr2=PETSc.Viewer().createHDF5(FILENAME, mode=PETSc.Viewer.Mode.READ)
data2.load(vwr2)

PETSc.Sys.syncPrint("Are they equal? " + ["No!", "Yes!"][data1.equal(data2)])
