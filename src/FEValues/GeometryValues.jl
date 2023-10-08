struct MappingValues{JT, HT<:Union{Nothing,AbstractTensor{3}}}
    J::JT # dx/dξ # Jacobian
    H::HT # dJ/dξ # Hessian
end
@inline getjacobian(mv::MappingValues) = mv.J 
@inline gethessian(mv::MappingValues{<:Any,<:AbstractTensor}) = mv.H

# This will be needed for optimizing away the hessian calculation/updates
# for cases when this is known to be zero (due to the geometric interpolation)
#@inline gethessian(::MappingValues{JT,Nothing}) where JT = _make_hessian(JT)
#@inline _make_hessian(::Type{Tensor{2,dim,T}}) where {dim,T} = zero(Tensor{3,dim,T})

struct RequiresHessian{B} end
RequiresHessian(B::Bool) = RequiresHessian{B}()
function RequiresHessian(ip_fun::Interpolation, ip_geo::Interpolation)
    # Leave ip_geo as input, because for later the hessian can also be avoided 
    # for fully linear geometric elements (e.g. triangle and tetrahedron)
    # This optimization is left out for now. 
    RequiresHessian(requires_hessian(get_mapping_type(ip_fun)))
end

struct GeometryValues{IP, M_t, dMdξ_t, d2Mdξ2_t}
    ip::IP             # ::Interpolation                Geometric interpolation 
    M::M_t             # ::AbstractVector{<:Number}     Values of geometric shape functions
    dMdξ::dMdξ_t       # ::AbstractVector{<:Vec}        Gradients of geometric shape functions in ref-domain
    d2Mdξ2::d2Mdξ2_t   # ::AbstractVector{<:Tensor{2}}  Hessians of geometric shape functions in ref-domain
                       # ::Nothing                      When hessians are not required
end
function GeometryValues(::Type{T}, ip::ScalarInterpolation, qr::QuadratureRule, ::RequiresHessian{RH}) where {T,RH}
    n_shape = getnbasefunctions(ip)
    n_qpoints = getnquadpoints(qr)
    VT   = Vec{getdim(ip),T}
    M    = zeros(T,  n_shape, n_qpoints)
    dMdξ = zeros(VT, n_shape, n_qpoints)
    if RH
        HT = Tensor{2,getdim(ip),T}
        dM2dξ2 = zeros(HT, n_shape, n_qpoints)
    else
        dM2dξ2 = nothing
    end
    for (qp, ξ) in pairs(getpoints(qr))
        for i in 1:n_shape
            if RH
                dM2dξ2[i, qp], dMdξ[i, qp], M[i, qp] = shape_hessian_gradient_and_value(ip, ξ, i)
            else
                dMdξ[i, qp], M[i, qp] = shape_gradient_and_value(ip, ξ, i)
            end
        end
    end
    return GeometryValues(ip, M, dMdξ, dM2dξ2)
end
function Base.copy(v::GeometryValues)
    d2Mdξ2_copy = v.d2Mdξ2 === nothing ? nothing : copy(v.d2Mdξ2)
    return GeometryValues(copy(v.ip), copy(v.M), copy(v.dMdξ), d2Mdξ2_copy)
end

getngeobasefunctions(geovals::GeometryValues) = size(geovals.M, 1)
@propagate_inbounds geometric_value(geovals::GeometryValues, q_point::Int, base_func::Int) = geovals.M[base_func, q_point]
get_geometric_interpolation(geovals::GeometryValues) = geovals.ip

RequiresHessian(geovals::GeometryValues) = RequiresHessian(geovals.d2Mdξ2 !== nothing)

# Hot-fixes to support embedded elements before MixedTensors are available
# See https://github.com/Ferrite-FEM/Tensors.jl/pull/188
@inline otimes_helper(x::Vec{dim}, dMdξ::Vec{dim}) where dim = x ⊗ dMdξ
@inline function otimes_helper(x::Vec{sdim}, dMdξ::Vec{rdim}) where {sdim, rdim}
    SMatrix{sdim,rdim}((x[i]*dMdξ[j] for i in 1:sdim, j in 1:rdim)...)
end
# End of embedded hot-fixes

