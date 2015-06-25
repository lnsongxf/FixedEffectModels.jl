# An Abstract VCE model contains object needed to compute errors. Important methods are residuals, regressors, number of obs, degree of freedom

abstract AbstractVcovData
residuals(x::AbstractVcovData) = error("not defined")
regressors(x::AbstractVcovData) = error("not defined")
nobs(x::AbstractVcovData) = size(regressors(x), 1)
df_residual(x::AbstractVcovData) = size(regressors(x), 1)
function hatmatrix(x::AbstractVcovData) 
	temp = At_mul_B(regressors(x), regressors(x))
	H = inv(cholfact!(temp))
end


immutable type VcovData <: AbstractVcovData
	regressors::Matrix{Float64} # If weight, matrix should be X\sqrt{W}
	residuals::Vector{Float64}
	nobs::Int
	df_residual::Int
end
residuals(x::VcovData) = x.residuals
regressors(x::VcovData) = x.regressors
nobs(x::VcovData) = x.nobs
df_residual(x::VcovData) = x.df_residual

immutable type VcovDataHat <: AbstractVcovData
	regressors::Matrix{Float64} # If weight, matrix should be X\sqrt{W}
	hatmatrix::Matrix{Float64} # If weight, matrix should be X\sqrt{W}
	residuals::Vector{Float64}
	nobs::Int
	df_residual::Int
end
residuals(x::VcovDataHat) = x.residuals
regressors(x::VcovDataHat) = x.regressors
hatmatrix(x::VcovDataHat) = x.hatmatrix
nobs(x::VcovDataHat) = x.nobs
df_residual(x::VcovDataHat) = x.df_residual

# convert a linear model into VcovDataHat
function VcovDataHat(x::LinearModel) 
	VcovDataHat(x.pp.X, inv(cholfact(x)), residuals(x), size(x.pp.X, 1), size(x.pp.X, 2))
end



# An AbstractVCE  should have two methods: allvars that returns variables needed in the dataframe, and vcov, that returns a covariance matrix
abstract AbstractVcov
allvars(x::AbstractVcov) = nothing
vcov(x::AbstractVcovData, v::AbstractVcov) = error("not defined")
vcov(x::AbstractVcovData, v::AbstractVcov, df::AbstractDataFrame) = vcov(x::AbstractVcovData, v::AbstractVcov)


immutable type VcovSimple <: AbstractVcov 
end

vcov(x::VcovData, t::VcovSimple) = vcov(x)



#
# simple
#


function vcov(x::AbstractVcovData, t::VcovSimple)
 	hatmatrix(x) * (sum(residuals(x).^2)/  df_residual(x))
end


#
# White
#


immutable type VcovWhite <: AbstractVcov 
end

function vcov(x::AbstractVcovData, t::VcovWhite) 
	Xu = broadcast(*,  regressors(x), residuals(x))
	S = At_mul_B(Xu, Xu)
	scale!(S, nobs(x)/df_residual(x))
	sandwich(x, S) 
end


function sandwich(x::AbstractVcovData, S::Matrix{Float64})
	H = hatmatrix(x)
	H * S * H
end


#
# HAC
#

immutable type VcovHac <: AbstractVcov
	time::Symbol
	nlag::Int
	weightfunction::Function
end

# default uses the Bartlett kernel 
VcovHac(time, nlag) = VcovHac(time, nlag, (i, n) -> 1 - i/(n+1))

allvars(x::VcovHac) = x.time

function vcov(x::AbstractVcovData, v::VcovHac, df)
	time = df[v.time]
	nlag = v.nlag
	weights = map(i -> v.weightfunction(i, nlag), [1:nlag])

	Xu = broadcast(*,  regressors(x), residuals(x))
	rhos = Array(Matrix{Float64}, nlag)

	# 1 is juste White
	rhos[1] = At_mul_B(Xu, Xu)	

	for i in 2:nlags
		lagx = lag(x, i, time)
		isna = sum(isna(x), 2) + sum(isna(lagx), 2)
		rhos[i] = At_mul_B(x[!isna, :], lagx[!isna, :]) +  At_mul_B(lagx[!isna, :], x[!isna, :]) 
		scale!(rhos[i], weights[i] * (size(x, 1) - i) / (size(x, 1) -i - lenth(isna)))
	end
	S = sum(rhos)
	scale!(S, nobs(x)/df_residual(x))
	sandwich(x, S) 
end

function lag(x::Array, n::Int, time::Vector) 
	index = findin(time - n, time)
	lagx = DataArray(eltype(x), dim(x))
	lagx[index] = x[index]
	return(lagx)
end

#
# Cluster
#

immutable type VcovCluster  <: AbstractVcov
	clusters::Vector{Symbol}
end
VcovCluster(x::Symbol) = VcovCluster([x])

allvars(x::VcovCluster) = x.clusters

# Cameron, Gelbach, & Miller (2011).
function vcov(x::AbstractVcovData, v::VcovCluster, df::AbstractDataFrame) 
	df = df[v.clusters]
	S = fill(zero(Float64), (size(regressors(x), 2), size(regressors(x), 2)))
	for i in 1:length(v.clusters)
		for c in combinations(v.clusters, i)
			if rem(length(c), 2) == 1
				S += helper_cluster(x, group(df[c]))
			else
				S -= helper_cluster(x, group(df[c]))
			end
		end
	end
	scale!(S, (nobs(x) - 1) / df_residual(x))
	sandwich(x, S)
end

function helper_cluster(x::AbstractVcovData, f::PooledDataArray)
	X = regressors(x)
	residuals = residuals(x)
	pool = f.pool
	refs = f.refs

	# if only one obs by pool, use White, as in Petersen (2009) & Thomson (2011)
	if length(pool) == size(X, 1)
		Xu = broadcast(*,  regressors(x), residuals(x))
		At_mul_B(Xu, Xu)
		return(At_mul_B(Xu, Xu))
	else
		# otherwise
		X2 = fill(zero(Float64), (size(X, 2), length(f.pool)))
		for j in 1:size(X, 2)
			for i in 1:size(X, 1)
				@inbounds X2[j, refs[i]] += X[i, j] * residuals[i]
			end
		end
		out = A_mul_Bt(X2, X2)
		scale!(out, length(pool) / length(pool - 1))
		return(out)
	end
end







