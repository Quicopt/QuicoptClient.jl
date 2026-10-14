# Modeling

Turn a JuMP model into a Quicopt `Program` and encode it to bytes.

```@docs
QuicoptClient.import_model
QuicoptClient.encode
```

## Stochastic models

A stochastic model is an ordinary JuMP model with two decorations: variables
given a *distribution*, and *aggregators* closing every stochastic subexpression
before it reaches the objective or a constraint root.

```julia
using QuicoptClient, JuMP

m = Model()
@variable(m, 0 <= x <= 200)            # decision: how much to stock
@variable(m, demand)                   # random: what will be asked for
set_distribution(m, demand, :normal, 100.0, 15.0)
set_scenarios(m, 512; seed = 42)

@objective(m, Min, 3x + 10 * expectation(max(demand - x, 0)))
result = solve(m)
```

Using `demand` twice refers to the *same* draw — one name is one random
variable; declare independent ones as separate variables.
These models solve through the service only: the aggregator heads are symbolic,
so attaching a local optimizer fails with an unsupported-operator error.

A chance constraint bounds a probability, so the comparison against the
threshold is an argument of [`prob`](@ref) rather than part of its name — that
way it can only attach to the quantity, not to the probability the constraint is
already bounding:

```julia
@constraint(m, prob(demand - x, ≤, 0) >= 0.9)   # stock out in ≤ 10% of scenarios
```

```@docs
QuicoptClient.set_distribution
QuicoptClient.set_scenarios
QuicoptClient.expectation
QuicoptClient.cvar
QuicoptClient.prob
```

## Orderings and lookup tables

A permutation places items in as many slots, one item per slot, both numbered
from 1: for a route, the items are the stops and the slots the visits.
Its [`item_at`](@ref) and [`slot_of`](@ref) are expressions whose values the
service chooses, and a [`lookup_table`](@ref) indexed with them reads data at the
positions they pick. The result carries each permutation's arrangement both ways
round, as `result.structures.<name>.item_at` and `.slot_of`. A model with a
permutation or a lookup table is solved by a search, so its status is
`"heuristic"`.

```@docs
QuicoptClient.permutation
QuicoptClient.Permutation
QuicoptClient.item_at
QuicoptClient.slot_of
QuicoptClient.precede!
QuicoptClient.lookup_table
QuicoptClient.LookupTable
```

## Minimum loads, fees and blocks

A variable declared with JuMP's `Semicontinuous(lower, upper)` or
`Semiinteger(lower, upper)` set is 0 or within the set's range, and nothing in
between: a delivery of none, or of at least a minimum load. The range is the
variable's bounds, so both ends must be finite and the variable carries no other
bound. [`active`](@ref) is 1 when such a variable is not 0, which turns a fixed
fee into one term.

A fee due once a total passes a threshold is JuMP's `ifelse` over a comparison,
written inside a JuMP macro, where a comparison of variables is an expression:
`ifelse(sum(ship[w, :]) >= 1, opening[w], 0)`. Any of `>=`, `<=`, `>`, `<` and
`==` works, and `min` and `max` cap or floor an expression in the same spirit.

A [`block`](@ref) names the variables of one subproblem, such as one customer's
deliveries. Every solution the service returns satisfies the constraints that
involve only one block's variables.

```@docs
QuicoptClient.active
QuicoptClient.block
```

## Groups

A partition puts each item into one of several parts, both numbered from 1:
people into teams, jobs onto machines. Its [`part_of`](@ref) is the part
an item is in and its [`size_of`](@ref) how many items a part holds. The result carries
both, as `result.structures.<name>.part_of` and `.size_of`.

```@docs
QuicoptClient.partition
QuicoptClient.Partition
QuicoptClient.part_of
QuicoptClient.size_of
```