# For creating initial value
function otimes_returntype(#=typeof(x)=#::Type{<:Vec{sdim,Tx}}, #=typeof(dMdξ)=#::Type{<:Vec{rdim,TM}}) where {sdim,rdim,Tx,TM}
    return SMatrix{sdim,rdim,promote_type(Tx,TM)}
end
function otimes_returntype(#=typeof(x)=#::Type{<:Vec{dim,Tx}}, #=typeof(dMdξ)=#::Type{<:Vec{dim,TM}}) where {dim, Tx, TM}
    return Tensor{2,dim,promote_type(Tx,TM)}
end
function otimes_returntype(#=typeof(x)=#::Type{<:Vec{dim,Tx}}, #=typeof(d2Mdξ2)=#::Type{<:Tensor{2,dim,TM}}) where {dim, Tx, TM}
    return Tensor{3,dim,promote_type(Tx,TM)}
end

@propagate_inbounds calculate_mapping(geovals::GeometryValues, args...) = calculate_mapping(RequiresHessian(geovals), geovals, args...)

@inline function calculate_mapping(::RequiresHessian{false}, geo_values::GeometryValues, q_point, x)
    #fecv_J = zero(Tensors.getreturntype(⊗, eltype(x), eltype(geo_values.dMdξ)))
    fecv_J = zero(otimes_returntype(eltype(x), eltype(geo_values.dMdξ)))
    @inbounds for j in 1:getngeobasefunctions(geo_values)
        #fecv_J += x[j] ⊗ geo_values.dMdξ[j, q_point]
        fecv_J += otimes_helper(x[j], geo_values.dMdξ[j, q_point])
    end
    return MappingValues(fecv_J, nothing)
end

@inline function calculate_mapping(::RequiresHessian{true}, geo_values::GeometryValues, q_point, x)
    J = zero(otimes_returntype(eltype(x), eltype(geo_values.dMdξ)))
    H = zero(otimes_returntype(eltype(x), eltype(geo_values.d2Mdξ2)))
    @inbounds for j in 1:getngeobasefunctions(geo_values)
        J += x[j] ⊗ geo_values.dMdξ[j, q_point]
        H += x[j] ⊗ geo_values.d2Mdξ2[j, q_point]
    end
    return MappingValues(J, H)
end

calculate_detJ(J::Tensor{2}) = det(J)
calculate_detJ(J::SMatrix) = embedding_det(J)

# Embedded

"""
    embedding_det(J::SMatrix{3, 2})

Embedding determinant for surfaces in 3D.

TLDR: "det(J) =" ||∂x/∂ξ₁ × ∂x/∂ξ₂||₂

The transformation theorem for some function f on a 2D surface in 3D space leads to
  ∫ f ⋅ dS = ∫ f ⋅ (∂x/∂ξ₁ × ∂x/∂ξ₂) dξ₁dξ₂ = ∫ f ⋅ n ||∂x/∂ξ₁ × ∂x/∂ξ₂||₂ dξ₁dξ₂
where ||∂x/∂ξ₁ × ∂x/∂ξ₂||₂ is "detJ" and n is the unit normal.
See e.g. https://scicomp.stackexchange.com/questions/41741/integration-of-d-1-dimensional-functions-on-finite-element-surfaces for simple explanation.
For more details see e.g. the doctoral thesis by Mirza Cenanovic **Tangential Calculus** [Cenanovic2017](@cite).
"""
embedding_det(J::SMatrix{3,2}) = norm(J[:,1] × J[:,2])

"""
    embedding_det(J::Union{SMatrix{2, 1}, SMatrix{3, 1}})

Embedding determinant for curves in 2D and 3D.

TLDR: "det(J) =" ||∂x/∂ξ||₂

The transformation theorem for some function f on a 1D curve in 2D and 3D space leads to
  ∫ f ⋅ dE = ∫ f ⋅ ∂x/∂ξ dξ = ∫ f ⋅ t ||∂x/∂ξ||₂ dξ
where ||∂x/∂ξ||₂ is "detJ" and t is "the unit tangent".
See e.g. https://scicomp.stackexchange.com/questions/41741/integration-of-d-1-dimensional-functions-on-finite-element-surfaces for simple explanation.
"""
embedding_det(J::Union{SMatrix{2, 1}, SMatrix{3, 1}}) = norm(J)
