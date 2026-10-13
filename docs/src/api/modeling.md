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

## Orders and lookup tables

A permutation places `n` items in `n` slots, one item per slot, both numbered
from 1: for a route, the items are the stops and the slots the visits. Its
[`item_at`](@ref) and [`slot_of`](@ref) are expressions whose values the service
chooses, and a [`lookup_table`](@ref) indexed with them reads data at the
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
