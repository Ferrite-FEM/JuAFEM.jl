using JuAFEM
using Tensors
using Test
using ForwardDiff
import SHA
using Random
using LinearAlgebra
using SparseArrays
using BlockArrays

include("test_utils.jl")
include("test_interpolations.jl")
include("test_cellvalues.jl")
include("test_facevalues.jl")
include("test_quadrules.jl")
include("test_assemble.jl")
include("test_dofs.jl")
include("test_constraints.jl")
include("test_grid_dofhandler_vtk.jl")
include("test_mixeddofhandler.jl")
include("test_l2_projection.jl")
# include("test_notebooks.jl")
include("test_examples.jl")

using GLMakie
using AbstractPlotting: mesh, mesh!, surface, surface!, arrows, arrows!, scatter, lines, scatterlines, wireframe!, plot
include("test_plotting.jl")
