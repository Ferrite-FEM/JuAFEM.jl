# Helpers to get the correct types for FunctionValues for the given function and, if needed, geometric interpolations. 
struct SInterpolationDims{rdim,sdim} end
struct VInterpolationDims{rdim,sdim,vdim} end
function InterpolationDims(::ScalarInterpolation, ip_geo::VectorizedInterpolation{sdim}) where sdim
    return SInterpolationDims{getdim(ip_geo),sdim}()
end
function InterpolationDims(::VectorInterpolation{vdim}, ip_geo::VectorizedInterpolation{sdim}) where {vdim,sdim}
    return VInterpolationDims{getdim(ip_geo),sdim,vdim}()
end

typeof_N(::Type{T}, ::SInterpolationDims) where T = T
typeof_N(::Type{T}, ::VInterpolationDims{<:Any,dim,dim}) where {T,dim} = Vec{dim,T}
typeof_N(::Type{T}, ::VInterpolationDims{<:Any,<:Any,vdim}) where {T,vdim} = SVector{vdim,T} # Why not ::Vec here?

typeof_dNdx(::Type{T}, ::SInterpolationDims{dim,dim}) where {T,dim} = Vec{dim,T}
typeof_dNdx(::Type{T}, ::SInterpolationDims{<:Any,sdim}) where {T,sdim} = SVector{sdim,T} # Why not ::Vec here?
typeof_dNdx(::Type{T}, ::VInterpolationDims{dim,dim,dim}) where {T,dim} = Tensor{2,dim,T}
typeof_dNdx(::Type{T}, ::VInterpolationDims{<:Any,sdim,vdim}) where {T,sdim,vdim} = SMatrix{vdim,sdim,T} # If vdim=sdim!=rdim Tensor would be possible...

typeof_dNdξ(::Type{T}, ::SInterpolationDims{dim,dim}) where {T,dim} = Vec{dim,T}
typeof_dNdξ(::Type{T}, ::SInterpolationDims{rdim}) where {T,rdim} = SVector{rdim,T} # Why not ::Vec here?
typeof_dNdξ(::Type{T}, ::VInterpolationDims{dim,dim,dim}) where {T,dim} = Tensor{2,dim,T}
typeof_dNdξ(::Type{T}, ::VInterpolationDims{rdim,<:Any,vdim}) where {T,rdim,vdim} = SMatrix{vdim,rdim,T} # If vdim=rdim!=sdim Tensor would be possible...

struct FunctionValues{IP, N_t, dNdx_t, dNdξ_t}
    ip::IP          # ::Interpolation
    N_x::N_t        # ::AbstractMatrix{Union{<:Tensor,<:Number}}
    N_ξ::N_t        # ::AbstractMatrix{Union{<:Tensor,<:Number}}
    dNdx::dNdx_t    # ::AbstractMatrix{Union{<:Tensor,<:StaticArray}}
    dNdξ::dNdξ_t    # ::AbstractMatrix{Union{<:Tensor,<:StaticArray}}
end
function FunctionValues(::Type{T}, ip::Interpolation, qr::QuadratureRule, ip_geo::VectorizedInterpolation) where T
    ip_dims = InterpolationDims(ip, ip_geo)
    N_t = typeof_N(T, ip_dims)
    dNdx_t = typeof_dNdx(T, ip_dims)
    dNdξ_t = typeof_dNdξ(T, ip_dims)
    n_shape = getnbasefunctions(ip)
    n_qpoints = getnquadpoints(qr)
    
    N_ξ  = zeros(N_t,    n_shape, n_qpoints)
    if isa(get_mapping_type(ip), IdentityMapping)
        N_x = N_ξ
    else
        N_x  = zeros(N_t,    n_shape, n_qpoints)
    end
    dNdξ = zeros(dNdξ_t, n_shape, n_qpoints)
    dNdx = fill(zero(dNdx_t) * T(NaN), n_shape, n_qpoints)
    fv = FunctionValues(ip, N_x, N_ξ, dNdx, dNdξ)
    precompute_values!(fv, qr) # Precompute N and dNdξ
    return fv
end
function Base.copy(v::FunctionValues)
    N_ξ_copy = copy(v.N_ξ)
    N_x_copy = v.N_ξ === v.N_x ? N_ξ_copy : copy(v.N_x) # Preserve aliasing
    return FunctionValues(copy(v.ip), N_x_copy, N_ξ_copy, copy(v.dNdx), copy(v.dNdξ))
end

function precompute_values!(fv::FunctionValues, qr::QuadratureRule)
    n_shape = getnbasefunctions(fv.ip)
    for (qp, ξ) in pairs(getpoints(qr))
        for i in 1:n_shape
            fv.dNdξ[i, qp], fv.N_ξ[i, qp] = shape_gradient_and_value(fv.ip, ξ, i)
        end
    end
