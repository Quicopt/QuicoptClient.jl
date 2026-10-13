# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# ── a `Program` ↔ bytes: the generated protobuf structs ─────────────────────
#
# A model *is* the ProtoBuf.jl-generated `Program` (`src/proto/`, regenerated from
# the published `program.proto` by `gen/gen.jl`). These small constructors build
# its nodes; `encode` turns a `Program` into (v1) bytes. Protobuf omits fields
# holding their default value and does not fix map order, so two encodings of one
# model can differ byte for byte while meaning exactly the same thing to the
# service (a separate verification harness proves that equivalence).

"""
    _pb

Alias for the ProtoBuf.jl-generated module `quicopt.modeler.v1`, whose structs
(`Program`, `Expression`, `Constraint`, …) are what a model is made of. Aliased for
brevity throughout the encoder and importer.
"""
const _pb = quicopt.modeler.v1

"""
    _elem(e) -> IndexElem

Wrap one coordinate of an index tuple as an `IndexElem`: an `Integer` becomes a
concrete `:int` coordinate, a `Symbol` a bound-index `:name`.
"""
_elem(e::Integer) = _pb.IndexElem(kind = PB.OneOf(:int,  Int64(e)))
_elem(e::Symbol)  = _pb.IndexElem(kind = PB.OneOf(:name, String(e)))

"""
    _index(t) -> Index

Build an `Index` from a coordinate tuple `t`, wrapping each entry with `_elem`.
An empty tuple yields the scalar (zero-dimensional) index.
"""
_index(t::Tuple)  = _pb.Index(elems = _pb.IndexElem[_elem(e) for e in t])

"""
    _const(v) -> Expression

A constant expression node holding the `Float64` value `v`.
"""
_const(v::Real)                     = _pb.Expression(node = PB.OneOf(:constant, Float64(v)))

"""
    _var(name, idx=()) -> Expression

A variable-reference expression node for `name` at coordinate tuple `idx` (empty for
a scalar variable).
"""
_var(name::Symbol, idx::Tuple = ()) = _pb.Expression(node = PB.OneOf(:var, _pb.VarRef(name = String(name), index = _index(idx))))

"""
    _apply(op, args) -> Expression

An operator-application expression node: operator `op` (a `Symbol`, stored by name)
applied to the child expressions `args`.
"""
_apply(op::Symbol, args::Vector)    = _pb.Expression(node = PB.OneOf(:apply, _pb.Apply(op = String(op), args = args)))

"""
    _source_ref(name) -> Expression

A stochastic-source reference node. Identity lives in the name: every
`SourceRef` carrying the same name denotes the same random variable, so copies
of a subtree never mint independent draws.
"""
_source_ref(name::Symbol) = _pb.Expression(node = PB.OneOf(:source, _pb.SourceRef(name = String(name))))

"""
    _struct_ref(name) -> Expression

A reference to a declared structure, such as a permutation, by name. It appears
only as the second argument of the operator reading one of the structure's parts.
"""
_struct_ref(name::Symbol) = _pb.Expression(node = PB.OneOf(:structure, _pb.StructRef(name = String(name))))

"""
    _table_ref(param, index) -> Expression

The entry of the parameter table `param` at positions given by the expressions
`index` (one or two), read when the model is solved.
"""
_table_ref(param::Symbol, index::Vector) =
    _pb.Expression(node = PB.OneOf(:table, _pb.TableRef(param = String(param), index = index)))

"""
    _iszero(e) -> Bool

Whether expression `e` is the additive-identity constant `Const(0.0)` — the test
`_sum` uses to prune vanishing terms.
"""
_iszero(e) = e.node !== nothing && e.node.name === :constant && e.node[] == 0.0

"""
    _zero() -> ConSet

The `Zero` constraint set (equality: the residual must vanish).
"""
_zero()               = _pb.ConSet(kind = PB.OneOf(:zero,   _pb.Zero()))

"""
    _nonneg() -> ConSet

The `Nonneg` constraint set (inequality: the residual must be nonnegative).
"""
_nonneg()             = _pb.ConSet(kind = PB.OneOf(:nonneg, _pb.Nonneg()))

"""
    _scalarbound(x) -> Bound

A scalar variable `Bound` carrying the `Float64` value `x`. `±Inf` passes through as
a free (unbounded) direction.
"""
_scalarbound(x::Real) = _pb.Bound(kind = PB.OneOf(:scalar, Float64(x)))

"""
    encode(prog) -> Vector{UInt8}

Encode a `Program` to the (v1) bytes the service reads. Two encodings of one model
can differ byte for byte and still mean the same thing — compare decoded
`Program`s, never raw bytes.
"""
function encode(prog::_pb.Program)
    io = IOBuffer()
    PB.encode(PB.ProtoEncoder(io), prog)
    take!(io)
end