end

getnbasefunctions(funvals::FunctionValues) = size(funvals.N_x, 1)
@propagate_inbounds shape_value(funvals::FunctionValues, q_point::Int, base_func::Int) = funvals.N_x[base_func, q_point]
@propagate_inbounds shape_gradient(funvals::FunctionValues, q_point::Int, base_func::Int) = funvals.dNdx[base_func, q_point]
@propagate_inbounds shape_symmetric_gradient(funvals::FunctionValues, q_point::Int, base_func::Int) = symmetric(shape_gradient(funvals, q_point, base_func))

get_function_interpolation(funvals::FunctionValues) = funvals.ip

shape_value_type(funvals::FunctionValues) = eltype(funvals.N_x)
shape_gradient_type(funvals::FunctionValues) = eltype(funvals.dNdx)

# Mapping types 
struct IdentityMapping end 
struct CovariantPiolaMapping end 
struct ContravariantPiolaMapping end 
# Not yet implemented:
# struct DoubleCovariantPiolaMapping end 
# struct DoubleContravariantPiolaMapping end 

get_mapping_type(fv::FunctionValues) = get_mapping_type(fv.ip)

requires_hessian(::IdentityMapping) = false
requires_hessian(::ContravariantPiolaMapping) = true
requires_hessian(::CovariantPiolaMapping) = true

# Support for embedded elements
calculate_Jinv(J::Tensor{2}) = inv(J)
calculate_Jinv(J::SMatrix) = pinv(J)

# Hotfix to get the dots right for embedded elements until mixed tensors are merged.
# Scalar/Vector interpolations with sdim == rdim (== vdim)
@inline dothelper(A, B) = A ⋅ B
# Vector interpolations with sdim == rdim != vdim
@inline dothelper(A::SMatrix{vdim, dim}, B::Tensor{2, dim}) where {vdim, dim} = A * SMatrix{dim, dim}(B)
# Scalar interpolations with sdim > rdim
@inline dothelper(A::SVector{rdim}, B::SMatrix{rdim, sdim}) where {rdim, sdim} = B' * A
# Vector interpolations with sdim > rdim
@inline dothelper(B::SMatrix{vdim, rdim}, A::SMatrix{rdim, sdim}) where {vdim, rdim, sdim} = B * A

@inline function apply_mapping!(funvals::FunctionValues, args...)
    return apply_mapping!(funvals, get_mapping_type(funvals), args...)
end

@inline function apply_mapping!(funvals::FunctionValues, ::IdentityMapping, q_point::Int, mapping_values, args...)
    Jinv = calculate_Jinv(getjacobian(mapping_values))
    @inbounds for j in 1:getnbasefunctions(funvals)
        #funvals.dNdx[j, q_point] = funvals.dNdξ[j, q_point] ⋅ Jinv # TODO via Tensors.jl
        funvals.dNdx[j, q_point] = dothelper(funvals.dNdξ[j, q_point], Jinv)
    end
    return nothing
end

@inline function apply_mapping!(funvals::FunctionValues, ::CovariantPiolaMapping, q_point::Int, mapping_values, cell)
    H = gethessian(mapping_values)
    Jinv = inv(getjacobian(mapping_values))
    @inbounds for j in 1:getnbasefunctions(funvals)
        d = get_direction(funvals.ip, j, cell)
        dNdξ = funvals.dNdξ[j, q_point]
        N_ξ = funvals.N_ξ[j, q_point]
        funvals.N_x[j, q_point] = d*(N_ξ ⋅ Jinv)
        funvals.dNdx[j, q_point] = d*(Jinv' ⋅ dNdξ ⋅ Jinv - Jinv' ⋅ (N_ξ ⋅ Jinv ⋅ H ⋅ Jinv))
    end
    return nothing
end

@inline function apply_mapping!(funvals::FunctionValues, ::ContravariantPiolaMapping, q_point::Int, mapping_values, cell)
    H = gethessian(mapping_values)
    J = getjacobian(mapping_values)
    Jinv = inv(J)
    detJ = det(J)
    I2 = one(J)
    H_Jinv = H⋅Jinv
    A1 = (H_Jinv ⊡ (otimesl(I2,I2))) / detJ
    A2 = (Jinv' ⊡ H_Jinv) / detJ
    @inbounds for j in 1:getnbasefunctions(funvals)
        d = get_direction(funvals.ip, j, cell)
        dNdξ = funvals.dNdξ[j, q_point]
        N_ξ = funvals.N_ξ[j, q_point]
        funvals.N_x[j, q_point] = d*(J ⋅ N_ξ)/detJ
        funvals.dNdx[j, q_point] = d*(J ⋅ dNdξ ⋅ Jinv/detJ + A1 ⋅ N_ξ - (J ⋅ N_ξ) ⊗ A2)
    end
    return nothing
end
